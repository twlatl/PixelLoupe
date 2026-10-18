import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("People: face regions and person keywords")
@MainActor
struct PeopleTests {
    private func makeStore() throws -> CatalogStore {
        try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: try TemporaryDirectory().url.appending(path: "P.pixelloupe"))
    }

    private func photo(_ name: String, in context: NSManagedObjectContext) -> Photo {
        let photo = Photo(context: context)
        photo.id = UUID(); photo.fileName = name; photo.filePath = "/x/\(name)"
        photo.captureDate = Date(); photo.importDate = Date(); photo.editDate = Date()
        return photo
    }

    // MARK: Model

    @Test("A face region keeps its rectangle and status, points at its person, and goes with its photo")
    func model() throws {
        let store = try makeStore()
        let context = store.viewContext
        let a = photo("A.jpg", in: context)
        let ted = PixelLoupe.Tag.findOrCreate(named: "Ted", in: context)
        ted.isPerson = true
        let region = FaceRegion(context: context)
        region.id = UUID(); region.x = 0.2; region.y = 0.1; region.width = 0.1; region.height = 0.15
        region.person = ted
        region.photo = a
        region.status = .confirmed
        store.save()
        #expect(a.faceRegions == [region] && ted.faceRegions == [region])
        #expect(region.rect == CGRect(x: 0.2, y: 0.1, width: 0.1, height: 0.15) && region.status == .confirmed)
        region.statusValue = 99
        #expect(region.status == .suggested, "an unknown status reads as suggested")
        // Deleting the keyword leaves the region (unnamed); deleting the photo takes it.
        context.delete(ted)
        store.save()
        #expect(region.person == nil && a.faceRegions.count == 1)
        context.delete(a)
        store.save()
        #expect(try context.count(for: FaceRegion.fetchRequest()) == 0)
    }

    @Test("Opens a version twelve catalog and adds face regions")
    func migratesVersionTwelve() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "V12.pixelloupe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(Fixtures.referencedInfo).write(to: CatalogPackage.infoURL(in: packageURL))
        let momd = try #require(Bundle(for: Photo.self).url(forResource: "PixelLoupe", withExtension: "momd"))
        let v12 = try #require(NSManagedObjectModel(contentsOf: momd.appending(path: "PixelLoupe 12.mom")))
        #expect(v12.entitiesByName["FaceRegion"] == nil)
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: v12)
            _ = try coordinator.addPersistentStore(type: .sqlite, at: CatalogPackage.databaseURL(in: packageURL))
            let context = NSManagedObjectContext(.mainQueue)
            context.persistentStoreCoordinator = coordinator
            let photo = NSEntityDescription.insertNewObject(forEntityName: "Photo", into: context)
            photo.setValue(UUID(), forKey: "id")
            photo.setValue("v12.jpg", forKey: "fileName")
            photo.setValue(Date(), forKey: "captureDate"); photo.setValue(Date(), forKey: "importDate"); photo.setValue(Date(), forKey: "editDate")
            try context.save()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }
        let store = try CatalogStore.open(at: packageURL)
        let photo = try #require(try store.viewContext.fetch(Photo.fetchRequest()).first)
        #expect(photo.faceRegions.isEmpty)
    }

    // MARK: Smart collection rule

    @Test("Person is … finds photos with that person keyword, and only person keywords")
    func personRule() throws {
        let store = try makeStore()
        let context = store.viewContext
        let ted = PixelLoupe.Tag.findOrCreate(named: "Ted", in: context)
        ted.isPerson = true
        let teddy = PixelLoupe.Tag.findOrCreate(named: "Teddy bear", in: context)   // not a person
        let ada = PixelLoupe.Tag.findOrCreate(named: "Ada Lovelace", in: context)
        ada.isPerson = true
        let withTed = photo("ted.jpg", in: context), withBear = photo("bear.jpg", in: context), withAda = photo("ada.jpg", in: context)
        _ = photo("none.jpg", in: context)
        withTed.tags = [ted]; withBear.tags = [teddy]; withAda.tags = [ada, teddy]
        try context.save()
        func names(_ operator: SmartCollectionRules.Operator, _ value: String) throws -> [String] {
            let rule = SmartCollectionRules.Rule(field: .person, operator: `operator`, value: value)
            let request = Photo.fetchRequest()
            request.predicate = rule.predicate(now: Date(), calendar: .current)
            request.sortDescriptors = [NSSortDescriptor(key: "fileName", ascending: true)]
            return try context.fetch(request).map(\.fileName)
        }
        #expect(try names(.is, "ted") == ["ted.jpg"], "an exact name, ignoring case")
        #expect(try names(.is, "Teddy bear").isEmpty, "a non-person keyword isn't a person")
        #expect(try names(.contains, "Love") == ["ada.jpg"])
        #expect(try names(.isNot, "Ted") == ["ada.jpg", "bear.jpg", "none.jpg"])
        #expect(try names(.doesNotContain, "ada") == ["bear.jpg", "none.jpg", "ted.jpg"])
        #expect(try names(.isNotEmpty, "") == ["ada.jpg", "ted.jpg"] && names(.isEmpty, "") == ["bear.jpg", "none.jpg"])
        #expect(SmartCollectionRules.Field.person.title == "Person" && SmartCollectionRules.Field.person.operators.contains(.is))
        // It survives being saved with a collection's rules.
        let rules = SmartCollectionRules(rules: [.init(field: .person, operator: .is, value: "Ted")])
        let decoded = try JSONDecoder().decode(SmartCollectionRules.self, from: JSONEncoder().encode(rules))
        #expect(decoded == rules)
    }

    // MARK: Keyword List

    @Test("Person keywords are listed together under People, and still in the tree")
    func peopleGroup() throws {
        let store = try makeStore()
        let context = store.viewContext
        let places = PixelLoupe.Tag.findOrCreate(named: "Places", in: context)
        let family = PixelLoupe.Tag.makeChild(named: "Family", of: nil, in: context)
        let ted = PixelLoupe.Tag.makeChild(named: "Ted", of: family, in: context)
        ted.isPerson = true
        let ada = PixelLoupe.Tag.makeChild(named: "Ada", of: nil, in: context)
        ada.isPerson = true
        _ = places
        let a = photo("A.jpg", in: context)
        a.tags = [ted]
        try context.save()

        let list = KeywordListView(store: store)
        list.reload()
        list.outlineView.expandItem(nil, expandChildren: true)
        let titles = list.shownTitles
        #expect(titles.first == "People" && titles.prefix(3) == ["People", "  Ada", "  Ted"], "\(titles)")
        #expect(titles.contains("Family") && titles.contains("  Ted"), "Ted is also under Family")
        // The group isn't a keyword: it can't be assigned, and its count is its people's.
        let group = try #require(list.roots.first)
        #expect(group.isGroup && group.id == nil && group.count == 1)
        // Without people there is no group.
        ted.isPerson = false; ada.isPerson = false
        try context.save()
        list.reload()
        #expect(!list.shownTitles.contains("People"))
    }

    // MARK: Import

    private func createFaceTables(_ fixture: PhotosFixture) throws {
        try fixture.run("""
            INSERT INTO AgLibraryKeyword (id_local, id_global, genealogy, includeOnExport, includeParents, includeSynonyms, keywordType, lc_name, name, parent) VALUES
                (1, 'k1', '', 1, 1, 1, NULL, NULL, NULL, NULL),
                (5, 'k5', '/1/5', 0, 1, 1, 'person', 'ted', 'Ted', 1),
                (6, 'k6', '/1/6', 1, 1, 1, NULL, 'ada', 'Ada', 1);
            CREATE TABLE AgLibraryFace (id_local INTEGER PRIMARY KEY, bl_x, bl_y, br_x, br_y, cluster INTEGER, ignored INTEGER, image INTEGER, tl_x, tl_y, tr_x, tr_y, regionType);
            CREATE TABLE AgLibraryKeywordFace (id_local INTEGER PRIMARY KEY, face INTEGER, keyFace INTEGER, rankOrder, tag INTEGER, userPick INTEGER, userReject INTEGER);
            INSERT INTO AgLibraryFace (id_local, bl_x, bl_y, br_x, br_y, cluster, ignored, image, tl_x, tl_y, tr_x, tr_y, regionType) VALUES
                (1, 0.20, 0.30, 0.30, 0.30, 7, 0, 10, 0.20, 0.10, 0.30, 0.10, 1),
                (2, 0.50, 0.60, 0.60, 0.60, NULL, 0, 10, 0.50, 0.40, 0.60, 0.40, 1),
                (3, 0.10, 0.20, 0.20, 0.20, NULL, 1, 13, 0.10, 0.10, 0.20, 0.10, 1),
                (4, 0.40, 0.40, 0.50, 0.40, NULL, 0, 99, 0.40, 0.30, 0.50, 0.30, 1),
                (5, 0.70, 0.70, 0.80, 0.70, NULL, 0, 13, 0.70, 0.60, 0.80, 0.60, 1),
                (6, 0.30, 0.30, 0.30, 0.30, NULL, 0, 13, 0.30, 0.30, 0.30, 0.30, 1);
            INSERT INTO AgLibraryKeywordFace (face, rankOrder, tag, userPick, userReject) VALUES
                (1, 0, 5, 1, 0),
                (2, 0, 6, 0, 0), (2, 1, 5, 0, 0),
                (5, 0, 6, 0, 1), (5, 1, 5, 1, 0);
            """)
    }

    @Test("Faces import with their rectangles; named ones point at their person and mark it")
    func importsFaces() async throws {
        let fixture = try PhotosFixture()
        try createFaceTables(fixture)
        let (store, report) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }, { LightroomKeywordsPhase() }, { LightroomFacesPhase() }])
        let photos = Dictionary(try store.viewContext.fetch(Photo.fetchRequest()).filter { !$0.isVirtualCopy }.map { ($0.fileName, $0) }) { first, _ in first }
        let a = try #require(photos["A.jpg"])
        let regions = a.faceRegions.sorted { $0.x < $1.x }
        #expect(regions.count == 2)
        let first = regions[0]
        #expect(abs(first.x - 0.2) < 1e-9 && abs(first.y - 0.1) < 1e-9 && abs(first.width - 0.1) < 1e-9 && abs(first.height - 0.2) < 1e-9)
        #expect(first.person?.name == "Ted" && first.status == .confirmed && first.clusterID == 7)
        // A suggestion (not picked) keeps its first usable name but isn't confirmed.
        #expect(regions[1].person?.name == "Ada" && regions[1].status == .suggested)
        // D: an ignored face, and one whose first link is rejected (the second, picked, wins).
        let d = try #require(photos["D.cr2"])
        let byX = d.faceRegions.sorted { $0.x < $1.x }
        #expect(byX.count == 2 && byX[0].status == .ignored && byX[0].person == nil)
        #expect(byX[1].person?.name == "Ted" && byX[1].status == .confirmed)
        // A face on a photo that wasn't imported, and one with no area, are left out.
        #expect(try store.viewContext.count(for: FaceRegion.fetchRequest()) == 4)
        #expect(report.imported.contains(.init(title: "Face regions", count: 4)) && report.imported.contains(.init(title: "People", count: 2)))
        let people = try store.viewContext.fetch(PixelLoupe.Tag.fetchRequest()).filter(\.isPerson).map(\.name).sorted()
        #expect(people == ["Ada", "Ted"], "naming a face marks its keyword as a person")
    }

    @Test("A catalog without face tables imports fine")
    func noFaces() async throws {
        let fixture = try PhotosFixture()
        let (store, report) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }, { LightroomKeywordsPhase() }, { LightroomFacesPhase() }])
        #expect(try store.viewContext.count(for: FaceRegion.fetchRequest()) == 0)
        #expect(report.imported.allSatisfy { $0.title != "Face regions" })
    }
}
