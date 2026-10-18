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
            let destination = try #require(editing.hdrDestination(for: ids))
            let output = try await HDRMergeRunner.run(
                sources: editing.hdrMergeSources(ids), options: options, destination: destination,
                thumbnailDirectory: store.thumbnails.directory
            )
            let id = try #require(editing.addMergedHDR(output, sources: ids, createsStack: options.createsStack))
            return photo(id)
        }
    }

    @Test func sourcesCarryTheCatalogsShootingDetails() async throws {
        let setup = try await Setup()
        let sources = setup.editing.hdrMergeSources(setup.ids)
        #expect(sources.map(\.url.lastPathComponent) == ["IMG_0.dng", "IMG_1.dng", "IMG_2.dng"])
        #expect(sources[1].exposureTime == 0.01 && sources[1].aperture == 8 && sources[1].iso == 100)
        #expect(sources[1].make == "Canon" && sources[1].model == "EOS R5")
        // A virtual copy is the same file, so it isn't merged twice.
        let copies = setup.editing.createVirtualCopies(of: [setup.ids[0]])
        #expect(setup.editing.hdrMergeSources(setup.ids + copies).count == 3)
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

    @Test func menusOfferHDRWithLightroomsShortcut() async throws {
        let photoMenu = try #require(MainMenu.make().items.first { $0.title == "Photo" }?.submenu)
        let merge = try #require(photoMenu.items.first { $0.title == "Photo Merge" }?.submenu)
        #expect(merge.items.map(\.title) == ["HDR…", "Panorama…"])
        let hdr = merge.items[0], panorama = merge.items[1]
        #expect(hdr.keyEquivalent == "h" && hdr.keyEquivalentModifierMask == .control)
        // ⌃M is Lightroom's Panorama shortcut, left free until Panorama exists.
        #expect(panorama.keyEquivalent.isEmpty)

        let setup = try await Setup()
        let controller = CatalogWindowController(store: setup.store)
        #expect(!controller.responds(to: #selector(PixelLoupeActions.photoMergePanorama(_:))), "Panorama stays disabled")
        controller.state.selectedPhotoIDs = [setup.ids[0]]
        #expect(!controller.validateUserInterfaceItem(hdr), "needs two photos")
        controller.state.selectedPhotoIDs = setup.ids
        #expect(controller.validateUserInterfaceItem(hdr))
        let context = controller.rootViewController.main.library.grid.contextMenu()
        #expect(context.items.first { $0.title == "Photo Merge" }?.submenu?.items.map(\.title) == ["HDR…", "Panorama…"])
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
        let destination = try #require(setup.editing.hdrDestination(for: setup.ids))
        let sources = setup.editing.hdrMergeSources(setup.ids)
        let directory = setup.store.thumbnails.directory
        let task = Task {
            try await HDRMergeRunner.run(sources: sources, options: HDRMergeOptions(), destination: destination, thumbnailDirectory: directory)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
    }
}
