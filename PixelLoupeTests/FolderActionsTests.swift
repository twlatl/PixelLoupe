import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Folder actions")
@MainActor
struct FolderActionsTests {
    /// A directory's path as the catalog stores it, without the trailing slash `URL` adds.
    private static func path(_ url: URL) -> String { url.path(percentEncoded: false).trimmingSuffix("/") }

    /// `Photos` (one photo of its own) ▸ `Trip` (A.jpg, B.jpg, with a virtual copy of A) ▸ `Day 2` (C.jpg),
    /// in a referenced catalog with real files.
    private struct Setup {
        let directory: TemporaryDirectory
        let store: CatalogStore
        let root: String
        let trip: String
        let day2: String
        let photos: [String: Photo]

        var editing: FolderEditing { FolderEditing(store: store) }
        var context: NSManagedObjectContext { store.viewContext }

        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
        func photoCount() -> Int { (try? context.count(for: Photo.fetchRequest())) ?? -1 }
    }

    private func makeSetup() throws -> Setup {
        let directory = try TemporaryDirectory()
        let rootURL = try directory.subdirectory("Photos")
        let tripURL = try directory.subdirectory("Photos/Trip")
        let day2URL = try directory.subdirectory("Photos/Trip/Day 2")
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let context = store.viewContext
        func folder(_ url: URL, parent: Folder?) -> Folder {
            let folder = Folder(context: context)
            folder.path = Self.path(url)
            folder.name = url.lastPathComponent
            folder.parent = parent
            return folder
        }
        let root = folder(rootURL, parent: nil)
        let trip = folder(tripURL, parent: root)
        let day2 = folder(day2URL, parent: trip)

        var photos: [String: Photo] = [:]
        func photo(_ name: String, in folder: Folder) throws {
            let url = URL(filePath: folder.path).appending(path: name)
            try Fixtures.writeJPEG(to: url)
            let photo = Photo(context: context)
            photo.id = UUID()
            photo.fileName = name
            photo.filePath = url.path(percentEncoded: false)
            photo.fileType = "JPG"
            photo.fileSize = Int64(try Data(contentsOf: url).count)
            photo.captureDate = Date()
            photo.importDate = Date()
            photo.editDate = Date()
            photo.folder = folder
            photos[name] = photo
        }
        try photo("Root.jpg", in: root)
        try photo("A.jpg", in: trip)
        try photo("B.jpg", in: trip)
        try photo("C.jpg", in: day2)
        let copy = Photo(context: context)
        copy.id = UUID()
        copy.fileName = "A.jpg"
        copy.filePath = photos["A.jpg"]!.filePath
        copy.fileType = "JPG"
        copy.captureDate = Date()
        copy.importDate = Date()
        copy.editDate = Date()
        copy.folder = trip
        copy.master = photos["A.jpg"]
        copy.copyName = "Copy 1"
        photos["A copy"] = copy
        try context.save()
        context.undoManager?.removeAllActions()
        return Setup(directory: directory, store: store, root: root.path, trip: trip.path, day2: day2.path, photos: photos)
    }

    // MARK: - Create, rename, remove

    @Test("Create Folder Inside makes the folder on disk and in the catalog; undo takes it away")
    func createsFolderInside() throws {
        let setup = try makeSetup()
        let path = try setup.editing.createFolder(named: "Selects", inside: setup.trip)
        #expect(path == setup.trip + "/Selects")
        #expect(setup.exists(path))
        let folder = try #require(setup.editing.folder(at: path))
        #expect(folder.parent?.path == setup.trip && folder.name == "Selects")

        setup.context.undoManager?.undo()
        #expect(setup.editing.folder(at: path) == nil)
        #expect(!setup.exists(path))
        setup.context.undoManager?.redo()
        #expect(setup.editing.folder(at: path) != nil && setup.exists(path))

        #expect(throws: FolderEditing.EditError.self) { try setup.editing.createFolder(named: "Selects", inside: setup.trip) }
        #expect(throws: FolderEditing.EditError.self) { try setup.editing.createFolder(named: "a/b", inside: setup.trip) }
        #expect(throws: FolderEditing.EditError.self) { try setup.editing.createFolder(named: "  ", inside: setup.trip) }
    }

    @Test("Rename renames the folder on disk, its subfolders and photos follow, and undo renames it back")
    func renamesFolder() throws {
        let setup = try makeSetup()
        let renamed = setup.root + "/Ireland"
        let newPath = try setup.editing.rename(setup.trip, to: "Ireland")
        #expect(newPath == renamed)
        #expect(setup.exists(renamed + "/A.jpg") && !setup.exists(setup.trip))
        #expect(setup.editing.folder(at: renamed)?.name == "Ireland")
        #expect(setup.editing.folder(at: renamed + "/Day 2") != nil)
        #expect(setup.photos["C.jpg"]?.filePath == renamed + "/Day 2/C.jpg")
        #expect(setup.photos["A copy"]?.filePath == renamed + "/A.jpg")
        #expect(setup.context.undoManager?.undoActionName == "Rename Folder")

        setup.context.undoManager?.undo()
        #expect(setup.exists(setup.trip + "/A.jpg") && !setup.exists(renamed))
        #expect(setup.photos["C.jpg"]?.filePath == setup.trip + "/Day 2/C.jpg")
        #expect(setup.editing.folder(at: setup.trip)?.name == "Trip")
        setup.context.undoManager?.redo()
        #expect(setup.exists(renamed) && setup.photos["A.jpg"]?.filePath == renamed + "/A.jpg")

        // Not over another folder.
        try FileManager.default.createDirectory(atPath: setup.root + "/Taken", withIntermediateDirectories: false)
        #expect(throws: FolderEditing.EditError.self) { try setup.editing.rename(renamed, to: "Taken") }
    }

    @Test("Remove takes the folder, its subfolders and their photos out of the catalog but leaves the files")
    func removesFolder() throws {
        let setup = try makeSetup()
        #expect(setup.editing.photoCount(in: setup.trip) == 4)
        setup.editing.remove(setup.trip)
        #expect(setup.photoCount() == 1)
        #expect(setup.editing.folder(at: setup.trip) == nil && setup.editing.folder(at: setup.day2) == nil)
        #expect(setup.exists(setup.trip + "/A.jpg") && setup.exists(setup.day2 + "/C.jpg"))

        setup.context.undoManager?.undo()
        #expect(setup.photoCount() == 5)
        #expect(setup.editing.folder(at: setup.day2)?.parent?.path == setup.trip)
    }

    // MARK: - Favorites, labels, parents

    @Test("Favorites and color labels are kept on the folder and undo")
    func favoritesAndLabels() throws {
        let setup = try makeSetup()
        setup.editing.setFavorite(true, at: setup.trip)
        setup.editing.setLabel(.green, at: setup.trip)
        let trip = try #require(setup.editing.folder(at: setup.trip))
        #expect(trip.isFavorite && trip.label == .green && trip.colorLabel == ColorLabel.green.rawValue)
        // Both were done in one event, so they're one undo step.
        setup.context.undoManager?.undo()
        #expect(trip.label == .none && !trip.isFavorite)
    }

    @Test("Hide This Parent promotes the subfolders; Show Parent Folder brings a parent back")
    func hidesAndShowsParent() throws {
        let setup = try makeSetup()
        // Photos has photos of its own: it can't be hidden.
        #expect(!setup.editing.canHideParent(setup.root))
        #expect(!setup.editing.canHideParent(setup.trip))   // not top-level
        setup.photos["Root.jpg"]!.folder = setup.editing.folder(at: setup.trip)
        #expect(setup.editing.canHideParent(setup.root))

        setup.editing.hideParent(setup.root)
        #expect(setup.editing.folder(at: setup.root) == nil)
        let trip = try #require(setup.editing.folder(at: setup.trip))
        #expect(trip.parent == nil && trip.children.count == 1)
        #expect(setup.photoCount() == 5)

        #expect(setup.editing.canShowParent(setup.trip))
        #expect(setup.editing.showParent(setup.trip) == setup.root)
        let root = try #require(setup.editing.folder(at: setup.root))
        #expect(root.parent == nil && root.children.map(\.path) == [setup.trip] && root.name == "Photos")
        #expect(!setup.editing.canShowParent("/Volumes"))
    }

    // MARK: - Collections

    @Test("Create Collection holds the folder's photos, subfolders included")
    func createsCollectionFromFolder() throws {
        let setup = try makeSetup()
        let collection = try #require(setup.editing.createCollection(from: setup.trip))
        #expect(collection.name == "Trip" && collection.kind == .collection)
        #expect(Set(collection.photos.map(\.fileName)) == ["A.jpg", "B.jpg", "C.jpg"] && collection.photos.count == 4)
    }

    @Test("Create Collection Set mirrors the folder tree")
    func createsCollectionSetFromFolder() throws {
        let setup = try makeSetup()
        let set = try #require(setup.editing.createCollectionSet(from: setup.root))
        #expect(set.name == "Photos" && set.kind == .set && set.parent == nil)
        let children = set.children.sorted { $0.name < $1.name }
        // Its own photo in a collection of its own name; Trip (with a subfolder) as a set.
        #expect(children.map(\.name) == ["Photos", "Trip"])
        #expect(children[0].kind == .collection && children[0].photos.map(\.fileName) == ["Root.jpg"])
        #expect(children[1].kind == .set)
        let trip = children[1].children.sorted { $0.name < $1.name }
        #expect(trip.map(\.name) == ["Day 2", "Trip"])
        #expect(trip[0].kind == .collection && trip[0].photos.map(\.fileName) == ["C.jpg"])
        #expect(trip[1].photos.count == 3)
        setup.context.undoManager?.undo()
        #expect((try setup.context.count(for: PhotoCollection.fetchRequest())) == 0)
    }

    // MARK: - Synchronize

    @Test("Synchronize finds new, missing and changed files")
    func plansSynchronize() async throws {
        let setup = try makeSetup()
        try Fixtures.writeJPEG(to: URL(filePath: setup.day2 + "/New.jpg"))
        try FileManager.default.createDirectory(atPath: setup.trip + "/Later", withIntermediateDirectories: false)
        try Fixtures.writeJPEG(to: URL(filePath: setup.trip + "/Later/Newer.jpg"))
        try FileManager.default.removeItem(atPath: setup.trip + "/B.jpg")
        // C changed after it was imported: new keywords and a different size.
        try Fixtures.writeJPEG(to: URL(filePath: setup.day2 + "/C.jpg"), width: 80, keywords: ["Cliffs"])
        setup.photos["C.jpg"]!.importDate = Date(timeIntervalSinceNow: -60)
        try setup.context.save()

        let plan = await FolderSync.plan(folder: setup.trip, info: setup.store.info, context: setup.store.newBackgroundContext())
        #expect(Set(plan.newFiles.map(\.url.lastPathComponent)) == ["New.jpg", "Newer.jpg"])
        #expect(plan.missing == [setup.photos["B.jpg"]!.objectID])
        #expect(plan.changed == [setup.photos["C.jpg"]!.objectID])

        let updates = await FolderSync.readUpdates(plan.changed, in: setup.context)
        FolderSync.apply(updates, in: setup.context)
        let photo = try #require(setup.photos["C.jpg"])
        #expect(photo.pixelWidth == 80 && photo.tags.map(\.name) == ["Cliffs"])

        // New photos are added in place, into the folder tree under the synchronized folder.
        let candidates = await ImportService.readCandidates(plan.newFiles)
        let summary = try await ImportService(store: setup.store).importPhotos(candidates, transfer: .add)
        #expect(summary.imported == 2)
        setup.context.refreshAllObjects()
        let later = try #require(setup.editing.folder(at: setup.trip + "/Later"))
        #expect(later.parent?.path == setup.trip && later.photos.map(\.fileName) == ["Newer.jpg"])
    }

    // MARK: - Export as Catalog

    @Test("Export as Catalog copies the folder's photos, keywords, collections and files into a new catalog")
    func exportsCatalog() async throws {
        let setup = try makeSetup()
        let tag = Tag.findOrCreate(named: "Ireland", in: setup.context)
        setup.photos["A.jpg"]!.tags.insert(tag)
        setup.photos["A.jpg"]!.rating = 4
        let elsewhere = Tag.findOrCreate(named: "Unrelated", in: setup.context)
        setup.photos["Root.jpg"]!.tags.insert(elsewhere)
        CollectionEditing(store: setup.store).create(.collection, named: "Best", in: nil, photos: [setup.photos["B.jpg"]!.objectID, setup.photos["Root.jpg"]!.objectID])
        try setup.context.save()
        try Data([1, 2, 3]).write(to: ThumbnailStore.url(for: setup.photos["A.jpg"]!.id, in: setup.store.thumbnails.directory))

        let destination = setup.directory.url.appending(path: "Exported", directoryHint: .isDirectory)
        let result = try await CatalogExporter.export(folder: setup.trip, from: setup.store, to: destination, options: .init())
        #expect(result.photoCount == 4 && result.failures.isEmpty)
        #expect(result.catalogURL.lastPathComponent == "Exported.pixelloupe")

        let copiedRoot = Self.path(destination.appending(path: "Trip"))
        #expect(setup.exists(copiedRoot + "/A.jpg") && setup.exists(copiedRoot + "/Day 2/C.jpg"))

        let exported = try CatalogStore.open(at: result.catalogURL)
        let context = exported.viewContext
        let photos = try context.fetch(Photo.fetchRequest())
        #expect(photos.count == 4)
        let a = try #require(photos.first { $0.fileName == "A.jpg" && $0.master == nil })
        #expect(a.filePath == copiedRoot + "/A.jpg" && a.rating == 4 && a.tags.map(\.name) == ["Ireland"])
        #expect(a.virtualCopies.count == 1 && a.virtualCopies.first?.copyName == "Copy 1")
        #expect(try context.fetch(Tag.fetchRequest()).map(\.name) == ["Ireland"])
        let folders = try context.fetch(Folder.fetchRequest())
        #expect(Set(folders.map(\.path)) == [copiedRoot, copiedRoot + "/Day 2"])
        #expect(folders.first { $0.path == copiedRoot }?.parent == nil)
        let collection = try #require(try context.fetch(PhotoCollection.fetchRequest()).first)
        #expect(collection.name == "Best" && collection.photos.map(\.fileName) == ["B.jpg"])
        #expect(setup.exists(ThumbnailStore.url(for: a.id, in: exported.thumbnails.directory).path(percentEncoded: false)))
    }

    @Test("Without negative files the exported catalog refers to the photos where they are")
    func exportsCatalogReferencingFiles() async throws {
        let setup = try makeSetup()
        let destination = setup.directory.url.appending(path: "Referenced", directoryHint: .isDirectory)
        let options = CatalogExporter.Options(copiesFiles: false, includesPreviews: false)
        let result = try await CatalogExporter.export(folder: setup.day2, from: setup.store, to: destination, options: options)
        #expect(result.photoCount == 1)
        #expect(!setup.exists(Self.path(destination) + "/Day 2"))
        let exported = try CatalogStore.open(at: result.catalogURL)
        #expect(try exported.viewContext.fetch(Photo.fetchRequest()).map(\.filePath) == [setup.day2 + "/C.jpg"])
        await #expect(throws: CatalogError.self) {
            try await CatalogExporter.export(folder: setup.day2, from: setup.store, to: destination, options: options)
        }
    }

    @Test("Build / Include Smart Previews copies the photos' Smart Previews and builds the missing ones")
    func exportsCatalogWithSmartPreviews() async throws {
        let setup = try makeSetup()
        // A has one already (its virtual copy shares it); B and C don't.
        let a = try #require(setup.photos["A.jpg"])
        let smartPreviews = setup.store.smartPreviews
        try FileManager.default.createDirectory(at: smartPreviews.directory, withIntermediateDirectories: true)
        let existing = SmartPreviewStore.url(for: a.id, fileExtension: "heic", in: smartPreviews.directory)
        try SmartPreviewWriter.write(original: a.fileURL, to: existing)
        smartPreviews.didWrite(existing, for: a.id)

        var options = CatalogExporter.Options()
        let without = try await CatalogExporter.export(
            folder: setup.trip, from: setup.store, to: setup.directory.url.appending(path: "Without", directoryHint: .isDirectory), options: options
        )
        #expect(without.smartPreviewCount == 0)
        #expect(!setup.exists(Self.path(CatalogPackage.smartPreviewsURL(in: without.catalogURL))), "off unless asked for")

        options.includesSmartPreviews = true
        let result = try await CatalogExporter.export(
            folder: setup.trip, from: setup.store, to: setup.directory.url.appending(path: "With", directoryHint: .isDirectory), options: options
        )
        #expect(result.smartPreviewCount == 3)
        let exported = try CatalogStore.open(at: result.catalogURL)
        await exported.smartPreviews.load()
        let photos = try exported.viewContext.fetch(Photo.fetchRequest())
        #expect(photos.count == 4 && photos.allSatisfy(exported.smartPreviews.contains), "the virtual copy shares A's")
        let copied = try #require(exported.smartPreviews.files[a.id])
        #expect(try Data(contentsOf: copied) == Data(contentsOf: existing), "A's is copied")
    }

    // MARK: - Sidebar

    @Test("The folder's context menu lists Lightroom's folder actions and the row shows the star and label")
    func sidebarMenuAndBadges() throws {
        let setup = try makeSetup()
        setup.editing.setFavorite(true, at: setup.trip)
        setup.editing.setLabel(.red, at: setup.trip)
        let sidebar = SidebarViewController(store: setup.store, state: LibraryState())
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        let outline = try #require(sidebar.view.descendants.compactMap { $0 as? NSOutlineView }.first)
        outline.expandItem(nil, expandChildren: true)
        let row = try #require((0..<outline.numberOfRows).first { row in
            guard let item = outline.item(atRow: row) as? SidebarViewController.Item, case .folder(let path) = item.kind else { return false }
            return path == setup.trip
        })
        let item = try #require(outline.item(atRow: row) as? SidebarViewController.Item)
        #expect(item.isFavorite && item.label == .red)
        let cell = try #require(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView)
        #expect(!cell.favoriteBadge.isHidden && cell.label == .red)

        let menu = sidebar.folderMenu(for: item, path: setup.trip)
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == [
            "Create Folder Inside “Trip”…", "Create Collection Set “Trip”", "Create Collection “Trip”",
            "Remove from Favorites", "Add Color Label to Folder", "Rename…", "Remove…", "Hide This Parent",
            "Show Parent Folder", "Synchronize Folder…", "Update Folder Location…", "Import to this Folder…",
            "Export this Folder as a Catalog…", "Show in Finder", "Get Info",
        ])
        #expect(menu.items.allSatisfy { $0.isSeparatorItem || $0.submenu != nil || $0.representedObject as? String == setup.trip })
        let labels = try #require(menu.item(withTitle: "Add Color Label to Folder")?.submenu)
        #expect(labels.items.map(\.title) == ["No Label", "Red", "Yellow", "Green", "Blue", "Purple"])
        #expect(labels.item(withTitle: "Red")?.state == .on)
    }

    @Test("Folder actions are enabled where they apply")
    func validatesFolderActions() throws {
        let setup = try makeSetup()
        let controller = CatalogWindowController(store: setup.store)
        func enabled(_ action: Selector, _ path: String) -> Bool {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            item.representedObject = path
            return controller.validateUserInterfaceItem(item)
        }
        #expect(!enabled(#selector(CatalogWindowController.hideFolderParent(_:)), setup.root))   // has photos of its own
        #expect(!enabled(#selector(CatalogWindowController.hideFolderParent(_:)), setup.trip))   // not top-level
        #expect(enabled(#selector(CatalogWindowController.showFolderParent(_:)), setup.root))
        #expect(!enabled(#selector(CatalogWindowController.showFolderParent(_:)), setup.trip))
        #expect(enabled(#selector(CatalogWindowController.renameFolder(_:)), setup.trip))
        #expect(enabled(#selector(CatalogWindowController.createCollectionFromFolder(_:)), setup.trip))
        controller.close()
    }

    @Test("Opens a version 13 catalog and adds the folder's favorite and label")
    func migratesVersionThirteen() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "V13.pixelloupe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(Fixtures.referencedInfo).write(to: CatalogPackage.infoURL(in: packageURL))
        let momd = try #require(Bundle(for: Photo.self).url(forResource: "PixelLoupe", withExtension: "momd"))
        let v13 = try #require(NSManagedObjectModel(contentsOf: momd.appending(path: "PixelLoupe 13.mom")))
        #expect(v13.entitiesByName["Folder"]?.attributesByName["isFavorite"] == nil)
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: v13)
            _ = try coordinator.addPersistentStore(type: .sqlite, at: CatalogPackage.databaseURL(in: packageURL))
            let context = NSManagedObjectContext(.mainQueue)
            context.persistentStoreCoordinator = coordinator
            let folder = NSEntityDescription.insertNewObject(forEntityName: "Folder", into: context)
            folder.setValue("/Photos", forKey: "path")
            folder.setValue("Photos", forKey: "name")
            try context.save()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }
        let store = try CatalogStore.open(at: packageURL)
        let folder = try #require(try store.viewContext.fetch(Folder.fetchRequest()).first)
        #expect(folder.path == "/Photos" && !folder.isFavorite && folder.label == .none)
        folder.isFavorite = true
        folder.label = .blue
        try store.viewContext.save()
    }
}
