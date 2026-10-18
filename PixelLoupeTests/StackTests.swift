import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Stacks")
@MainActor
struct StackTests {
    private struct Setup {
        let store: CatalogStore
        let photos: [Photo]
        var editing: PhotoEditing { PhotoEditing(store: store) }
        var undo: UndoManager { store.viewContext.undoManager! }
    }

    private func makeSetup(count: Int = 6) throws -> Setup {
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: try TemporaryDirectory().url.appending(path: "C.pixelloupe"))
        var photos: [Photo] = []
        for index in 0..<count {
            let photo = Photo(context: store.viewContext)
            photo.id = UUID()
            photo.fileName = "IMG_\(index).jpg"
            photo.captureDate = Date(timeIntervalSince1970: Double(index))
            photo.importDate = Date()
            photo.editDate = Date()
            photos.append(photo)
        }
        try store.viewContext.save()
        store.viewContext.undoManager?.groupsByEvent = false
        store.viewContext.undoManager?.removeAllActions()
        return Setup(store: store, photos: photos)
    }

    private func grouped<T>(_ setup: Setup, _ body: () -> T) -> T {
        setup.undo.beginUndoGrouping()
        defer { setup.undo.endUndoGrouping() }
        return body()
    }

    private func visible(_ setup: Setup) throws -> [String] {
        let request = Photo.fetchRequest()
        request.predicate = LibraryFilter().predicate
        request.sortDescriptors = LibraryFilter().sortDescriptors
        return try setup.store.viewContext.fetch(request).map(\.fileName)
    }

    @Test("Grouping makes a collapsed stack under the first photo; the others leave the grid; undo restores")
    func grouping() throws {
        let setup = try makeSetup()
        let p = setup.photos
        #expect(grouped(setup) { setup.editing.groupIntoStack([p[1].objectID, p[2].objectID, p[3].objectID]) })
        let stack = try #require(p[1].stack)
        #expect(stack.isCollapsed && stack.orderedPhotos.map(\.fileName) == ["IMG_1.jpg", "IMG_2.jpg", "IMG_3.jpg"])
        #expect(p[1].stackPosition == 1 && p[2].stackPosition == 2 && p[3].stackPosition == 3)
        #expect(!p[1].isHiddenInStack && p[2].isHiddenInStack && p[3].isHiddenInStack)
        #expect(try visible(setup) == ["IMG_0.jpg", "IMG_1.jpg", "IMG_4.jpg", "IMG_5.jpg"])
        #expect(setup.undo.undoActionName == "Group into Stack")

        setup.undo.undo()
        #expect(p[1].stack == nil && p[2].stack == nil && !p[2].isHiddenInStack)
        #expect(try visible(setup).count == 6)
        // A single photo can't be stacked.
        #expect(!grouped(setup) { setup.editing.groupIntoStack([p[0].objectID]) })
    }

    @Test("Collapse and expand show and hide the other photos; Collapse All / Expand All reach every stack")
    func collapsing() throws {
        let setup = try makeSetup()
        let p = setup.photos
        grouped(setup) { _ = setup.editing.groupIntoStack([p[0].objectID, p[1].objectID]) }
        grouped(setup) { _ = setup.editing.groupIntoStack([p[3].objectID, p[4].objectID, p[5].objectID]) }
        #expect(try visible(setup) == ["IMG_0.jpg", "IMG_2.jpg", "IMG_3.jpg"])

        grouped(setup) { setup.editing.toggleCollapsed([p[0].objectID]) }
        #expect(setup.undo.undoActionName == "Expand Stack")
        #expect(try visible(setup) == ["IMG_0.jpg", "IMG_1.jpg", "IMG_2.jpg", "IMG_3.jpg"])
        grouped(setup) { setup.editing.toggleCollapsed([p[0].objectID]) }
        #expect(setup.undo.undoActionName == "Collapse Stack")

        grouped(setup) { setup.editing.setAllStacksCollapsed(false) }
        #expect(try visible(setup).count == 6 && setup.undo.undoActionName == "Expand All Stacks")
        grouped(setup) { setup.editing.setAllStacksCollapsed(true) }
        #expect(try visible(setup) == ["IMG_0.jpg", "IMG_2.jpg", "IMG_3.jpg"])
        // Collapsing again changes nothing.
        grouped(setup) { setup.editing.setAllStacksCollapsed(true) }
        #expect(try visible(setup) == ["IMG_0.jpg", "IMG_2.jpg", "IMG_3.jpg"])
    }

    @Test("Move to Top changes which photo shows; Remove from Stack dissolves a stack left with one")
    func reordering() throws {
        let setup = try makeSetup()
        let p = setup.photos
        grouped(setup) { _ = setup.editing.groupIntoStack([p[0].objectID, p[1].objectID, p[2].objectID]) }
        grouped(setup) { setup.editing.moveToTopOfStack(p[2].objectID) }
        #expect(setup.undo.undoActionName == "Move to Top of Stack")
        #expect(p[2].stack?.orderedPhotos.map(\.fileName) == ["IMG_2.jpg", "IMG_0.jpg", "IMG_1.jpg"])
        #expect(try visible(setup) == ["IMG_2.jpg", "IMG_3.jpg", "IMG_4.jpg", "IMG_5.jpg"])
        #expect(p[0].isHiddenInStack && !p[2].isHiddenInStack)

        grouped(setup) { setup.editing.removeFromStack([p[0].objectID]) }
        #expect(p[0].stack == nil && !p[0].isHiddenInStack && p[1].stackPosition == 2)
        #expect(try visible(setup).contains("IMG_0.jpg"))
        grouped(setup) { setup.editing.removeFromStack([p[1].objectID]) }
        #expect(p[2].stack == nil && p[1].stack == nil, "one photo isn't a stack")
        #expect(try setup.store.viewContext.count(for: PhotoStack.fetchRequest()) == 0)
        #expect(try visible(setup).count == 6)
    }

    @Test("Unstack dissolves whole stacks; stacking a photo that's in a stack moves it")
    func unstackingAndMerging() throws {
        let setup = try makeSetup()
        let p = setup.photos
        grouped(setup) { _ = setup.editing.groupIntoStack([p[0].objectID, p[1].objectID, p[2].objectID]) }
        // Group photos from a stack with a loose one: they leave their stack, which survives with two.
        grouped(setup) { _ = setup.editing.groupIntoStack([p[2].objectID, p[4].objectID]) }
        #expect(p[2].stack !== p[0].stack && p[2].stack?.photos == [p[2], p[4]])
        #expect(p[0].stack?.orderedPhotos.map(\.fileName) == ["IMG_0.jpg", "IMG_1.jpg"])
        // Taking a photo out of a two-photo stack by grouping it elsewhere dissolves the old stack.
        grouped(setup) { _ = setup.editing.groupIntoStack([p[1].objectID, p[5].objectID]) }
        #expect(p[0].stack == nil, "the first stack was left with one photo")
        grouped(setup) { setup.editing.unstack([p[5].objectID]) }
        #expect(setup.undo.undoActionName == "Unstack")
        #expect(p[1].stack == nil && p[5].stack == nil && !p[5].isHiddenInStack)
        #expect(try setup.store.viewContext.count(for: PhotoStack.fetchRequest()) == 1)
    }

    @Test("The window: ⌘G, S, ⇧S, selection and the menu")
    func window() throws {
        let setup = try makeSetup()
        let p = setup.photos
        setup.undo.groupsByEvent = true
        let controller = CatalogWindowController(store: setup.store)
        controller.showWindow(nil)
        defer { controller.close() }
        controller.window?.layoutIfNeeded()
        func press(_ key: String, shift: Bool = false) -> Bool {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: 0, windowNumber: 0, context: nil,
                characters: shift ? key.uppercased() : key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 1)!
            return KeyCommand(event: event).map { controller.perform($0) } ?? false
        }

        // No stack yet: S isn't taken.
        controller.state.selectedPhotoIDs = [p[0].objectID]
        #expect(!press("s") && !press("s", shift: true))

        // ⌘G on the selection (in grid order, whatever the selection order) stacks them under the first.
        controller.state.selectedPhotoIDs = [p[2].objectID, p[0].objectID, p[1].objectID]
        controller.groupIntoStack(nil)
        #expect(p[0].stack?.orderedPhotos.map(\.fileName) == ["IMG_0.jpg", "IMG_1.jpg", "IMG_2.jpg"])
        #expect(controller.state.selectedPhotoIDs == [p[0].objectID], "the collapsed stack is represented by its top photo")
        #expect(controller.state.photoOrder.count == 4)

        // S expands it; the selected photo stays; S again collapses.
        #expect(press("s"))
        #expect(p[0].stack?.isCollapsed == false && controller.state.photoOrder.count == 6)
        controller.state.selectedPhotoIDs = [p[1].objectID]
        #expect(press("s"))
        #expect(p[0].stack?.isCollapsed == true && controller.state.selectedPhotoIDs == [p[0].objectID], "selection moves to the top")

        // ⇧S moves the selected photo to the top.
        #expect(press("s"))
        controller.state.selectedPhotoIDs = [p[2].objectID]
        #expect(press("s", shift: true))
        #expect(p[2].stackPosition == 1)

        // The stacking menu.
        let photoMenu = try #require(MainMenu.make().items.first { $0.title == "Photo" }?.submenu)
        let stacking = try #require(photoMenu.items.first { $0.title == "Stacking" }?.submenu)
        #expect(stacking.items.map(\.title) == [
            "Group into Stack", "Unstack", "Collapse Stack", "Move to Top of Stack", "Remove from Stack", "", "Collapse All Stacks", "Expand All Stacks",
        ])
        let group = stacking.items[0], unstack = stacking.items[1], toggle = stacking.items[2], top = stacking.items[3]
        #expect(group.keyEquivalent == "g" && group.keyEquivalentModifierMask == .command)
        #expect(unstack.keyEquivalent == "g" && unstack.keyEquivalentModifierMask == [.command, .shift])
        #expect(toggle.keyEquivalent == "s" && toggle.keyEquivalentModifierMask.isEmpty)
        #expect(top.keyEquivalent == "s" && top.keyEquivalentModifierMask == .shift)
        controller.state.selectedPhotoIDs = [p[2].objectID]
        #expect(!controller.validateUserInterfaceItem(group), "needs two photos")
        #expect(controller.validateUserInterfaceItem(unstack) && controller.validateUserInterfaceItem(toggle))
        #expect(toggle.title == "Collapse Stack", "the stack is open, so the command collapses it")
        controller.unstack(nil)
        #expect(!controller.validateUserInterfaceItem(unstack) && !controller.validateUserInterfaceItem(toggle))
    }

    @Test("Cells show a stack's count on its top photo and tint the members of an open stack")
    func cell() throws {
        let setup = try makeSetup()
        let p = setup.photos
        grouped(setup) { _ = setup.editing.groupIntoStack([p[0].objectID, p[1].objectID, p[2].objectID]) }
        let top = try #require(PhotoGridItem.stackInfo(for: p[0]))
        #expect(top == .init(count: 3, isCollapsed: true, isTop: true))
        #expect(PhotoGridItem.stackInfo(for: p[1]) == .init(count: 3, isCollapsed: true, isTop: false))
        #expect(PhotoGridItem.stackInfo(for: p[4]) == nil)
        let view = PhotoGridCellView()
        view.setStack(top)
        #expect(view.accessibilityValue() as? String == "Unrated, Top of a stack of 3")
        view.setStack(nil)
        #expect(view.accessibilityValue() as? String == "Unrated")
    }

    @Test("Imports Lightroom's folder stacks with order and collapsed state")
    func importsStacks() async throws {
        let fixture = try PhotosFixture()
        try fixture.run("""
            CREATE TABLE AgLibraryFolderStack (id_local INTEGER PRIMARY KEY, id_global, collapsed INTEGER NOT NULL DEFAULT 0, text NOT NULL DEFAULT '');
            CREATE TABLE AgLibraryFolderStackImage (id_local INTEGER PRIMARY KEY, collapsed INTEGER NOT NULL DEFAULT 0, image INTEGER NOT NULL DEFAULT 0, position NOT NULL DEFAULT '', stack INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE AgLibraryCollectionStack (id_local INTEGER PRIMARY KEY, id_global);
            INSERT INTO AgLibraryFolderStack (id_local, id_global, collapsed) VALUES (1, 's1', 1), (2, 's2', 0), (3, 's3', 1);
            INSERT INTO AgLibraryFolderStackImage (image, position, stack) VALUES
                (10, '---1', 1), (11, '---0', 1), (15, '---2', 1),
                (13, '---0', 2), (12, '---1', 2),
                (10, '---0', 3);
            INSERT INTO AgLibraryCollectionStack VALUES (1, 'c1');
            """)
        let (store, report) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }, { LightroomStacksPhase() }])
        let photos = Dictionary(try store.viewContext.fetch(Photo.fetchRequest()).filter { !$0.isVirtualCopy }.map { ($0.fileName, $0) }) { first, _ in first }
        // Stack 1: B, A, E (by order key), collapsed, so only B shows. Stack 2 (D and a video) is a stack too; stack 3 (one photo) is skipped.
        let stack = try #require(photos["B.jpg"]?.stack)
        #expect(stack.orderedPhotos.map(\.fileName) == ["B.jpg", "A.jpg", "E.jpg"] && stack.isCollapsed)
        #expect(photos["A.jpg"]?.isHiddenInStack == true && photos["E.jpg"]?.isHiddenInStack == true && photos["B.jpg"]?.isHiddenInStack == false)
        #expect(photos["D.cr2"]?.stack?.orderedPhotos.map(\.fileName) == ["D.cr2", "C.mov"])
        #expect(try store.viewContext.count(for: PhotoStack.fetchRequest()) == 2)
        #expect(report.imported.contains(.init(title: "Stacks", count: 2)) && report.imported.contains(.init(title: "Photos in stacks", count: 5)))
        #expect(report.warnings.contains { $0.contains("1 stack inside collections not imported") })
    }

    @Test("Opens a version nine catalog and adds the stack fields")
    func migratesVersionNine() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "V9.pixelloupe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(Fixtures.referencedInfo).write(to: CatalogPackage.infoURL(in: packageURL))
        let momd = try #require(Bundle(for: Photo.self).url(forResource: "PixelLoupe", withExtension: "momd"))
        let v9 = try #require(NSManagedObjectModel(contentsOf: momd.appending(path: "PixelLoupe 9.mom")))
        #expect(v9.entitiesByName["PhotoStack"] == nil)
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: v9)
            _ = try coordinator.addPersistentStore(type: .sqlite, at: CatalogPackage.databaseURL(in: packageURL))
            let context = NSManagedObjectContext(.mainQueue)
            context.persistentStoreCoordinator = coordinator
            let photo = NSEntityDescription.insertNewObject(forEntityName: "Photo", into: context)
            photo.setValue(UUID(), forKey: "id")
            photo.setValue("v9.jpg", forKey: "fileName")
            photo.setValue(Date(), forKey: "captureDate")
            photo.setValue(Date(), forKey: "importDate")
            photo.setValue(Date(), forKey: "editDate")
            try context.save()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }
        let store = try CatalogStore.open(at: packageURL)
        let photo = try #require(try store.viewContext.fetch(Photo.fetchRequest()).first)
        #expect(photo.stack == nil && photo.stackPosition == 0 && !photo.isHiddenInStack)
        // It shows in the grid (not hidden).
        let request = Photo.fetchRequest()
        request.predicate = LibraryFilter().predicate
        #expect(try store.viewContext.count(for: request) == 1)
    }
}
