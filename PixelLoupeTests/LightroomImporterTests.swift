import CoreData
import Foundation
import Testing
@testable import PixelLoupe

/// Collects values from `@Sendable` callbacks.
nonisolated private final class Collector<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) { lock.withLock { storage.append(value) } }
    var values: [Value] { lock.withLock { storage } }
}

/// A phase that makes `count` photos in batches of `batchSize`, noting a difference on every third.
nonisolated private final class FakePhase: LightroomImportPhase {
    let title: String
    let count: Int
    let batchSize: Int
    let firstLightroomID: Int
    var onBatch: (@Sendable (Int) -> Void)?
    private var made = 0

    init(title: String, count: Int, batchSize: Int = 100, firstLightroomID: Int = 1, onBatch: (@Sendable (Int) -> Void)? = nil) {
        self.title = title
        self.count = count
        self.batchSize = batchSize
        self.firstLightroomID = firstLightroomID
        self.onBatch = onBatch
    }

    func prepare(_ context: LightroomImportContext) async throws -> Int { count }

    func importBatch(_ context: LightroomImportContext) async throws -> Int {
        let size = min(batchSize, count - made)
        guard size > 0 else { return 0 }
        let start = made
        let first = firstLightroomID
        let title = title
        let managed = context.managedObjectContext
        let pairs: [(lightroomID: Int, photoID: UUID)] = await managed.perform {
            var pairs: [(lightroomID: Int, photoID: UUID)] = []
            for offset in 0..<size {
                let index = start + offset
                let photo = Photo(context: managed)
                photo.id = UUID()
                photo.fileName = "IMG_\(index).jpg"
                photo.filePath = "/Photos/IMG_\(index).jpg"
                photo.fileType = "JPG"
                photo.captureDate = Date(timeIntervalSince1970: Double(index))
                photo.importDate = context.importDate
                photo.editDate = context.importDate
                photo.lightroomID = "LR-\(first + index)"
                pairs.append((first + index, photo.id))
                if index % 3 == 0 {
                    context.report.recordDifference("masks", title: "Masks", for: photo)
                    if index % 6 == 0 { context.report.recordDifference("upright", title: "Upright", for: photo) }
                }
            }
            return pairs
        }
        try context.idMap.record(pairs)
        context.report.addImported(title, count: size)
        made += size
        onBatch?(made)
        return size
    }
}

@Suite("Lightroom importer")
@MainActor
struct LightroomImporterTests {
    private struct Setup {
        let directory: TemporaryDirectory
        let fixture: FixtureCatalog
        let catalog: LightroomCatalog
        let packageURL: URL
        let store: CatalogStore
    }

    private func makeSetup() throws -> Setup {
        let directory = try TemporaryDirectory()
        let fixture = try FixtureCatalog(in: directory.url)
        try fixture.populate()
        let packageURL = directory.url.appending(path: "Imported.pixelloupe", directoryHint: .isDirectory)
        let store = try CatalogStore.create(at: packageURL, info: CatalogInfo(name: "Imported", storageMode: .referenced))
        return Setup(directory: directory, fixture: fixture, catalog: try LightroomCatalog(url: fixture.url), packageURL: packageURL, store: store)
    }

    @Test("Runs phases in order, saving per batch, and writes the report")
    func runsPhases() async throws {
        let setup = try makeSetup()
        let progress = Collector<LightroomImportProgress>()
        let summary = try setup.catalog.summary()

        let report = try await LightroomImporter.run(
            catalog: setup.catalog, sourceName: "Test.lrcat", summary: summary,
            into: setup.store.newBackgroundContext(), packageURL: setup.packageURL,
            phases: [
                { FakePhase(title: "Importing photos", count: 250, firstLightroomID: 1) },
                { FakePhase(title: "Importing more", count: 10, batchSize: 4, firstLightroomID: 1000) },
            ],
            progress: { progress.append($0) })

        // Everything was saved to the store.
        let context = setup.store.viewContext
        #expect(try context.count(for: Photo.fetchRequest()) == 260)
        let first = Photo.fetchRequest()
        first.predicate = NSPredicate(format: "lightroomID == %@", "LR-1")
        #expect(try context.fetch(first).count == 1)

        // Report: totals, groups biggest first, saved in the package and readable again.
        #expect(report.imported == [.init(title: "Importing photos", count: 250), .init(title: "Importing more", count: 10)])
        let masks = try #require(report.groups.first { $0.key == "masks" })
        let upright = try #require(report.groups.first { $0.key == "upright" })
        // Indexes divisible by 3 (0, 3, … 249): 84, plus 0, 3, 6, 9 of the second phase: 4.
        #expect(masks.photoCount == 84 + 4)
        #expect(upright.photoCount == 42 + 2)
        #expect(report.groups.first?.key == "masks")
        #expect(report.sourceName == "Test.lrcat" && report.summary.photos == 2)
        let loaded = try #require(LightroomImportReport.load(from: setup.packageURL))
        #expect(loaded == report)
        #expect(LightroomImportReport.exists(in: setup.packageURL))

        // "Show Photos" predicates and the smart collection.
        let request = Photo.fetchRequest()
        request.predicate = LightroomImportReport.predicate(forReason: "upright")
        #expect(try context.count(for: request) == upright.photoCount)
        request.predicate = LightroomImportReport.predicate(forReason: nil)
        #expect(try context.count(for: request) == masks.photoCount)
        request.predicate = LightroomImportReport.predicate(forReason: "mask")
        #expect(try context.count(for: request) == 0)

        let collections = try context.fetch(PhotoCollection.fetchRequest())
        let smart = try #require(collections.first { $0.name == "Imported with Differences" })
        #expect(smart.kind == .smart)
        request.predicate = smart.rules.predicate
        #expect(try context.count(for: request) == masks.photoCount)

        // Progress rose through both phases and finished at 100%.
        let values = progress.values
        #expect(values.first?.completed == 0)
        let fractions = values.map(\.fraction)
        #expect(fractions == fractions.sorted())
        #expect(values.last?.fraction == 1)
        #expect(values.contains { $0.phaseIndex == 1 && $0.phaseTitle == "Importing more" && $0.completed == 10 && $0.total == 10 })
    }

    @Test("Cancelling stops at a batch boundary; the partial catalog can be deleted")
    func cancel() async throws {
        let setup = try makeSetup()
        let holder = Collector<Task<LightroomImportReport, Error>>()
        let task = Task { [catalog = setup.catalog, packageURL = setup.packageURL, context = setup.store.newBackgroundContext()] in
            try await LightroomImporter.run(
                catalog: catalog, sourceName: "Test.lrcat", summary: LightroomCatalogSummary(), into: context,
                packageURL: packageURL,
                phases: [{
                    FakePhase(title: "Importing photos", count: 1000, onBatch: { made in
                        if made == 300 { holder.values.first?.cancel() }
                    })
                }],
                progress: { _ in })
        }
        holder.append(task)
        do {
            _ = try await task.value
            Issue.record("the import should have been cancelled")
        } catch is CancellationError {}

        let saved = try setup.store.viewContext.count(for: Photo.fetchRequest())
        #expect(saved >= 300 && saved < 1000)
        #expect(!LightroomImportReport.exists(in: setup.packageURL))

        setup.store.closeAndDelete()
        #expect(!FileManager.default.fileExists(atPath: setup.packageURL.path(percentEncoded: false)))
    }

    @Test("Phases can look up photos by Lightroom id")
    func idMapLookup() async throws {
        let setup = try makeSetup()
        nonisolated final class Lookup: LightroomImportPhase, @unchecked Sendable {
            let title = "Lookup"
            var found: [UUID?] = []
            func prepare(_ context: LightroomImportContext) async throws -> Int { 0 }
            func importBatch(_ context: LightroomImportContext) async throws -> Int { 0 }
            func finish(_ context: LightroomImportContext) async throws {
                found = [context.idMap.photoID(forLightroomID: 7), context.idMap.photoID(forLightroomID: 9999)]
            }
        }
        let lookup = Lookup()
        _ = try await LightroomImporter.run(
            catalog: setup.catalog, sourceName: "Test.lrcat", summary: LightroomCatalogSummary(),
            into: setup.store.newBackgroundContext(), packageURL: setup.packageURL,
            phases: [{ FakePhase(title: "Photos", count: 20) }, { lookup }], progress: { _ in })
        #expect(lookup.found.count == 2)
        let id = try #require(lookup.found[0])
        #expect(lookup.found[1] == nil)
        let request = Photo.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        #expect(try setup.store.viewContext.fetch(request).first?.lightroomID == "LR-7")
    }

    @Test("The ID map stores and replaces mappings, and cleans up")
    func idMap() throws {
        var map: LightroomIDMap? = try LightroomIDMap()
        var pairs: [(lightroomID: Int, photoID: UUID)] = []
        for id in 1...5000 { pairs.append((id, UUID())) }
        try map?.record(pairs)
        #expect(map?.count == 5000)
        #expect(map?.photoID(forLightroomID: 2500) == pairs[2499].photoID)
        #expect(map?.photoID(forLightroomID: 0) == nil)
        let replacement = UUID()
        try map?.record([(2500, replacement)])
        #expect(map?.photoID(forLightroomID: 2500) == replacement)
        #expect(map?.count == 5000)
        let scratch = try #require(map?.directory)
        #expect(FileManager.default.fileExists(atPath: scratch.path(percentEncoded: false)))
        map = nil
        #expect(!FileManager.default.fileExists(atPath: scratch.path(percentEncoded: false)))
    }

    @Test("Summarizes a catalog's contents")
    func summary() throws {
        let directory = try TemporaryDirectory()
        let photos = try directory.subdirectory("Photos/2020")
        try Data("x".utf8).write(to: photos.appending(path: "IMG_0001.CR3"))
        let fixture = try FixtureCatalog(in: directory.url)
        try fixture.populate()
        // Point the root folder at the real directory: IMG_0001 exists, IMG_0002 is missing.
        let root = directory.url.appending(path: "Photos").path(percentEncoded: false) + "/"
        try fixture.run("UPDATE AgLibraryRootFolder SET absolutePath = '\(root)'")
        try fixture.run("INSERT INTO Adobe_images (id_local, id_global, fileFormat, rootFile) VALUES (13, 'img13', 'XYZ', 2)")

        let catalog = try LightroomCatalog(url: fixture.url)
        var summary = try catalog.summary()
        #expect(summary.lightroomVersion == "Lightroom Classic 15 (18.0.0)")
        #expect(summary.photos == 3)  // 10, 12 and the unsupported file; 11 is a virtual copy
        #expect(summary.virtualCopies == 1)
        #expect(summary.folders == 2)
        #expect(summary.keywords == 1)  // the child "Dog"; "Animals" has no parent, like Lightroom's hidden root
        #expect(summary.collections == 1 && summary.smartCollections == 1 && summary.collectionSets == 1)
        #expect(summary.stacks == 0)
        #expect(summary.photosWithEdits == 1)
        #expect(summary.photosWithMasksOrHealing == 2)
        #expect(summary.unsupportedFiles == ["XYZ": 1])
        #expect(summary.missingFiles == nil)

        let progress = Collector<Int>()
        summary.missingFiles = try catalog.countMissingFiles { checked, _ in progress.append(checked) }
        // Images 10, 11 share IMG_0001 (present); 12 and 13 point at IMG_0002 (missing).
        #expect(summary.missingFiles == 2)
    }

    @Test("A smart-collection rule matches photos imported with differences")
    func smartRule() throws {
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: try TemporaryDirectory().url.appending(path: "C.pixelloupe"))
        let context = store.viewContext
        func photo(_ differences: String?) -> Photo {
            let photo = Photo(context: context)
            photo.id = UUID()
            photo.captureDate = Date()
            photo.importDate = Date()
            photo.editDate = Date()
            photo.importDifferences = differences
            return photo
        }
        _ = [photo(nil), photo("|masks|"), photo("|masks|upright|")]
        try context.save()

        func count(_ value: String, _ op: SmartCollectionRules.Operator = .is) throws -> Int {
            let request = Photo.fetchRequest()
            request.predicate = SmartCollectionRules(rules: [.init(field: .importedWithDifferences, operator: op, value: value)]).predicate
            return try context.count(for: request)
        }
        #expect(try count("true") == 2)
        #expect(try count("false") == 1)
        #expect(try count("true", .isNot) == 1)
        #expect(SmartCollectionRules.Field.importedWithDifferences.title == "Imported with Differences")
    }

    @Test("Opens a version four catalog and adds the Lightroom fields")
    func migratesVersionFour() throws {
        let directory = try TemporaryDirectory()
        let packageURL = directory.url.appending(path: "V4.pixelloupe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(Fixtures.referencedInfo).write(to: CatalogPackage.infoURL(in: packageURL))

        let momd = try #require(Bundle(for: Photo.self).url(forResource: "PixelLoupe", withExtension: "momd"))
        let v4 = try #require(NSManagedObjectModel(contentsOf: momd.appending(path: "PixelLoupe 4.mom")))
        #expect(v4.entitiesByName["Photo"]?.attributesByName["lightroomID"] == nil)
        do {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: v4)
            _ = try coordinator.addPersistentStore(type: .sqlite, at: CatalogPackage.databaseURL(in: packageURL))
            let context = NSManagedObjectContext(.mainQueue)
            context.persistentStoreCoordinator = coordinator
            let photo = NSEntityDescription.insertNewObject(forEntityName: "Photo", into: context)
            photo.setValue(UUID(), forKey: "id")
            photo.setValue("v4.jpg", forKey: "fileName")
            photo.setValue(Date(), forKey: "captureDate")
            photo.setValue(Date(), forKey: "importDate")
            photo.setValue(Date(), forKey: "editDate")
            try context.save()
            for store in coordinator.persistentStores { try coordinator.remove(store) }
        }

        let store = try CatalogStore.open(at: packageURL)
        let photo = try #require(try store.viewContext.fetch(Photo.fetchRequest()).first)
        #expect(photo.fileName == "v4.jpg" && photo.lightroomID == nil && photo.importDifferences == nil)
        photo.lightroomID = "ABC"
        photo.importDifferences = "|masks|"
        try store.viewContext.save()
        #expect(photo.lightroomID == "ABC")
    }

    @Test("The Lightroom import report round-trips through JSON")
    func reportCoding() throws {
        let directory = try TemporaryDirectory()
        #expect(!LightroomImportReport.exists(in: directory.url))
        #expect(LightroomImportReport.load(from: directory.url) == nil)
        let report = LightroomImportReport(
            sourceName: "A.lrcat", lightroomVersion: "Lightroom Classic 15", importedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 12.5, summary: LightroomCatalogSummary(photos: 3), imported: [.init(title: "Photos", count: 3)],
            groups: [.init(key: "masks", title: "Masks", photoCount: 2)], warnings: ["Something"])
        try report.save(to: directory.url)
        #expect(LightroomImportReport.load(from: directory.url) == report)
        #expect(LightroomImportReport.title(forReason: "camera-profile") == "Camera Profile")
        #expect(LightroomImportReport.title(forReason: nil) == "photos imported with differences")
    }
}
