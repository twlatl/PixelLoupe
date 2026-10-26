import Accelerate
import CoreImage
import CryptoKit
import Foundation
import Vision

/// The subject Vision finds in a photo, for Subject and Background masks (see ADR 0003).
///
/// Finding it takes a moment, so it is found once per photo and kept: in memory, and on disk in the app's
/// caches, never in the catalog. It is found on the photo after Lens Corrections, Rotate/Flip and Transform
/// (the frame masks are placed on) and before any tone or color edits, so it is keyed by the file and those
/// settings: changing Exposure leaves it alone, changing the geometry finds it again. Settings pasted onto
/// another photo find that photo's subject, since the file is part of the key.
///
/// Rendering off the main thread (thumbnails, exports, the Navigator) waits for it, so they always show the
/// mask. Develop's preview draws on the main thread, so it asks without waiting: the subject is found in the
/// background and `didFind` is posted when it's ready, to draw again.
nonisolated final class SubjectMatteStore: @unchecked Sendable {
    /// Posted on the main thread when a photo's subject has been found (or found to be missing).
    static let didFind = Notification.Name("PixelLoupe.SubjectMatteStore.didFind")

    static let shared = SubjectMatteStore(directory: defaultDirectory)

    static var defaultDirectory: URL {
        URL.cachesDirectory.appending(path: Bundle.main.bundleIdentifier ?? "PixelLoupe").appending(path: "SubjectMattes")
    }

    /// The long edge of the image Vision looks at; the mask is scaled from it to whatever size renders.
    static let detectionLongEdge: CGFloat = 1536

    /// Where the subject is: white over the subject, black elsewhere. Rows are from the top.
    /// Immutable once made (`CIImage` is), so it can be handed between threads.
    struct Matte: @unchecked Sendable {
        var width: Int
        var height: Int
        var bytes: Data
        /// The matte as an image `width` × `height` from the origin; nil when no subject was found.
        let image: CIImage?

        init(width: Int, height: Int, bytes: Data) {
            self.width = width
            self.height = height
            self.bytes = bytes
            image = width > 0 && height > 0 && bytes.count == width * height
                ? CIImage(bitmapData: bytes, bytesPerRow: width, size: CGSize(width: width, height: height), format: .L8, colorSpace: nil)
                : nil
        }

        static let noSubject = Matte(width: 0, height: 0, bytes: Data())
        var hasSubject: Bool { image != nil }
    }

    enum Status: Equatable, Sendable {
        case finding, found, noSubject
    }

    let directory: URL
    private let detect: @Sendable (CGImage) -> Matte?
    private let lock = NSLock()
    private var mattes: [String: Matte] = [:]
    /// Keys most recently used last, to keep memory to a few dozen photos.
    private var recent: [String] = []
    private var finding: [String: DispatchGroup] = [:]
    private static let memoryLimit = 24

    /// `detect` finds the subject in an image, or returns nil when it couldn't look (which isn't kept, so
    /// it's tried again); Vision's by default.
    init(directory: URL, detect: @escaping @Sendable (CGImage) -> Matte? = SubjectMatteStore.detectWithVision) {
        self.directory = directory
        self.detect = detect
    }

    // MARK: - Asking

    /// The subject of `source`'s photo with `adjustments`' geometry. Waiting finds it now if it must (off the
    /// main thread); otherwise nil until it's found in the background.
    func matte(for source: DevelopSource, adjustments: PhotoAdjustments, waiting: Bool) -> Matte? {
        let request = Request(source: source, adjustments: adjustments)
        if let matte = remembered(request.key) { return matte }
        if waiting { return find(request) }
        Task.detached(priority: .userInitiated) { [self] in
            _ = find(request)
            await MainActor.run { NotificationCenter.default.post(name: Self.didFind, object: self) }
        }
        return nil
    }

    /// Whether the subject is known yet, for the Masking panel (doesn't wait, or start finding it).
    func status(for source: DevelopSource, adjustments: PhotoAdjustments) -> Status {
        guard let matte = remembered(Request(source: source, adjustments: adjustments).key) else { return .finding }
        return matte.hasSubject ? .found : .noSubject
    }

    private func remembered(_ key: String) -> Matte? {
        lock.withLock {
            guard let matte = mattes[key] else { return nil }
            recent.removeAll { $0 == key }
            recent.append(key)
            return matte
        }
    }

    private func remember(_ matte: Matte, for key: String) {
        lock.withLock {
            mattes[key] = matte
            recent.removeAll { $0 == key }
            recent.append(key)
            while recent.count > Self.memoryLimit { mattes[recent.removeFirst()] = nil }
        }
    }

    // MARK: - Finding

    /// What identifies a subject: the file and the geometry it's found on.
    struct Request: Sendable {
        var url: URL
        var isSmartPreview: Bool
        var geometry: PhotoAdjustments

        init(source: DevelopSource, adjustments: PhotoAdjustments) {
            url = source.url
            isSmartPreview = source.isSmartPreview
            var geometry = PhotoAdjustments()
            geometry.lens = adjustments.lens
            geometry.orientation = adjustments.orientation
            geometry.transform = adjustments.transform
            self.geometry = geometry
        }

        var key: String {
            struct Identity: Encodable {
                var version = 1
                var path: String
                var isSmartPreview: Bool
                var lens: PhotoAdjustments.LensCorrections
                var orientation: PhotoAdjustments.Orientation
                var transform: PhotoAdjustments.Transform
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let identity = Identity(path: url.path(percentEncoded: false), isSmartPreview: isSmartPreview,
                                    lens: geometry.lens, orientation: geometry.orientation, transform: geometry.transform)
            let data = (try? encoder.encode(identity)) ?? Data(url.path(percentEncoded: false).utf8)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Finds the subject (or reads it from disk), once however many renders ask at the same time.
    private func find(_ request: Request) -> Matte? {
        let key = request.key
        let (group, isFinding) = lock.withLock { () -> (DispatchGroup, Bool) in
            if let group = finding[key] { return (group, false) }
            let group = DispatchGroup()
            group.enter()
            finding[key] = group
            return (group, true)
        }
        guard isFinding else {
            group.wait()
            return remembered(key)
        }
        defer {
            lock.withLock { finding[key] = nil }
            group.leave()
        }
        if let matte = remembered(key) { return matte }
        if let matte = read(key) {
            remember(matte, for: key)
            return matte
        }
        guard let image = Self.detectionImage(for: request), let matte = detect(image) else { return nil }
        write(matte, for: key)
        remember(matte, for: key)
        return matte
    }

    /// The photo with only its geometry applied, `detectionLongEdge` on its long edge.
    static func detectionImage(for request: Request) -> CGImage? {
        let source = request.isSmartPreview ? DevelopSource(smartPreview: request.url) : DevelopSource(url: request.url)
        guard let source else { return nil }
        let image = source.image(with: request.geometry, scale: source.scale(toFit: detectionLongEdge))
        guard !image.extent.isEmpty, !image.extent.isInfinite, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return PhotoRenderer.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space)
    }

    /// Vision's foreground instance mask: every subject it finds, together.
    @Sendable static func detectWithVision(_ image: CGImage) -> Matte? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        do { try handler.perform([request]) } catch { return nil }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty,
              let buffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        else { return .noSubject }
        return matte(from: buffer)
    }

    /// A one-component float mask (rows from the top) as 8-bit gray.
    static func matte(from buffer: CVPixelBuffer) -> Matte? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer), width > 0, height > 0 else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var bytes = Data(capacity: width * height)
        var row = [Float](repeating: 0, count: width), gray = [UInt8](repeating: 0, count: width)
        for y in 0..<height {
            let source = UnsafeBufferPointer(start: (base + y * rowBytes).assumingMemoryBound(to: Float.self), count: width)
            vDSP.multiply(255, vDSP.clip(source, to: 0...1), result: &row)
            vDSP.convertElements(of: row, to: &gray, rounding: .towardNearestInteger)
            bytes.append(contentsOf: gray)
        }
        return Matte(width: width, height: height, bytes: bytes)
    }

    // MARK: - Disk

    /// A matte file: width and height (32-bit little-endian), then the gray bytes; compressed (LZFSE).
    private func url(for key: String) -> URL { directory.appending(path: "\(key).matte") }

    private func read(_ key: String) -> Matte? {
        guard let compressed = try? Data(contentsOf: url(for: key)),
              let data = try? (compressed as NSData).decompressed(using: .lzfse) as Data, data.count >= 8
        else { return nil }
        let width = Int(data[0..<4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
        let height = Int(data[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
        guard data.count == 8 + width * height else { return nil }
        return width == 0 ? .noSubject : Matte(width: width, height: height, bytes: data.subdata(in: 8..<data.count))
    }

    private func write(_ matte: Matte, for key: String) {
        var data = Data()
        withUnsafeBytes(of: UInt32(matte.width).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(matte.height).littleEndian) { data.append(contentsOf: $0) }
        data.append(matte.bytes)
        guard let compressed = try? (data as NSData).compressed(using: .lzfse) as Data else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? compressed.write(to: url(for: key), options: .atomic)
    }
}
