import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Library filter")
struct LibraryFilterTests {
    let directory: TemporaryDirectory
    let store: CatalogStore

    init() throws {
        directory = try TemporaryDirectory()
        store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url)

        let context = store.viewContext
        let trip = folder("/Photos/Trip", in: context)
        let day = folder("/Photos/Trip/Day 1", in: context)
        day.parent = trip
        let home = folder("/Photos/Home", in: context)
        let landscape = PixelLoupe.Tag.findOrCreate(named: "Landscape", in: context)
        let family = PixelLoupe.Tag.findOrCreate(named: "Family", in: context)

        insert("a.CR3", rating: 5, flag: .picked, camera: ("Canon", "EOS R5"), lens: "RF24-70mm", folder: day, tags: [landscape], day: 3)
        insert("b.NEF", rating: 3, flag: .unflagged, camera: ("NIKON", "Z 8"), lens: "NIKKOR Z 50mm", folder: trip, tags: [], day: 1)
        insert("c.jpg", rating: 1, flag: .rejected, camera: ("Apple", "iPhone 17 Pro"), lens: nil, folder: home, tags: [family], day: 2)
        insert("d.ARW", rating: 0, flag: .unflagged, camera: ("SONY", "ILCE-7RM5"), lens: "FE 24-70mm GM II", folder: home, tags: [landscape, family], day: 4)
        try context.save()
    }

    private func folder(_ path: String, in context: NSManagedObjectContext) -> Folder {
        let folder = Folder(context: context)
        folder.path = path
        folder.name = (path as NSString).lastPathComponent
        return folder
    }

    private func insert(
        _ name: String, rating: Int16, flag: PhotoFlag, camera: (String, String), lens: String?,
        folder: Folder, tags: Set<PixelLoupe.Tag>, day: Int
    ) {
        let photo = Photo(context: store.viewContext)
        photo.id = UUID()
        photo.fileName = name
        photo.filePath = folder.path + "/" + name
        photo.fileType = (name as NSString).pathExtension.uppercased()
        photo.rating = rating
        photo.photoFlag = flag
        photo.cameraMake = camera.0
        photo.cameraModel = camera.1
        photo.lensModel = lens
        photo.folder = folder
        photo.tags = tags
        photo.captureDate = Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
        photo.importDate = Date(timeIntervalSince1970: TimeInterval(10 - day) * 86_400)
        photo.editDate = photo.importDate
    }

    private func names(_ filter: LibraryFilter) throws -> [String] {
        let request = Photo.fetchRequest()
        request.predicate = filter.predicate
        request.sortDescriptors = filter.sortDescriptors
        return try store.viewContext.fetch(request).map(\.fileName)
    }

    @Test func noFilterReturnsEverythingByCaptureTime() throws {
        // No filter still leaves out the photos a collapsed stack hides.
        #expect(LibraryFilter().predicate?.predicateFormat == "isHiddenInStack == 0")
        #expect(try names(LibraryFilter()) == ["b.NEF", "c.jpg", "a.CR3", "d.ARW"])
    }

    @Test func descendingReversesOrder() throws {
        var filter = LibraryFilter()
        filter.ascending = false
        #expect(try names(filter) == ["d.ARW", "a.CR3", "c.jpg", "b.NEF"])
    }

    @Test(arguments: [
        (LibraryFilter.RatingComparison.atLeast, 3, ["b.NEF", "a.CR3"]),
        (.exactly, 3, ["b.NEF"]),
        (.atMost, 1, ["c.jpg", "d.ARW"]),
    ])
    func ratingFilter(comparison: LibraryFilter.RatingComparison, rating: Int, expected: [String]) throws {
        var filter = LibraryFilter()
        filter.attributes.rating = rating
        filter.attributes.ratingComparison = comparison
        #expect(try names(filter) == expected)
    }

    @Test func tagFilterMatchesAnySelectedTag() throws {
        var filter = LibraryFilter()
        filter.metadata.select(keywords: ["Landscape"])
        #expect(try names(filter) == ["a.CR3", "d.ARW"])
        filter.metadata.select(keywords: ["Landscape", "Family"])
        #expect(try names(filter) == ["c.jpg", "a.CR3", "d.ARW"])
    }

    @Test func flagFilterMatchesAnySelectedFlag() throws {
        var filter = LibraryFilter()
        filter.attributes.flags = [.picked]
        #expect(try names(filter) == ["a.CR3"])
        filter.attributes.flags = [.unflagged, .rejected]
        #expect(try names(filter) == ["b.NEF", "c.jpg", "d.ARW"])
        filter.attributes.flags = [.picked, .rejected]
        filter.attributes.rating = 1
        #expect(try names(filter) == ["c.jpg", "a.CR3"], "flags combine with the rating filter")
    }

    @Test func searchMatchesCameraAndLensCaseInsensitively() throws {
        var filter = LibraryFilter()
        filter.text.field = .cameraAndLens
        filter.text.query = "nikon"
        #expect(try names(filter) == ["b.NEF"])
        filter.text.query = "24-70"
        #expect(try names(filter) == ["a.CR3", "d.ARW"])
        filter.text.query = "sony 24-70"
        #expect(try names(filter) == ["d.ARW"])
        filter.text.query = "a.CR3"
        #expect(try names(filter).isEmpty, "file names are not searched")
    }

    private func search(
        _ query: String, in field: LibraryFilter.TextSearch.Field = .anySearchable,
        _ rule: LibraryFilter.TextSearch.Rule = .containsAll
    ) throws -> [String] {
        var filter = LibraryFilter()
        filter.text = .init(field: field, rule: rule, query: query)
        return try names(filter)
    }

    @Test func anySearchableFieldSearchesFileNamesAndKeywords() throws {
        #expect(try search("a.CR3") == ["a.CR3"])
        #expect(try search("landscape") == ["a.CR3", "d.ARW"])
        #expect(try search("canon landscape") == ["a.CR3"], "Contains All needs every word")
        #expect(try search("family", in: .keywords) == ["c.jpg", "d.ARW"])
        #expect(try search("canon", in: .keywords).isEmpty)
        #expect(try search("a.CR3", in: .fileName) == ["a.CR3"])
    }

    @Test func rules() throws {
        #expect(try search("nikon sony", in: .cameraAndLens, .contains) == ["b.NEF", "d.ARW"], "Contains needs any word")
        #expect(try search("nikon sony", in: .cameraAndLens, .containsAll).isEmpty)
        #expect(try search("70", in: .cameraAndLens, .contains) == ["a.CR3", "d.ARW"])
        #expect(try search("70", in: .cameraAndLens, .containsWords).isEmpty, "70 is part of 70mm")
        #expect(try search("24", in: .cameraAndLens, .containsWords) == ["d.ARW"], "RF24 isn't the word 24")
        #expect(try search("canon apple", in: .cameraAndLens, .doesNotContain) == ["b.NEF", "d.ARW"])
        #expect(try search("nik", in: .cameraAndLens, .startsWith) == ["b.NEF"])
        #expect(try search("kon", in: .cameraAndLens, .startsWith).isEmpty)
        #expect(try search("kon", in: .cameraAndLens, .endsWith) == ["b.NEF"])
    }

    @Test func doesNotContainLeavesOutKeywords() throws {
        #expect(try search("family", in: .keywords, .doesNotContain) == ["b.NEF", "a.CR3"])
        #expect(try search("rf24", in: .cameraAndLens, .doesNotContain) == ["b.NEF", "c.jpg", "d.ARW"],
                "a photo with no lens doesn't contain the word")
        #expect(try search("landscape", in: .anySearchable, .doesNotContain) == ["b.NEF", "c.jpg"])
    }

    @Test func inlineSyntaxOverridesTheRule() throws {
        #expect(try search("24-70 !sony", in: .cameraAndLens) == ["a.CR3"])
        #expect(try search("+nik", in: .cameraAndLens) == ["b.NEF"])
        #expect(try search("kon+", in: .cameraAndLens) == ["b.NEF"])
        #expect(try search("canon nikon !z", in: .cameraAndLens, .contains) == ["a.CR3"], "any plain word, but never z")
        #expect(try search("! +", in: .cameraAndLens).count == 4, "a bare ! or + is no word")
        #expect(LibraryFilter.TextSearch(query: " ! ").isEmpty)
    }

    @Test func textSearchSavedBeforeFieldsAndRulesStillLoads() throws {
        let data = try PropertyListEncoder().encode(["query": "canon"])
        let text = try PropertyListDecoder().decode(LibraryFilter.TextSearch.self, from: data)
        #expect(text == .init(query: "canon"))
    }

    @Test func folderScopeIncludesSubfolders() throws {
        var filter = LibraryFilter()
        filter.scope = .folder(path: "/Photos/Trip")
        #expect(try names(filter) == ["b.NEF", "a.CR3"])
        filter.scope = .folder(path: "/Photos/Trip/Day 1")
        #expect(try names(filter) == ["a.CR3"])
    }

    @Test func folderScopeDoesNotMatchSiblingPrefix() throws {
        let context = store.viewContext
        let tripX = folder("/Photos/TripX", in: context)
        insert("e.jpg", rating: 0, flag: .unflagged, camera: ("Fujifilm", "X-T5"), lens: nil, folder: tripX, tags: [], day: 5)
        var filter = LibraryFilter()
        filter.scope = .folder(path: "/Photos/Trip")
        #expect(try !names(filter).contains("e.jpg"))
    }

    @Test(arguments: PhotoSortKey.allCases)
    func everySortKeyFetches(key: PhotoSortKey) throws {
        var filter = LibraryFilter()
        filter.sortKey = key
        #expect(try names(filter).count == 4)
    }

    @Test func sortByRatingThenCaptureTime() throws {
        var filter = LibraryFilter()
        filter.sortKey = .rating
        filter.ascending = false
        #expect(try names(filter) == ["a.CR3", "b.NEF", "c.jpg", "d.ARW"])
    }

    /// a.CR3 is edited, labelled red and stacked with b.NEF; c.jpg has a custom Lightroom label;
    /// d.ARW is a video; e.CR3 is a virtual copy of a.CR3.
    private func addAttributes() throws {
        let context = store.viewContext
        let photos = Dictionary(uniqueKeysWithValues: try context.fetch(Photo.fetchRequest()).map { ($0.fileName, $0) })
        let a = try #require(photos["a.CR3"]), b = try #require(photos["b.NEF"])
        a.adjustmentsData = Data([1])
        a.label = .red
        try #require(photos["c.jpg"]).labelText = "Approved"
        try #require(photos["d.ARW"]).isVideo = true
        let stack = PhotoStack(context: context)
        stack.isCollapsed = false
        a.stack = stack
        b.stack = stack
        stack.renumber([a, b])
        insert("e.CR3", rating: 0, flag: .unflagged, camera: ("Canon", "EOS R5"), lens: nil,
               folder: try #require(a.folder), tags: [], day: 5)
        let copy = try #require(try context.fetch(Photo.fetchRequest()).first { $0.fileName == "e.CR3" })
        copy.master = a
        try context.save()
    }

    @Test(arguments: [
        ([LibraryFilter.Attributes.EditStatus.edited], ["a.CR3"]),
        ([.unedited], ["b.NEF", "c.jpg", "d.ARW", "e.CR3"]),
        ([.edited, .unedited], ["b.NEF", "c.jpg", "a.CR3", "d.ARW", "e.CR3"]),
    ])
    func editFilter(status: [LibraryFilter.Attributes.EditStatus], expected: [String]) throws {
        try addAttributes()
        var filter = LibraryFilter()
        filter.attributes.editStatus = Set(status)
        #expect(try names(filter) == expected)
    }

    @Test func otherLabelIsALabelWithNoColor() throws {
        try addAttributes()
        var filter = LibraryFilter()
        filter.attributes.otherLabel = true
        #expect(try names(filter) == ["c.jpg"])
        filter.attributes.colorLabels = [.red]
        #expect(try names(filter) == ["c.jpg", "a.CR3"])
        filter.attributes = .init(colorLabels: [.none])
        #expect(try names(filter) == ["b.NEF", "d.ARW", "e.CR3"], "a custom label isn't \"no label\"")
    }

    @Test(arguments: [
        ([LibraryFilter.Attributes.Kind.original], ["b.NEF", "c.jpg", "a.CR3"]),
        ([.virtualCopy], ["e.CR3"]),
        ([.video], ["d.ARW"]),
        ([.virtualCopy, .video], ["d.ARW", "e.CR3"]),
    ])
    func kindFilter(kinds: [LibraryFilter.Attributes.Kind], expected: [String]) throws {
        try addAttributes()
        var filter = LibraryFilter()
        filter.attributes.kinds = Set(kinds)
        #expect(try names(filter) == expected)
    }

    @Test func stackFilter() throws {
        try addAttributes()
        var filter = LibraryFilter()
        filter.attributes.stackStatus = [.stacked]
        #expect(try names(filter) == ["b.NEF", "a.CR3"])
        filter.attributes.stackStatus = [.unstacked]
        #expect(try names(filter) == ["c.jpg", "d.ARW", "e.CR3"])
    }

    @Test func attributeGroupsCombine() throws {
        try addAttributes()
        var filter = LibraryFilter()
        filter.attributes.flags = [.unflagged]
        filter.attributes.kinds = [.original, .virtualCopy]
        filter.attributes.stackStatus = [.unstacked]
        #expect(try names(filter) == ["e.CR3"], "a photo must match every group")
        filter.attributes.kinds = []
        #expect(try names(filter) == ["d.ARW", "e.CR3"])
    }

    @Test func attributesSavedBeforeTheNewGroupsStillLoad() throws {
        let data = try PropertyListEncoder().encode(["rating": 3])
        let attributes = try PropertyListDecoder().decode(LibraryFilter.Attributes.self, from: data)
        #expect(attributes == .init(rating: 3))
    }

    // MARK: - Metadata columns

    private func columnValues(_ columns: [LibraryFilter.MetadataBrowser.Column]) throws -> [[MetadataColumn.Value]] {
        try LibraryFilter.MetadataBrowser.values(for: columns, base: LibraryFilter().scopePredicate, in: store.viewContext)
    }

    private func metadata(_ columns: [LibraryFilter.MetadataBrowser.Column]) throws -> [String] {
        var filter = LibraryFilter()
        filter.metadata = .init(columns: columns)
        return try names(filter)
    }

    @Test func columnsCascadeFromLeftToRight() throws {
        let all = try columnValues([.init(kind: .camera), .init(kind: .lens)])
        #expect(all[0].map(\.title) == ["EOS R5", "ILCE-7RM5", "iPhone 17 Pro", "Z 8"])
        #expect(all[0].allSatisfy { $0.count == 1 })
        #expect(all[1].map(\.title) == ["FE 24-70mm GM II", "NIKKOR Z 50mm", "RF24-70mm", "Unknown Lens"], "unknown last")

        let canon = try columnValues([.init(kind: .camera, selection: ["EOS R5"]), .init(kind: .lens)])
        #expect(canon[1].map(\.title) == ["RF24-70mm"], "the lens column counts only what the camera leaves")
        #expect(try metadata([.init(kind: .camera, selection: ["EOS R5", "Z 8"])]) == ["b.NEF", "a.CR3"], "values in a column are OR'd")
        #expect(try metadata([.init(kind: .camera, selection: ["EOS R5", "Z 8"]), .init(kind: .lens, selection: ["RF24-70mm"])]) == ["a.CR3"])
        #expect(try metadata([.init(kind: .lens, selection: [""])]) == ["c.jpg"], "Unknown Lens")
    }

    @Test func keywordColumnCountsEachKeyword() throws {
        let values = try columnValues([.init(kind: .keyword)])[0]
        #expect(values.map(\.key) == ["Family", "Landscape"])
        #expect(values.map(\.count) == [2, 2])
        #expect(try metadata([.init(kind: .keyword, selection: ["Landscape"])]) == ["a.CR3", "d.ARW"])
    }

    @Test func dateColumnNestsMonthsAndDays() throws {
        let years = try columnValues([.init(kind: .date)])[0]
        #expect(years.count == 1 && years[0].count == 4)
        let days = years[0].children.flatMap(\.children)
        #expect(days.map(\.count).reduce(0, +) == 4)
        // b.NEF was taken on day 1; its day's key finds just it.
        let captured = Date(timeIntervalSince1970: 86_400)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: captured)
        let key = String(format: "%04ld-%02ld-%02ld", components.year!, components.month!, components.day!)
        #expect(days.contains { $0.key == key })
        #expect(try metadata([.init(kind: .date, selection: [key])]) == ["b.NEF"])
        #expect(try metadata([.init(kind: .date, selection: [String(components.year!)])]).count == 4)
    }

    @Test func aspectRatioFollowsOrientation() throws {
        let photos = Dictionary(uniqueKeysWithValues: try store.viewContext.fetch(Photo.fetchRequest()).map { ($0.fileName, $0) })
        for (name, width, height, orientation) in [("a.CR3", 6000, 4000, 1), ("b.NEF", 6000, 4000, 6), ("c.jpg", 3000, 4000, 1), ("d.ARW", 100, 100, 1)] {
            let photo = try #require(photos[name])
            photo.pixelWidth = Int32(width)
            photo.pixelHeight = Int32(height)
            photo.orientation = Int16(orientation)
        }
        try store.viewContext.save()
        let values = try columnValues([.init(kind: .aspectRatio)])[0]
        #expect(Dictionary(uniqueKeysWithValues: values.map { ($0.title, $0.count) }) == ["Landscape": 1, "Portrait": 2, "Square": 1])
        #expect(try metadata([.init(kind: .aspectRatio, selection: ["portrait"])]) == ["b.NEF", "c.jpg"])
    }

    @Test func aChosenValueTheSourceLacksStillHasARow() throws {
        var filter = LibraryFilter()
        filter.scope = .folder(path: "/Photos/Home")
        let values = try LibraryFilter.MetadataBrowser.values(
            for: [.init(kind: .camera, selection: ["Z 8"])], base: filter.scopePredicate, in: store.viewContext
        )[0]
        #expect(values.last?.title == "Z 8" && values.last?.count == 0)
    }

    @Test func selectingKeywordsUsesOrAddsAKeywordColumn() {
        var browser = LibraryFilter.MetadataBrowser()
        browser.columns[1].selection = ["EOS R5"]
        browser.select(keywords: ["Family"])
        #expect(browser.columns.map(\.kind) == [.keyword, .date, .camera, .lens, .label])
        #expect(browser.columns[0].selection == ["Family"])
        let othersAreAll = browser.columns.dropFirst().allSatisfy { $0.selection.isEmpty }
        #expect(othersAreAll, "the other columns go back to All")
        browser.select(keywords: ["Landscape"])
        #expect(browser.columns.count == 5 && browser.columns[0].selection == ["Landscape"], "an existing Keyword column is reused")

        var full = LibraryFilter.MetadataBrowser(columns: Array(repeating: .init(kind: .camera), count: 8))
        full.select(keywords: ["Family"])
        #expect(full.columns.count == 8 && full.columns[0].kind == .keyword)
    }

    @Test func metadataSavedWithoutColumnsGetsTheDefaults() throws {
        let decoded = try PropertyListDecoder().decode(LibraryFilter.MetadataBrowser.self, from: PropertyListEncoder().encode([String: String]()))
        #expect(decoded.columns.map(\.kind) == [.date, .camera, .lens, .label])
    }

    @Test func combinedFilters() throws {
        var filter = LibraryFilter()
        filter.scope = .folder(path: "/Photos/Home")
        filter.metadata.select(keywords: ["Family"])
        filter.attributes.rating = 1
        #expect(try names(filter) == ["c.jpg"])
    }
}
