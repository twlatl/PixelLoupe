import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("External editing settings", .serialized)
@MainActor
struct ExternalEditingSettingsTests {
    private static let keys = [
        "ExternalEditorPrimary", "ExternalEditorAdditional", "ExternalEditorPresets",
        "ExternalEditStacksWithOriginal", "ExternalEditNaming",
    ]

    private func clear() {
        for key in Self.keys { Defaults.store.removeObject(forKey: key) }
    }

    @Test func defaultsFollowLightroom() {
        clear()
        defer { clear() }
        let preferences = ExternalEditingPreferences()
        #expect(preferences.primary.applicationPath == nil)
        #expect(preferences.primary.format == .tiff && preferences.primary.colorSpace == .proPhotoRGB)
        #expect(preferences.primary.bitDepth == 16 && preferences.primary.resolution == 240 && preferences.primary.compression == .zip)
        #expect(preferences.additional.colorSpace == .sRGB && preferences.additional.bitDepth == 8 && preferences.additional.compression == .lzw)
        #expect(preferences.stacksWithOriginal)
        #expect(preferences.naming.template == .filenameEdit)
        #expect(preferences.presets.isEmpty && preferences.currentPreset == nil)
    }

    @Test func preferencesAreSavedAndReadBack() {
        clear()
        defer { clear() }
        let preferences = ExternalEditingPreferences()
        preferences.primary.applicationPath = "/Applications/Preview.app"
        preferences.primary.format = .psd
        preferences.additional.bitDepth = 16
        preferences.stacksWithOriginal = false
        preferences.naming.template = .customNameSequence
        preferences.naming.customText = "Retouch"

        let reread = ExternalEditingPreferences()
        #expect(reread.primary == preferences.primary)
        #expect(reread.additional.bitDepth == 16)
        #expect(!reread.stacksWithOriginal)
        #expect(reread.naming == preferences.naming)
    }

    @Test func presetsSaveRenameApplyAndDelete() {
        clear()
        defer { clear() }
        let preferences = ExternalEditingPreferences()
        preferences.additional.applicationPath = "/Applications/Preview.app"
        preferences.savePreset(named: "  Preview 8-bit ")
        #expect(preferences.presets.map(\.name) == ["Preview 8-bit"])
        #expect(preferences.currentPreset?.name == "Preview 8-bit")

        // Changing a setting makes it Custom; choosing the preset brings its settings back.
        preferences.additional.bitDepth = 16
        #expect(preferences.currentPreset == nil)
        preferences.applyPreset("Preview 8-bit")
        #expect(preferences.additional.bitDepth == 8)

        preferences.renamePreset("Preview 8-bit", to: "Preview")
        #expect(preferences.presets.map(\.name) == ["Preview"])
        #expect(ExternalEditingPreferences().presets.map(\.name) == ["Preview"])
        preferences.deletePreset("Preview")
        #expect(preferences.presets.isEmpty)
    }

    @Test func decodingIsTolerant() throws {
        let settings = try JSONDecoder().decode(ExternalEditorSettings.self, from: Data(#"{"format":"psd","bitDepth":"x"}"#.utf8))
        #expect(settings.format == .psd)
        #expect(settings.bitDepth == 16 && settings.colorSpace == .proPhotoRGB)
        let naming = try JSONDecoder().decode(ExternalEditNaming.self, from: Data("{}".utf8))
        #expect(naming == ExternalEditNaming())
    }

    @Test func exportSettingsWriteTheEditorsFile() {
        var editor = ExternalEditorSettings()
        editor.format = .psd
        editor.colorSpace = .adobeRGB
        editor.resolution = 300
        let settings = editor.exportSettings(naming: ExternalEditNaming())
        #expect(settings.format == .psd && settings.colorSpace == .adobeRGB && settings.bitDepth == 16)
        #expect(settings.pixelsPerInch == 300)
        #expect(!settings.resizes && !settings.sharpens && !settings.watermarks && settings.metadata == .all)
        #expect(settings.renames && settings.namingTemplate == .filenameEdit)
    }

    @Test func namingExampleMatchesLightroom() {
        var naming = ExternalEditNaming()
        #expect(naming.example(format: .psd) == "IMG_0002-Edit.psd")
        #expect(naming.example(format: .tiff) == "IMG_0002-Edit.tif")
        naming.template = .customNameSequence
        naming.customText = "Retouch"
        naming.startNumber = 5
        #expect(naming.example(format: .tiff) == "Retouch-5.tif")
    }

    @Test func filenameEditIsAnExportTemplateToo() {
        var settings = ExportSettings()
        settings.renames = true
        settings.namingTemplate = .filenameEdit
        let item = ExportItem(
            source: URL(filePath: "/Photos/DSC_1.NEF"), adjustments: PhotoAdjustments(), metadata: PhotoMetadata(),
            keywords: [], rating: 0, captureDate: .now
        )
        #expect(ExportNaming.fileName(for: item, index: 0, total: 1, settings: settings) == "DSC_1-Edit.jpg")
    }
}

@Suite("Edit In")
@MainActor
struct EditInTests {
    /// A referenced catalog with one JPEG, `Trip/IMG_1.jpg`.
    private struct Setup {
        let directory: TemporaryDirectory
        let store: CatalogStore
        let photo: Photo
        var editing: PhotoEditing { PhotoEditing(store: store) }

        init() async throws {
            directory = try TemporaryDirectory()
            let trip = try directory.subdirectory("Trip")
            let url = try Fixtures.writeJPEG(to: trip.appending(path: "IMG_1.jpg"), width: 96, height: 64)
            store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "Test.pixelloupe"))
            _ = try await ImportService(store: store).importPhotos(from: [url])
            photo = try #require(try store.viewContext.fetch(Photo.fetchRequest()).first)
        }

        func editIn(
            _ ids: [NSManagedObjectID]? = nil, choice: ExternalEditMode = .copyWithAdjustments,
            editor: ExternalEditorSettings = ExternalEditorSettings(), stacks: Bool = true, collectionID: UUID? = nil
        ) async -> (jobs: [ExternalEditJob], result: ExternalEditRunner.Result, added: [Photo]) {
            let settings = editor.exportSettings(naming: ExternalEditNaming())
            let jobs = editing.externalEditJobs(ids ?? [photo.objectID], choice: choice, settings: settings)
            let result = await ExternalEditRunner.run(jobs, settings: settings, thumbnailDirectory: store.thumbnails.directory) { _, _ in }
            let added = editing.addExternalEdits(result.outputs, stacksWithOriginal: stacks, collectionID: collectionID)
            return (jobs, result, editing.photos(added))
        }
    }

    @Test func rawPhotosAndVirtualCopiesAlwaysSendACopyWithAdjustments() async throws {
        let setup = try await Setup()
        #expect(PhotoEditing.asksWhatToEdit(setup.photo))
        #expect(PhotoEditing.externalEditMode(for: setup.photo, choice: .original) == .original)

        let copy = try #require(setup.editing.photos(setup.editing.createVirtualCopies(of: [setup.photo.objectID])).first)
        #expect(!PhotoEditing.asksWhatToEdit(copy))
        #expect(PhotoEditing.externalEditMode(for: copy, choice: .original) == .copyWithAdjustments)

        // Edit In knows a raw file by its extension, so a catalog row is enough. (Importing a real one decodes it for a
        // thumbnail, which on CI's virtual machines can take longer than the test's two minutes.)
        let raw = Photo(context: setup.store.viewContext)
        raw.id = UUID()
        raw.fileName = "IMG_2.DNG"
        raw.filePath = setup.photo.fileURL.deletingLastPathComponent().appending(path: raw.fileName).path(percentEncoded: false)
        raw.fileType = "DNG"
        raw.captureDate = Date()
        raw.importDate = Date()
        raw.editDate = Date()
        #expect(!PhotoEditing.asksWhatToEdit(raw))
        #expect(PhotoEditing.externalEditMode(for: raw, choice: .copy) == .copyWithAdjustments)
    }

    @Test func copiesAreNamedBesideTheOriginalWithoutOverwriting() async throws {
        let setup = try await Setup()
        let folder = setup.photo.fileURL.deletingLastPathComponent()
        try Data("taken".utf8).write(to: folder.appending(path: "IMG_1-Edit.tif"))
        let copies = setup.editing.createVirtualCopies(of: [setup.photo.objectID])
        let settings = ExternalEditorSettings().exportSettings(naming: ExternalEditNaming())
        let jobs = setup.editing.externalEditJobs([setup.photo.objectID] + copies, choice: .copyWithAdjustments, settings: settings)
        #expect(jobs.map(\.url.lastPathComponent) == ["IMG_1-Edit-2.tif", "IMG_1-Edit-3.tif"])
        #expect(jobs.allSatisfy { $0.url.deletingLastPathComponent() == folder })

        let plain = setup.editing.externalEditJobs([setup.photo.objectID], choice: .copy, settings: settings)
        #expect(plain.map(\.url.lastPathComponent) == ["IMG_1-Edit.jpg"])
        let original = setup.editing.externalEditJobs([setup.photo.objectID], choice: .original, settings: settings)
        #expect(original.map(\.url) == [setup.photo.fileURL] && !original[0].makesCopy)
    }

    @Test func copyJoinsTheCatalogStackedAboveItsOriginal() async throws {
        let setup = try await Setup()
        let context = setup.store.viewContext
        setup.photo.rating = 3
        setup.photo.photoFlag = .picked
        setup.photo.colorLabel = 2
        setup.photo.tags.insert(Tag.findOrCreate(named: "Ireland", in: context))
        var adjustments = setup.photo.adjustments
        adjustments.light.exposure = 1
        setup.photo.adjustments = adjustments
        var metadata = setup.photo.metadata
        metadata[.title] = "Cliffs"
        setup.photo.metadata = metadata
        setup.store.save()

        let (_, result, added) = await setup.editIn()
        #expect(result.failures.isEmpty)
        let copy = try #require(added.first)
        #expect(copy.fileName == "IMG_1-Edit.tif" && copy.fileType == "TIF")
        #expect(FileManager.default.fileExists(atPath: copy.filePath))
        #expect(copy.folder == setup.photo.folder)
        #expect(copy.pixelWidth == 96 && copy.pixelHeight == 64 && copy.fileSize > 0)
        #expect(copy.captureDate == setup.photo.captureDate)
        #expect(copy.rating == 3 && copy.colorLabel == 2 && copy.photoFlag == .unflagged)
        #expect(copy.tagNames == ["Ireland"])
        #expect(copy.metadata[.title] == "Cliffs" && copy.titleText == "Cliffs")
        // The edits are in the copy's pixels, so it starts from defaults.
        #expect(copy.adjustments.isDefault)
        #expect(copy.stack == setup.photo.stack && copy.stack != nil)
        #expect(copy.stack?.orderedPhotos == [copy, setup.photo])
        #expect(!copy.isHiddenInStack)
        #expect(FileManager.default.fileExists(atPath: setup.store.thumbnails.url(for: copy.id).path(percentEncoded: false)))

        // A second edit lands just above the original, under the first.
        let (_, _, again) = await setup.editIn()
        let second = try #require(again.first)
        #expect(second.fileName == "IMG_1-Edit-2.tif")
        #expect(setup.photo.stack?.orderedPhotos == [copy, second, setup.photo])
    }

    @Test func copyWithAdjustmentsBakesTheEditsIn() async throws {
        let setup = try await Setup()
        var adjustments = setup.photo.adjustments
        adjustments.light.exposure = 2
        setup.photo.adjustments = adjustments
        var editor = ExternalEditorSettings()
        editor.bitDepth = 8
        editor.colorSpace = .sRGB
        let (jobs, _, _) = await setup.editIn(editor: editor)
        let plain = try #require(NSImage(contentsOf: setup.photo.fileURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let edited = try #require(NSImage(contentsOf: jobs[0].url)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(brightness(edited) > brightness(plain) + 0.05)
    }

    @Test func plainCopyIsTheOriginalFile() async throws {
        let setup = try await Setup()
        let (jobs, _, added) = await setup.editIn(choice: .copy, stacks: false)
        let copy = try #require(added.first)
        #expect(copy.fileName == "IMG_1-Edit.jpg" && copy.stack == nil)
        #expect(try Data(contentsOf: jobs[0].url) == Data(contentsOf: setup.photo.fileURL))
    }

    @Test func editingTheOriginalAddsNothing() async throws {
        let setup = try await Setup()
        let (jobs, result, added) = await setup.editIn(choice: .original)
        #expect(jobs.count == 1 && result.outputs.isEmpty && added.isEmpty)
        #expect(try setup.store.viewContext.count(for: Photo.fetchRequest()) == 1)
    }

    @Test func copyOfAVirtualCopyUsesItsEditsAndStacksWithTheMaster() async throws {
        let setup = try await Setup()
        let copyID = try #require(setup.editing.createVirtualCopies(of: [setup.photo.objectID]).first)
        let virtual = try #require(setup.editing.photos([copyID]).first)
        var adjustments = virtual.adjustments
        adjustments.light.exposure = 1
        virtual.adjustments = adjustments
        let (jobs, _, added) = await setup.editIn([copyID])
        #expect(jobs[0].item.adjustments == adjustments)
        let edit = try #require(added.first)
        #expect(edit.fileName == "IMG_1-Edit.tif")
        #expect(edit.stack != nil && edit.stack == setup.photo.stack)
    }

    @Test func copyJoinsTheCollectionItWasEditedFrom() async throws {
        let setup = try await Setup()
        let collection = CollectionEditing(store: setup.store).create(.collection, named: "Best", in: nil, photos: [setup.photo.objectID])
        let (_, _, added) = await setup.editIn(collectionID: collection.id)
        let copy = try #require(added.first)
        #expect(collection.photos.contains(copy))
    }

    @Test func videosAreLeftOut() async throws {
        let setup = try await Setup()
        setup.photo.isVideo = true
        #expect(setup.editing.externalEditPhotos([setup.photo.objectID]).isEmpty)
        #expect(!PhotoEditing.asksWhatToEdit(setup.photo))
    }

    private func brightness(_ image: CGImage) -> Double {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixel = context.data!.assumingMemoryBound(to: UInt8.self)
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 765
    }
}

@Suite("Edits from other apps")
@MainActor
struct ExternalChangeTests {
    /// Stands in for FSEvents.
    final class FakeWatcher: FolderWatching {
        var onChange: (([String]) -> Void)?
        var folders = Set<String>()
        func watch(_ folders: Set<String>) { self.folders = folders }
        func stop() { folders = [] }
    }

    private struct Setup {
        let directory: TemporaryDirectory
        let store: CatalogStore
        let photo: Photo

        init() async throws {
            directory = try TemporaryDirectory()
            let trip = try directory.subdirectory("Trip")
            let url = try Fixtures.writeJPEG(to: trip.appending(path: "IMG_1.jpg"), width: 96, height: 64)
            store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "Test.pixelloupe"))
            _ = try await ImportService(store: store).importPhotos(from: [url])
            photo = try #require(try store.viewContext.fetch(Photo.fetchRequest()).first)
        }

        /// Another app saves a bigger, cropped version of the photo a little later.
        func saveElsewhere() throws {
            try Fixtures.writeJPEG(to: photo.fileURL, width: 120, height: 40)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: photo.filePath)
        }

        func waitUntil(_ condition: () -> Bool) async {
            for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
        }
    }

    @Test func fileNewerThanItsThumbnailHasChanged() {
        let now = Date()
        #expect(FileAvailability.isChanged(file: now.addingTimeInterval(5), thumbnail: now))
        #expect(!FileAvailability.isChanged(file: now.addingTimeInterval(0.5), thumbnail: now))
        #expect(!FileAvailability.isChanged(file: now, thumbnail: now.addingTimeInterval(5)))
    }

    @Test func checkReloadsAPhotoAnotherAppSaved() async throws {
        let setup = try await Setup()
        let monitor = ExternalEditMonitor(store: setup.store, watcher: FakeWatcher())
        monitor.start()
        defer { monitor.stop() }
        let thumbnail = setup.store.thumbnails.url(for: setup.photo.id)
        let before = try Data(contentsOf: thumbnail)
        var reloaded: UUID?
        let observer = NotificationCenter.default.addObserver(
            forName: ExternalEditMonitor.photoFileDidChangeNotification, object: monitor, queue: .main
        ) { notification in
            let id = notification.userInfo?["id"] as? UUID
            MainActor.assumeIsolated { reloaded = id }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        // Nothing has changed yet.
        setup.store.availability.refresh()
        await setup.store.availability.waitForRefresh()
        await monitor.waitForReloads()
        #expect(reloaded == nil)

        try setup.saveElsewhere()
        setup.store.availability.refresh()
        await setup.store.availability.waitForRefresh()
        await setup.waitUntil { reloaded != nil }
        await monitor.waitForReloads()
        #expect(reloaded == setup.photo.id)
        #expect(setup.photo.pixelWidth == 120 && setup.photo.pixelHeight == 40)
        #expect(setup.photo.fileSize == Int64(try Data(contentsOf: setup.photo.fileURL).count))
        #expect(try Data(contentsOf: thumbnail) != before)
        #expect(setup.store.viewContext.undoManager?.canUndo != true)

        // Once redrawn, the thumbnail is newer again; nothing more to reload.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: thumbnail.path(percentEncoded: false))
        reloaded = nil
        setup.store.availability.refresh()
        await setup.store.availability.waitForRefresh()
        await monitor.waitForReloads()
        #expect(reloaded == nil)
    }

    @Test func watchingTrackedFilesTriggersACheck() async throws {
        let setup = try await Setup()
        let watcher = FakeWatcher()
        let monitor = ExternalEditMonitor(store: setup.store, watcher: watcher)
        monitor.start()
        defer { monitor.stop() }
        monitor.track([setup.photo.fileURL])
        let folder = setup.photo.fileURL.deletingLastPathComponent().path(percentEncoded: false)
        #expect(watcher.folders == [folder.hasSuffix("/") ? String(folder.dropLast()) : folder])

        try setup.saveElsewhere()
        // A file nobody handed to an editor is ignored.
        watcher.onChange?([setup.directory.url.appending(path: "Other.jpg").path(percentEncoded: false)])
        watcher.onChange?([setup.photo.filePath])
        await setup.waitUntil { setup.photo.pixelWidth == 120 }
        await monitor.waitForReloads()
        #expect(setup.photo.pixelWidth == 120)
    }
}

@Suite("Settings window size")
@MainActor
struct SettingsWindowSizeTests {
    /// Each pane gets a window tall enough for all of it (the long External Editing pane included),
    /// unless the screen is shorter, and the window is titled after the pane.
    @Test func windowFitsEachPane() throws {
        let controller = SettingsWindowController()
        let window = try #require(controller.window)
        let tabs = try #require(window.contentViewController as? NSTabViewController)
        defer { controller.close() }
        for index in tabs.tabViewItems.indices {
            tabs.selectedTabViewItemIndex = index
            let item = tabs.tabViewItems[index]
            let pane = try #require(item.viewController)
            pane.view.layoutSubtreeIfNeeded()
            let wanted = pane.preferredContentSize.height
            let screen = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? .greatestFiniteMagnitude
            let content = window.contentRect(forFrameRect: window.frame).height
            #expect(wanted > 0)
            #expect(content >= min(wanted, screen - (window.frame.height - content)) - 1, "\(item.label) fits")
            #expect(window.title == item.label)
        }
    }

    /// External Editing is too long to show whole: it's about half height, with a scroll bar that
    /// stays visible, and scrolls to its last section.
    @Test func externalEditingScrollsWithAVisibleScrollBar() throws {
        let controller = SettingsWindowController()
        let window = try #require(controller.window)
        let tabs = try #require(window.contentViewController as? NSTabViewController)
        defer { controller.close() }
        tabs.selectedTabViewItemIndex = try #require(tabs.tabViewItems.firstIndex { $0.label == "External Editing" })
        let scroll = try #require(tabs.tabViewItems[tabs.selectedTabViewItemIndex].viewController?.view as? NSScrollView)
        scroll.layoutSubtreeIfNeeded()
        #expect(scroll.contentView.bounds.height == ScrollingSettingsPane.visibleHeight)
        #expect(scroll.hasVerticalScroller && scroll.scrollerStyle == .legacy && !scroll.autohidesScrollers)
        let document = try #require(scroll.documentView)
        #expect(document.frame.height > scroll.contentView.bounds.height * 1.5, "most of the pane is below the fold")
    }
}
