import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

/// Where a catalog keeps its Smart Previews, and building and discarding them (RAW-119).
@Suite("Smart Preview store and builder")
@MainActor
struct SmartPreviewStoreTests {
    private struct Setup {
        let directory: TemporaryDirectory
        let store: CatalogStore
        /// Two JPEGs and a video.
        let photos: [Photo]
    }

    private func makeSetup() throws -> Setup {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.create(
            at: directory.url.appending(path: "C.pixelloupe", directoryHint: .isDirectory), info: Fixtures.referencedInfo
        )
        let folder = try directory.subdirectory("Photos")
        var photos: [Photo] = []
        for name in ["IMG_1.jpg", "IMG_2.jpg", "CLIP.mov"] {
            let url = folder.appending(path: name)
            if name.hasSuffix(".jpg") { try Fixtures.writeJPEG(to: url, width: 320, height: 240) } else { try Data([0]).write(to: url) }
            photos.append(makePhoto(in: store, url: url))
        }
        photos[2].isVideo = true
        try store.viewContext.save()
        return Setup(directory: directory, store: store, photos: photos)
    }

    private func makePhoto(in store: CatalogStore, url: URL, master: Photo? = nil) -> Photo {
        let photo = Photo(context: store.viewContext)
        photo.id = UUID()
        photo.fileName = url.lastPathComponent
        photo.filePath = url.path(percentEncoded: false)
        photo.fileType = url.pathExtension.uppercased()
        photo.captureDate = Date()
        photo.importDate = Date()
        photo.editDate = Date()
        photo.master = master
        return photo
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    @Test func buildingWritesOneForEachPhotoButNotForVideos() async throws {
        let setup = try makeSetup()
        let builder = setup.store.smartPreviewBuilder
        var progress: [LibraryState.ImportStatus?] = []
        builder.onProgress = { progress.append($0) }
        var changed = Set<UUID>()
        let observer = NotificationCenter.default.addObserver(
            forName: SmartPreviewStore.didChangeNotification, object: setup.store.smartPreviews, queue: nil
        ) { notification in
            let ids = notification.userInfo?["ids"] as? Set<UUID> ?? []
            MainActor.assumeIsolated { changed.formUnion(ids) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        builder.start(after: .zero)
        builder.build(setup.photos)
        await builder.waitUntilIdle()

        let smartPreviews = setup.store.smartPreviews
        for photo in setup.photos.prefix(2) {
            let file = try #require(smartPreviews.file(for: photo))
            #expect(file.deletingLastPathComponent().lastPathComponent == "Smart Previews")
            #expect(file.lastPathComponent == "\(photo.id.uuidString).heic")
            #expect(SmartPreviewInfo.read(from: file)?.isCurrent(for: photo.fileURL) == true)
            #expect(setup.store.sourceStatus(of: photo) == .originalAndSmartPreview)
        }
        #expect(smartPreviews.file(for: setup.photos[2]) == nil && setup.store.sourceStatus(of: setup.photos[2]) == nil,
                "a video gets none")
        #expect(changed == Set(setup.photos.prefix(2).map(\.id)))
        #expect(progress.first == LibraryState.ImportStatus(completed: 0, total: 2))
        #expect(progress.contains(LibraryState.ImportStatus(completed: 1, total: 2)))
        #expect(progress.last == .some(nil), "the progress goes away when it's done")
    }

    @Test func aSmartPreviewIsRebuiltOnlyWhenItsOriginalChanges() async throws {
        let setup = try makeSetup()
        let builder = setup.store.smartPreviewBuilder
        let photo = setup.photos[0]
        builder.start(after: .zero)
        builder.build([photo])
        await builder.waitUntilIdle()
        let file = try #require(setup.store.smartPreviews.file(for: photo))
        func modified() throws -> Date? { try URL(filePath: file.path(percentEncoded: false)).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let written = try modified()

        builder.build([photo])
        await builder.waitUntilIdle()
        #expect(try modified() == written, "a current one is left alone")

        // The next time the catalog opens, one whose original changed is rebuilt.
        try Fixtures.writeJPEG(to: photo.fileURL, width: 400, height: 300)
        builder.stop()
        builder.start(after: .zero)
        await builder.waitUntilIdle()
        let rebuilt = try #require(SmartPreviewInfo.read(from: file))
        #expect(rebuilt.originalWidth == 400 && rebuilt.isCurrent(for: photo.fileURL))
    }

    @Test func aMissingOriginalKeepsItsSmartPreview() async throws {
        let setup = try makeSetup()
        let builder = setup.store.smartPreviewBuilder
        builder.start(after: .zero)
        builder.build([setup.photos[0]])
        await builder.waitUntilIdle()
        let file = try #require(setup.store.smartPreviews.file(for: setup.photos[0]))

        for photo in setup.photos.prefix(2) { try FileManager.default.removeItem(at: photo.fileURL) }
        setup.store.availability.set(missing: [setup.photos[0].id, setup.photos[1].id], offlineFolders: [])
        builder.stop()
        builder.start(after: .zero)
        builder.build(setup.photos)
        await builder.waitUntilIdle()
        #expect(exists(file))
        #expect(!setup.store.smartPreviews.contains(setup.photos[1]), "none can be built without the original")
        #expect(setup.store.sourceStatus(of: setup.photos[0]) == .smartPreview)
        #expect(setup.store.sourceStatus(of: setup.photos[1]) == .missing)
    }

    @Test func virtualCopiesShareTheirMastersSmartPreview() async throws {
        let setup = try makeSetup()
        let master = setup.photos[0]
        let copy = makePhoto(in: setup.store, url: master.fileURL, master: master)
        try setup.store.viewContext.save()
        let builder = setup.store.smartPreviewBuilder
        builder.start(after: .zero)
        builder.build([copy])
        await builder.waitUntilIdle()

        let file = try #require(setup.store.smartPreviews.file(for: copy))
        #expect(file.lastPathComponent == "\(master.id.uuidString).heic", "written under the master's ID")
        #expect(setup.store.smartPreviews.file(for: master) == file)

        setup.store.smartPreviews.discard([copy])
        #expect(!exists(file) && !setup.store.smartPreviews.contains(master), "discarding the copy's discards the file's")
    }

    @Test func theFolderIsListedWhenTheCatalogOpens() async throws {
        let setup = try makeSetup()
        let directory = setup.store.smartPreviews.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = setup.photos[1].id
        for name in ["\(id.uuidString).dng", ".\(UUID().uuidString)-\(id.uuidString).dng", "notes.txt"] {
            try Data([1]).write(to: directory.appending(path: name))
        }
        let reopened = try CatalogStore.open(at: setup.store.packageURL)
        #expect(reopened.smartPreviews.files.isEmpty, "listed off the main thread")
        await reopened.smartPreviews.load()
        #expect(reopened.smartPreviews.files == [id: directory.appending(path: "\(id.uuidString).dng")],
                "files being written and other files are left out")
    }

    @Test func smartPreviewsOfRemovedPhotosArePrunedOnOpen() async throws {
        let setup = try makeSetup()
        let directory = setup.store.smartPreviews.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let kept = directory.appending(path: "\(setup.photos[0].id.uuidString).heic")
        let orphan = directory.appending(path: "\(UUID().uuidString).dng")
        for url in [kept, orphan] { try Data([1]).write(to: url) }

        setup.store.pruneOrphanedPreviews()
        for _ in 0..<50 where exists(orphan) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!exists(orphan))
        #expect(exists(kept))
    }

    @Test func thePreviewsMenuFollowsTheSelection() async throws {
        let setup = try makeSetup()
        let controller = CatalogWindowController(store: setup.store)
        defer { controller.close() }
        let build = #selector(PixelLoupeActions.buildSmartPreviews(_:)), discard = #selector(PixelLoupeActions.discardSmartPreviews(_:))
        func isEnabled(_ action: Selector) -> Bool {
            controller.validateUserInterfaceItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
        }
        controller.state.selectedPhotoIDs = [setup.photos[2].objectID]
        #expect(!isEnabled(build), "a video gets none")
        controller.state.selectedPhotoIDs = setup.photos.map(\.objectID)
        #expect(isEnabled(build))
        #expect(!isEnabled(discard), "nothing to discard yet")

        controller.buildSmartPreviews(nil)
        for _ in 0..<250 where !setup.store.smartPreviews.contains(setup.photos[1]) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(isEnabled(discard))

        controller.showWindow(nil)
        controller.discardSmartPreviews(nil)
        let window = try #require(controller.window)
        let sheet = try #require(window.attachedSheet, "asks first")
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        #expect(!setup.store.smartPreviews.contains(setup.photos[0]) && !setup.store.smartPreviews.contains(setup.photos[1]))
        #expect(!isEnabled(discard))
    }

    @Test func theHistogramSaysWhatThePhotoIsDrawnFrom() throws {
        let histogram = HistogramView()
        func statusLabel(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.accessibilityIdentifier() == "histogramSourceStatus" { return field }
            return view.subviews.lazy.compactMap(statusLabel).first
        }
        let label = try #require(statusLabel(in: histogram))
        #expect(label.stringValue.isEmpty)
        histogram.sourceStatus = .originalAndSmartPreview
        #expect(label.stringValue == "Original + Smart Preview")
        histogram.sourceStatus = .smartPreview
        #expect(label.stringValue == "Smart Preview")
        histogram.sourceStatus = nil
        #expect(label.stringValue.isEmpty)
    }
}
