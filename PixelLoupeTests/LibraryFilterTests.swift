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
        filter.metadata.tags = ["Landscape"]
        #expect(try names(filter) == ["a.CR3", "d.ARW"])
        filter.metadata.tags = ["Landscape", "Family"]
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
        filter.text.query = "nikon"
        #expect(try names(filter) == ["b.NEF"])
        filter.text.query = "24-70"
        #expect(try names(filter) == ["a.CR3", "d.ARW"])
        filter.text.query = "sony 24-70"
        #expect(try names(filter) == ["d.ARW"])
        filter.text.query = "a.CR3"
        #expect(try names(filter).isEmpty, "file names are not searched")
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

    @Test func combinedFilters() throws {
        var filter = LibraryFilter()
        filter.scope = .folder(path: "/Photos/Home")
        filter.metadata.tags = ["Family"]
        filter.attributes.rating = 1
        #expect(try names(filter) == ["c.jpg"])
    }
}
