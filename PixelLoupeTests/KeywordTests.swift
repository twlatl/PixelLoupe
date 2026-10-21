import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Hierarchical keywords")
@MainActor
struct KeywordTests {
    private func makeStore() throws -> CatalogStore {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        store.viewContext.undoManager?.groupsByEvent = false
        store.viewContext.undoManager?.removeAllActions()
        return store
    }

    /// Runs `body` as one undo group: the undo manager needs an open group when groups aren't tied to
    /// run loop events (as in these tests).
    private func grouped<T>(_ store: CatalogStore, _ body: () throws -> T) rethrows -> T {
        let undo = store.viewContext.undoManager
        undo?.beginUndoGrouping()
        defer { undo?.endUndoGrouping() }
        return try body()
    }

    private func photo(_ name: String, tags: Set<PixelLoupe.Tag> = [], in context: NSManagedObjectContext) -> Photo {
        let photo = Photo(context: context)
        photo.id = UUID()
        photo.fileName = name
        photo.captureDate = Date()
        photo.importDate = Date()
        photo.editDate = Date()
        photo.tags = tags
        return photo
    }

    private func count(_ predicate: NSPredicate?, in context: NSManagedObjectContext) throws -> Int {
        let request = Photo.fetchRequest()
        request.predicate = predicate
        return try context.count(for: request)
    }

    @Test("Typed paths split on > and |")
    func parsing() {
        #expect(PixelLoupe.Tag.parsePath("Places > Ireland > Dublin") == ["Places", "Ireland", "Dublin"])
        #expect(PixelLoupe.Tag.parsePath("Places|Ireland | Dublin") == ["Places", "Ireland", "Dublin"])
        #expect(PixelLoupe.Tag.parsePath("  Family  ") == ["Family"])
        #expect(PixelLoupe.Tag.parsePath(" > A >> B > ") == ["A", "B"])
        #expect(PixelLoupe.Tag.parsePath("").isEmpty)
        #expect(PixelLoupe.Tag.parsePath(" > ").isEmpty)
    }

    @Test("A path makes the tree once; siblings are unique, other branches can repeat a name")
    func paths() throws {
        let store = try makeStore()
        let context = store.viewContext
        let dublin = try #require(PixelLoupe.Tag.findOrCreate(path: ["Places", "Ireland", "Dublin"], in: context))
        try context.save()
        #expect(dublin.displayPath == "Places > Ireland > Dublin" && dublin.pathKey == "Places > Ireland > Dublin")
        #expect(dublin.parent?.name == "Ireland" && dublin.parent?.parent?.parent == nil)
        #expect(try context.count(for: PixelLoupe.Tag.fetchRequest()) == 3)

        // The same path, in another case, finds the same keywords.
        let again = try #require(PixelLoupe.Tag.findOrCreate(path: ["places", "IRELAND", "dublin"], in: context))
        #expect(again === dublin)
        #expect(try context.count(for: PixelLoupe.Tag.fetchRequest()) == 3)

        // "Dublin" under another parent is a different keyword.
        let ohio = try #require(PixelLoupe.Tag.findOrCreate(path: ["Places", "Ohio", "Dublin"], in: context))
        try context.save()
        #expect(ohio !== dublin && ohio.displayPath == "Places > Ohio > Dublin")
        #expect(PixelLoupe.Tag.tags(named: "dublin", in: context).count == 2)

        // Creating a sibling with a taken name is refused, in any case.
        let keywords = KeywordEditing(store: store)
        try context.save()
        #expect(throws: KeywordEditing.Failure.duplicate("ireland")) { try keywords.create(named: "ireland", in: dublin.parent?.parent) }
        #expect(throws: KeywordEditing.Failure.emptyName) { try keywords.create(named: "  ", in: nil) }
        let wales = try grouped(store) { try keywords.create(named: "Wales", in: dublin.parent?.parent) }
        #expect(wales.pathKey == "Places > Wales")
        #expect(store.viewContext.undoManager?.undoActionName == "Create Keyword")
    }

    @Test("Renaming updates every path below; a rename onto a sibling is refused; both undo")
    func renaming() throws {
        let store = try makeStore()
        let context = store.viewContext
        let dublin = try #require(PixelLoupe.Tag.findOrCreate(path: ["Places", "Ireland", "Dublin"], in: context))
        let ireland = try #require(dublin.parent)
        _ = PixelLoupe.Tag.findOrCreate(path: ["Places", "Eire"], in: context)
        try context.save()
        let keywords = KeywordEditing(store: store)

        #expect(throws: KeywordEditing.Failure.duplicate("eire")) { try keywords.rename(ireland, to: "eire") }
        try grouped(store) { try keywords.rename(ireland, to: "Éire") }
        #expect(dublin.pathKey == "Places > Éire > Dublin" && ireland.pathKey == "Places > Éire")
        #expect(context.undoManager?.undoActionName == "Rename Keyword")
        context.undoManager?.undo()
        #expect(ireland.name == "Ireland")
    }

    @Test("Deleting a keyword deletes the keywords inside it, and photos keep the rest")
    func deleting() throws {
        let store = try makeStore()
        let context = store.viewContext
        let dublin = try #require(PixelLoupe.Tag.findOrCreate(path: ["Places", "Ireland", "Dublin"], in: context))
        let family = PixelLoupe.Tag.findOrCreate(named: "Family", in: context)
        let tagged = photo("a.jpg", tags: [dublin, family], in: context)
        try context.save()
        let parent = try #require(dublin.parent)
        grouped(store) { KeywordEditing(store: store).delete(parent) }
        #expect(try context.count(for: PixelLoupe.Tag.fetchRequest()) == 2)  // Places, Family
        #expect(tagged.tags.map(\.name) == ["Family"])
    }

    @Test("A plain name uses the one keyword with that name, makes a root keyword if none, and is ambiguous if several")
    func resolving() throws {
        let store = try makeStore()
        let context = store.viewContext
        _ = PixelLoupe.Tag.findOrCreate(path: ["Places", "Ireland", "Dublin"], in: context)
        guard case .tag(let found)? = PixelLoupe.Tag.resolve("dublin", in: context) else { Issue.record("expected a keyword"); return }
        #expect(found.displayPath == "Places > Ireland > Dublin")
        guard case .tag(let made)? = PixelLoupe.Tag.resolve("Birthday", in: context) else { Issue.record("expected a keyword"); return }
        #expect(made.parent == nil && made.pathKey == "Birthday")
        guard case .tag(let path)? = PixelLoupe.Tag.resolve("Places | Ohio > Dublin", in: context) else { Issue.record("expected a keyword"); return }
        #expect(path.displayPath == "Places > Ohio > Dublin")
        guard case .ambiguous(let options)? = PixelLoupe.Tag.resolve("Dublin", in: context) else { Issue.record("expected a choice"); return }
        #expect(options.map(\.displayPath) == ["Places > Ireland > Dublin", "Places > Ohio > Dublin"])
        #expect(PixelLoupe.Tag.resolve(" > ", in: context) == nil)
    }

    @Test("The keyword filter matches a keyword and everything below it")
    func filterMatchesDescendants() throws {
        let store = try makeStore()
        let context = store.viewContext
        let dublin = try #require(PixelLoupe.Tag.findOrCreate(path: ["Places", "Ireland", "Dublin"], in: context))
        let cork = try #require(PixelLoupe.Tag.findOrCreate(path: ["Places", "Ireland", "Cork"], in: context))
        let paris = try #require(PixelLoupe.Tag.findOrCreate(path: ["Places", "France", "Paris"], in: context))
        let family = PixelLoupe.Tag.findOrCreate(named: "Family", in: context)
        _ = photo("dublin.jpg", tags: [dublin], in: context)
        _ = photo("cork.jpg", tags: [cork, family], in: context)
        _ = photo("paris.jpg", tags: [paris], in: context)
        _ = photo("none.jpg", in: context)
        try context.save()

        func matches(_ paths: Set<String>) throws -> Int {
            var filter = LibraryFilter()
            filter.metadata.select(keywords: paths)
            return try count(filter.predicate, in: context)
        }
        #expect(try matches(["Places"]) == 3)
        #expect(try matches(["Places > Ireland"]) == 2)
        #expect(try matches(["places > ireland > dublin"]) == 1)
        #expect(try matches(["Places > Ireland", "Family"]) == 2)
        #expect(try matches(["Places > France", "Places > Ireland > Cork"]) == 2)
        #expect(try matches(["Ireland"]) == 0, "a keyword is chosen by its path")
        #expect(try matches(["Place"]) == 0, "not a prefix match on names")
        #expect(try matches([]) == 4)
    }

    @Test("Smart collection keyword rules match names, ancestors and synonyms")
    func smartRules() throws {
        let store = try makeStore()
        let context = store.viewContext
        let dublin = try #require(PixelLoupe.Tag.findOrCreate(path: ["Places", "Ireland", "Dublin"], in: context))
        let dog = try #require(PixelLoupe.Tag.findOrCreate(path: ["Animals", "Dog"], in: context))
        dog.synonyms = ["puppy", "hound"]
        _ = photo("dublin.jpg", tags: [dublin], in: context)
        _ = photo("dog.jpg", tags: [dog], in: context)
        _ = photo("none.jpg", in: context)
        try context.save()
        func count(_ op: SmartCollectionRules.Operator, _ text: String) throws -> Int {
            try self.count(SmartCollectionRules(rules: [.init(field: .keywords, operator: op, value: text)]).predicate, in: context)
        }
        #expect(try count(.contains, "Dublin") == 1)
        #expect(try count(.contains, "ireland") == 1, "a photo tagged Dublin matches its parent Ireland")
        #expect(try count(.contains, "places") == 1)
        #expect(try count(.contains, "puppy") == 1, "synonyms match")
        #expect(try count(.startsWith, "hou") == 1)
        #expect(try count(.containsAll, "ireland, dublin") == 1)
        #expect(try count(.containsAll, "ireland, puppy") == 0)
        #expect(try count(.doesNotContain, "ireland") == 2)
        #expect(try count(.doesNotContain, "puppy") == 2)
        #expect(try count(.isEmpty, "") == 1)
        #expect(try count(.isNotEmpty, "") == 2)
    }

    @Test("Exporting honors each keyword's flags")
    func exportNames() throws {
        let store = try makeStore()
        let context = store.viewContext
        let dublin = try #require(PixelLoupe.Tag.findOrCreate(path: ["Places", "Ireland", "Dublin"], in: context))
        dublin.synonyms = ["Baile Átha Cliath"]
        #expect(PixelLoupe.Tag.exportNames(for: [dublin]) == ["Baile Átha Cliath", "Dublin", "Ireland", "Places"])
        dublin.includeParents = false
        #expect(PixelLoupe.Tag.exportNames(for: [dublin]) == ["Baile Átha Cliath", "Dublin"])
        dublin.includeSynonyms = false
        #expect(PixelLoupe.Tag.exportNames(for: [dublin]) == ["Dublin"])
        dublin.includeOnExport = false
        #expect(PixelLoupe.Tag.exportNames(for: [dublin]).isEmpty)
        // A parent marked not to export is left out when a child brings it along.
        dublin.includeOnExport = true
        dublin.includeParents = true
        try #require(dublin.parent).includeOnExport = false
        #expect(PixelLoupe.Tag.exportNames(for: [dublin]) == ["Dublin", "Places"])
    }

    @Test("Keywords from a catalog without a tree get their paths")
    func migration() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "V6.pixelloupe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(Fixtures.referencedInfo).write(to: CatalogPackage.infoURL(in: packageURL))
        let momd = try #require(Bundle(for: Photo.self).url(forResource: "PixelLoupe", withExtension: "momd"))
        let v6 = try #require(NSManagedObjectModel(contentsOf: momd.appending(path: "PixelLoupe 6.mom")))
        #expect(v6.entitiesByName["Tag"]?.attributesByName["pathKey"] == nil)
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: v6)
            _ = try coordinator.addPersistentStore(type: .sqlite, at: CatalogPackage.databaseURL(in: packageURL))
            let context = NSManagedObjectContext(.mainQueue)
            context.persistentStoreCoordinator = coordinator
            let photo = NSEntityDescription.insertNewObject(forEntityName: "Photo", into: context)
            photo.setValue(UUID(), forKey: "id")
            photo.setValue("old.jpg", forKey: "fileName")
            photo.setValue(Date(), forKey: "captureDate")
            photo.setValue(Date(), forKey: "importDate")
            photo.setValue(Date(), forKey: "editDate")
            let tag = NSEntityDescription.insertNewObject(forEntityName: "Tag", into: context)
            tag.setValue("Family", forKey: "name")
            photo.setValue(Set([tag]), forKey: "tags")
            try context.save()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }
        let store = try CatalogStore.open(at: packageURL)
        let tag = try #require(try store.viewContext.fetch(PixelLoupe.Tag.fetchRequest()).first)
        #expect(tag.name == "Family" && tag.pathKey == "Family" && tag.parent == nil)
        #expect(tag.includeOnExport && tag.includeParents && tag.includeSynonyms && !tag.isPerson)
        // The old keyword filter still works.
        var filter = LibraryFilter()
        filter.metadata.select(keywords: ["Family"])
        #expect(try count(filter.predicate, in: store.viewContext) == 1)
    }

    @Test("The Keywords field makes paths, asks about shared names, and removes by path")
    func inspectorKeywords() throws {
        let store = try makeStore()
        let context = store.viewContext
        let state = LibraryState()
        let first = photo("a.jpg", in: context), second = photo("b.jpg", in: context)
        _ = PixelLoupe.Tag.findOrCreate(path: ["Places", "Ireland", "Dublin"], in: context)
        _ = PixelLoupe.Tag.findOrCreate(path: ["Places", "Ohio", "Dublin"], in: context)
        try context.save()
        let inspector = LibraryInspectorViewController(store: store, state: state)
        inspector.loadViewIfNeeded()
        state.selectedPhotoIDs = [first.objectID, second.objectID]

        // A path.
        inspector.addKeywords(["Travel > Italy > Rome", "Birthday"])
        #expect(first.tagPaths == ["Birthday", "Travel > Italy > Rome"])
        #expect(inspector.keywordField.pillTitles == ["Birthday", "Rome"], "pills show the leaf name")
        #expect(context.undoManager?.undoActionName == "Add Keywords")

        // A name that two keywords share asks; the choice is used. Dismissing adds nothing.
        var asked: [[String]] = []
        inspector.chooseKeyword = { options in
            asked.append(options.map(\.displayPath))
            return options.last
        }
        inspector.addKeywords(["Dublin"])
        #expect(asked == [["Places > Ireland > Dublin", "Places > Ohio > Dublin"]])
        #expect(first.tagPaths.contains("Places > Ohio > Dublin") && !first.tagPaths.contains("Places > Ireland > Dublin"))
        inspector.chooseKeyword = { _ in nil }
        inspector.addKeywords(["Dublin"])
        #expect(first.tags.count == 3)

        // Removing goes by path, so the other Dublin is untouched.
        first.tags.insert(try #require(PixelLoupe.Tag.findOrCreate(path: ["Places", "Ireland", "Dublin"], in: context)))
        inspector.removeKeyword("Places > Ohio > Dublin")
        #expect(first.tagPaths == ["Birthday", "Places > Ireland > Dublin", "Travel > Italy > Rome"])
    }

    @Test("The Keyword List shows the tree with counts, filters it, and tracks the selection")
    func keywordList() throws {
        let store = try makeStore()
        let context = store.viewContext
        let dublin = try #require(PixelLoupe.Tag.findOrCreate(path: ["Places", "Ireland", "Dublin"], in: context))
        let cork = try #require(PixelLoupe.Tag.findOrCreate(path: ["Places", "Ireland", "Cork"], in: context))
        let family = PixelLoupe.Tag.findOrCreate(named: "Family", in: context)
        cork.synonyms = ["rebel county"]
        let a = photo("a.jpg", tags: [dublin, family], in: context)
        let b = photo("b.jpg", tags: [dublin], in: context)
        try context.save()

        let list = KeywordListView(store: store)
        list.reload()
        #expect(list.roots.map(\.name) == ["Family", "Places"])
        #expect(list.roots[0].name == "Family" && list.roots[0].count == 1)
        let ireland = try #require(list.roots.last?.children.first)
        #expect(ireland.name == "Ireland" && ireland.children.map(\.name) == ["Cork", "Dublin"])
        #expect(ireland.children.map(\.count) == [0, 2])

        // Membership follows the selection: on all, on some, none.
        list.updateMembership(for: [a, b])
        #expect(list.membership(of: dublin.objectID) == .all)
        #expect(list.membership(of: family.objectID) == .some)
        #expect(list.membership(of: cork.objectID) == .none)

        // Filtering by a name, a synonym or a parent keeps the way down to each match.
        list.setFilter("rebel")
        let shown = list.shownTitles
        #expect(shown.contains("    Cork"))
        #expect(shown.contains("Places") && shown.contains("  Ireland"))
        list.setFilter("family")
        #expect(list.shownTitles == ["Family"])
        list.setFilter("zzz")
        #expect(list.shownTitles.isEmpty)
        list.setFilter("")
        #expect(list.roots.count == 2)
    }

    @Test("Keyword counts come from one query")
    func counts() throws {
        let store = try makeStore()
        let context = store.viewContext
        let tag = PixelLoupe.Tag.findOrCreate(named: "Family", in: context)
        let empty = PixelLoupe.Tag.findOrCreate(named: "Unused", in: context)
        for index in 0..<5 { _ = photo("\(index).jpg", tags: index < 3 ? [tag] : [], in: context) }
        try context.save()
        let counts = KeywordListView.photoCounts(in: context)
        #expect(counts[tag.pathKey] == 3 && counts[empty.pathKey] == 0)
    }

    @Test("Imports Lightroom's keyword tree, flags, synonyms and assignments")
    func importsKeywords() async throws {
        let fixture = try PhotosFixture()
        // The hidden root (no name), Places > Ireland > Dublin, a person, and one keyword with flags off.
        try fixture.run("""
            INSERT INTO AgLibraryKeyword (id_local, id_global, genealogy, includeOnExport, includeParents, includeSynonyms, keywordType, lc_name, name, parent) VALUES
                (1, 'k1', '', 1, 1, 1, NULL, NULL, NULL, NULL),
                (2, 'k2', '/1/2', 1, 1, 1, NULL, 'places', 'Places', 1),
                (3, 'k3', '/1/2/3', 1, 0, 1, NULL, 'ireland', 'Ireland', 2),
                (4, 'k4', '/1/2/3/4', 1, 1, 0, NULL, 'dublin', 'Dublin', 3),
                (5, 'k5', '/1/5', 0, 1, 1, 'person', 'ted', 'Ted', 1),
                (6, 'k6', '/1/6', 1, 1, 1, NULL, 'dublin', 'Dublin', 1);
            INSERT INTO AgLibraryKeywordSynonym (keyword, lc_name, name) VALUES (4, 'baile', 'Baile'), (4, 'dyflin', 'Dyflin');
            INSERT INTO AgLibraryKeywordImage (image, tag) VALUES (10, 4), (10, 5), (11, 4), (13, 6), (14, 4), (999, 4);
            """)
        let (store, report) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }, { LightroomKeywordsPhase() }])
        let context = store.viewContext
        let tags = Dictionary(try context.fetch(PixelLoupe.Tag.fetchRequest()).map { ($0.displayPath, $0) }) { first, _ in first }
        #expect(Set(tags.keys) == ["Places", "Places > Ireland", "Places > Ireland > Dublin", "Ted", "Dublin"])
        let dublin = try #require(tags["Places > Ireland > Dublin"])
        #expect(dublin.synonyms == ["Baile", "Dyflin"] && dublin.includeOnExport && dublin.includeParents && !dublin.includeSynonyms)
        #expect(try #require(tags["Places > Ireland"]).includeParents == false)
        let ted = try #require(tags["Ted"])
        #expect(ted.isPerson && !ted.includeOnExport && ted.parent == nil)
        #expect(tags["Dublin"] != nil && tags["Dublin"] !== dublin, "the same name elsewhere is its own keyword")

        let everything = try context.fetch(Photo.fetchRequest())
        let photos = Dictionary(everything.filter { !$0.isVirtualCopy }.map { ($0.fileName, $0) }) { first, _ in first }
        #expect(photos["A.jpg"]?.tagPaths == ["Places > Ireland > Dublin", "Ted"])
        // The virtual copy (image 14) has its own keywords.
        #expect(everything.first(where: \.isVirtualCopy)?.tagPaths == ["Places > Ireland > Dublin"])
        #expect(photos["B.jpg"]?.tagPaths == ["Places > Ireland > Dublin"])
        #expect(photos["D.cr2"]?.tagPaths == ["Dublin"])
        #expect(photos["E.jpg"]?.tags.isEmpty == true)
        // An unknown image (999) gets nothing.
        #expect(report.imported.contains(.init(title: "Keywords", count: 5)))
        #expect(report.imported.contains(.init(title: "Keyword assignments", count: 5)))
    }
}
