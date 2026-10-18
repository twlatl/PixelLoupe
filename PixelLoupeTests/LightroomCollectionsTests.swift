import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Lightroom smart rule translation")
struct LightroomSmartRulesTests {
    private func translate(_ lua: String, collections: [Int: String] = [:]) throws -> LightroomSmartRules.Translation {
        LightroomSmartRules.translate(try LuaTableParser.parse(lua), context: .init(collectionNames: collections))
    }

    /// One rule from `{ criteria, operation, value… }` Lua fields.
    private func one(_ fields: String, collections: [Int: String] = [:]) throws -> SmartCollectionRules.Rule? {
        let translation = try translate("s = { { \(fields) }, combine = \"intersect\" }", collections: collections)
        return translation.rules.rules.first
    }

    typealias Rule = SmartCollectionRules.Rule

    @Test("The default smart collections translate to their PixelLoupe rules")
    func defaults() throws {
        #expect(try one(#"criteria = "labelColor", operation = "==", value = 1"#) == Rule(field: .labelColor, operator: .is, value: "red"))
        #expect(try one(#"criteria = "rating", operation = ">=", value = 5"#) == Rule(field: .rating, operator: .atLeast, value: "5"))
        #expect(try one(#"criteria = "captureTime", operation = "inLast", value = 1, value_units = "months""#)
            == Rule(field: .captureDate, operator: .inTheLast, value: "1", unit: .months))
        #expect(try one(#"criteria = "touchTime", operation = "inLast", value = 2, value_units = "days""#)
            == Rule(field: .editDate, operator: .inTheLast, value: "2", unit: .days))
        #expect(try one(#"criteria = "fileFormat", operation = "==", value = "VIDEO""#) == Rule(field: .fileType, operator: .is, value: "Video"))
        #expect(try one(#"criteria = "keywords", operation = "empty""#) == Rule(field: .keywords, operator: .isEmpty, value: ""))
    }

    @Test("Ratings, picks and labels")
    func flagsAndLabels() throws {
        let ratings: [(String, SmartCollectionRules.Operator)] = [("==", .is), ("!=", .isNot), (">", .greaterThan), (">=", .atLeast), ("<", .lessThan), ("<=", .atMost)]
        for (operation, op) in ratings {
            #expect(try one("criteria = \"rating\", operation = \"\(operation)\", value = 3") == Rule(field: .rating, operator: op, value: "3"))
        }
        #expect(try one(#"criteria = "rating", operation = "in", value = 2, value2 = 4"#) == Rule(field: .rating, operator: .inRange, value: "2", value2: "4"))
        #expect(try one(#"criteria = "pick", operation = "==", value = 1"#) == Rule(field: .flag, operator: .is, value: "picked"))
        #expect(try one(#"criteria = "pick", operation = "!=", value = -1"#) == Rule(field: .flag, operator: .isNot, value: "rejected"))
        #expect(try one(#"criteria = "pick", operation = "==", value = 0"#) == Rule(field: .flag, operator: .is, value: "unflagged"))
        #expect(try one(#"criteria = "labelColor", operation = "!=", value = 4"#) == Rule(field: .labelColor, operator: .isNot, value: "blue"))
        #expect(try one(#"criteria = "labelColor", operation = "==", value = "Green""#) == Rule(field: .labelColor, operator: .is, value: "green"))
        #expect(try one(#"criteria = "labelColor", operation = "==", value = 9"#) == nil)
    }

    @Test("Text criteria and operations")
    func text() throws {
        let fields: [(String, SmartCollectionRules.Field)] = [
            ("labelText", .labelText), ("keywords", .keywords), ("filename", .fileName), ("folder", .folder), ("camera", .camera),
            ("lens", .lens), ("title", .title), ("caption", .caption), ("creator", .creator), ("copyright", .copyright), ("allText", .anyText),
        ]
        for (criteria, field) in fields {
            #expect(try one("criteria = \"\(criteria)\", operation = \"words\", value = \"abc\"") == Rule(field: field, operator: .contains, value: "abc"), "\(criteria)")
            #expect(try one("criteria = \"\(criteria)\", operation = \"beginsWith\", value = \"abc\"") == Rule(field: field, operator: .startsWith, value: "abc"))
            #expect(try one("criteria = \"\(criteria)\", operation = \"endsWith\", value = \"abc\"") == Rule(field: field, operator: .endsWith, value: "abc"))
            #expect(try one("criteria = \"\(criteria)\", operation = \"noneOf\", value = \"abc\"") == Rule(field: field, operator: .doesNotContain, value: "abc"))
            #expect(try one("criteria = \"\(criteria)\", operation = \"empty\"") == Rule(field: field, operator: .isEmpty, value: ""))
            #expect(try one("criteria = \"\(criteria)\", operation = \"notEmpty\"") == Rule(field: field, operator: .isNotEmpty, value: ""))
        }
        #expect(try one(#"criteria = "keywords", operation = "all", value = "a b""#) == Rule(field: .keywords, operator: .containsAll, value: "a b"))
        #expect(try one(#"criteria = "keywords", operation = "any", value = "a b""#) == Rule(field: .keywords, operator: .contains, value: "a b"))
        #expect(try one(#"criteria = "camera", operation = "==", value = "Canon""#) == Rule(field: .camera, operator: .is, value: "Canon"))
        #expect(try one(#"criteria = "camera", operation = "!=", value = "Canon""#) == Rule(field: .camera, operator: .isNot, value: "Canon"))
        #expect(try one(#"criteria = "filename", operation = "bogus", value = "x""#) == nil)
    }

    @Test("Dates")
    func dates() throws {
        for (name, field) in [("captureTime", SmartCollectionRules.Field.captureDate), ("touchTime", .editDate), ("importDate", .importDate)] {
            #expect(try one("criteria = \"\(name)\", operation = \"==\", value = \"2020-05-04\"") == Rule(field: field, operator: .is, value: "2020-05-04"))
            #expect(try one("criteria = \"\(name)\", operation = \"!=\", value = \"2020-05-04\"") == Rule(field: field, operator: .isNot, value: "2020-05-04"))
            #expect(try one("criteria = \"\(name)\", operation = \">\", value = \"2020-05-04\"") == Rule(field: field, operator: .isAfter, value: "2020-05-04"))
            #expect(try one("criteria = \"\(name)\", operation = \"<\", value = \"2020-05-04\"") == Rule(field: field, operator: .isBefore, value: "2020-05-04"))
            // On or after / on or before include the day itself.
            #expect(try one("criteria = \"\(name)\", operation = \">=\", value = \"2020-05-04\"") == Rule(field: field, operator: .isAfter, value: "2020-05-03"))
            #expect(try one("criteria = \"\(name)\", operation = \"<=\", value = \"2020-05-31\"") == Rule(field: field, operator: .isBefore, value: "2020-06-01"))
            #expect(try one("criteria = \"\(name)\", operation = \"in\", value = \"2020-05-01\", value2 = \"2020-05-31\"")
                == Rule(field: field, operator: .inRange, value: "2020-05-01", value2: "2020-05-31"))
            #expect(try one("criteria = \"\(name)\", operation = \"notInLast\", value = 3, value_units = \"weeks\"")
                == Rule(field: field, operator: .notInTheLast, value: "3", unit: .weeks))
        }
        #expect(try one(#"criteria = "captureTime", operation = "==", value = 5"#) == nil)
    }

    @Test("Numbers, booleans, file formats, treatment and collections")
    func others() throws {
        for (name, field) in [("isoSpeedRating", SmartCollectionRules.Field.isoSpeed), ("focalLength", .focalLength), ("aperture", .aperture), ("shutterSpeed", .shutterSpeed)] {
            #expect(try one("criteria = \"\(name)\", operation = \">=\", value = 400") == Rule(field: field, operator: .atLeast, value: "400"))
            #expect(try one("criteria = \"\(name)\", operation = \"<\", value = 2.8") == Rule(field: field, operator: .lessThan, value: "2.8"))
            #expect(try one("criteria = \"\(name)\", operation = \"in\", value = 1, value2 = 5") == Rule(field: field, operator: .inRange, value: "1", value2: "5"))
        }
        #expect(try one(#"criteria = "hasGPS", operation = "==", value = true"#) == Rule(field: .hasGPS, operator: .is, value: "true"))
        #expect(try one(#"criteria = "hasGPS", operation = "!=", value = true"#) == Rule(field: .hasGPS, operator: .is, value: "false"))
        #expect(try one(#"criteria = "hasAdjustments", operation = "==", value = false"#) == Rule(field: .edited, operator: .is, value: "false"))
        #expect(try one(#"criteria = "cropped", operation = "==", value = true"#) == Rule(field: .cropped, operator: .is, value: "true"))
        #expect(try one(#"criteria = "treatment", operation = "==", value = "grayscale""#) == Rule(field: .blackAndWhite, operator: .is, value: "true"))
        #expect(try one(#"criteria = "treatment", operation = "!=", value = "color""#) == Rule(field: .blackAndWhite, operator: .is, value: "true"))
        for (format, type) in [("RAW", "Raw"), ("DNG", "DNG"), ("JPG", "JPEG"), ("TIFF", "TIFF"), ("PNG", "PNG"), ("HEIC", "HEIF"), ("VIDEO", "Video")] {
            #expect(try one("criteria = \"fileFormat\", operation = \"==\", value = \"\(format)\"") == Rule(field: .fileType, operator: .is, value: type))
        }
        #expect(try one(#"criteria = "fileFormat", operation = "!=", value = "PSD""#) == nil)
        #expect(try one(#"criteria = "collection", operation = "==", value = 7"#, collections: [7: "Trip"]) == Rule(field: .collection, operator: .is, value: "Trip"))
        #expect(try one(#"criteria = "collection", operation = "!=", value = "Trip""#, collections: [7: "Trip"]) == Rule(field: .collection, operator: .isNot, value: "Trip"))
        #expect(try one(#"criteria = "collection", operation = "==", value = 99"#, collections: [7: "Trip"]) == nil)
    }

    @Test("Combine, nested groups and rules that can't be translated")
    func combining() throws {
        #expect(try translate(#"s = { { criteria = "rating", operation = "==", value = 1 }, combine = "union" }"#).rules.match == .any)
        #expect(try translate(#"s = { { criteria = "rating", operation = "==", value = 1 }, combine = "exclude" }"#).rules.match == .none)
        #expect(try translate(#"s = { { criteria = "rating", operation = "==", value = 1 }, combine = "intersect" }"#).rules.match == .all)

        let nested = try translate("""
            s = {
                { criteria = "rating", operation = ">=", value = 4 },
                { combine = "union",
                  { criteria = "labelColor", operation = "==", value = 1 },
                  { criteria = "pick", operation = "==", value = 1 },
                  { combine = "exclude", { criteria = "camera", operation = "==", value = "X" } } },
                combine = "intersect",
            }
            """)
        #expect(nested.unmapped.isEmpty)
        #expect(nested.rules.rules.count == 1 && nested.rules.groups.count == 1)
        let group = nested.rules.groups[0]
        #expect(group.match == .any && group.rules.count == 2 && group.groups.count == 1)
        #expect(group.groups[0].match == .none && group.groups[0].rules.count == 1)

        let unmapped = try translate("""
            s = { { criteria = "rating", operation = ">=", value = 3 },
                  { criteria = "bogus", operation = "notEmpty" },
                  { criteria = "aspectRatio", operation = "==", value = "portrait" },
                  combine = "intersect" }
            """)
        #expect(unmapped.rules.rules.count == 1)
        #expect(unmapped.unmapped == ["bogus notEmpty", "aspectRatio == portrait"])
    }
}

@Suite("Smart rule fields")
@MainActor
struct SmartRuleFieldTests {
    private func store() throws -> CatalogStore {
        try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: try TemporaryDirectory().url.appending(path: "C.pixelloupe"))
    }

    private func count(_ rules: SmartCollectionRules, in store: CatalogStore) throws -> Int {
        let request = Photo.fetchRequest()
        request.predicate = rules.predicate
        return try store.viewContext.count(for: request)
    }

    private func photos(in store: CatalogStore) throws -> [Photo] {
        let context = store.viewContext
        func make(_ name: String, configure: (Photo) -> Void) -> Photo {
            let photo = Photo(context: context)
            photo.id = UUID()
            photo.fileName = name
            photo.fileType = "JPG"
            photo.captureDate = Date()
            photo.importDate = Date()
            photo.editDate = Date()
            configure(photo)
            return photo
        }
        let trip = PhotoCollection.make(.collection, named: "Trip", in: nil, context: context)
        let result = [
            make("a.jpg") { $0.iso = 100; $0.focalLength = 24; $0.aperture = 2.8; $0.shutterSpeed = 0.01; $0.hasGPS = true; $0.titleText = "Sunset"; $0.cameraModel = "Canon" },
            make("b.jpg") { $0.iso = 3200; $0.focalLength = 200; $0.aperture = 8; $0.shutterSpeed = 1.0 / 500; $0.captionText = "A dog at the beach"; $0.isCropped = true },
            make("c.jpg") { $0.isBlackAndWhite = true; $0.creatorText = "Ted"; $0.copyrightText = "© Ted"; $0.fileType = "MOV" },
            make("d.cr2") { $0.fileType = "CR2" },
        ]
        trip.photos = [result[0], result[1]]
        try context.save()
        return result
    }

    @Test("Number fields: exact (with rounding), ranges and unknown values")
    func numbers() throws {
        let store = try store()
        _ = try photos(in: store)
        func count(_ field: SmartCollectionRules.Field, _ op: SmartCollectionRules.Operator, _ value: String, _ value2: String = "") throws -> Int {
            try self.count(SmartCollectionRules(rules: [.init(field: field, operator: op, value: value, value2: value2)]), in: store)
        }
        #expect(try count(.isoSpeed, .is, "100") == 1)
        #expect(try count(.isoSpeed, .atLeast, "400") == 1)
        #expect(try count(.isoSpeed, .lessThan, "400") == 1, "photos without an ISO never match")
        #expect(try count(.isoSpeed, .isNot, "100") == 1)
        #expect(try count(.isoSpeed, .inRange, "50", "5000") == 2)
        #expect(try count(.focalLength, .greaterThan, "100") == 1)
        #expect(try count(.aperture, .is, "2.8") == 1)
        #expect(try count(.aperture, .atMost, "8") == 2)
        #expect(try count(.shutterSpeed, .atLeast, "0.01") == 1)
        #expect(try count(.shutterSpeed, .lessThan, "0.01") == 1)
    }

    @Test("Booleans, text, collection and file type fields")
    func others() throws {
        let store = try store()
        _ = try photos(in: store)
        func rule(_ field: SmartCollectionRules.Field, _ op: SmartCollectionRules.Operator, _ value: String) throws -> Int {
            try count(SmartCollectionRules(rules: [.init(field: field, operator: op, value: value)]), in: store)
        }
        #expect(try rule(.hasGPS, .is, "true") == 1 && rule(.hasGPS, .is, "false") == 3)
        #expect(try rule(.cropped, .is, "true") == 1)
        #expect(try rule(.blackAndWhite, .is, "true") == 1)
        #expect(try rule(.title, .contains, "sun") == 1)
        #expect(try rule(.caption, .contains, "beach") == 1)
        #expect(try rule(.creator, .is, "ted") == 1)
        #expect(try rule(.copyright, .contains, "Ted") == 1)
        #expect(try rule(.anyText, .contains, "dog beach") == 1, "every word, anywhere")
        #expect(try rule(.anyText, .contains, "canon") == 1)
        #expect(try rule(.anyText, .doesNotContain, "dog") == 3)
        #expect(try rule(.collection, .is, "trip") == 2)
        #expect(try rule(.collection, .isNot, "Trip") == 2)
        #expect(try rule(.fileType, .is, "Video") == 1)
        #expect(try rule(.fileType, .is, "Raw") == 1, "a video isn't a raw file")
    }

    @Test("Match none, and nested groups")
    func combining() throws {
        let store = try store()
        _ = try photos(in: store)
        let gps = SmartCollectionRules.Rule(field: .hasGPS, operator: .is, value: "true")
        let cropped = SmartCollectionRules.Rule(field: .cropped, operator: .is, value: "true")
        #expect(try count(SmartCollectionRules(match: .none, rules: [gps, cropped]), in: store) == 2)
        #expect(try count(SmartCollectionRules(match: .any, rules: [gps, cropped]), in: store) == 2)
        // (iso >= 400 AND cropped) OR has GPS
        let high = SmartCollectionRules(match: .all, rules: [.init(field: .isoSpeed, operator: .atLeast, value: "400"), cropped])
        #expect(try count(SmartCollectionRules(match: .any, rules: [gps], groups: [high]), in: store) == 2)
        // everything but a group
        #expect(try count(SmartCollectionRules(match: .none, rules: [], groups: [high]), in: store) == 3)
    }

    @Test("Rules saved before groups existed still load")
    func decodesOldRules() throws {
        let old = Data(#"{"match":"any","rules":[{"field":"rating","operator":"atLeast","value":"3","value2":"","unit":"days"}]}"#.utf8)
        let rules = try JSONDecoder().decode(SmartCollectionRules.self, from: old)
        #expect(rules.match == .any && rules.rules.count == 1 && rules.groups.isEmpty)
        let nested = SmartCollectionRules(match: .none, rules: rules.rules, groups: [rules])
        #expect(try JSONDecoder().decode(SmartCollectionRules.self, from: JSONEncoder().encode(nested)) == nested)
    }
}

@Suite("Custom order")
@MainActor
struct CustomOrderTests {
    @Test("Sorts by the order list, with unlisted photos after in the order given")
    func sorting() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let items = [("a", a), ("b", b), ("c", c), ("d", d)].map { (item: $0.0, id: $0.1) }
        #expect(CustomOrder.sorted(items, by: [c, a]) == ["c", "a", "b", "d"])
        #expect(CustomOrder.sorted(items, by: []) == ["a", "b", "c", "d"])
        #expect(CustomOrder.sorted(items, by: [d, c, b, a, UUID()]) == ["d", "c", "b", "a"])
    }

    @Test("Moving photos puts them before the drop point")
    func moving() {
        let ids = (0..<6).map { _ in UUID() }
        func order(_ moved: [Int], to index: Int) -> [Int] {
            let result = CustomOrder.moved(moved.map { ids[$0] }, to: index, in: ids)
            return result.map { ids.firstIndex(of: $0)! }
        }
        #expect(order([4], to: 1) == [0, 4, 1, 2, 3, 5])
        #expect(order([1], to: 4) == [0, 2, 3, 1, 4, 5])
        #expect(order([0], to: 6) == [1, 2, 3, 4, 5, 0])
        #expect(order([2, 3], to: 0) == [2, 3, 0, 1, 4, 5])
        #expect(order([1, 4], to: 3) == [0, 2, 1, 4, 3, 5])
        #expect(order([3], to: 3) == [0, 1, 2, 3, 4, 5])
        #expect(order([3], to: 4) == [0, 1, 2, 3, 4, 5])
        #expect(order([], to: 2) == [0, 1, 2, 3, 4, 5])
    }

    @Test("The grid shows a collection in its custom order, and dragging changes it undoably")
    func grid() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let context = store.viewContext
        var photos: [Photo] = []
        for index in 0..<5 {
            let photo = Photo(context: context)
            photo.id = UUID()
            photo.fileName = "\(index).jpg"
            photo.captureDate = Date(timeIntervalSince1970: Double(index))
            photo.importDate = Date()
            photo.editDate = Date()
            photos.append(photo)
        }
        let collection = PhotoCollection.make(.collection, named: "Mine", in: nil, context: context)
        collection.photos = Set(photos)
        collection.customOrder = [photos[3], photos[1], photos[4]].map(\.id)
        try context.save()

        let state = LibraryState()
        let grid = GridViewController(store: store, state: state)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = grid
        grid.loadViewIfNeeded()
        state.filter.scope = .collection(id: collection.id, content: collection.content)
        state.filter.sortKey = .customOrder
        RunLoop.current.run(until: Date())
        func shown() -> [String] {
            state.photoOrder.compactMap { (try? context.existingObject(with: $0) as? Photo)?.fileName }
        }
        #expect(shown() == ["3.jpg", "1.jpg", "4.jpg", "0.jpg", "2.jpg"])

        // Descending shows it the other way round; another sort ignores the order.
        state.filter.ascending = false
        RunLoop.current.run(until: Date())
        #expect(shown() == ["2.jpg", "0.jpg", "4.jpg", "1.jpg", "3.jpg"], "the reverse of ascending")
        state.filter.ascending = true
        state.filter.sortKey = .captureTime
        RunLoop.current.run(until: Date())
        #expect(shown() == ["0.jpg", "1.jpg", "2.jpg", "3.jpg", "4.jpg"])
        window.contentViewController = nil
    }
}

@Suite("Lightroom collections import")
@MainActor
struct LightroomCollectionsImportTests {
    private func fixture() throws -> PhotosFixture {
        let fixture = try PhotosFixture()
        try fixture.run("""
            INSERT INTO AgLibraryCollection (id_local, creationId, genealogy, imageCount, name, parent, systemOnly) VALUES
                (100, 'com.adobe.ag.library.group', '/100', 0, 'Smart Collections', NULL, ''),
                (101, 'com.adobe.ag.library.collection', '/100/101', 3, 'Trip', 100, ''),
                (102, 'com.adobe.ag.library.smart_collection', '/100/102', 0, 'Four Stars', 100, ''),
                (103, 'com.adobe.ag.library.smart_collection', '/103', 0, 'Copies', NULL, ''),
                (104, 'com.adobe.ag.library.collection', '/104', 1, 'quick collection', NULL, '1.0'),
                (105, 'com.adobe.ag.slideshow.unsaved', '/105', 0, 'Unsaved Slideshow', NULL, '1.0'),
                (106, 'com.adobe.ag.library.collection', '/106', 0, 'Orphan', 999, ''),
                (107, 'com.adobe.ag.library.smart_collection', '/107', 0, 'Mixed', NULL, '');
            INSERT INTO AgLibraryCollectionContent (collection, content, owningModule) VALUES
                (102, 's = { { criteria = "rating", operation = ">=", value = 4 }, combine = "intersect" }', 'ag.library.smart_collection'),
                (103, 's = { { criteria = "copyName", operation = "notEmpty" }, combine = "intersect" }', 'ag.library.smart_collection'),
                (107, 's = { { criteria = "collection", operation = "==", value = 101 }, { criteria = "aspectRatio", operation = "==", value = "square" }, { combine = "union", { criteria = "labelColor", operation = "==", value = 1 } }, combine = "exclude" }', 'ag.library.smart_collection');
            INSERT INTO AgLibraryCollectionImage (collection, image, positionInCollection) VALUES
                (101, 11, 2.0), (101, 10, 1.0), (101, 12, 3.0), (101, 14, 4.0), (104, 10, 1.0), (101, 13, 0.5);
            """)
        return fixture
    }

    @Test("Imports collections, sets, smart collections and the Quick Collection, with order and warnings")
    func importsCollections() async throws {
        let fixture = try fixture()
        let (store, report) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }, { LightroomCollectionsPhase() }])
        let context = store.viewContext
        let all = try context.fetch(PhotoCollection.fetchRequest())
        let byName = Dictionary(all.map { ($0.name, $0) }) { first, _ in first }
        #expect(Set(byName.keys) == ["Smart Collections", "Trip", "Four Stars", "Copies", "Quick Collection", "Orphan", "Mixed", "Imported with Differences"])

        let set = try #require(byName["Smart Collections"])
        #expect(set.kind == .set && set.parent == nil)
        let trip = try #require(byName["Trip"])
        #expect(trip.kind == .collection && trip.parent === set)
        #expect(byName["Four Stars"]?.parent === set && byName["Four Stars"]?.kind == .smart)
        #expect(byName["Orphan"]?.parent == nil, "a collection whose set wasn't imported goes to the top")

        // Membership and Lightroom's order; photos that weren't imported are left out.
        let everything = try context.fetch(Photo.fetchRequest())
        let photos = Dictionary(everything.filter { !$0.isVirtualCopy }.map { ($0.fileName, $0) }) { first, _ in first }
        let copy = try #require(everything.first { $0.isVirtualCopy })
        #expect(trip.photos.count == 5 && Set(trip.photos.map(\.fileName)) == ["A.jpg", "B.jpg", "C.mov", "D.cr2"])
        #expect(trip.customOrder == [photos["D.cr2"], photos["A.jpg"], photos["B.jpg"], photos["C.mov"], copy].compactMap { $0?.id })
        #expect(byName["Quick Collection"]?.photos.map(\.fileName) == ["A.jpg"])

        // Smart collections.
        let four = try #require(byName["Four Stars"])
        #expect(four.rules == SmartCollectionRules(match: .all, rules: [.init(field: .rating, operator: .atLeast, value: "4")]))
        #expect(four.importWarning == nil && four.luaRules == nil)
        // A copy-name rule translates now that copies exist.
        let copies = try #require(byName["Copies"])
        #expect(copies.rules.rules == [.init(field: .copyName, operator: .isNotEmpty, value: "")] && copies.importWarning == nil)
        let mixed = try #require(byName["Mixed"])
        #expect(mixed.rules.match == .none && mixed.rules.rules == [.init(field: .collection, operator: .is, value: "Trip")])
        #expect(mixed.rules.groups.count == 1 && mixed.rules.groups[0].match == .any)
        #expect(mixed.importWarning?.contains("aspectRatio == square") == true)

        // Only PixelLoupe-native data remains in the report.
        #expect(report.imported.contains(.init(title: "Collections", count: 3)))  // Trip, Quick Collection, Orphan
        #expect(report.imported.contains(.init(title: "Smart collections", count: 3)))
        #expect(report.imported.contains(.init(title: "Collection sets", count: 1)))
        #expect(report.imported.contains(.init(title: "Photos in collections", count: 6)))
        #expect(report.warnings.contains { $0.contains("1 slideshow collection not imported") })
        #expect(report.warnings.contains { $0.contains("“Mixed”") } && !report.warnings.contains { $0.contains("“Copies”") })
    }

    @Test("Lightroom's text order keys (---0, ---9, ---A…) give the custom order; unordered photos follow")
    func textOrderKeys() async throws {
        let fixture = try PhotosFixture()
        try fixture.run("""
            INSERT INTO AgLibraryCollection (id_local, creationId, genealogy, imageCount, name, parent, systemOnly) VALUES
                (200, 'com.adobe.ag.library.collection', '/200', 5, 'Keys', NULL, '');
            INSERT INTO AgLibraryCollectionImage (collection, image, positionInCollection) VALUES
                (200, 10, '---B'), (200, 15, NULL), (200, 11, '---0'), (200, 13, '---A'), (200, 12, '---9'), (200, 14, NULL);
            """)
        let (store, _) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }, { LightroomCollectionsPhase() }])
        let collection = try #require(try store.viewContext.fetch(PhotoCollection.fetchRequest()).first { $0.name == "Keys" })
        let names = collection.customOrder.compactMap { id -> String? in
            let request = Photo.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            return try? store.viewContext.fetch(request).first.map { $0.fileName + ($0.isVirtualCopy ? " (copy)" : "") }
        }
        // ---0 (B), ---9 (the video), ---A (D), ---B (A); then E and A's copy (unordered, in the order added).
        #expect(names == ["B.jpg", "C.mov", "D.cr2", "A.jpg", "E.jpg", "A.jpg (copy)"])
    }

    @Test("Order keys compare as bytes; numbers numerically; ordered photos come first")
    func orderKeys() {
        func photo(_ key: String? = nil, number: Double? = nil) -> LRCollectionImage {
            LRCollectionImage(collection: 1, image: 1, position: key, positionNumber: number)
        }
        let items = [photo("---B"), photo(), photo("---0"), photo("---a"), photo("---A"), photo("---9")].enumerated().map { (item: $0.element, arrival: $0.offset) }
        let sorted = items.sorted { LRCollectionImage.isOrdered($0, before: $1) }.map(\.arrival)
        #expect(sorted == [2, 5, 4, 0, 3, 1])
        let numbers = [photo(number: 10), photo(number: 2), photo()].enumerated().map { (item: $0.element, arrival: $0.offset) }
        #expect(numbers.sorted { LRCollectionImage.isOrdered($0, before: $1) }.map(\.arrival) == [1, 0, 2])
    }

    @Test("Photos get ISO, focal length, aperture, shutter speed, GPS and treatment from Lightroom's harvest")
    func shootingDetails() async throws {
        let fixture = try PhotosFixture()
        try fixture.run("""
            ALTER TABLE AgHarvestedExifMetadata ADD COLUMN isoSpeedRating;
            ALTER TABLE AgHarvestedExifMetadata ADD COLUMN focalLength;
            ALTER TABLE AgHarvestedExifMetadata ADD COLUMN aperture;
            ALTER TABLE AgHarvestedExifMetadata ADD COLUMN shutterSpeed;
            UPDATE AgHarvestedExifMetadata SET isoSpeedRating = 800.0, focalLength = 50.0, aperture = 6.0, shutterSpeed = 6.643856 WHERE image = 13;
            INSERT INTO Adobe_imageDevelopSettings (image, grayscale) VALUES (13, 1);
            """)
        let (store, _) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }])
        let photos = Dictionary(try store.viewContext.fetch(Photo.fetchRequest()).filter { !$0.isVirtualCopy }.map { ($0.fileName, $0) }) { first, _ in first }
        // D.cr2's file is offline: Lightroom's values (APEX aperture 6 is ƒ/8; APEX time 6.64 is 1/100 s).
        let d = try #require(photos["D.cr2"])
        #expect(d.iso == 800 && d.focalLength == 50 && abs(d.aperture - 8) < 0.001 && abs(d.shutterSpeed - 0.01) < 0.0001)
        #expect(d.hasGPS && d.isBlackAndWhite)
        // A.jpg is read from its file (the fixture JPEG has no exposure data, and no GPS).
        let a = try #require(photos["A.jpg"])
        #expect(a.iso == 0 && !a.hasGPS && !a.isBlackAndWhite)
    }

    @Test("Lightroom's own smart collections replace PixelLoupe's starter set, so there are no duplicates")
    func noStarterDuplicates() throws {
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: try TemporaryDirectory().url.appending(path: "C.pixelloupe"))
        // What the import coordinator does when it finishes.
        store.viewState.createdDefaultCollections = true
        CollectionEditing(store: store).createDefaultSmartCollections()
        #expect(try store.viewContext.count(for: PhotoCollection.fetchRequest()) == 0)
    }

    @Test("Opens a version seven catalog and adds the new fields")
    func migratesVersionSeven() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "V7.pixelloupe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(Fixtures.referencedInfo).write(to: CatalogPackage.infoURL(in: packageURL))
        let momd = try #require(Bundle(for: Photo.self).url(forResource: "PixelLoupe", withExtension: "momd"))
        let v7 = try #require(NSManagedObjectModel(contentsOf: momd.appending(path: "PixelLoupe 7.mom")))
        #expect(v7.entitiesByName["Photo"]?.attributesByName["iso"] == nil)
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: v7)
            _ = try coordinator.addPersistentStore(type: .sqlite, at: CatalogPackage.databaseURL(in: packageURL))
            let context = NSManagedObjectContext(.mainQueue)
            context.persistentStoreCoordinator = coordinator
            let photo = NSEntityDescription.insertNewObject(forEntityName: "Photo", into: context)
            photo.setValue(UUID(), forKey: "id")
            photo.setValue("v7.jpg", forKey: "fileName")
            photo.setValue(Date(), forKey: "captureDate")
            photo.setValue(Date(), forKey: "importDate")
            photo.setValue(Date(), forKey: "editDate")
            let collection = NSEntityDescription.insertNewObject(forEntityName: "PhotoCollection", into: context)
            collection.setValue(UUID(), forKey: "id")
            collection.setValue("Old", forKey: "name")
            collection.setValue(Date(), forKey: "createdDate")
            try context.save()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }
        let store = try CatalogStore.open(at: packageURL)
        let photo = try #require(try store.viewContext.fetch(Photo.fetchRequest()).first)
        #expect(photo.iso == 0 && photo.aperture == 0 && !photo.hasGPS && photo.titleText == nil)
        let collection = try #require(try store.viewContext.fetch(PhotoCollection.fetchRequest()).first)
        #expect(collection.customOrder.isEmpty && collection.importWarning == nil && collection.luaRules == nil)
    }
}
