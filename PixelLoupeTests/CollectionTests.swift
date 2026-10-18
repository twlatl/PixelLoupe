import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

/// A catalog (SQLite, so predicates are checked by the real store) with six varied photos.
@MainActor
private struct Library {
    let directory: TemporaryDirectory
    let store: CatalogStore
    /// By file name.
    let photos: [String: Photo]

    init() throws {
        directory = try TemporaryDirectory()
        store = try CatalogStore.create(at: directory.url.appending(path: "C.pixelloupe", directoryHint: .isDirectory), info: Fixtures.referencedInfo)
        let context = store.viewContext
        let now = Date()
        let day: TimeInterval = 86_400
        func folder(_ path: String) -> Folder {
            let folder = Folder(context: context)
            folder.path = path
            folder.name = (path as NSString).lastPathComponent
            return folder
        }
        let trips = folder("/Photos/Trips"), home = folder("/Photos/Home")
        let family = Tag.findOrCreate(named: "Family", in: context), beach = Tag.findOrCreate(named: "Beach", in: context)
        var photos: [String: Photo] = [:]
        func photo(_ name: String, rating: Int16, flag: PhotoFlag, make: String?, model: String?, lens: String?,
                   capturedDaysAgo: Double, tags: Set<PixelLoupe.Tag>, folder: Folder, edited: Bool) {
            let photo = Photo(context: context)
            photo.id = UUID()
            photo.fileName = name
            photo.filePath = folder.path + "/" + name
            photo.fileType = (name as NSString).pathExtension.uppercased()
            photo.rating = rating
            photo.photoFlag = flag
            photo.cameraMake = make
            photo.cameraModel = model
            photo.lensModel = lens
            photo.captureDate = now - capturedDaysAgo * day
            photo.importDate = now - 1 * day
            photo.editDate = now - (edited ? 0.5 : 30) * day
            photo.tags = tags
            photo.folder = folder
            if edited {
                var adjustments = PhotoAdjustments()
                adjustments.light.exposure = 0.3
                photo.adjustments = adjustments
            }
            photos[name] = photo
        }
        photo("A.ARW", rating: 5, flag: .picked, make: "SONY", model: "ILCE-7M4", lens: "FE 24-70mm F2.8 GM II",
              capturedDaysAgo: 3, tags: [family, beach], folder: trips, edited: true)
        photo("B.ARW", rating: 3, flag: .unflagged, make: "SONY", model: "ILCE-6600", lens: "E 18-50mm",
              capturedDaysAgo: 60, tags: [family], folder: trips, edited: false)
        photo("C.JPG", rating: 0, flag: .rejected, make: "Apple", model: "iPhone 17 Pro", lens: nil,
              capturedDaysAgo: 400, tags: [], folder: home, edited: false)
        photo("D.HEIC", rating: 4, flag: .picked, make: "Apple", model: "iPhone 17 Pro", lens: nil,
              capturedDaysAgo: 10, tags: [beach], folder: home, edited: true)
        photo("E.DNG", rating: 1, flag: .unflagged, make: "Leica", model: "Q3", lens: "Summilux 28",
              capturedDaysAgo: 800, tags: [], folder: home, edited: false)
        photo("F.CR3", rating: 5, flag: .unflagged, make: "Canon", model: "EOS R5", lens: "RF24-70mm F2.8",
              capturedDaysAgo: 20, tags: [], folder: trips, edited: false)
        try context.save()
        context.undoManager?.removeAllActions()
        self.photos = photos
    }

    /// The file names a rule set matches, through the store.
    func matches(_ rules: SmartCollectionRules) throws -> Set<String> {
        let request = Photo.fetchRequest()
        request.predicate = rules.predicate
        return Set(try store.viewContext.fetch(request).map(\.fileName))
    }

    func matches(_ rule: SmartCollectionRules.Rule) throws -> Set<String> {
        try matches(SmartCollectionRules(rules: [rule]))
    }

    func ids(_ names: String...) -> [NSManagedObjectID] { names.map { photos[$0]!.objectID } }
}

@Suite("Smart collection rules")
@MainActor
struct SmartCollectionRuleTests {
    typealias Rule = SmartCollectionRules.Rule

    @Test func ratings() throws {
        let library = try Library()
        #expect(try library.matches(Rule(field: .rating, operator: .is, value: "5")) == ["A.ARW", "F.CR3"])
        #expect(try library.matches(Rule(field: .rating, operator: .atLeast, value: "4")) == ["A.ARW", "D.HEIC", "F.CR3"])
        #expect(try library.matches(Rule(field: .rating, operator: .lessThan, value: "3")) == ["C.JPG", "E.DNG"])
        #expect(try library.matches(Rule(field: .rating, operator: .inRange, value: "1", value2: "3")) == ["B.ARW", "E.DNG"])
        #expect(try library.matches(Rule(field: .rating, operator: .isNot, value: "5")).count == 4)
    }

    @Test func flagsAndFileTypesAndEdits() throws {
        let library = try Library()
        #expect(try library.matches(Rule(field: .flag, operator: .is, value: "picked")) == ["A.ARW", "D.HEIC"])
        #expect(try library.matches(Rule(field: .flag, operator: .isNot, value: "unflagged")) == ["A.ARW", "C.JPG", "D.HEIC"])
        #expect(try library.matches(Rule(field: .fileType, operator: .is, value: "Raw")) == ["A.ARW", "B.ARW", "F.CR3"])
        #expect(try library.matches(Rule(field: .fileType, operator: .is, value: "HEIF")) == ["D.HEIC"])
        #expect(try library.matches(Rule(field: .fileType, operator: .isNot, value: "JPEG")).count == 5)
        #expect(try library.matches(Rule(field: .edited, operator: .is, value: "true")) == ["A.ARW", "D.HEIC"])
    }

    @Test func keywords() throws {
        let library = try Library()
        #expect(try library.matches(Rule(field: .keywords, operator: .contains, value: "fam")) == ["A.ARW", "B.ARW"])
        #expect(try library.matches(Rule(field: .keywords, operator: .containsAll, value: "family, beach")) == ["A.ARW"])
        #expect(try library.matches(Rule(field: .keywords, operator: .doesNotContain, value: "beach")) == ["B.ARW", "C.JPG", "E.DNG", "F.CR3"])
        #expect(try library.matches(Rule(field: .keywords, operator: .isEmpty, value: "")) == ["C.JPG", "E.DNG", "F.CR3"])
        #expect(try library.matches(Rule(field: .keywords, operator: .isNotEmpty, value: "")) == ["A.ARW", "B.ARW", "D.HEIC"])
    }

    @Test func cameraLensFileNameFolder() throws {
        let library = try Library()
        #expect(try library.matches(Rule(field: .camera, operator: .contains, value: "sony")) == ["A.ARW", "B.ARW"])
        #expect(try library.matches(Rule(field: .camera, operator: .is, value: "iPhone 17 Pro")) == ["C.JPG", "D.HEIC"])
        #expect(try library.matches(Rule(field: .lens, operator: .startsWith, value: "FE")) == ["A.ARW"])
        #expect(try library.matches(Rule(field: .lens, operator: .isEmpty, value: "")) == ["C.JPG", "D.HEIC"])
        #expect(try library.matches(Rule(field: .fileName, operator: .endsWith, value: ".ARW")) == ["A.ARW", "B.ARW"])
        #expect(try library.matches(Rule(field: .folder, operator: .contains, value: "Trips")) == ["A.ARW", "B.ARW", "F.CR3"])
    }

    @Test func dates() throws {
        let library = try Library()
        #expect(try library.matches(Rule(field: .captureDate, operator: .inTheLast, value: "1", unit: .months)) == ["A.ARW", "D.HEIC", "F.CR3"])
        #expect(try library.matches(Rule(field: .captureDate, operator: .notInTheLast, value: "1", unit: .years)) == ["C.JPG", "E.DNG"])
        #expect(try library.matches(Rule(field: .editDate, operator: .inTheLast, value: "2", unit: .days)) == ["A.ARW", "D.HEIC"])
        let today = SmartCollectionRules.dayFormatter.string(from: Date())
        let weekAgo = SmartCollectionRules.dayFormatter.string(from: Date() - 7 * 86_400)
        #expect(try library.matches(Rule(field: .captureDate, operator: .inRange, value: weekAgo, value2: today)) == ["A.ARW"])
        #expect(try library.matches(Rule(field: .captureDate, operator: .isAfter, value: weekAgo)) == ["A.ARW"])
        let yesterday = SmartCollectionRules.dayFormatter.string(from: Date() - 86_400)
        #expect(try library.matches(Rule(field: .importDate, operator: .is, value: yesterday)).count == 6)
    }

    @Test func matchAllOrAny() throws {
        let library = try Library()
        let rules = [Rule(field: .rating, operator: .is, value: "5"), Rule(field: .camera, operator: .contains, value: "Sony")]
        #expect(try library.matches(SmartCollectionRules(match: .all, rules: rules)) == ["A.ARW"])
        #expect(try library.matches(SmartCollectionRules(match: .any, rules: rules)) == ["A.ARW", "B.ARW", "F.CR3"])
    }

    @Test func rulesRoundTrip() throws {
        let rules = SmartCollectionRules(match: .any, rules: [Rule(field: .captureDate, operator: .inTheLast, value: "3", unit: .weeks)])
        #expect(try JSONDecoder().decode(SmartCollectionRules.self, from: JSONEncoder().encode(rules)) == rules)
        // Every field's default rule and every operator it offers make a valid predicate.
        let library = try Library()
        for field in SmartCollectionRules.Field.allCases {
            for op in field.operators {
                var rule = Rule.default(for: field)
                rule.operator = op
                if field.valueKind == .date, op != .inTheLast, op != .notInTheLast {
                    rule.value = SmartCollectionRules.dayFormatter.string(from: Date())
                }
                _ = try library.matches(rule)
            }
        }
    }
}

@Suite("Collections")
@MainActor
struct CollectionEditingTests {
    @Test func collectionsHoldPhotosAndUndo() throws {
        let library = try Library()
        let editing = CollectionEditing(store: library.store)
        let undoManager = try #require(library.store.viewContext.undoManager)
        let trip = editing.create(.collection, named: "Trip", in: nil, photos: library.ids("A.ARW", "B.ARW"))
        #expect(Set(trip.photos.map(\.fileName)) == ["A.ARW", "B.ARW"])
        editing.add(library.ids("F.CR3"), to: trip.id)
        editing.remove(library.ids("A.ARW"), from: trip.id)
        #expect(Set(trip.photos.map(\.fileName)) == ["B.ARW", "F.CR3"])
        #expect(undoManager.undoActionName == "Remove from Collection")

        // B toggles: adds when any are missing, removes when all are in.
        #expect(editing.toggle(library.ids("A.ARW", "B.ARW"), in: trip.id))
        #expect(trip.photos.count == 3)
        #expect(!editing.toggle(library.ids("A.ARW", "B.ARW"), in: trip.id))
        #expect(Set(trip.photos.map(\.fileName)) == ["F.CR3"])

        let request = Photo.fetchRequest()
        request.predicate = trip.content.predicate
        #expect(try library.store.viewContext.fetch(request).map(\.fileName) == ["F.CR3"], "the Library shows its photos")
    }

    @Test func setsShowEverythingInsideAndDeleteWithTheirCollections() throws {
        let library = try Library()
        let editing = CollectionEditing(store: library.store)
        let set = editing.create(.set, named: "Travel", in: nil)
        let trip = editing.create(.collection, named: "Trip", in: set.id, photos: library.ids("C.JPG"))
        let fives = editing.create(.smart, named: "Fives", in: set.id, rules: SmartCollectionRules(rules: [.init(field: .rating, operator: .is, value: "5")]))
        #expect(trip.parent == set && fives.parent == set)
        #expect(trip.path == "Travel ▸ Trip")
        let request = Photo.fetchRequest()
        request.predicate = set.content.predicate
        #expect(Set(try library.store.viewContext.fetch(request).map(\.fileName)) == ["A.ARW", "C.JPG", "F.CR3"])

        editing.delete(set.id)
        #expect(try library.store.viewContext.count(for: PhotoCollection.fetchRequest()) == 0)
        #expect(try library.store.viewContext.count(for: Photo.fetchRequest()) == 6, "photos stay")
    }

    @Test func aSetCantMoveInsideItself() throws {
        let library = try Library()
        let editing = CollectionEditing(store: library.store)
        let outer = editing.create(.set, named: "Outer", in: nil)
        let smart = editing.create(.smart, named: "Smart", in: outer.id)
        editing.update(smart.id, name: "Renamed", parent: nil, rules: SmartCollectionRules())
        #expect(smart.parent == nil && smart.name == "Renamed")
        #expect(editing.sets(excluding: outer.id).isEmpty)
    }

    @Test func starterSmartCollectionsAreMadeOnce() throws {
        let library = try Library()
        let editing = CollectionEditing(store: library.store)
        editing.createDefaultSmartCollections()
        let request = PhotoCollection.fetchRequest()
        request.predicate = NSPredicate(format: "kindValue == %d", PhotoCollection.Kind.smart.rawValue)
        let smart = try library.store.viewContext.fetch(request)
        #expect(Set(smart.map(\.name)) == ["Five Stars", "Past Month", "Recently Modified", "Without Keywords"])
        #expect(smart.allSatisfy { $0.parent?.name == "Smart Collections" })
        #expect(library.store.viewContext.undoManager?.canUndo == false, "not an undoable edit")
        let fiveStars = try #require(smart.first { $0.name == "Five Stars" })
        #expect(try library.matches(fiveStars.rules) == ["A.ARW", "F.CR3"])

        // Deleting them sticks.
        editing.delete(fiveStars.parent!.id)
        editing.createDefaultSmartCollections()
        #expect(try library.store.viewContext.count(for: PhotoCollection.fetchRequest()) == 0)
    }
}

@Suite("Collections in the window")
@MainActor
struct CollectionWindowTests {
    /// Every test starts with each sidebar section expanded.
    init() {
        Defaults.store.set(false, forKey: "CollectionsCollapsed")
        Defaults.store.removeObject(forKey: "CollapsedSidebarHeaders")
    }

    private func window(_ library: Library) -> CatalogWindowController {
        let controller = CatalogWindowController(store: library.store)
        controller.showWindow(nil)
        controller.window?.layoutIfNeeded()
        return controller
    }

    private func rows(_ controller: CatalogWindowController) -> [String] {
        let outline = controller.window!.contentView!.descendants.compactMap { $0 as? NSOutlineView }.first!
        return (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? SidebarViewController.Item)?.title }
    }

    @Test func theSidebarListsCollectionsSortedByKindWithCounts() throws {
        let library = try Library()
        let controller = window(library)
        defer { controller.close() }
        let editing = CollectionEditing(store: library.store)
        editing.create(.collection, named: "Alpha", in: nil, photos: library.ids("A.ARW", "C.JPG"))
        editing.create(.smart, named: "Zulu Picks", in: nil, rules: SmartCollectionRules(rules: [.init(field: .flag, operator: .is, value: "picked")]))
        controller.rootViewController.main.sidebar.reload()
        let titles = rows(controller)
        let collections = Array(titles.drop { $0 != "Collections" })
        #expect(collections.prefix(4) == ["Collections", "", "Smart Collections", "Five Stars"], "the filter row, then sets first")
        #expect(collections.firstIndex(of: "Zulu Picks")! < collections.firstIndex(of: "Alpha")!, "smart before regular when sorting by kind")

        let sidebar = controller.rootViewController.main.sidebar
        let outline = controller.window!.contentView!.descendants.compactMap { $0 as? NSOutlineView }.first!
        let alpha = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SidebarViewController.Item }.first { $0.title == "Alpha" }
        #expect(alpha?.count == 2)
        let picks = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SidebarViewController.Item }.first { $0.title == "Zulu Picks" }
        #expect(picks?.count == 2)

        // Filtering by name keeps matches (and the sets they're in).
        sidebar.collectionFilterField.stringValue = "five"
        sidebar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: sidebar.collectionFilterField))
        #expect(Array(rows(controller).drop { $0 != "Collections" }) == ["Collections", "", "Smart Collections", "Five Stars"])
        sidebar.collectionFilterField.stringValue = ""
        sidebar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: sidebar.collectionFilterField))
    }

    @Test func theCollectionsSectionCollapsesToItsHeading() throws {
        let library = try Library()
        let controller = window(library)
        defer { controller.close() }
        let sidebar = controller.rootViewController.main.sidebar
        #expect(rows(controller).contains("Five Stars"))
        #expect(sidebar.collectionsDisclosure.accessibilityValue() as? String == "expanded")

        sidebar.collectionsDisclosure.performClick(nil)
        #expect(rows(controller).last == "Collections", "just the heading")
        #expect(sidebar.collectionsDisclosure.accessibilityValue() as? String == "collapsed")
        sidebar.reload()
        #expect(rows(controller).last == "Collections", "stays collapsed when the sidebar reloads")

        sidebar.collectionsDisclosure.performClick(nil)
        #expect(rows(controller).contains("Five Stars"))
        // The ⊕ menu sits beside the chevron.
        #expect(sidebar.collectionsButton.superview === sidebar.collectionsDisclosure.superview)
        #expect(sidebar.collectionsButton.itemTitles.contains("Create Collection…"))
    }

    @Test func togglingCollectionsLeavesACollapsedFoldersHeaderCollapsed() throws {
        let library = try Library()
        let controller = window(library)
        defer { controller.close() }
        let sidebar = controller.rootViewController.main.sidebar
        let outline = controller.window!.contentView!.descendants.compactMap { $0 as? NSOutlineView }.first!
        let folders = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SidebarViewController.Item }
            .first { $0.title == "Folders" }!
        let folderRows = { (0..<outline.numberOfRows).filter {
            if case .folder? = (outline.item(atRow: $0) as? SidebarViewController.Item)?.kind { return true }
            return false
        }.count }
        #expect(folderRows() > 0)

        outline.collapseItem(folders)   // as its Show/Hide button does
        #expect(folderRows() == 0)
        sidebar.collectionsDisclosure.performClick(nil)
        #expect(folderRows() == 0, "collapsing Collections leaves Folders collapsed")
        sidebar.collectionsDisclosure.performClick(nil)
        #expect(folderRows() == 0, "and so does expanding it")
        sidebar.reload()
        #expect(folderRows() == 0, "and so does any reload")

        let expanded = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? SidebarViewController.Item }
            .first { $0.title == "Folders" }!
        outline.expandItem(expanded)
        #expect(folderRows() > 0)
        sidebar.reload()
        #expect(folderRows() > 0)
    }

    @Test func selectingACollectionShowsItsPhotosAndIsRestored() throws {
        let library = try Library()
        let editing = CollectionEditing(store: library.store)
        let trip = editing.create(.collection, named: "Trip", in: nil, photos: library.ids("B.ARW", "E.DNG"))
        do {
            let controller = window(library)
            controller.state.filter.scope = .collection(id: trip.id, content: trip.content)
            #expect(Set(controller.state.photoOrder.compactMap { (try? library.store.viewContext.existingObject(with: $0) as? Photo)?.fileName }) == ["B.ARW", "E.DNG"])
            controller.close()
        }
        #expect(library.store.viewState.collectionID == trip.id)
        let reopened = window(library)
        defer { reopened.close() }
        #expect(reopened.state.filter.scope.collectionID == trip.id)
        #expect(reopened.state.photoOrder.count == 2)
    }

    @Test func newCollectionDialogCreatesWithSelectedPhotosAndTarget() throws {
        let library = try Library()
        let controller = window(library)
        defer { controller.close() }
        controller.state.selectedPhotoIDs = library.ids("A.ARW", "D.HEIC")
        controller.newCollection(nil)
        let dialog = try #require(controller.lastCollectionDialog)
        #expect(dialog.nameField.stringValue == "Collection")
        #expect(dialog.includeSelectedCheckbox.state == .on)
        dialog.nameField.stringValue = "Beach Day"
        dialog.targetCheckbox.state = .on
        dialog.create(nil)
        let created = try #require(CollectionEditing(store: library.store).collections().first { $0.path == "Beach Day" })
        let collection = try #require(PhotoCollection.with(id: created.id, in: library.store.viewContext))
        #expect(Set(collection.photos.map(\.fileName)) == ["A.ARW", "D.HEIC"])
        #expect(library.store.viewState.targetCollectionID == created.id)
        #expect(controller.state.filter.scope.collectionID == created.id, "and shows it")
        let outline = controller.window!.contentView!.descendants.compactMap { $0 as? NSOutlineView }.first!
        let row = try #require((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarViewController.Item)?.title == "Beach Day" })
        #expect((outline.item(atRow: row) as? SidebarViewController.Item)?.isTarget == true, "marked as the target")
        let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
        #expect(cell?.textField?.stringValue == "Beach Day +")

        // B adds the selection to the target, and again removes it.
        controller.state.selectedPhotoIDs = library.ids("F.CR3")
        #expect(controller.perform(.addToTargetCollection))
        #expect(collection.photos.count == 3)
        #expect(controller.perform(.addToTargetCollection))
        #expect(collection.photos.count == 2)
    }

    @Test func smartCollectionDialogSavesItsRules() throws {
        let library = try Library()
        let controller = window(library)
        defer { controller.close() }
        controller.newSmartCollection(nil)
        let dialog = try #require(controller.lastCollectionDialog)
        let editor = try #require(dialog.rulesEditor)
        #expect(editor.rules == [.default(for: .rating)])
        let row = try #require(editor.rows.first)
        row.fieldPopUp.selectItem(withTitle: "Camera")
        _ = row.fieldPopUp.target?.perform(row.fieldPopUp.action, with: row.fieldPopUp)
        #expect(editor.rules[0].field == .camera && editor.rules[0].operator == .contains)
        dialog.nameField.stringValue = "Canon"
        dialog.matchPopUp.selectItem(withTitle: "any")
        dialog.create(nil)
        let request = PhotoCollection.fetchRequest()
        request.predicate = NSPredicate(format: "name == 'Canon'")
        let smart = try #require(try library.store.viewContext.fetch(request).first)
        #expect(smart.kind == .smart && smart.rules.match == .any && smart.rules.rules[0].field == .camera)
    }

    @Test func droppingPhotosOnACollectionAddsThem() throws {
        let library = try Library()
        let controller = window(library)
        defer { controller.close() }
        let trip = CollectionEditing(store: library.store).create(.collection, named: "Trip", in: nil)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PixelLoupeTestDrag"))
        pasteboard.clearContents()
        pasteboard.writeObjects(library.ids("A.ARW", "B.ARW").map(PhotoDrag.pasteboardItem))
        #expect(Set(PhotoDrag.objectIDs(from: pasteboard, store: library.store)) == Set(library.ids("A.ARW", "B.ARW")))
        CollectionEditing(store: library.store).add(PhotoDrag.objectIDs(from: pasteboard, store: library.store), to: trip.id)
        #expect(trip.photos.count == 2)
    }
}

@Suite("Library menu")
@MainActor
struct LibraryMenuTests {
    @Test func collectionItemsAreAtTheTopOfTheLibraryMenu() throws {
        let menu = MainMenu.make()
        let titles = menu.items.map(\.title)
        #expect(titles.firstIndex(of: "Library")! == titles.firstIndex(of: "Edit")! + 1)
        let library = try #require(menu.items.first { $0.title == "Library" }?.submenu)
        #expect(library.items.prefix(3).map(\.title) == ["New Collection…", "New Smart Collection…", "New Collection Set…"])
        #expect(library.items[0].keyEquivalent == "n" && library.items[0].keyEquivalentModifierMask == .command)
        let file = try #require(menu.items.first { $0.title == "File" }?.submenu)
        let newCatalog = try #require(file.items.first { $0.title == "New Catalog…" })
        #expect(newCatalog.keyEquivalentModifierMask == [.command, .option], "⌘N went to New Collection")
    }

    @Test func bIsAddToTargetCollection() {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                     context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11)!
        #expect(KeyCommand(event: event) == .addToTargetCollection)
    }
}
