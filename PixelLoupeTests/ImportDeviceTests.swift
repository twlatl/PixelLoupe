import AppKit
import ImageCaptureCore
import Testing
@testable import PixelLoupe

/// Cameras and phones in the import window (RAW-86), with a stand-in device: ImageCaptureCore needs a
/// real one plugged in.
@Suite("Import devices", .serialized)
struct ImportDeviceTests {
    @MainActor
    final class FakeDevice: ImportDevice {
        let id = "FAKE-\(UUID().uuidString)"
        let name = "Ted's iPhone"
        let symbol = "iphone"
        let kindName = "iPhone"
        let folder: URL
        var ejected = 0
        /// A phone that isn't unlocked yet (or doesn't trust this Mac).
        var isLocked = false
        var thumbnailRequests = 0

        init(folder: URL) {
            self.folder = folder
        }

        private var names: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []).sorted()
        }

        func files() async throws -> [ImportDeviceFile] {
            if isLocked { throw ImportDevices.DeviceError.locked(kindName) }
            return names.enumerated().map { index, name in
                let size = (try? folder.appending(path: name).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return ImportDeviceFile(id: String(index), name: name, size: Int64(size),
                                        date: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index)), isVideo: false)
            }
        }

        func thumbnail(of fileID: String, maxPixelSize: Int) async -> CGImage? {
            thumbnailRequests += 1
            return ThumbnailStore.previewImage(from: folder.appending(path: names[Int(fileID)!]), maxPixelSize: maxPixelSize)
        }

        func download(_ fileIDs: [String], to destination: URL, progress: @escaping (Int) -> Void) async throws -> [URL] {
            try fileIDs.enumerated().map { index, id in
                let name = names[Int(id)!]
                let target = destination.appending(path: name)
                try FileManager.default.copyItem(at: folder.appending(path: name), to: target)
                progress(index + 1)
                return target
            }
        }

        func eject() { ejected += 1 }
    }

    @Test func deviceURLsNameTheDeviceAndFile() {
        let file = ImportDeviceFile(id: "12", name: "IMG 0001.HEIC", size: 1, date: .now, isVideo: false)
        let url = ImportDevices.url(of: file, on: "ABC-123")
        #expect(ImportDevices.isDeviceURL(url))
        #expect(ImportDevices.parse(url)?.deviceID == "ABC-123")
        #expect(ImportDevices.parse(url)?.fileID == "12")
        #expect(url.lastPathComponent == "IMG 0001.HEIC", "the grid shows the file's name")
        #expect(ImportDevices.parse(ImportDevices.url(of: "ABC-123"))?.fileID == nil)
        #expect(!ImportDevices.isDeviceURL(URL(filePath: "/Volumes/Card")))
    }

    @Test func cardsInAReaderAreListedOnlyAsCards() {
        #expect(ImportDevices.isMassStorage(ICDeviceTransport.transportTypeMassStorage.rawValue))
        #expect(!ImportDevices.isMassStorage(ICDeviceTransport.transportTypeUSB.rawValue), "a phone or camera over USB is a device")
        #expect(!ImportDevices.isMassStorage(nil))
    }

    @Test func passcodeLockedErrorIsRecognized() {
        // ImageCaptureCore's "Please unlock", which a trusted iPhone also reports while its session opens.
        let error = NSError(domain: "com.apple.ImageCaptureCore", code: -9943,
                            userInfo: [NSLocalizedDescriptionKey: "Please unlock “Ted's iPhone”"])
        #expect(CameraImportDevice.isPasscodeLocked(error))
        #expect(!CameraImportDevice.isPasscodeLocked(NSError(domain: "com.apple.ImageCaptureCore", code: -9934)))
    }

    @Test @MainActor func aLockedPhoneIsReadAgainOnceItsUnlocked() async throws {
        let directory = try TemporaryDirectory()
        let phone = try directory.subdirectory("Phone")
        try Fixtures.writeJPEG(to: phone.appending(path: "IMG_0001.JPG"))
        let device = FakeDevice(folder: phone)
        device.isLocked = true
        ImportDevices.shared.add(device)
        defer { ImportDevices.shared.remove(id: device.id) }

        let info = Fixtures.managedInfo(storage: try directory.subdirectory("Storage"))
        let catalog = directory.url.appending(path: "Test.pixelloupe")
        let store = try CatalogStore.inMemory(info: info, packageURL: catalog)
        let source = ImportWindowSource(urls: [ImportDevices.url(of: device.id)])
        let controller = ImportWindowController(service: ImportService(store: store), catalogURL: catalog, info: info, source: source)
        defer { controller.close() }
        let content = try #require(controller.window?.contentView)
        let grid = try #require(content.firstMatch { $0.accessibilityIdentifier() == "importGrid" } as? NSCollectionView)
        let message = try #require(content.firstMatch { $0.accessibilityIdentifier() == "importMessage" } as? NSTextField)
        for _ in 0..<200 where !message.stringValue.hasPrefix("Unlock") { try await Task.sleep(for: .milliseconds(20)) }
        #expect(message.stringValue == "Unlock the iPhone and choose Trust on it to see its photos.")
        #expect(!message.isHidden && grid.numberOfSections == 0)

        // Another device unlocking doesn't read this one again.
        device.isLocked = false
        NotificationCenter.default.post(name: ImportDevices.didUnlockNotification, object: "SOMETHING-ELSE")
        try await Task.sleep(for: .milliseconds(200))
        #expect(grid.numberOfSections == 0)

        NotificationCenter.default.post(name: ImportDevices.didUnlockNotification, object: device.id)
        for _ in 0..<200 where grid.numberOfSections == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(grid.numberOfSections == 1 && grid.numberOfItems(inSection: 0) == 1)
        #expect(message.isHidden)
    }

    @Test @MainActor func aPhonesPhotosAreListedDownloadedAndImportedAsCopies() async throws {
        let directory = try TemporaryDirectory()
        let phone = try directory.subdirectory("Phone")
        try Fixtures.writeJPEG(to: phone.appending(path: "IMG_0001.JPG"))
        try Fixtures.writeJPEG(to: phone.appending(path: "IMG_0002.JPG"), captureDate: "2026:10:13 10:00:00")
        let device = FakeDevice(folder: phone)
        ImportDevices.shared.add(device)
        defer { ImportDevices.shared.remove(id: device.id) }

        let info = Fixtures.managedInfo(storage: try directory.subdirectory("Storage"))
        let catalog = directory.url.appending(path: "Test.pixelloupe")
        let store = try CatalogStore.inMemory(info: info, packageURL: catalog)
        let source = ImportWindowSource(urls: [ImportDevices.url(of: device.id)])
        #expect(source.isDevice && source.title == "Ted's iPhone" && source.symbol == "iphone")

        let controller = ImportWindowController(service: ImportService(store: store), catalogURL: catalog, info: info, source: source)
        defer { controller.close() }
        var imported: [ImportService.Candidate] = []
        var transfer: ImportTransfer?
        controller.onImport = { candidates, chosen, _, _, _ in
            imported = candidates
            transfer = chosen
        }
        let content = try #require(controller.window?.contentView)
        let grid = try #require(content.firstMatch { $0.accessibilityIdentifier() == "importGrid" } as? NSCollectionView)
        let button = try #require(content.firstMatch { $0.accessibilityIdentifier() == "importButton" } as? NSButton)
        let eject = try #require(content.firstMatch { $0.accessibilityIdentifier() == "importEjectAfterImport" } as? NSButton)
        for _ in 0..<200 where grid.numberOfSections == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(grid.numberOfItems(inSection: 0) == 2)
        #expect(controller.options.addUnavailableReason != nil, "a phone's photos are copied")
        #expect(eject.isEnabled)

        // Previews come from the device.
        let preview = await ImportPreviewLoader().image(for: ImportDevices.url(of: try await device.files()[0], on: device.id), isVideo: false)
        #expect(preview != nil && device.thumbnailRequests > 0)

        eject.state = .on
        button.performClick(nil)
        for _ in 0..<200 where imported.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(transfer == .copy)
        #expect(imported.map(\.source.url.lastPathComponent).sorted() == ["IMG_0001.JPG", "IMG_0002.JPG"])
        let staged = try #require(imported.first?.source.url)
        #expect(FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)), "downloaded to a staging folder")
        #expect(imported.allSatisfy { $0.metadata?.captureDate != nil }, "read from the downloaded files")

        controller.importDidFinish(failures: [])
        #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)), "the staging folder is cleaned up")
        #expect(device.ejected == 1, "Eject After Import")
    }
}

private extension NSView {
    func firstMatch(_ matches: (NSView) -> Bool) -> NSView? {
        if matches(self) { return self }
        for subview in subviews {
            if let match = subview.firstMatch(matches) { return match }
        }
        return nil
    }
}
