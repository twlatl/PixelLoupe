import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

/// RAW-259: each Library source remembers its selection.
@Suite("Selection per source")
struct SourceSelectionTests {
    /// A catalog with photos a0–a3 in /A and b0–b1 in /B, in capture order.
    private struct Catalog {
        let directory: TemporaryDirectory
        let store: CatalogStore
        let a: [UUID]
        let b: [UUID]
        var packageURL: URL { store.packageURL }
    }

    private func makeCatalog() throws -> Catalog {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.create(at: directory.url.appending(path: "Sources.pixelloupe", directoryHint: .isDirectory),
                                            info: Fixtures.referencedInfo)
        let context = store.viewContext
        var time = 0.0
        func photos(_ count: Int, in path: String) -> [UUID] {
            let folder = Folder(context: context)
            folder.path = path
            folder.name = (path as NSString).lastPathComponent
            return (0..<count).map { index in
                let photo = Photo(context: context)
                photo.id = UUID()
                photo.fileName = "\(index).jpg"
                photo.filePath = "\(path)/\(index).jpg"
                photo.fileType = "JPG"
                time += 60
                photo.captureDate = Date(timeIntervalSince1970: time)
                photo.importDate = Date()
                photo.editDate = Date()
                photo.folder = folder
                return photo.id
            }
        }
        let a = photos(4, in: "/A")
        let b = photos(2, in: "/B")
        try context.save()
        return Catalog(directory: directory, store: store, a: a, b: b)
    }

    private func window(for store: CatalogStore) -> CatalogWindowController {
        let controller = CatalogWindowController(store: store)
        controller.showWindow(nil)
        return controller
    }

    private func objectIDs(_ ids: [UUID], in store: CatalogStore) throws -> [NSManagedObjectID] {
        let photos = try store.viewContext.fetch(Photo.fetchRequest())
        return ids.compactMap { id in photos.first { $0.id == id }?.objectID }
    }

    private func selected(_ controller: CatalogWindowController, in store: CatalogStore) -> [UUID] {
        controller.state.selectedPhotoIDs.compactMap { (try? store.viewContext.existingObject(with: $0) as? Photo)?.id }
    }

    @Test func comingBackToAFolderSelectsWhatItHadSelected() throws {
        let catalog = try makeCatalog()
        let controller = window(for: catalog.store)
        defer { controller.close() }
        let state = controller.state

        state.filter.scope = .folder(path: "/A")
        state.selectedPhotoIDs = try objectIDs([catalog.a[2], catalog.a[0]], in: catalog.store)
        state.filter.scope = .folder(path: "/B")
        #expect(state.selectedPhotoIDs.isEmpty, "nothing in /B was selected yet")
        state.selectedPhotoIDs = try objectIDs([catalog.b[1]], in: catalog.store)

        state.filter.scope = .folder(path: "/A")
        #expect(selected(controller, in: catalog.store) == [catalog.a[2], catalog.a[0]], "the active photo is still first")
        state.filter.scope = .folder(path: "/B")
        #expect(selected(controller, in: catalog.store) == [catalog.b[1]])
    }

    @Test func aSelectionThatsInTheNewSourceCarriesOver() throws {
        let catalog = try makeCatalog()
        let controller = window(for: catalog.store)
        defer { controller.close() }
        let state = controller.state

        state.filter.scope = .allPhotos
        state.selectedPhotoIDs = try objectIDs([catalog.a[1]], in: catalog.store)
        state.filter.scope = .folder(path: "/B")
        state.selectedPhotoIDs = try objectIDs([catalog.b[0]], in: catalog.store)
        // b0 is in All Photographs too: it stays selected rather than All Photographs' a1 coming back.
        state.filter.scope = .allPhotos
        #expect(selected(controller, in: catalog.store) == [catalog.b[0]])
        // …and that's now what All Photographs remembers.
        state.filter.scope = .folder(path: "/A")
        #expect(state.selectedPhotoIDs.isEmpty)
        state.filter.scope = .allPhotos
        #expect(selected(controller, in: catalog.store) == [catalog.b[0]])
    }

    @Test func aSelectionMadeWithTheSourceWins() throws {
        let catalog = try makeCatalog()
        let controller = window(for: catalog.store)
        defer { controller.close() }
        let state = controller.state

        state.filter.scope = .folder(path: "/A")
        state.selectedPhotoIDs = try objectIDs([catalog.a[0]], in: catalog.store)
        state.filter.scope = .folder(path: "/B")
        // As Synchronize Folder ▸ Show Missing does: the folder, then the photos to select in it.
        state.filter.scope = .folder(path: "/A")
        state.selectedPhotoIDs = try objectIDs([catalog.a[3]], in: catalog.store)
        state.filter.scope = .folder(path: "/B")
        state.filter.scope = .folder(path: "/A")
        #expect(selected(controller, in: catalog.store) == [catalog.a[3]])
    }

    @Test func photosAFilterHidesComeBackWhenItsCleared() throws {
        let catalog = try makeCatalog()
        let rated = try catalog.store.viewContext.fetch(Photo.fetchRequest()).first { $0.id == catalog.a[2] }
        rated?.rating = 5
        try catalog.store.viewContext.save()
        let controller = window(for: catalog.store)
        defer { controller.close() }
        let state = controller.state

        state.filter.scope = .folder(path: "/A")
        state.selectedPhotoIDs = try objectIDs([catalog.a[0], catalog.a[2]], in: catalog.store)
        state.filter.attributes.rating = 5
        #expect(selected(controller, in: catalog.store) == [catalog.a[2]], "only the shown photo stays selected")
        state.filter.attributes.rating = nil
        #expect(selected(controller, in: catalog.store) == [catalog.a[0], catalog.a[2]])

        // Hidden photos stay remembered when switching sources too, and when saved.
        state.filter.attributes.rating = 3
        state.filter.scope = .folder(path: "/B")
        state.filter.attributes.rating = nil
        state.filter.scope = .folder(path: "/A")
        #expect(selected(controller, in: catalog.store) == [catalog.a[0], catalog.a[2]])
        state.filter.attributes.rating = 5
        controller.saveSelection()
        #expect(catalog.store.viewState.selectedPhotos == [catalog.a[0], catalog.a[2]])
    }

    @Test func aPhotoInACollapsedStackIsShownAsItsTopPhoto() throws {
        let catalog = try makeCatalog()
        let controller = window(for: catalog.store)
        defer { controller.close() }
        let state = controller.state
        let editing = PhotoEditing(store: catalog.store)

        state.filter.scope = .folder(path: "/A")
        let ids = try objectIDs(catalog.a, in: catalog.store)
        #expect(editing.groupIntoStack([ids[1], ids[2]]))   // collapsed, under a1
        editing.toggleCollapsed([ids[1]])                   // expanded
        state.selectedPhotoIDs = [ids[2]]

        editing.toggleCollapsed([ids[1]])
        #expect(state.selectedPhotoIDs == [ids[1]], "the top photo stands in for the hidden one")
        editing.toggleCollapsed([ids[1]])
        #expect(state.selectedPhotoIDs == [ids[2]], "expanding selects the photo again")
    }

    @Test func eachSourcesSelectionIsSavedWithTheCatalog() throws {
        let catalog = try makeCatalog()
        do {
            let controller = window(for: catalog.store)
            controller.state.filter.scope = .folder(path: "/B")
            controller.state.selectedPhotoIDs = try objectIDs([catalog.b[1]], in: catalog.store)
            controller.state.filter.scope = .folder(path: "/A")
            controller.state.selectedPhotoIDs = try objectIDs([catalog.a[3]], in: catalog.store)
            controller.close()
        }
        let reopened = try CatalogStore.open(at: catalog.packageURL)
        let controller = window(for: reopened)
        defer { controller.close() }
        #expect(selected(controller, in: reopened) == [catalog.a[3]])
        controller.state.filter.scope = .folder(path: "/B")
        #expect(selected(controller, in: reopened) == [catalog.b[1]])
    }

    @Test func renamingAFolderKeepsItsSelection() throws {
        let catalog = try makeCatalog()
        let controller = window(for: catalog.store)
        defer { controller.close() }
        let state = controller.state

        state.filter.scope = .folder(path: "/B")
        state.selectedPhotoIDs = try objectIDs([catalog.b[1]], in: catalog.store)
        state.filter.scope = .folder(path: "/A")
        let folder = try #require(try catalog.store.viewContext.fetch(Folder.fetchRequest()).first { $0.path == "/B" })
        folder.path = "/C"
        try catalog.store.viewContext.save()
        controller.followFolder(from: "/B", to: "/C")
        state.filter.scope = .folder(path: "/C")
        #expect(selected(controller, in: catalog.store) == [catalog.b[1]])
    }
}

/// The remembered selections themselves.
@Suite("Selection memory")
struct SelectionMemoryTests {
    private func store() throws -> (TemporaryDirectory, CatalogStore, [NSManagedObjectID]) {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.create(at: directory.url.appending(path: "Memory.pixelloupe", directoryHint: .isDirectory),
                                            info: Fixtures.referencedInfo)
        let folder = Folder(context: store.viewContext)
        folder.path = "/A"
        folder.name = "A"
        let photos = (0..<3).map { index in
            let photo = Photo(context: store.viewContext)
            photo.id = UUID()
            photo.fileName = "\(index).jpg"
            photo.filePath = "/A/\(index).jpg"
            photo.fileType = "JPG"
            photo.captureDate = Date()
            photo.importDate = Date()
            photo.editDate = Date()
            photo.folder = folder
            return photo
        }
        try store.viewContext.save()
        return (directory, store, photos.map(\.objectID))
    }

    @Test func foldersInsideARenamedFolderMoveWithIt() throws {
        let (directory, store, ids) = try store()
        defer { _ = directory }
        let memory = SelectionMemory(saved: [], context: store.viewContext)
        memory.remember([ids[0]], for: .folder(path: "/A"))
        memory.remember([ids[1]], for: .folder(path: "/A/Inside"))
        memory.remember([ids[2]], for: .folder(path: "/AB"))
        memory.renameFolder(from: "/A", to: "/Z")
        #expect(memory.selection(for: .folder(path: "/Z")) == [ids[0]])
        #expect(memory.selection(for: .folder(path: "/Z/Inside")) == [ids[1]])
        #expect(memory.selection(for: .folder(path: "/AB")) == [ids[2]], "only the folder and the ones inside it")
        #expect(memory.selection(for: .folder(path: "/A")) == nil)
    }

    @Test func onlyTheLatestImportIsRemembered() throws {
        let (directory, store, ids) = try store()
        defer { _ = directory }
        let memory = SelectionMemory(saved: [], context: store.viewContext)
        let (first, second) = (UUID(), UUID())
        memory.remember([ids[0]], for: .previousImport(id: first))
        memory.remember([ids[1]], for: .previousImport(id: second))
        #expect(memory.selection(for: .previousImport(id: second)) == [ids[1]])
        #expect(memory.selection(for: .previousImport(id: first)) == nil)
        #expect(memory.saved.count == 1)
    }

    @Test func theSourcesVisitedLongestAgoAreForgotten() throws {
        let (directory, store, ids) = try store()
        defer { _ = directory }
        let memory = SelectionMemory(saved: [], context: store.viewContext)
        for index in 0..<(SelectionMemory.maximumSources + 5) {
            memory.remember([ids[0]], for: .collection(id: UUID(), content: .members(UUID())))
            if index == 0 { memory.remember([ids[1]], for: .allPhotos) }
        }
        #expect(memory.saved.count == SelectionMemory.maximumSources)
        #expect(memory.selection(for: .allPhotos) == nil, "All Photographs was remembered second")
    }

    @Test func savedSelectionsForSourcesThatAreGoneAreDropped() throws {
        let (directory, store, ids) = try store()
        defer { _ = directory }
        let photoID = try #require((try store.viewContext.existingObject(with: ids[0]) as? Photo)?.id)
        let saved = [
            RememberedSelection(source: .folder(path: "/A"), photos: [photoID]),
            RememberedSelection(source: .folder(path: "/Gone"), photos: [photoID]),
            RememberedSelection(source: .collection(id: UUID()), photos: [photoID]),
            RememberedSelection(source: .previousImport(id: UUID()), photos: [photoID]),
            RememberedSelection(source: .allPhotos, photos: [photoID]),
        ]
        let memory = SelectionMemory(saved: saved, context: store.viewContext)
        #expect(memory.saved.map(\.source) == [.folder(path: "/A"), .allPhotos])
        #expect(memory.selection(for: .folder(path: "/A")) == [ids[0]])
    }

    @Test func aSavedStateRoundTrips() throws {
        var state = CatalogViewState(folderPath: "/A")
        state.sourceSelections = [RememberedSelection(source: .publishAlbum(id: UUID()), photos: [UUID()])]
        let data = try PropertyListEncoder().encode(state)
        #expect(try PropertyListDecoder().decode(CatalogViewState.self, from: data) == state)
    }
}
