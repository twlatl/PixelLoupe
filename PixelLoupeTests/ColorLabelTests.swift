import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Color labels")
@MainActor
struct ColorLabelTests {
    private func makeStore(photos count: Int = 6) throws -> (CatalogStore, [Photo]) {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        _ = directory  // the in-memory store keeps nothing on disk beyond thumbnails
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
        return (store, photos)
    }

    @Test("Names map to colors, ignoring case")
    func names() {
        #expect(ColorLabel(name: "Red") == .red)
        #expect(ColorLabel(name: " yellow ") == .yellow)
        #expect(ColorLabel(name: "GREEN") == .green)
        #expect(ColorLabel(name: "Blue") == .blue)
        #expect(ColorLabel(name: "purple") == .purple)
        #expect(ColorLabel(name: "") == nil)
        #expect(ColorLabel(name: "None") == nil)
        #expect(ColorLabel(name: "Approved") == nil)
        #expect(ColorLabel.colors.count == 5)
        #expect(ColorLabel.allCases.compactMap(\.shortcut) == ["6", "7", "8", "9"])
        #expect(ColorLabel(ruleValue: "blue") == .blue && ColorLabel(ruleValue: "x") == nil)
    }

    @Test("6–9 map to the labels, purple has no key")
    func keys() throws {
        func command(_ characters: String) -> KeyCommand? {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)
            return event.flatMap(KeyCommand.init(event:))
        }
        #expect(command("6") == .colorLabel(.red))
        #expect(command("7") == .colorLabel(.yellow))
        #expect(command("8") == .colorLabel(.green))
        #expect(command("9") == .colorLabel(.blue))
        #expect(command("5") == .rating(5))
    }

    @Test("Setting, toggling and clearing a label are undoable and named")
    func editing() throws {
        let (store, photos) = try makeStore()
        let editing = PhotoEditing(store: store)
        let ids = photos.prefix(3).map(\.objectID)
        let undo = try #require(store.viewContext.undoManager)

        func run(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
        }
        run { editing.setColorLabel(.red, for: ids, toggling: true) }
        #expect(photos.prefix(3).allSatisfy { $0.label == .red } && photos[3].label == .none)
        #expect(undo.undoActionName == "Set Color Label to Red")

        // The same key again clears it.
        run { editing.setColorLabel(.red, for: ids, toggling: true) }
        #expect(photos.prefix(3).allSatisfy { $0.label == .none })
        #expect(undo.undoActionName == "Clear Color Label")

        // A mixed selection gets the label first; the key doesn't toggle it off.
        photos[0].label = .red
        run { editing.setColorLabel(.red, for: ids, toggling: true) }
        #expect(photos.prefix(3).allSatisfy { $0.label == .red })

        // The menu sets without toggling.
        run { editing.setColorLabel(.red, for: ids) }
        #expect(photos.prefix(3).allSatisfy { $0.label == .red })
        run { editing.setColorLabel(.none, for: ids) }
        #expect(photos.prefix(3).allSatisfy { $0.label == .none })

        undo.undo()
        #expect(photos.prefix(3).allSatisfy { $0.label == .red })
        undo.undo()
        undo.undo()
        #expect(photos[0].label == .red && photos[1].label == .none)
    }

    @Test("Pressing 6–9 in the catalog window labels the selection; the same key clears it; the menu sets purple")
    func windowShortcuts() throws {
        let (store, photos) = try makeStore(photos: 3)
        store.viewContext.undoManager?.groupsByEvent = true
        let controller = CatalogWindowController(store: store)
        controller.showWindow(nil)
        defer { controller.close() }
        func press(_ key: String) -> Bool {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
            return KeyCommand(event: event).map { controller.perform($0) } ?? false
        }
        // Nothing selected: the key isn't taken.
        controller.state.selectedPhotoIDs = []
        #expect(!press("6"))

        let order = controller.state.photoOrder
        controller.state.selectedPhotoIDs = [order[0]]
        let first = try #require(photos.first { $0.objectID == order[0] })
        for (key, label) in [("6", ColorLabel.red), ("7", .yellow), ("8", .green), ("9", .blue)] {
            #expect(press(key))
            #expect(first.label == label)
        }
        #expect(press("9"))
        #expect(first.label == ColorLabel.none, "the same key clears the label")

        // Several selected: toggling applies to all.
        controller.state.selectedPhotoIDs = Array(order.prefix(2))
        #expect(press("6"))
        #expect(photos.filter { order.prefix(2).contains($0.objectID) }.allSatisfy { $0.label == .red })

        // Purple comes from the menu.
        let purple = NSMenuItem(title: "Purple", action: nil, keyEquivalent: "")
        purple.tag = Int(ColorLabel.purple.rawValue)
        controller.setColorLabelFromMenu(purple)
        #expect(photos.filter { order.prefix(2).contains($0.objectID) }.allSatisfy { $0.label == .purple })
        let photoMenu = try #require(MainMenu.make().items.first { $0.title == "Photo" }?.submenu)
        let labelMenu = try #require(photoMenu.items.first { $0.title == "Set Color Label" }?.submenu)
        #expect(labelMenu.items.map(\.title) == ["None", "Red  (6)", "Yellow  (7)", "Green  (8)", "Blue  (9)", "Purple"])
    }

    @Test("A label replaces a custom label's text")
    func customText() throws {
        let (store, photos) = try makeStore(photos: 1)
        photos[0].labelText = "Approved"
        PhotoEditing(store: store).setColorLabel(.green, for: [photos[0].objectID])
        #expect(photos[0].label == .green && photos[0].labelText == nil)
    }

    @Test("Filters by any combination of labels, including none")
    func filtering() throws {
        let (store, photos) = try makeStore()
        let labels: [ColorLabel] = [.red, .red, .yellow, .none, .blue, .none]
        for (photo, label) in zip(photos, labels) { photo.label = label }
        try store.viewContext.save()
        func count(_ set: Set<ColorLabel>) throws -> Int {
            var filter = LibraryFilter()
            filter.colorLabels = set
            let request = Photo.fetchRequest()
            request.predicate = filter.predicate
            return try store.viewContext.count(for: request)
        }
        #expect(try count([]) == 6)
        #expect(try count([.red]) == 2)
        #expect(try count([.red, .yellow]) == 3)
        #expect(try count([.none]) == 2)
        #expect(try count([.none, .blue]) == 3)
        #expect(try count([.green]) == 0)
    }

    @Test("Sorts by label")
    func sorting() throws {
        let (store, photos) = try makeStore(photos: 4)
        for (photo, label) in zip(photos, [ColorLabel.blue, .red, .none, .green]) { photo.label = label }
        try store.viewContext.save()
        var filter = LibraryFilter()
        filter.sortKey = .colorLabel
        filter.ascending = true
        let request = Photo.fetchRequest()
        request.sortDescriptors = filter.sortDescriptors
        let sorted = try store.viewContext.fetch(request).map(\.label)
        #expect(sorted == [.none, .red, .green, .blue])
        #expect(PhotoSortKey.colorLabel.title == "Label Color")
    }

    @Test("Smart collections match label colors and custom label text")
    func smartRules() throws {
        let (store, photos) = try makeStore()
        photos[0].label = .red
        photos[1].label = .blue
        photos[2].labelText = "Approved"
        try store.viewContext.save()
        func count(_ rule: SmartCollectionRules.Rule) throws -> Int {
            let request = Photo.fetchRequest()
            request.predicate = SmartCollectionRules(rules: [rule]).predicate
            return try store.viewContext.count(for: request)
        }
        #expect(try count(.init(field: .labelColor, operator: .is, value: "red")) == 1)
        #expect(try count(.init(field: .labelColor, operator: .isNot, value: "red")) == 5)
        #expect(try count(.init(field: .labelColor, operator: .is, value: "none")) == 4)
        #expect(try count(.init(field: .labelText, operator: .is, value: "approved")) == 1)
        #expect(try count(.init(field: .labelText, operator: .contains, value: "appr")) == 1)
        #expect(SmartCollectionRules.Field.labelColor.valueKind == .colorLabel)
        #expect(SmartCollectionRules.Rule.default(for: .labelColor).value == "red")
        #expect(SmartCollectionRules.Field.labelColor.operatorGroups == [[.is, .isNot]])
    }

    @Test("The Metadata panel shows the color label and edits it as a label")
    func metadataField() throws {
        let (store, photos) = try makeStore(photos: 2)
        photos[0].label = .purple
        let values = MetadataValues(info: .init(photo: photos[0]), file: FileMetadata())
        #expect(values.value(.label) == "Purple")
        #expect(MetadataValues(info: .init(photo: photos[1]), file: FileMetadata()).value(.label) == "None")
        #expect(MetadataField.field(.label).kind == .choice(["None", "Red", "Yellow", "Green", "Blue", "Purple"]))
        _ = store
    }

    @Test("Opens a version five catalog and adds the label fields")
    func migratesVersionFive() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "V5.pixelloupe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(Fixtures.referencedInfo).write(to: CatalogPackage.infoURL(in: packageURL))
        let momd = try #require(Bundle(for: Photo.self).url(forResource: "PixelLoupe", withExtension: "momd"))
        let v5 = try #require(NSManagedObjectModel(contentsOf: momd.appending(path: "PixelLoupe 5.mom")))
        #expect(v5.entitiesByName["Photo"]?.attributesByName["colorLabel"] == nil)
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: v5)
            _ = try coordinator.addPersistentStore(type: .sqlite, at: CatalogPackage.databaseURL(in: packageURL))
            let context = NSManagedObjectContext(.mainQueue)
            context.persistentStoreCoordinator = coordinator
            let photo = NSEntityDescription.insertNewObject(forEntityName: "Photo", into: context)
            photo.setValue(UUID(), forKey: "id")
            photo.setValue("v5.jpg", forKey: "fileName")
            photo.setValue(Date(), forKey: "captureDate")
            photo.setValue(Date(), forKey: "importDate")
            photo.setValue(Date(), forKey: "editDate")
            try context.save()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }
        let store = try CatalogStore.open(at: packageURL)
        let photo = try #require(try store.viewContext.fetch(Photo.fetchRequest()).first)
        #expect(photo.fileName == "v5.jpg" && photo.label == .none && photo.labelText == nil)
        photo.label = .yellow
        try store.viewContext.save()
        #expect(photo.colorLabel == 2)
    }

    @Test("Imports Lightroom's labels, keeping custom names as text and reporting them")
    func importsLabels() async throws {
        let fixture = try PhotosFixture()
        try fixture.run("""
            UPDATE Adobe_images SET colorLabels = 'Red' WHERE id_local = 10;
            UPDATE Adobe_images SET colorLabels = 'Approved' WHERE id_local = 11;
            UPDATE Adobe_images SET colorLabels = 'blue' WHERE id_local = 15;
            UPDATE Adobe_images SET colorLabels = 'Approved' WHERE id_local = 13;
            """)
        let (store, report) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }])
        let byName = Dictionary(try store.viewContext.fetch(Photo.fetchRequest()).filter { !$0.isVirtualCopy }.map { ($0.fileName, $0) }) { first, _ in first }
        #expect(byName["A.jpg"]?.label == .red)
        #expect(byName["E.jpg"]?.label == .blue)
        #expect(byName["B.jpg"]?.label == ColorLabel.none && byName["B.jpg"]?.labelText == "Approved")
        #expect(byName["D.cr2"]?.labelText == "Approved")
        let group = try #require(report.groups.first { $0.key == "label-approved" })
        #expect(group.photoCount == 2 && group.title.contains("Approved"))
        #expect(byName["B.jpg"]?.importDifferences == "|label-approved|")
    }
}
