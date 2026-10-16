import AppKit
import ImageCaptureCore
import ImageIO
import UniformTypeIdentifiers

/// A file on a camera or phone, as the import window lists it.
nonisolated struct ImportDeviceFile: Sendable, Equatable {
    var id: String
    var name: String
    var size: Int64
    var date: Date
    var isVideo: Bool
}

/// A connected camera or phone the import window can read (under Devices). Photos on it have no path
/// on disk, so the import window lists them by `ImportDevices.url(of:on:)` and downloads the checked
/// ones before importing them as copies.
@MainActor
protocol ImportDevice: AnyObject {
    var id: String { get }
    var name: String { get }
    /// "iphone", "ipad" or "camera".
    var symbol: String { get }
    /// "iPhone", "Camera".
    var kindName: String { get }
    /// The device's photos and videos. Throws ``ImportDevices/DeviceError/locked`` for a phone that needs
    /// unlocking (and trusting this Mac) first.
    func files() async throws -> [ImportDeviceFile]
    func thumbnail(of fileID: String, maxPixelSize: Int) async -> CGImage?
    /// Downloads the files into `folder`, calling `progress` with how many are done. Returns their URLs.
    func download(_ fileIDs: [String], to folder: URL, progress: @escaping (Int) -> Void) async throws -> [URL]
    func eject()
}

/// The connected cameras and phones (through ImageCaptureCore), and the `pixelloupe-device://` URLs
/// that stand for their files in the import window.
@MainActor
final class ImportDevices: NSObject {
    static let shared = ImportDevices()
    /// Posted when a device connects or disconnects.
    static let didChangeNotification = Notification.Name("ImportDevicesDidChange")
    nonisolated static let scheme = "pixelloupe-device"

    enum DeviceError: LocalizedError {
        case locked(String)
        case disconnected
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .locked(let kind): "Unlock the \(kind) and choose Trust on it to see its photos."
            case .disconnected: "The device was disconnected."
            case .downloadFailed(let name): "\(name) couldn't be downloaded."
            }
        }
    }

    private(set) var devices: [any ImportDevice] = []
    private var browser: ICDeviceBrowser?

    /// Starts watching for cameras and phones (once the import window is on screen).
    func start() {
        guard browser == nil else { return }
        let browser = ICDeviceBrowser()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
        self.browser = browser
    }

    func add(_ device: any ImportDevice) {
        guard !devices.contains(where: { $0.id == device.id }) else { return }
        devices.append(device)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    func remove(id: String) {
        devices.removeAll { $0.id == id }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    func device(id: String) -> (any ImportDevice)? {
        devices.first { $0.id == id }
    }

    // MARK: URLs

    /// The URL standing for a whole device (its source in the import window).
    nonisolated static func url(of deviceID: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "device"
        components.path = "/" + deviceID
        return components.url!
    }

    /// The URL standing for one file on a device.
    nonisolated static func url(of file: ImportDeviceFile, on deviceID: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "device"
        components.path = "/\(deviceID)/\(file.id)/\(file.name)"
        return components.url!
    }

    nonisolated static func isDeviceURL(_ url: URL?) -> Bool {
        url?.scheme == scheme
    }

    /// The device and file a URL stands for (no file for a whole device).
    nonisolated static func parse(_ url: URL) -> (deviceID: String, fileID: String?)? {
        guard isDeviceURL(url) else { return nil }
        let parts = url.path(percentEncoded: false).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let deviceID = parts.first else { return nil }
        return (deviceID, parts.count > 1 ? parts[1] : nil)
    }

    // MARK: Reading

    /// A device's files as import candidates (with the metadata the device gives), for the grid.
    func candidates(on deviceID: String) async throws -> [ImportService.Candidate] {
        guard let device = device(id: deviceID) else { throw DeviceError.disconnected }
        let root = Self.url(of: deviceID)
        return try await device.files().map { file in
            var metadata = ImageMetadata()
            metadata.captureDate = file.date
            metadata.isVideo = file.isVideo
            return ImportService.Candidate(
                source: .init(url: Self.url(of: file, on: deviceID), anchor: root),
                metadata: metadata, fileSize: file.size, fileDate: file.date)
        }
    }

    func thumbnail(for url: URL, maxPixelSize: Int) async -> CGImage? {
        guard let (deviceID, fileID) = Self.parse(url), let fileID, let device = device(id: deviceID) else { return nil }
        return await device.thumbnail(of: fileID, maxPixelSize: maxPixelSize)
    }

    /// Downloads the device files `urls` stand for into `folder`, in order.
    func download(_ urls: [URL], to folder: URL, progress: @escaping (Int) -> Void) async throws -> [URL] {
        guard let deviceID = urls.first.flatMap(Self.parse)?.deviceID, let device = device(id: deviceID) else {
            throw DeviceError.disconnected
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try await device.download(urls.compactMap { Self.parse($0)?.fileID }, to: folder, progress: progress)
    }
}

extension ImportDevices: @preconcurrency ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        // A memory card in a reader reaches ImageCaptureCore as a mass-storage "camera", but it's also a
        // mounted disk, listed as a card: it's listed once, not again here. (Its mount point stays
        // empty until a session is opened, so the transport type is what tells.)
        guard let camera = device as? ICCameraDevice, !Self.isMassStorage(camera.transportType) else { return }
        add(CameraImportDevice(camera))
    }

    /// Whether a device's transport is mass storage: a card or disk that's mounted as a volume.
    nonisolated static func isMassStorage(_ transportType: String?) -> Bool {
        transportType == ICDeviceTransport.transportTypeMassStorage.rawValue
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if let id = device.uuidString { remove(id: id) }
    }
}

/// A camera or phone connected over USB, read with ImageCaptureCore.
@MainActor
final class CameraImportDevice: NSObject, ImportDevice {
    private let camera: ICCameraDevice
    private var filesByID: [String: ICCameraFile] = [:]
    private var catalogWaiters: [CheckedContinuation<Void, Error>] = []
    private var isCatalogComplete = false

    init(_ camera: ICCameraDevice) {
        self.camera = camera
        super.init()
        camera.delegate = self
    }

    var id: String { camera.uuidString ?? camera.name ?? "camera" }
    var name: String { camera.name ?? kindName }

    var symbol: String {
        let product = (camera.productKind ?? "").lowercased()
        if product.contains("iphone") { return "iphone" }
        if product.contains("ipad") { return "ipad" }
        return "camera"
    }

    var kindName: String {
        switch symbol {
        case "iphone": "iPhone"
        case "ipad": "iPad"
        default: "Camera"
        }
    }

    func files() async throws -> [ImportDeviceFile] {
        if !camera.hasOpenSession { try await camera.requestOpenSession() }
        if camera.isAccessRestrictedAppleDevice || camera.isLocked { throw ImportDevices.DeviceError.locked(kindName) }
        if !isCatalogComplete {
            try await withCheckedThrowingContinuation { catalogWaiters.append($0) }
        }
        filesByID = [:]
        var files: [ImportDeviceFile] = []
        for (index, item) in (camera.mediaFiles ?? []).enumerated() {
            guard let file = item as? ICCameraFile, let name = file.name else { continue }
            let id = String(index)
            filesByID[id] = file
            let type = file.uti.flatMap { UTType($0) }
            files.append(ImportDeviceFile(
                id: id, name: name, size: Int64(file.fileSize),
                date: file.exifCreationDate ?? file.creationDate ?? Date(),
                isVideo: type?.conforms(to: .movie) ?? SupportedImageTypes.isVideo(URL(filePath: name))))
        }
        return files
    }

    func thumbnail(of fileID: String, maxPixelSize: Int) async -> CGImage? {
        guard let file = filesByID[fileID] else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: maxPixelSize]) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func download(_ fileIDs: [String], to folder: URL, progress: @escaping (Int) -> Void) async throws -> [URL] {
        var urls: [URL] = []
        for (index, fileID) in fileIDs.enumerated() {
            try Task.checkCancellation()
            guard let file = filesByID[fileID], let name = file.name else { throw ImportDevices.DeviceError.disconnected }
            let saved: String? = await withCheckedContinuation { continuation in
                _ = file.requestDownload(options: [.downloadsDirectoryURL: folder, .saveAsFilename: name, .overwrite: true]) { filename, _ in
                    continuation.resume(returning: filename)
                }
            }
            guard let saved else { throw ImportDevices.DeviceError.downloadFailed(name) }
            urls.append(folder.appending(path: saved))
            progress(index + 1)
        }
        return urls
    }

    func eject() {
        camera.requestEject()
    }

    fileprivate func catalogDidComplete(_ error: Error?) {
        isCatalogComplete = error == nil
        let waiters = catalogWaiters
        catalogWaiters = []
        for waiter in waiters {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }
}

extension CameraImportDevice: @preconcurrency ICCameraDeviceDelegate {
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        catalogDidComplete(nil)
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        if let error { catalogDidComplete(error) }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        isCatalogComplete = false
    }

    func didRemove(_ device: ICDevice) {
        catalogDidComplete(ImportDevices.DeviceError.disconnected)
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        NotificationCenter.default.post(name: ImportDevices.didChangeNotification, object: ImportDevices.shared)
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
}
