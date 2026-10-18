import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Sidebar folder state")
struct SidebarStateTests {
    /// Folders /Photos ▸ 2025 ▸ 05-01 and /Photos ▸ 2026, plus /Other.
    private func makeCatalog(at packageURL: URL) throws -> CatalogStore {
        let store = try CatalogStore.create(at: packageURL, info: Fixtures.referencedInfo)
        let context = store.viewContext
        func folder(_ path: String, parent: Folder?) -> Folder {
            let folder = Folder(context: context)
            folder.path = path
            folder.name = (path as NSString).lastPathComponent
            folder.parent = parent
            return folder
        }
        let photos = folder("/Photos", parent: nil)
        let year = folder("/Photos/2025", parent: photos)
        _ = folder("/Photos/2025/05-01", parent: year)
        _ = folder("/Photos/2026", parent: photos)
        _ = folder("/Other", parent: nil)
        try context.save()
        return store
    }

    private func sidebar(for store: CatalogStore) -> (SidebarViewController, NSOutlineView) {
        let controller = SidebarViewController(store: store, state: LibraryState())
        controller.view.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        // The sidebar is the catalog's name, the Navigator, then the outline in a scroll view.
        let outline = controller.view.descendants.compactMap { $0 as? NSOutlineView }.first!
        return (controller, outline)
    }

    private func item(_ path: String, in outline: NSOutlineView) -> SidebarViewController.Item? {
        (0..<outline.numberOfRows).lazy.compactMap { outline.item(atRow: $0) as? SidebarViewController.Item }.first {
            if case .folder(let itemPath) = $0.kind { itemPath == path } else { false }
        }
    }

    /// The row for a folder (which must be showing).
    private func row(_ path: String, in outline: NSOutlineView) throws -> SidebarViewController.Item {
        try #require(item(path, in: outline))
    }

    private func expandedPaths(in outline: NSOutlineView) -> Set<String> {
        Set((0..<outline.numberOfRows).compactMap { row -> String? in
            guard let item = outline.item(atRow: row) as? SidebarViewController.Item,
                  case .folder(let path) = item.kind, outline.isItemExpanded(item) else { return nil }
            return path
        })
    }

    @Test func expandedFoldersAreRestoredWhenTheCatalogReopens() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "State.pixelloupe", directoryHint: .isDirectory)
        do {
            let store = try makeCatalog(at: packageURL)
            let (_, outline) = sidebar(for: store)
            #expect(expandedPaths(in: outline).isEmpty, "folders start collapsed")
            outline.expandItem(try row("/Photos", in: outline))
            outline.expandItem(try row("/Photos/2025", in: outline))
        }

        let reopened = try CatalogStore.open(at: packageURL)
        #expect(reopened.viewState.expandedFolderPaths == ["/Photos", "/Photos/2025"])
        let (_, outline) = sidebar(for: reopened)
        #expect(expandedPaths(in: outline) == ["/Photos", "/Photos/2025"])
        #expect(item("/Photos/2025/05-01", in: outline) != nil, "the expanded subfolder's children are visible")
    }

    @Test func collapsingIsSavedButSubfoldersKeepTheirState() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "State.pixelloupe", directoryHint: .isDirectory)
        do {
            let store = try makeCatalog(at: packageURL)
            let (_, outline) = sidebar(for: store)
            outline.expandItem(try row("/Photos", in: outline))
            outline.expandItem(try row("/Photos/2025", in: outline))
            outline.collapseItem(try row("/Photos", in: outline))
            #expect(store.viewState.expandedFolderPaths == ["/Photos/2025"])
        }

        // Relaunched with the parent collapsed: expanding it brings back the expanded subfolder.
        let reopened = try CatalogStore.open(at: packageURL)
        let (_, outline) = sidebar(for: reopened)
        #expect(expandedPaths(in: outline).isEmpty)
        outline.expandItem(try row("/Photos", in: outline))
        #expect(expandedPaths(in: outline) == ["/Photos", "/Photos/2025"])
    }

    @Test func removedFoldersAreForgotten() throws {
        let directory = try TemporaryDirectory()
        let store = try makeCatalog(at: directory.url.appending(path: "State.pixelloupe", directoryHint: .isDirectory))
        store.viewState.expandedFolderPaths = ["/Photos", "/Gone"]

        let (_, outline) = sidebar(for: store)
        #expect(expandedPaths(in: outline) == ["/Photos"])
        #expect(store.viewState.expandedFolderPaths == ["/Photos"])
    }

    /// Adds photos to folders of a saved catalog.
    private func addPhotos(_ names: [(String, String)], to store: CatalogStore) throws -> [UUID] {
        let context = store.viewContext
        var ids: [UUID] = []
        for (name, folderPath) in names {
            let request = Folder.fetchRequest()
            request.predicate = NSPredicate(format: "path == %@", folderPath)
            let photo = Photo(context: context)
            photo.id = UUID()
            photo.fileName = name
            photo.filePath = folderPath + "/" + name
            photo.fileType = "JPG"
            photo.captureDate = Date(timeIntervalSince1970: Double(ids.count) * 60)
            photo.importDate = Date()
            photo.editDate = Date()
            photo.folder = try context.fetch(request).first
            ids.append(photo.id)
        }
        try context.save()
        return ids
    }

    @Test func theFolderAndPhotosShownAreRestored() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "State.pixelloupe", directoryHint: .isDirectory)
        let ids: [UUID]
        do {
            let store = try makeCatalog(at: packageURL)
            ids = try addPhotos([("a.jpg", "/Photos/2025"), ("b.jpg", "/Photos/2025"), ("c.jpg", "/Photos/2025/05-01"), ("d.jpg", "/Other")], to: store)
            let controller = CatalogWindowController(store: store)
            controller.showWindow(nil)
            controller.state.filter.scope = .folder(path: "/Photos/2025")
            let photos = try store.viewContext.fetch(Photo.fetchRequest())
            controller.state.selectedPhotoIDs = [ids[2], ids[0]].compactMap { id in photos.first { $0.id == id }?.objectID }
            controller.close()
        }

        let reopened = try CatalogStore.open(at: packageURL)
        #expect(reopened.viewState.folderPath == "/Photos/2025")
        #expect(reopened.viewState.selectedPhotos == [ids[2], ids[0]])
        let controller = CatalogWindowController(store: reopened)
        defer { controller.close() }
        controller.showWindow(nil)
        #expect(controller.state.filter.scope == .folder(path: "/Photos/2025"))
        let selected = controller.state.selectedPhotoIDs.compactMap { (try? reopened.viewContext.existingObject(with: $0) as? Photo)?.id }
        // (The grid keeps its selection in grid order.)
        #expect(Set(selected) == [ids[2], ids[0]])
        // The sidebar shows the folder selected (and its parents expanded).
        let outline = try #require(controller.window?.contentView?.descendants.compactMap { $0 as? NSOutlineView }.first)
        let selectedRow = try #require(outline.item(atRow: outline.selectedRow) as? SidebarViewController.Item)
        if case .folder(let path) = selectedRow.kind { #expect(path == "/Photos/2025") } else { Issue.record("no folder selected") }
    }

    @Test func aMissingFolderFallsBackToAllPhotographs() throws {
        let directory = try TemporaryDirectory()
        let store = try makeCatalog(at: directory.url.appending(path: "State.pixelloupe", directoryHint: .isDirectory))
        store.viewState = CatalogViewState(folderPath: "/Gone", selectedPhotos: [UUID()])
        let controller = CatalogWindowController(store: store)
        defer { controller.close() }
        #expect(controller.state.filter.scope == .allPhotos)
        #expect(controller.state.selectedPhotoIDs.isEmpty)
    }

    @Test func aMissingOrOldStateFileMeansDefaults() throws {
        let directory = try TemporaryDirectory()
        #expect(CatalogViewState.load(from: directory.url) == CatalogViewState())
        try Data("<plist version=\"1.0\"><dict/></plist>".utf8).write(to: CatalogPackage.viewStateURL(in: directory.url))
        #expect(CatalogViewState.load(from: directory.url) == CatalogViewState())
    }
}
