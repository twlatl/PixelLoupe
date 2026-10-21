import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Photo Merge in the catalog")
@MainActor
struct PhotoMergeTests {
    /// A referenced catalog holding a three-exposure bracket, the photos in file name order.
    private struct Setup {
        let bracket: Bracket
        let store: CatalogStore
        let ids: [NSManagedObjectID]
        var editing: PhotoEditing { PhotoEditing(store: store) }

        init(stops: [Double] = [-2, 0, 2]) async throws {
            bracket = try Bracket(stops: stops)
            store = try CatalogStore.inMemory(
                info: Fixtures.referencedInfo, packageURL: bracket.directory.url.appending(path: "Test.pixelloupe")
            )
            _ = try await ImportService(store: store).importPhotos(from: bracket.sources.map(\.url))
            let request = Photo.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "fileName", ascending: true)]
            ids = try store.viewContext.fetch(request).map(\.objectID)
        }

        func photo(_ id: NSManagedObjectID) -> Photo { store.viewContext.object(with: id) as! Photo }

        func merge(_ ids: [NSManagedObjectID]? = nil, options: HDRMergeOptions = HDRMergeOptions()) async throws -> Photo {
            let ids = ids ?? self.ids
            let destination = try #require(editing.mergeDestination(for: ids, kind: .hdr))
            let output = try await HDRMergeRunner.run(
                sources: editing.photoMergeSources(ids), options: options, destination: destination,
                thumbnailDirectory: store.thumbnails.directory
            )
            let id = try #require(editing.addMergedPhoto(output, sources: ids, createsStack: options.createsStack))
            return photo(id)
        }
    }

    @Test func sourcesCarryTheCatalogsShootingDetails() async throws {
        let setup = try await Setup()
        let sources = setup.editing.photoMergeSources(setup.ids)
        #expect(sources.map(\.url.lastPathComponent) == ["IMG_0.dng", "IMG_1.dng", "IMG_2.dng"])
        #expect(sources[1].exposureTime == 0.01 && sources[1].aperture == 8 && sources[1].iso == 100)
        #expect(sources[1].make == "Canon" && sources[1].model == "EOS R5")
        // A virtual copy is the same file, so it isn't merged twice.
        let copies = setup.editing.createVirtualCopies(of: [setup.ids[0]])
        #expect(setup.editing.photoMergeSources(setup.ids + copies).count == 3)
    }

    @Test func mergedPhotoJoinsTheCatalogBesideItsSources() async throws {
        let setup = try await Setup()
        let first = setup.photo(setup.ids[0]), middle = setup.photo(setup.ids[1])
        first.tags.insert(Tag.findOrCreate(named: "Bracket", in: setup.store.viewContext))
        middle.tags.insert(Tag.findOrCreate(named: "Sunset", in: setup.store.viewContext))
        middle.rating = 4

        let merged = try await setup.merge()
        #expect(merged.fileName == "IMG_0-HDR.dng")
        #expect(merged.fileURL.deletingLastPathComponent() == first.fileURL.deletingLastPathComponent())
        #expect(FileManager.default.fileExists(atPath: merged.filePath))
        #expect(merged.folder == first.folder)
        #expect(merged.fileType == "DNG" && merged.fileSize > 0)
        #expect(merged.pixelWidth == Int32(setup.bracket.width) && merged.pixelHeight == Int32(setup.bracket.height))
        // The middle exposure is the reference.
        #expect(merged.captureDate == middle.captureDate)
        #expect(merged.cameraMake == "Canon" && merged.cameraModel == "EOS R5")
        #expect(merged.shutterSpeed == middle.shutterSpeed && merged.iso == middle.iso && merged.aperture == middle.aperture)
        #expect(Set(merged.tagNames) == ["Bracket", "Sunset"])
        #expect(merged.rating == 0 && merged.photoFlag == .unflagged && merged.colorLabel == 0)
        #expect(merged.stack == nil)
        #expect(FileManager.default.fileExists(atPath: setup.store.thumbnails.url(for: merged.id).path(percentEncoded: false)))
        #expect(merged.dedupeKey == merged.filePath)
    }

    @Test func secondMergeGetsTheNextName() async throws {
        let setup = try await Setup()
        _ = try await setup.merge()
        #expect(try await setup.merge().fileName == "IMG_0-HDR-2.dng")
    }

    @Test func createStackPutsTheMergeOnTop() async throws {
        let setup = try await Setup(stops: [0, 2, -2])
        var options = HDRMergeOptions()
        options.createsStack = true
        let merged = try await setup.merge(options: options)
        let stack = try #require(merged.stack)
        #expect(stack.isCollapsed)
        // The HDR on top, then the exposures darkest first.
        #expect(stack.orderedPhotos.map(\.fileName) == ["IMG_0-HDR.dng", "IMG_2.dng", "IMG_0.dng", "IMG_1.dng"])
        #expect(!merged.isHiddenInStack)
        #expect(setup.ids.allSatisfy { setup.photo($0).isHiddenInStack })
    }

    @Test func mergeJoinsTheStackItsSourcesShare() async throws {
        let setup = try await Setup()
        setup.editing.groupIntoStack(setup.ids)
        let stack = try #require(setup.photo(setup.ids[0]).stack)
        var options = HDRMergeOptions()
        options.createsStack = true
        let merged = try await setup.merge(options: options)
        #expect(merged.stack == stack)
        #expect(stack.orderedPhotos.first == merged)
        #expect(stack.photos.count == 4)
    }

    @Test func mergedPhotoStartsAtTheDefaultsWithTheCameraWhiteBalance() async throws {
        // As in Lightroom: Auto Settings' look is in the merge itself, and the white balance is As Shot.
        let setup = try await Setup()
        #expect(try await setup.merge().adjustments == PhotoAdjustments())
    }

    @Test func mergeIsNotUndoable() async throws {
        let setup = try await Setup()
        let undo = try #require(setup.store.viewContext.undoManager)
        undo.removeAllActions()
        _ = try await setup.merge(options: { var o = HDRMergeOptions(); o.createsStack = true; return o }())
        // Undoing would leave the new file behind, so the merge (like an import) isn't on the undo stack.
        #expect(!undo.canUndo)
    }

    @Test func menusOfferHDRAndPanoramaWithLightroomsShortcuts() async throws {
        let photoMenu = try #require(MainMenu.make().items.first { $0.title == "Photo" }?.submenu)
        let merge = try #require(photoMenu.items.first { $0.title == "Photo Merge" }?.submenu)
        let titles = ["HDR…", "HDR with Previous Settings", "Panorama…", "Panorama with Previous Settings"]
        #expect(merge.items.map(\.title) == titles)
        let hdr = merge.items[0], headlessHDR = merge.items[1], panorama = merge.items[2], headless = merge.items[3]
        #expect(hdr.keyEquivalent == "h" && hdr.keyEquivalentModifierMask == .control)
        #expect(panorama.keyEquivalent == "m" && panorama.keyEquivalentModifierMask == .control)
        // Holding Shift turns HDR… and Panorama… into the headless merges (⌃⇧H, ⌃⇧M).
        #expect(headlessHDR.isAlternate && headlessHDR.keyEquivalent == "h" && headlessHDR.keyEquivalentModifierMask == [.control, .shift])
        #expect(headless.isAlternate && headless.keyEquivalent == "m" && headless.keyEquivalentModifierMask == [.control, .shift])

        let setup = try await Setup()
        let controller = CatalogWindowController(store: setup.store)
        for item in [hdr, headlessHDR, panorama, headless] {
            controller.state.selectedPhotoIDs = [setup.ids[0]]
            #expect(!controller.validateUserInterfaceItem(item), "\(item.title) needs two photos")
            controller.state.selectedPhotoIDs = setup.ids
            #expect(controller.validateUserInterfaceItem(item), "\(item.title)")
        }
        let context = controller.rootViewController.main.library.grid.contextMenu()
        #expect(context.items.first { $0.title == "Photo Merge" }?.submenu?.items.map(\.title) == titles)
    }

    @Test("Says why photos can't be merged, from what the catalog knows (RAW-107)")
    func problemsFoundBeforeMerging() throws {
        let bracket = try Bracket()
        #expect(PhotoMergeSource.problem(merging: bracket.sources) == nil)
        #expect(PhotoMergeSource.problem(merging: [bracket.sources[0]]) == .tooFewPhotos)
        var jpeg = bracket.sources[1]
        jpeg.url = bracket.directory.url.appending(path: "a.jpg")
        #expect(PhotoMergeSource.problem(merging: [bracket.sources[0], jpeg]) == .notRaw("a.jpg"))
        var other = bracket.sources[1]
        other.model = "EOS R6"
        #expect(PhotoMergeSource.problem(merging: [bracket.sources[0], other]) == .differentCameras)
    }

    @Test("HDR with Previous Settings (⌃⇧H) merges with the saved options, then selects the result (RAW-107)")
    func headlessHDRMergeUsesTheLastSettings() async throws {
        let setup = try await Setup()
        var options = HDRMergeOptions()
        options.createsStack = true
        options.save()
        defer { Defaults.store.removeObject(forKey: "HDRMergeOptions") }

        let controller = CatalogWindowController(store: setup.store)
        defer { controller.close() }
        controller.showWindow(nil)
        controller.state.selectedPhotoIDs = setup.ids
        controller.photoMergeHDRWithPreviousSettings(nil)
        #expect(controller.window?.attachedSheet == nil, "no preview sheet")
        #expect(controller.state.mergeKind == .hdr)
        let task = try #require(controller.mergeTask)
        await task.value

        let selected = try #require(controller.state.selectedPhotoIDs.first)
        let merged = setup.photo(selected)
        #expect(controller.state.selectedPhotoIDs.count == 1)
        #expect(merged.fileName == "IMG_0-HDR.dng")
        #expect(merged.stack != nil, "Create Stack, as last saved")
    }

    @Test("A headless merge of photos that can't be merged says why instead of starting (RAW-107)")
    func headlessMergeExplainsWhyItCannotMerge() async throws {
        let setup = try await Setup()
        let jpeg = try Fixtures.writeJPEG(to: setup.bracket.directory.url.appending(path: "IMG_3.jpg"), width: 480, height: 320)
        _ = try await ImportService(store: setup.store).importPhotos(from: [jpeg])
        let request = Photo.fetchRequest()
        request.predicate = NSPredicate(format: "fileName == %@", "IMG_3.jpg")
        let jpegID = try #require(try setup.store.viewContext.fetch(request).first?.objectID)

        let controller = CatalogWindowController(store: setup.store)
        defer { controller.close() }
        controller.showWindow(nil)
        let window = try #require(controller.window)
        for merge in [controller.photoMergeHDRWithPreviousSettings, controller.photoMergePanoramaWithPreviousSettings] {
            // Two RAW photos make the menu item available; the JPEG among them can't be merged.
            controller.state.selectedPhotoIDs = setup.ids + [jpegID]
            merge(nil)
            #expect(controller.mergeTask == nil)
            let sheet = try #require(window.attachedSheet)
            #expect(sheet.contentView.flatMap { Self.text(in: $0) }?.contains("“IMG_3.jpg” isn’t a RAW photo") == true)
            window.endSheet(sheet)
        }
    }

    /// Every label's text in `view`, for reading an alert.
    private static func text(in view: NSView) -> String {
        ((view as? NSTextField)?.stringValue ?? "") + view.subviews.map { text(in: $0) }.joined(separator: "\n")
    }

    @Test func gridShowsTheMergedPhoto() async throws {
        let setup = try await Setup()
        let controller = CatalogWindowController(store: setup.store)
        let grid = controller.rootViewController.main.library.grid
        grid.loadViewIfNeeded()
        let merged = try await setup.merge()
        // The grid gets the photo under its permanent id, the one the selection and inspector use.
        #expect(controller.state.photoOrder.contains(merged.objectID))
        #expect(!controller.state.photoOrder.contains { $0.isTemporaryID })
        controller.state.selectedPhotoIDs = [merged.objectID]
        #expect(controller.state.selectedPhotoIDs == [merged.objectID])
    }

    @Test func cancellingWritesNothing() async throws {
        let setup = try await Setup()
        let destination = try #require(setup.editing.mergeDestination(for: setup.ids, kind: .hdr))
        let sources = setup.editing.photoMergeSources(setup.ids)
        let directory = setup.store.thumbnails.directory
        let task = Task {
            try await HDRMergeRunner.run(sources: sources, options: HDRMergeOptions(), destination: destination, thumbnailDirectory: directory)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }
}
