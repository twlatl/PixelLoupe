import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Previous Import")
struct PreviousImportTests {
    /// Adds photos as one import, or with no import id as photos made in the app (a merge, an Edit In
    /// copy) or imported before import ids were recorded.
    @discardableResult
    private func addPhotos(_ names: [String], importID: UUID?, at date: Date, to store: CatalogStore) throws -> [Photo] {
        let context = store.viewContext
        let photos = names.map { name in
            let photo = Photo(context: context)
            photo.id = UUID()
            photo.fileName = name
            photo.filePath = "/Photos/" + name
            photo.fileType = "JPG"
            photo.captureDate = date
            photo.importDate = date
            photo.importID = importID
            photo.editDate = date
            return photo
        }
        try context.save()
        return photos
    }

    private func names(in scope: LibraryFilter.Scope, of store: CatalogStore) throws -> [String] {
        var filter = LibraryFilter()
        filter.scope = scope
        let request = Photo.fetchRequest()
        request.predicate = filter.predicate
        request.sortDescriptors = [NSSortDescriptor(key: #keyPath(Photo.fileName), ascending: true)]
        return try store.viewContext.fetch(request).map(\.fileName)
    }

    private func makeStore(_ directory: TemporaryDirectory) throws -> CatalogStore {
        try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "Test.pixelloupe"))
    }

    private let earlier = Date(timeIntervalSince1970: 1_800_000_000)
    private var later: Date { earlier + 3_600 }

    // MARK: - The filter

    @Test func showsTheNewestImportAndNotPhotosMadeInTheApp() throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore(directory)
        let first = UUID(), second = UUID()
        try addPhotos(["a.jpg", "b.jpg"], importID: first, at: earlier, to: store)
        try addPhotos(["c.jpg"], importID: second, at: later, to: store)
        // A panorama merged after the import is newer, but wasn't imported.
        try addPhotos(["Pano.dng"], importID: nil, at: later + 60, to: store)

        #expect(Photo.latestImportID(in: store.viewContext) == second)
        #expect(try names(in: .previousImport(id: second), of: store) == ["c.jpg"])
        #expect(try names(in: .previousImport(id: first), of: store) == ["a.jpg", "b.jpg"])
    }

    @Test func thereIsNoPreviousImportUntilSomethingIsImported() throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore(directory)
        #expect(Photo.latestImportID(in: store.viewContext) == nil)
        // Photos imported before import ids were recorded don't count.
        try addPhotos(["old.jpg"], importID: nil, at: earlier, to: store)
        #expect(Photo.latestImportID(in: store.viewContext) == nil)
    }

    @Test func removingTheLastImportFallsBackToTheOneBefore() throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore(directory)
        let first = UUID()
        try addPhotos(["a.jpg"], importID: first, at: earlier, to: store)
        let newest = try addPhotos(["b.jpg"], importID: UUID(), at: later, to: store)
        store.viewContext.delete(newest[0])
        try store.viewContext.save()
        #expect(Photo.latestImportID(in: store.viewContext) == first)
    }

    @Test func aVirtualCopyStaysWithItsImport() throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore(directory)
        let id = UUID()
        let photos = try addPhotos(["a.jpg"], importID: id, at: earlier, to: store)
        PhotoEditing(store: store).createVirtualCopies(of: [photos[0].objectID])
        try store.viewContext.save()
        let shown = try store.viewContext.fetch(Photo.fetchRequest()).filter { $0.importID == id }
        #expect(shown.count == 2 && shown.contains(where: \.isVirtualCopy))
    }

    // MARK: - The sidebar

    private func sidebar(for store: CatalogStore, state: LibraryState = LibraryState()) -> (SidebarViewController, NSOutlineView) {
        let controller = SidebarViewController(store: store, state: state)
        controller.view.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        let outline = controller.view.descendants.compactMap { $0 as? NSOutlineView }.first!
        return (controller, outline)
    }

    private func previousImportRow(in outline: NSOutlineView) throws -> (row: Int, item: SidebarViewController.Item) {
        let row = try #require((0..<outline.numberOfRows).first {
            if case .previousImport = (outline.item(atRow: $0) as? SidebarViewController.Item)?.kind { true } else { false }
        })
        return (row, try #require(outline.item(atRow: row) as? SidebarViewController.Item))
    }

    @Test func theRowIsUnderAllPhotographsAndDimmedUntilThereIsAnImport() throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore(directory)
        try addPhotos(["old.jpg"], importID: nil, at: earlier, to: store)
        let (controller, outline) = sidebar(for: store)

        let (row, item) = try previousImportRow(in: outline)
        let above = try #require(outline.item(atRow: row - 1) as? SidebarViewController.Item)
        guard case .allPhotos = above.kind else { Issue.record("Previous Import isn't below All Photographs"); return }
        #expect(item.title == "Previous Import")
        #expect(outline.parent(forItem: item) as? SidebarViewController.Item === outline.parent(forItem: above) as? SidebarViewController.Item)
        // Nothing to show: no count, can't be selected, dimmed.
        #expect(item.scope == nil && item.count == nil)
        #expect(!controller.outlineView(outline, shouldSelectItem: item))
        let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView)
        #expect(!cell.isAccessibilityEnabled())
        #expect(cell.textField?.textColor == .tertiaryLabelColor)
        #expect(cell.accessibilityIdentifier() == "previousImport")
    }

    @Test func selectingTheRowShowsTheNewestImport() throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore(directory)
        let id = UUID()
        try addPhotos(["old.jpg"], importID: UUID(), at: earlier, to: store)
        try addPhotos(["a.jpg", "b.jpg"], importID: id, at: later, to: store)
        let state = LibraryState()
        let (controller, outline) = sidebar(for: store, state: state)

        let (row, item) = try previousImportRow(in: outline)
        #expect(item.count == 2)
        #expect(controller.outlineView(outline, shouldSelectItem: item))
        let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView)
        #expect(cell.isAccessibilityEnabled() && cell.textField?.textColor == .labelColor)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        #expect(state.filter.scope == .previousImport(id: id))
        #expect(try names(in: state.filter.scope, of: store) == ["a.jpg", "b.jpg"])
    }

    @Test func showingPreviousImportMovesOnToANewImport() throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore(directory)
        let first = UUID(), second = UUID()
        try addPhotos(["a.jpg"], importID: first, at: earlier, to: store)
        let state = LibraryState()
        state.filter.scope = .previousImport(id: first)
        let (controller, outline) = sidebar(for: store, state: state)

        let photos = try addPhotos(["b.jpg", "c.jpg"], importID: second, at: later, to: store)
        controller.reload()
        #expect(state.filter.scope == .previousImport(id: second))
        let (row, item) = try previousImportRow(in: outline)
        #expect(outline.selectedRow == row && item.count == 2)

        // With every photo of an import removed, it goes back to the one before…
        photos.forEach(store.viewContext.delete)
        try store.viewContext.save()
        controller.reload()
        #expect(state.filter.scope == .previousImport(id: first))

        // …and to All Photographs when there's none.
        try store.viewContext.fetch(Photo.fetchRequest()).forEach(store.viewContext.delete)
        try store.viewContext.save()
        controller.reload()
        #expect(state.filter.scope == .allPhotos)
        #expect(try previousImportRow(in: outline).item.scope == nil)
    }

    @Test func otherScopesAreLeftAloneByANewImport() throws {
        let directory = try TemporaryDirectory()
        let store = try makeStore(directory)
        let state = LibraryState()
        let (controller, _) = sidebar(for: store, state: state)
        try addPhotos(["a.jpg"], importID: UUID(), at: earlier, to: store)
        controller.reload()
        #expect(state.filter.scope == .allPhotos)
    }

    @Test func aRealImportUpdatesTheRowByItself() async throws {
        let directory = try TemporaryDirectory()
        let source = try directory.subdirectory("Card")
        try Fixtures.writeJPEG(to: source.appending(path: "IMG_0001.jpg"))
        try Fixtures.writeJPEG(to: source.appending(path: "IMG_0002.jpg"), captureDate: "2025:12:31 23:59:00")
        let store = try makeStore(directory)
        let (controller, outline) = sidebar(for: store)
        defer { controller.stop() }
        #expect(try previousImportRow(in: outline).item.scope == nil)

        let summary = try await ImportService(store: store).importPhotos(from: [source])
        #expect(summary.imported == 2)
        // The sidebar reloads shortly after the catalog changes.
        try await Task.sleep(for: .seconds(SidebarViewController.reloadDelay + 0.5))
        let item = try previousImportRow(in: outline).item
        #expect(item.count == 2)
        #expect(item.scope == Photo.latestImportID(in: store.viewContext).map { .previousImport(id: $0) })
    }

    // MARK: - Reopening the catalog

    @Test func showingPreviousImportIsRestoredWhenTheCatalogReopens() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "State.pixelloupe", directoryHint: .isDirectory)
        let id = UUID()
        do {
            let store = try CatalogStore.create(at: packageURL, info: Fixtures.referencedInfo)
            try addPhotos(["a.jpg"], importID: id, at: earlier, to: store)
            let controller = CatalogWindowController(store: store)
            controller.showWindow(nil)
            controller.state.filter.scope = .previousImport(id: id)
            controller.close()
        }

        let reopened = try CatalogStore.open(at: packageURL)
        #expect(reopened.viewState.showsPreviousImport)
        #expect(reopened.viewState.folderPath == nil && reopened.viewState.collectionID == nil)
        let controller = CatalogWindowController(store: reopened)
        defer { controller.close() }
        controller.showWindow(nil)
        #expect(controller.state.filter.scope == .previousImport(id: id))
        let outline = try #require(controller.window?.contentView?.descendants.compactMap { $0 as? NSOutlineView }.first)
        let row = try previousImportRow(in: outline).row
        #expect(outline.selectedRow == row)
    }

    @Test func aSavedPreviousImportWithNothingImportedFallsBackToAllPhotographs() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.create(
            at: directory.url.appending(path: "State.pixelloupe", directoryHint: .isDirectory), info: Fixtures.referencedInfo)
        var viewState = CatalogViewState()
        viewState.showsPreviousImport = true
        store.viewState = viewState
        let controller = CatalogWindowController(store: store)
        defer { controller.close() }
        #expect(controller.state.filter.scope == .allPhotos)
    }

    // MARK: - Older catalogs

    @Test("Opens a version fourteen catalog with no Previous Import")
    func migratesVersionFourteen() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "V14.pixelloupe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(Fixtures.referencedInfo).write(to: CatalogPackage.infoURL(in: packageURL))
        let momd = try #require(Bundle(for: Photo.self).url(forResource: "PixelLoupe", withExtension: "momd"))
        let v14 = try #require(NSManagedObjectModel(contentsOf: momd.appending(path: "PixelLoupe 14.mom")))
        #expect(v14.entitiesByName["Photo"]?.attributesByName["importID"] == nil)
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: v14)
            _ = try coordinator.addPersistentStore(type: .sqlite, at: CatalogPackage.databaseURL(in: packageURL))
            let context = NSManagedObjectContext(.mainQueue)
            context.persistentStoreCoordinator = coordinator
            let photo = NSEntityDescription.insertNewObject(forEntityName: "Photo", into: context)
            photo.setValue(UUID(), forKey: "id")
            photo.setValue("v14.jpg", forKey: "fileName")
            photo.setValue(Date(), forKey: "captureDate")
            photo.setValue(Date(), forKey: "importDate")
            photo.setValue(Date(), forKey: "editDate")
            try context.save()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }
        let store = try CatalogStore.open(at: packageURL)
        let photo = try #require(try store.viewContext.fetch(Photo.fetchRequest()).first)
        #expect(photo.fileName == "v14.jpg" && photo.importID == nil)
        #expect(Photo.latestImportID(in: store.viewContext) == nil)
    }
}
