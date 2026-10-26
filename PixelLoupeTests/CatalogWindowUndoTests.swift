import AppKit
import Foundation
import Testing
@testable import PixelLoupe

@MainActor
@Suite("⌘Z in the catalog window (RAW-194)", .serialized)
struct CatalogWindowUndoTests {
    @Test("The window undoes with the catalog's undo manager, from the start")
    func windowUsesTheCatalogsUndoManager() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let controller = CatalogWindowController(store: store)
        defer { controller.close() }
        let window = try #require(controller.window)
        #expect(window.undoManager === store.viewContext.undoManager)
        #expect(window.firstResponder?.undoManager === store.viewContext.undoManager)
    }

    @Test("⌘Z (Undo up the responder chain) undoes an edit made in the window")
    func commandZUndoesAnEdit() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let photo = Photo(context: store.viewContext)
        photo.id = UUID()
        photo.fileName = "IMG.jpg"
        photo.filePath = directory.url.appending(path: photo.fileName).path(percentEncoded: false)
        photo.fileType = "JPG"
        photo.pixelWidth = 600
        photo.pixelHeight = 400
        photo.captureDate = Date()
        photo.importDate = Date()
        photo.editDate = Date()
        try store.viewContext.save()
        let undo = try #require(store.viewContext.undoManager)
        undo.removeAllActions()
        // One user action as one undo group, as AppKit closes a group at the end of each event.
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }

        let controller = CatalogWindowController(store: store)
        controller.showWindow(nil)
        defer { controller.close() }
        let window = try #require(controller.window)
        controller.state.selectedPhotoIDs = [photo.objectID]

        undo.beginUndoGrouping()
        #expect(controller.perform(.rating(3)))
        undo.endUndoGrouping()
        #expect(photo.rating == 3)

        #expect(window.firstResponder?.tryToPerform(Selector(("undo:")), with: nil) == true)
        #expect(photo.rating == 0, "undone")
    }
}
