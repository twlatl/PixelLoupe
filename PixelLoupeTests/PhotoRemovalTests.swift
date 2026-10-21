import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Removing photos")
@MainActor
struct PhotoRemovalTests {
    /// A catalog with three photos in a folder of real files, the first tagged, edited and with an
    /// XMP sidecar. Removal moves files into `trash` (a folder of the test's own, not the Finder's
    /// Trash).
    private struct Setup {
        let directory: TemporaryDirectory
        let store: CatalogStore
        let photos: [Photo]
        let trashFolder: URL
        var removal: PhotoRemoval

        var undoManager: UndoManager { store.viewContext.undoManager! }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

        func photoCount() throws -> Int { try store.viewContext.count(for: Photo.fetchRequest()) }
    }

    private func makeSetup() throws -> Setup {
        let directory = try TemporaryDirectory()
        let folderURL = try directory.subdirectory("Photos")
        let trashFolder = try directory.subdirectory("Trash")
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let context = store.viewContext
        let folder = Folder(context: context)
        folder.path = folderURL.path(percentEncoded: false)
        folder.name = "Photos"
        let tag = PixelLoupe.Tag(context: context)
        tag.name = "Family"
        var photos: [Photo] = []
        for index in 0..<3 {
            let url = folderURL.appending(path: "IMG_\(index).jpg")
            try Fixtures.writeJPEG(to: url)
            let photo = Photo(context: context)
            photo.id = UUID()
            photo.fileName = url.lastPathComponent
            photo.filePath = url.path(percentEncoded: false)
            photo.fileType = "JPG"
            photo.captureDate = Date(timeIntervalSince1970: Double(index))
            photo.importDate = Date()
            photo.editDate = Date()
            photo.folder = folder
            photos.append(photo)
        }
        photos[0].tags = [tag]
        photos[0].rating = 4
        var adjustments = PhotoAdjustments()
        adjustments.light.exposure = 0.5
        photos[0].adjustments = adjustments
        try Data("<x:xmpmeta/>".utf8).write(to: folderURL.appending(path: "IMG_0.xmp"))
        try context.save()
        context.undoManager?.removeAllActions()

        let trash = PhotoRemoval.Trash { file in
            let destination = trashFolder.appending(path: "\(UUID().uuidString)-\(file.lastPathComponent)")
            try FileManager.default.moveItem(at: file, to: destination)
            return destination
        }
        return Setup(directory: directory, store: store, photos: photos, trashFolder: trashFolder,
                     removal: PhotoRemoval(store: store, trash: trash))
    }

    @Test func findsSidecars() throws {
        let directory = try TemporaryDirectory()
        let photo = directory.url.appending(path: "DSC1.ARW")
        try Data().write(to: photo)
        #expect(PhotoRemoval.files(for: photo) == [photo])
        try Data().write(to: directory.url.appending(path: "DSC1.xmp"))
        try Data().write(to: directory.url.appending(path: "DSC1.ARW.xmp"))
        #expect(PhotoRemoval.files(for: photo).map(\.lastPathComponent) == ["DSC1.ARW", "DSC1.xmp", "DSC1.ARW.xmp"])
    }

    @Test func removingFromTheCatalogKeepsTheFilesAndUndoes() throws {
        let setup = try makeSetup()
        let first = setup.photos[0]
        let file = first.fileURL, id = first.id
        #expect(setup.removal.remove([first.objectID], trash: false, actionName: "Remove Photo") == nil)
        #expect(try setup.photoCount() == 2)
        #expect(setup.exists(file), "the file stays on disk")
        #expect(setup.undoManager.undoActionName == "Remove Photo")

        setup.undoManager.undo()
        setup.store.save()
        let request = Photo.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        let restored = try #require(try setup.store.viewContext.fetch(request).first)
        #expect(restored.rating == 4 && restored.adjustments.light.exposure == 0.5, "edits come back")
        #expect(restored.tagNames == ["Family"] && restored.folder != nil, "keywords and folder too")

        setup.undoManager.redo()
        #expect(try setup.photoCount() == 2)
    }

    @Test func deletingFromDiskTrashesFilesAndSidecarsAndUndoBringsThemBack() throws {
        let setup = try makeSetup()
        let file = setup.photos[0].fileURL
        let sidecar = file.deletingPathExtension().appendingPathExtension("xmp")
        let second = setup.photos[1].fileURL
        let ids = setup.photos.prefix(2).map(\.objectID)
        #expect(setup.removal.remove(Array(ids), trash: true, actionName: "Remove Photos") == nil)
        #expect(try setup.photoCount() == 1)
        #expect(!setup.exists(file) && !setup.exists(sidecar) && !setup.exists(second))
        #expect(try FileManager.default.contentsOfDirectory(atPath: setup.trashFolder.path(percentEncoded: false)).count == 3)

        setup.undoManager.undo()
        #expect(try setup.photoCount() == 3)
        #expect(setup.exists(file) && setup.exists(sidecar), "files are back where they were")
        #expect(try FileManager.default.contentsOfDirectory(atPath: setup.trashFolder.path(percentEncoded: false)).isEmpty)

        setup.undoManager.redo()
        #expect(try setup.photoCount() == 1)
        #expect(!setup.exists(file) && !setup.exists(sidecar), "redo trashes them again")
        setup.undoManager.undo()
        #expect(setup.exists(file) && setup.exists(sidecar), "and undo still works after redo")
    }

    @Test func aFileThatCantBeTrashedKeepsItsPhoto() throws {
        var setup = try makeSetup()
        let locked = setup.photos[1].fileURL
        let inner = setup.removal.trash
        setup.removal.trash = PhotoRemoval.Trash { file in
            if file == locked { throw CocoaError(.fileWriteNoPermission) }
            return try inner.move(file)
        }
        let failure = setup.removal.remove(setup.photos.map(\.objectID), trash: true, actionName: "Remove Photos")
        #expect(failure == PhotoRemoval.Failure(fileNames: ["IMG_1.jpg"]))
        #expect(try setup.photoCount() == 1, "only the locked one stays")
        #expect(setup.exists(locked))
    }

    @Test func aMissingFileStillRemovesItsPhoto() throws {
        let setup = try makeSetup()
        try FileManager.default.removeItem(at: setup.photos[2].fileURL)
        #expect(setup.removal.remove([setup.photos[2].objectID], trash: true, actionName: "Remove Photo") == nil)
        #expect(try setup.photoCount() == 2)
    }

    @Test func thumbnailsOfRemovedPhotosArePrunedOnOpen() async throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "Prune.pixelloupe", directoryHint: .isDirectory)
        let store = try CatalogStore.create(at: packageURL, info: Fixtures.referencedInfo)
        let photo = Photo(context: store.viewContext)
        photo.id = UUID()
        photo.fileName = "a.jpg"
        photo.filePath = "/nowhere/a.jpg"
        photo.fileType = "JPG"
        photo.captureDate = Date()
        photo.importDate = Date()
        photo.editDate = Date()
        try store.viewContext.save()
        let kept = store.thumbnails.url(for: photo.id), orphan = store.thumbnails.url(for: UUID())
        let unrelated = store.thumbnails.directory.appending(path: "notes.txt")
        for url in [kept, orphan, unrelated] { try Data([1]).write(to: url) }

        store.pruneOrphanedPreviews()
        for _ in 0..<50 where FileManager.default.fileExists(atPath: orphan.path(percentEncoded: false)) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!FileManager.default.fileExists(atPath: orphan.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: kept.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: unrelated.path(percentEncoded: false)))
    }
}

@Suite("Remove Photo commands")
@MainActor
struct RemoveCommandTests {
    /// A catalog window with four photos (the 2nd and 4th rejected), in capture order.
    private func makeWindow() throws -> (CatalogWindowController, [NSManagedObjectID], TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        for index in 0..<4 {
            let photo = Photo(context: store.viewContext)
            photo.id = UUID()
            photo.fileName = "IMG_\(index).jpg"
            photo.filePath = directory.url.appending(path: photo.fileName).path(percentEncoded: false)
            photo.fileType = "JPG"
            photo.captureDate = Date(timeIntervalSince1970: Double(index) * 60)
            photo.importDate = Date()
            photo.editDate = Date()
            photo.photoFlag = index % 2 == 1 ? .rejected : .unflagged
        }
        try store.viewContext.save()
        let controller = CatalogWindowController(store: store)
        controller.showWindow(nil)
        controller.window?.layoutIfNeeded()
        return (controller, controller.state.photoOrder, directory)
    }

    /// Answers the open dialog with one of its buttons.
    private func answer(_ controller: CatalogWindowController, _ response: NSApplication.ModalResponse) throws {
        let window = try #require(controller.window)
        let sheet = try #require(window.attachedSheet)
        window.endSheet(sheet, returnCode: response)
    }

    @Test func removePhotoAsksThenSelectsTheNextPhoto() throws {
        let (controller, order, directory) = try makeWindow()
        defer { controller.close(); _ = directory }
        #expect(order.count == 4)
        controller.state.selectedPhotoIDs = [order[1]]
        controller.removePhoto(nil)
        #expect(controller.window?.attachedSheet != nil, "asks first")
        try answer(controller, .alertFirstButtonReturn)   // Remove from PixelLoupe
        #expect(controller.state.photoOrder == [order[0], order[2], order[3]])
        #expect(controller.state.selectedPhotoIDs == [order[2]], "the next photo is selected")
        #expect(controller.store.viewContext.undoManager?.undoActionName == "Remove Photo")
    }

    @Test func theGridsContextMenuHasRemovePhotoAboveShowInFinder() throws {
        let (controller, order, directory) = try makeWindow()
        defer { controller.close(); _ = directory }
        controller.state.selectedPhotoIDs = [order[0]]
        let menu = controller.rootViewController.main.library.grid.contextMenu()
        let titles = menu.items.map(\.title)
        let remove = try #require(titles.firstIndex(of: "Remove Photo…"))
        #expect(titles[remove + 1] == "Show in Finder")
        // It opens the same dialog as Photo ▸ Remove Photo, reached up the responder chain from
        // the grid (the menu has no fixed target).
        let item = menu.items[remove]
        #expect(item.target == nil)
        let grid = controller.rootViewController.main.library.grid
        #expect(grid.view.tryToPerform(try #require(item.action), with: item))
        #expect(controller.window?.attachedSheet != nil)
        try answer(controller, .alertThirdButtonReturn)
    }

    @Test func cancelChangesNothing() throws {
        let (controller, order, directory) = try makeWindow()
        defer { controller.close(); _ = directory }
        controller.state.selectedPhotoIDs = [order[0], order[1]]
        controller.removeSelectedPhotos(nil)
        try answer(controller, .alertThirdButtonReturn)   // Cancel
        #expect(controller.state.photoOrder.count == 4)
    }

    @Test func deleteRejectedShowsOnlyRejectedThenRestoresTheView() throws {
        let (controller, order, directory) = try makeWindow()
        defer { controller.close(); _ = directory }
        controller.state.filter.attributes.rating = nil
        controller.state.selectedPhotoIDs = [order[0], order[1]]
        let before = controller.state.filter
        controller.deleteRejectedPhotos(nil)
        #expect(controller.state.filter.attributes.flags == [.rejected], "only the rejected photos are shown")
        #expect(controller.state.photoOrder == [order[1], order[3]])
        let alert = try #require(controller.window?.attachedSheet)
        let message = alert.contentView?.descendants.compactMap { ($0 as? NSTextField)?.stringValue } ?? []
        #expect(message.contains("Delete the 2 rejected master photos from disk, or just remove them from PixelLoupe?"))
        try answer(controller, .alertFirstButtonReturn)   // Remove from PixelLoupe
        #expect(controller.state.filter == before, "the previous view comes back")
        #expect(controller.state.photoOrder == [order[0], order[2]])
        #expect(controller.state.selectedPhotoIDs == [order[0]], "removed photos leave the selection")
    }

    @Test func deleteRejectedWithNoneRejectedSaysSo() throws {
        let (controller, order, directory) = try makeWindow()
        defer { controller.close(); _ = directory }
        controller.state.filter.scope = .folder(path: "/nowhere")
        controller.deleteRejectedPhotos(nil)
        #expect(controller.state.filter.attributes.flags.isEmpty, "the view doesn't change")
        try answer(controller, .alertFirstButtonReturn)
        #expect(order.count == 4)
    }
}
