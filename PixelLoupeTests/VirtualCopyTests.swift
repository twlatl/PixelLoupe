import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Virtual copies")
@MainActor
struct VirtualCopyTests {
    private struct Setup {
        let directory: TemporaryDirectory
        let store: CatalogStore
        let photos: [Photo]
        let trashFolder: URL
        var editing: PhotoEditing { PhotoEditing(store: store) }
        var undo: UndoManager { store.viewContext.undoManager! }
        func trash() -> PhotoRemoval {
            let folder = trashFolder
            return PhotoRemoval(store: store, trash: .init { file in
                let destination = folder.appending(path: "\(UUID().uuidString)-\(file.lastPathComponent)")
                try FileManager.default.moveItem(at: file, to: destination)
                return destination
            })
        }
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }
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
        let family = PixelLoupe.Tag.findOrCreate(named: "Family", in: context)
        var photos: [Photo] = []
        for index in 0..<2 {
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
        photos[0].rating = 4
        photos[0].flag = 1
        photos[0].label = .red
        photos[0].tags = [family]
        var edits = PhotoAdjustments()
        edits.light.exposure = 0.5
        photos[0].adjustments = edits
        var metadata = PhotoMetadata()
        metadata[.title] = "Original"
        photos[0].metadata = metadata
        try context.save()
        try Fixtures.writeJPEG(to: store.thumbnails.url(for: photos[0].id))
        context.undoManager?.groupsByEvent = false
        context.undoManager?.removeAllActions()
        return Setup(directory: directory, store: store, photos: photos, trashFolder: trashFolder)
    }

    private func grouped(_ setup: Setup, _ body: () -> Void) {
        setup.undo.beginUndoGrouping()
        body()
        setup.undo.endUndoGrouping()
    }

    @Test("A copy carries the master's edits, rating, flag, label, keywords and metadata, and shares its file")
    func creating() throws {
        let setup = try makeSetup()
        let master = setup.photos[0]
        var created: [NSManagedObjectID] = []
        grouped(setup) { created = setup.editing.createVirtualCopies(of: [master.objectID]) }
        let copy = try #require(setup.editing.photos(created).first)
        #expect(copy.id != master.id && copy.master === master && master.virtualCopies == [copy])
        #expect(copy.copyName == "Copy 1" && copy.isVirtualCopy && !master.isVirtualCopy)
        #expect(copy.filePath == master.filePath && copy.fileName == master.fileName && copy.folder === master.folder)
        #expect(copy.rating == 4 && copy.flag == 1 && copy.label == .red && copy.tagNames == ["Family"])
        #expect(copy.adjustments.light.exposure == 0.5 && copy.metadata[.title] == "Original" && copy.titleText == "Original")
        #expect(setup.undo.undoActionName == "Create Virtual Copy")
        #expect(setup.exists(setup.store.thumbnails.url(for: copy.id)), "it shows its master's thumbnail at once")
        #expect(master.photosSharingFile == [master, copy] && copy.photosSharingFile == [master, copy])

        // A copy of a copy is another copy of the same master; names count up.
        var second: [NSManagedObjectID] = []
        grouped(setup) { second = setup.editing.createVirtualCopies(of: [copy.objectID]) }
        let again = try #require(setup.editing.photos(second).first)
        #expect(again.master === master && again.copyName == "Copy 2" && master.virtualCopies.count == 2)
        grouped(setup) { _ = setup.editing.createVirtualCopies(of: [master.objectID, setup.photos[1].objectID]) }
        #expect(setup.undo.undoActionName == "Create Virtual Copies")
        #expect(master.virtualCopies.map { $0.copyName }.sorted { ($0 ?? "") < ($1 ?? "") } == ["Copy 1", "Copy 2", "Copy 3"])
    }

    @Test("Editing a copy leaves its master alone, and undo removes the copy")
    func independence() throws {
        let setup = try makeSetup()
        let master = setup.photos[0]
        var created: [NSManagedObjectID] = []
        grouped(setup) { created = setup.editing.createVirtualCopies(of: [master.objectID]) }
        let copy = try #require(setup.editing.photos(created).first)
        grouped(setup) {
            setup.editing.setRating(1, for: [copy.objectID])
            var edits = copy.adjustments
            edits.light.exposure = -1
            copy.adjustments = edits
            copy.tags = []
        }
        #expect(master.rating == 4 && master.adjustments.light.exposure == 0.5 && master.tagNames == ["Family"])
        #expect(copy.rating == 1 && copy.tagNames.isEmpty)

        // Undo the copy's edits, then the copy itself.
        setup.undo.undo()
        setup.undo.undo()
        #expect(try setup.store.viewContext.count(for: Photo.fetchRequest()) == 2)
        #expect(master.virtualCopies.isEmpty)
    }

    @Test("Setting a copy as master swaps the roles")
    func settingMaster() throws {
        let setup = try makeSetup()
        let master = setup.photos[0]
        var made: [NSManagedObjectID] = []
        grouped(setup) { made = setup.editing.createVirtualCopies(of: [master.objectID, master.objectID]) }
        let copies = setup.editing.photos(made)
        let (first, second) = (copies[0], copies[1])
        grouped(setup) { setup.editing.setAsMaster(second.objectID) }
        #expect(second.master == nil && second.copyName == nil)
        #expect(master.master === second && master.copyName == "Copy 2")
        #expect(first.master === second)
        #expect(Set(second.virtualCopies) == [master, first])
        #expect(setup.undo.undoActionName == "Set Copy as Master")
        setup.undo.undo()
        #expect(master.master == nil && second.master === master)
    }

    @Test("Removing from disk keeps a file that a copy still uses; removing both trashes it once")
    func sharedFiles() throws {
        let setup = try makeSetup()
        let master = setup.photos[0]
        let file = master.fileURL
        var made: [NSManagedObjectID] = []
        grouped(setup) { made = setup.editing.createVirtualCopies(of: [master.objectID]) }
        let copy = try #require(setup.editing.photos(made).first)

        // Only the master goes: the file stays for the copy, which stays in the catalog.
        grouped(setup) { _ = setup.trash().remove([master.objectID], trash: true, actionName: "Remove Photo") }
        #expect(setup.exists(file), "the copy still uses it")
        #expect(try setup.store.viewContext.count(for: Photo.fetchRequest()) == 2)
        #expect(copy.master == nil, "an orphaned copy stands on its own")
        setup.undo.undo()

        // Both go: the file is trashed once, and undo brings it back.
        let masterAgain = try #require(setup.editing.photos([master.objectID]).first)
        _ = masterAgain
        var again: [NSManagedObjectID] = []
        grouped(setup) { again = [master.objectID, copy.objectID] }
        grouped(setup) { _ = setup.trash().remove(again, trash: true, actionName: "Remove Photos") }
        #expect(!setup.exists(file))
        #expect(try FileManager.default.contentsOfDirectory(atPath: setup.trashFolder.path(percentEncoded: false)).count == 1)
        setup.undo.undo()
        #expect(setup.exists(file))
    }

    @Test("Removing a master in the window asks about its copies")
    func removalPrompt() throws {
        let setup = try makeSetup()
        let master = setup.photos[0]
        var made: [NSManagedObjectID] = []
        grouped(setup) { made = setup.editing.createVirtualCopies(of: [master.objectID]) }
        let copy = try #require(setup.editing.photos(made).first)
        setup.undo.groupsByEvent = true

        let controller = CatalogWindowController(store: setup.store)
        controller.showWindow(nil)
        defer { controller.close() }
        controller.removeAskingAboutCopies([master.objectID], trash: false)
        let window = try #require(controller.window)
        let sheet = try #require(window.attachedSheet, "asks about the copy")
        window.endSheet(sheet, returnCode: .alertSecondButtonReturn)   // Keep Copies
        #expect(try setup.store.viewContext.count(for: Photo.fetchRequest()) == 2 && !copy.isDeleted)

        controller.removeAskingAboutCopies([copy.objectID], trash: false)
        #expect(window.attachedSheet == nil, "a copy with no copies of its own doesn't ask")
        #expect(try setup.store.viewContext.count(for: Photo.fetchRequest()) == 1)
    }

    @Test("Locating a missing file relinks the master and its copies together")
    func relink() throws {
        let setup = try makeSetup()
        let master = setup.photos[0]
        var made: [NSManagedObjectID] = []
        grouped(setup) { made = setup.editing.createVirtualCopies(of: [master.objectID]) }
        let copy = try #require(setup.editing.photos(made).first)
        let found = try setup.directory.subdirectory("Found").appending(path: "moved.jpg")
        try Fixtures.writeJPEG(to: found)
        grouped(setup) { try? FileRelinking.locate(copy, at: found, in: setup.store) }
        #expect(master.filePath == found.path(percentEncoded: false) && copy.filePath == master.filePath && master.fileName == "moved.jpg")
    }

    @Test("A copy follows its master in the grid and carries a badge and its name")
    func display() throws {
        let setup = try makeSetup()
        let master = setup.photos[0]
        var made: [NSManagedObjectID] = []
        grouped(setup) { made = setup.editing.createVirtualCopies(of: [master.objectID, master.objectID]) }
        let copies = setup.editing.photos(made)
        for ascending in [true, false] {
            var filter = LibraryFilter()
            filter.ascending = ascending
            let request = Photo.fetchRequest()
            request.sortDescriptors = filter.sortDescriptors
            let names = try setup.store.viewContext.fetch(request).filter { $0.fileName == "IMG_0.jpg" }.map { $0.copyName ?? "master" }
            #expect(names == ["master", "Copy 1", "Copy 2"], "a copy follows its master either way (ascending: \(ascending))")
        }

        let view = PhotoGridCellView()
        view.setCopy(name: copies[0].copyName, fileName: copies[0].fileName)
        #expect(view.toolTip == "IMG_0.jpg — Copy 1 (virtual copy)")
        #expect(view.accessibilityLabel() == "IMG_0.jpg, Copy 1")
        view.setCopy(name: nil, fileName: "IMG_0.jpg")
        #expect(view.toolTip == "IMG_0.jpg")
    }

    @Test("Smart rules find copies and copy names")
    func rules() throws {
        let setup = try makeSetup()
        grouped(setup) { _ = setup.editing.createVirtualCopies(of: [setup.photos[0].objectID, setup.photos[0].objectID]) }
        func count(_ rule: SmartCollectionRules.Rule) throws -> Int {
            let request = Photo.fetchRequest()
            request.predicate = SmartCollectionRules(rules: [rule]).predicate
            return try setup.store.viewContext.count(for: request)
        }
        #expect(try count(.init(field: .virtualCopy, operator: .is, value: "true")) == 2)
        #expect(try count(.init(field: .virtualCopy, operator: .is, value: "false")) == 2)
        #expect(try count(.init(field: .copyName, operator: .is, value: "copy 2")) == 1)
        #expect(try count(.init(field: .copyName, operator: .isNotEmpty, value: "")) == 2)
    }

    @Test("Photo menu has Create Virtual Copy on ⌘' and the commands enable correctly")
    func menu() throws {
        let setup = try makeSetup()
        let photoMenu = try #require(MainMenu.make().items.first { $0.title == "Photo" }?.submenu)
        let create = try #require(photoMenu.items.first { $0.title == "Create Virtual Copy" })
        #expect(create.keyEquivalent == "'" && create.keyEquivalentModifierMask == .command)
        #expect(photoMenu.items.contains { $0.title == "Set Copy as Master" })

        let controller = CatalogWindowController(store: setup.store)
        controller.showWindow(nil)
        defer { controller.close() }
        #expect(!controller.validateUserInterfaceItem(create))
        controller.state.selectedPhotoIDs = [setup.photos[0].objectID]
        #expect(controller.validateUserInterfaceItem(create))
        let setMaster = try #require(photoMenu.items.first { $0.title == "Set Copy as Master" })
        #expect(!controller.validateUserInterfaceItem(setMaster), "a master can't be set as master")
        grouped(setup) { controller.createVirtualCopy(nil) }
        let selected = try #require(PhotoEditing(store: setup.store).photos(controller.state.selectedPhotoIDs).first)
        #expect(selected.isVirtualCopy, "the new copy is selected")
        #expect(controller.validateUserInterfaceItem(setMaster))
    }

    @Test("Opens a version eight catalog and adds the virtual copy fields")
    func migratesVersionEight() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "V8.pixelloupe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(Fixtures.referencedInfo).write(to: CatalogPackage.infoURL(in: packageURL))
        let momd = try #require(Bundle(for: Photo.self).url(forResource: "PixelLoupe", withExtension: "momd"))
        let v8 = try #require(NSManagedObjectModel(contentsOf: momd.appending(path: "PixelLoupe 8.mom")))
        #expect(v8.entitiesByName["Photo"]?.attributesByName["copyName"] == nil)
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: v8)
            _ = try coordinator.addPersistentStore(type: .sqlite, at: CatalogPackage.databaseURL(in: packageURL))
            let context = NSManagedObjectContext(.mainQueue)
            context.persistentStoreCoordinator = coordinator
            let photo = NSEntityDescription.insertNewObject(forEntityName: "Photo", into: context)
            photo.setValue(UUID(), forKey: "id")
            photo.setValue("v8.jpg", forKey: "fileName")
            photo.setValue(Date(), forKey: "captureDate")
            photo.setValue(Date(), forKey: "importDate")
            photo.setValue(Date(), forKey: "editDate")
            try context.save()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }
        let store = try CatalogStore.open(at: packageURL)
        let photo = try #require(try store.viewContext.fetch(Photo.fetchRequest()).first)
        #expect(photo.fileName == "v8.jpg" && photo.master == nil && photo.virtualCopies.isEmpty && photo.copyName == nil)
    }
}
