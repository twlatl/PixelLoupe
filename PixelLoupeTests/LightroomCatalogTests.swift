import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import PixelLoupe

/// Builds small Lightroom-shaped catalogs (a subset of the real schema, as Lightroom Classic 15
/// writes it, without `hasPointColor` so the missing-column path is covered).
nonisolated final class FixtureCatalog {
    let url: URL
    private var db: OpaquePointer?

    init(in directory: URL, name: String = "Test.lrcat", dbVersion: String? = "1504001", wal: Bool = false) throws {
        url = directory.appending(path: name)
        guard sqlite3_open_v2(url.path(percentEncoded: false), &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw SQLiteError(code: 1, message: "cannot create fixture")
        }
        if wal { try run("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0") }
        try run("""
            CREATE TABLE Adobe_variablesTable (id_local INTEGER PRIMARY KEY, id_global, name, type, value);
            CREATE TABLE Adobe_images (
                id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL, captureTime, colorLabels NOT NULL DEFAULT '',
                copyName, fileFormat NOT NULL DEFAULT 'unset', fileHeight, fileWidth, masterImage INTEGER, orientation,
                pick NOT NULL DEFAULT 0, rating, rootFile INTEGER NOT NULL DEFAULT 0, touchTime NOT NULL DEFAULT 0);
            CREATE TABLE AgLibraryFile (
                id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL, baseName NOT NULL DEFAULT '', extension NOT NULL DEFAULT '',
                folder INTEGER NOT NULL DEFAULT 0, md5, modTime, originalFilename NOT NULL DEFAULT '', sidecarExtensions);
            CREATE TABLE AgLibraryFolder (
                id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL, parentId INTEGER, pathFromRoot NOT NULL DEFAULT '',
                rootFolder INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE AgLibraryRootFolder (
                id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL, absolutePath UNIQUE NOT NULL DEFAULT '',
                name NOT NULL DEFAULT '', relativePathFromCatalog);
            CREATE TABLE AgLibraryKeyword (
                id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL, genealogy NOT NULL DEFAULT '', includeOnExport INTEGER NOT NULL DEFAULT 1,
                includeParents INTEGER NOT NULL DEFAULT 1, includeSynonyms INTEGER NOT NULL DEFAULT 1, keywordType, lc_name, name, parent INTEGER);
            CREATE TABLE AgLibraryKeywordImage (id_local INTEGER PRIMARY KEY, image INTEGER NOT NULL DEFAULT 0, tag INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE AgLibraryKeywordSynonym (id_local INTEGER PRIMARY KEY, keyword INTEGER NOT NULL DEFAULT 0, lc_name, name);
            CREATE TABLE AgLibraryCollection (
                id_local INTEGER PRIMARY KEY, creationId NOT NULL DEFAULT '', genealogy NOT NULL DEFAULT '', imageCount,
                name NOT NULL DEFAULT '', parent INTEGER, systemOnly NOT NULL DEFAULT '');
            CREATE TABLE AgLibraryCollectionContent (id_local INTEGER PRIMARY KEY, collection INTEGER NOT NULL DEFAULT 0, content, owningModule);
            CREATE TABLE AgLibraryCollectionImage (
                id_local INTEGER PRIMARY KEY, collection INTEGER NOT NULL DEFAULT 0, image INTEGER NOT NULL DEFAULT 0, pick NOT NULL DEFAULT 0,
                positionInCollection);
            CREATE TABLE Adobe_imageDevelopSettings (
                id_local INTEGER PRIMARY KEY, grayscale INTEGER, hasAIMasks INTEGER NOT NULL DEFAULT 0, hasBigData INTEGER NOT NULL DEFAULT 0,
                hasMasks INTEGER NOT NULL DEFAULT 0, hasDevelopAdjustmentsEx, hasRetouch, image INTEGER, processVersion, text, whiteBalance);
            CREATE TABLE AgLibraryIPTC (id_local INTEGER PRIMARY KEY, caption, copyright, image INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE Adobe_AdditionalMetadata (id_local INTEGER PRIMARY KEY, id_global UNIQUE NOT NULL, image INTEGER, xmp NOT NULL DEFAULT '');
            """)
        if let dbVersion {
            try run("""
                INSERT INTO Adobe_variablesTable (id_global, name, value) VALUES ('1', 'Adobe_DBVersion', '\(dbVersion)');
                INSERT INTO Adobe_variablesTable (id_global, name, value) VALUES ('2', 'Adobe_CrsVersion', '18.0.0');
                """)
        }
    }

    deinit { sqlite3_close(db) }

    func run(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw SQLiteError(code: 1, message: text)
        }
    }

    /// Two folders, three photos (one a virtual copy), keywords with a synonym, a smart collection
    /// and develop settings.
    func populate() throws {
        try run("""
            INSERT INTO AgLibraryRootFolder VALUES (1, 'r1', '/Photos/', 'Photos', NULL);
            INSERT INTO AgLibraryFolder VALUES (1, 'f1', NULL, '', 1), (2, 'f2', 1, '2020/', 1);
            INSERT INTO AgLibraryFile VALUES
                (1, 'file1', 'IMG_0001', 'CR3', 2, 'abc', 1.0, 'IMG_0001.CR3', 'xmp'),
                (2, 'file2', 'IMG_0002', 'DNG', 2, NULL, NULL, 'IMG_0002.DNG', NULL);
            INSERT INTO Adobe_images (id_local, id_global, captureTime, colorLabels, copyName, fileFormat, fileHeight, fileWidth, masterImage, orientation, pick, rating, rootFile, touchTime) VALUES
                (10, 'img10', '2020-05-04T10:30:15', 'Red', NULL, 'RAW', 4000.0, 6000.0, 10, 'AB', 1.0, 4.0, 1, 600000000.5),
                (11, 'img11', '2020-05-04T10:31:00.5', '', 'Copy 1', 'RAW', 4000.0, 6000.0, 10, 'BC', 0.0, NULL, 1, 0),
                (12, 'img12', NULL, '', NULL, 'DNG', NULL, NULL, NULL, NULL, -1.0, 0.0, 2, 0);
            INSERT INTO AgLibraryKeyword VALUES
                (1, 'k1', '/1', 1, 1, 1, NULL, 'animals', 'Animals', NULL),
                (2, 'k2', '/1/2', 1, 0, 1, NULL, 'dog', 'Dog', 1);
            INSERT INTO AgLibraryKeywordSynonym (keyword, lc_name, name) VALUES (2, 'puppy', 'Puppy');
            INSERT INTO AgLibraryKeywordImage (image, tag) VALUES (10, 2), (11, 2), (12, 1);
            INSERT INTO AgLibraryCollection VALUES
                (5, 'com.adobe.ag.library.group', '/5', 0, 'Smart Collections', NULL, ''),
                (6, 'com.adobe.ag.library.smart_collection', '/5/6', 0, 'Five Stars', 5, ''),
                (7, 'com.adobe.ag.library.collection', '/7', 2, 'Trip', NULL, ''),
                (8, 'com.adobe.ag.library.collection', '/8', 1, 'quick collection', NULL, '1.0');
            INSERT INTO AgLibraryCollectionContent (collection, content, owningModule) VALUES
                (6, 's = { { criteria = "rating", operation = "==", value = 5, }, combine = "intersect", }', 'ag.library.smart_collection');
            INSERT INTO AgLibraryCollectionImage (collection, image, positionInCollection) VALUES (7, 11, 2.0), (7, 10, 1.0);
            INSERT INTO Adobe_imageDevelopSettings (image, grayscale, processVersion, text, whiteBalance, hasMasks, hasDevelopAdjustmentsEx, hasRetouch) VALUES
                (10, 0, '11.0', 's = { Exposure2012 = 0.35, ToneCurvePV2012 = { 0, 0, 255, 255, }, }', 'As Shot', 1, 1.0, NULL),
                (12, 1, NULL, NULL, NULL, 0, -1.0, '10000');
            INSERT INTO AgLibraryIPTC (caption, copyright, image) VALUES ('A dog', '© Ted', 10);
            """)
        let xmp = LightroomXMP.encode("<x:xmpmeta><rdf:Description xmp:Rating=\"4\"/></x:xmpmeta>")
        let statement = "INSERT INTO Adobe_AdditionalMetadata (id_global, image, xmp) VALUES ('m10', 10, ?1)"
        var prepared: OpaquePointer?
        sqlite3_prepare_v2(db, statement, -1, &prepared, nil)
        _ = xmp.withUnsafeBytes { sqlite3_bind_blob(prepared, 1, $0.baseAddress, Int32(xmp.count), nil) }
        sqlite3_step(prepared)
        sqlite3_finalize(prepared)
    }
}

@Suite("Lightroom catalog reader")
struct LightroomCatalogTests {
    private func makeCatalog(
        name: String = "Test.lrcat", dbVersion: String? = "1504001", wal: Bool = false
    ) throws -> (TemporaryDirectory, FixtureCatalog) {
        let directory = try TemporaryDirectory()
        let catalog = try FixtureCatalog(in: directory.url, name: name, dbVersion: dbVersion, wal: wal)
        try catalog.populate()
        return (directory, catalog)
    }

    private func checksums(of directory: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted() {
            let url = directory.appending(path: name)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            guard !isDirectory.boolValue else { continue }
            let modified = (try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.modificationDate] as? Date)?
                .timeIntervalSinceReferenceDate ?? 0
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            result[name] = "\(digest) \(modified)"
        }
        return result
    }

    @Test("Reads the version and the core entities")
    func readsEntities() throws {
        let (directory, fixture) = try makeCatalog()
        _ = directory
        let catalog = try LightroomCatalog(url: fixture.url)
        #expect(catalog.version == .init(dbVersion: 1504001, crsVersion: "18.0.0"))
        #expect(catalog.version.lightroomMajor == 15)
        #expect(!catalog.isSnapshot)

        var images: [LRImage] = []
        try catalog.images { images += $0 }
        #expect(images.map(\.id) == [10, 11, 12])
        let first = images[0]
        #expect(first.rating == 4 && first.pick == 1 && first.colorLabels == "Red")
        #expect(first.fileWidth == 6000 && first.fileHeight == 4000 && first.fileFormat == "RAW")
        #expect(first.orientation == "AB" && first.rootFile == 1 && first.touchTime == 600000000.5)
        #expect(!first.isVirtualCopy)
        #expect(first.captureDate == Date(timeIntervalSince1970: 1_588_588_215))
        #expect(images[1].isVirtualCopy && images[1].masterImage == 10 && images[1].copyName == "Copy 1")
        #expect(images[1].captureDate == Date(timeIntervalSince1970: 1_588_588_260.5))
        #expect(images[1].rating == nil)
        #expect(images[2].pick == -1 && images[2].captureTime == nil && images[2].captureDate == nil)

        var files: [LRFile] = []
        try catalog.files { files += $0 }
        #expect(files.map(\.fileName) == ["IMG_0001.CR3", "IMG_0002.DNG"])
        #expect(files[0].sidecarExtensions == "xmp" && files[0].folder == 2)

        #expect(try catalog.rootFolders().first?.absolutePath == "/Photos/")
        #expect(try catalog.folders().map(\.pathFromRoot) == ["", "2020/"])
        #expect(try catalog.folders()[1].parentID == 1)
        #expect(try catalog.rowCount(of: .images) == 3)
        #expect(try catalog.rowCount(of: .faces) == 0)
    }

    @Test("Reads keywords, collections, develop settings and metadata")
    func readsLibraryData() throws {
        let (directory, fixture) = try makeCatalog()
        _ = directory
        let catalog = try LightroomCatalog(url: fixture.url)

        let keywords = try catalog.keywords()
        #expect(keywords.map(\.name) == ["Animals", "Dog"])
        #expect(keywords[1].parent == 1 && keywords[1].genealogy == "/1/2" && !keywords[1].includeParents)
        #expect(try catalog.keywordSynonyms() == [LRKeywordSynonym(keyword: 2, name: "Puppy")])
        var assignments: [LRKeywordAssignment] = []
        try catalog.keywordAssignments { assignments += $0 }
        #expect(assignments.count == 3 && assignments.first == LRKeywordAssignment(image: 10, keyword: 2))

        let collections = try catalog.collections()
        #expect(collections.map(\.kind) == [.set, .smartCollection, .collection, .system("com.adobe.ag.library.collection")])
        let rules = try #require(try catalog.collectionContents().first)
        #expect(rules.collection == 6)
        #expect(try rules.parsed()["combine"]?.string == "intersect")
        #expect(try rules.parsed().table?.array.first?["value"]?.int == 5)
        var members: [LRCollectionImage] = []
        try catalog.collectionImages { members += $0 }
        #expect(members.map(\.image) == [11, 10])
        #expect(members.map(\.positionNumber) == [2, 1])

        var settings: [LRDevelopSettings] = []
        try catalog.developSettings { settings += $0 }
        #expect(settings.map(\.image) == [10, 12])
        let parsed = try #require(try settings[0].parsed())
        #expect(parsed["Exposure2012"]?.number == 0.35)
        #expect(settings[0].processVersion == "11.0" && !settings[0].hasPointColor && !settings[0].hasBigData)
        #expect(settings[1].grayscale)
        #expect(try settings[1].parsed() == nil)

        var metadata: [LRMetadata] = []
        try catalog.metadata { metadata += $0 }
        #expect(metadata.count == 3)
        #expect(metadata[0].caption == "A dog" && metadata[0].copyright == "© Ted")
        #expect(metadata[0].xmpPacket()?.contains("xmp:Rating=\"4\"") == true)
        #expect(metadata[1].caption == nil && metadata[1].xmpPacket() == nil)

        // Tables this fixture doesn't have are simply empty.
        var history = 0
        try catalog.historySteps { history += $0.count }
        try catalog.snapshots { history += $0.count }
        try catalog.faces { history += $0.count }
        #expect(history == 0)
        #expect(try catalog.stacks().isEmpty)
    }

    @Test("Streams in batches")
    func batching() throws {
        let (directory, fixture) = try makeCatalog()
        _ = directory
        let catalog = try LightroomCatalog(url: fixture.url)
        var sizes: [Int] = []
        try catalog.images(batchSize: 2) { sizes.append($0.count) }
        #expect(sizes == [2, 1])
    }

    @Test("Rejects catalogs older than Lightroom Classic 13 with a clear message")
    func oldVersion() throws {
        let (directory, fixture) = try makeCatalog(dbVersion: "1200000")
        _ = directory
        do {
            _ = try LightroomCatalog(url: fixture.url)
            Issue.record("expected an error")
        } catch let error as LightroomCatalogError {
            #expect(error == .unsupportedVersion(dbVersion: 1200000, crsVersion: "18.0.0"))
            #expect(error.localizedDescription.contains("12"))
            #expect(error.localizedDescription.contains("upgrade"))
        }
        let (otherDirectory, thirteen) = try makeCatalog(dbVersion: "1300000")
        _ = otherDirectory
        #expect(try LightroomCatalog(url: thirteen.url).version.lightroomMajor == 13)
    }

    @Test("Rejects files that aren't Lightroom catalogs")
    func notACatalog() throws {
        let directory = try TemporaryDirectory()
        let junk = directory.url.appending(path: "Junk.lrcat")
        try Data("not a database at all".utf8).write(to: junk)
        #expect(throws: LightroomCatalogError.notACatalog(junk)) { try LightroomCatalog(url: junk) }

        let noVersion = try FixtureCatalog(in: directory.url, name: "NoVersion.lrcat", dbVersion: nil)
        #expect(throws: LightroomCatalogError.notACatalog(noVersion.url)) { try LightroomCatalog(url: noVersion.url) }

        let missing = directory.url.appending(path: "Missing.lrcat")
        #expect(throws: LightroomCatalogError.notFound(missing)) { try LightroomCatalog(url: missing) }
    }

    @Test("A catalog open in Lightroom needs the snapshot path, which leaves Lightroom's files untouched")
    func lockedCatalog() throws {
        let (directory, fixture) = try makeCatalog(wal: true)
        // Lightroom's files: a lock file, and a write-ahead log that Lightroom hasn't checkpointed.
        let lock = LightroomCatalog.lockFile(for: fixture.url)
        try Data("lock".utf8).write(to: lock)
        try FileManager.default.createDirectory(
            at: directory.url.appending(path: "Test.lrcat-data"), withIntermediateDirectories: true)
        try Data("blob".utf8).write(to: directory.url.appending(path: "Test.lrcat-data/000001.blob"))
        #expect(FileManager.default.fileExists(atPath: fixture.url.path(percentEncoded: false) + "-wal"))
        // A change that exists only in the WAL.
        try fixture.run("INSERT INTO AgLibraryKeyword VALUES (3, 'k3', '/3', 1, 1, 1, NULL, 'wal only', 'Wal only', NULL)")

        #expect(LightroomCatalog.isOpenInLightroom(fixture.url))
        #expect(throws: LightroomCatalogError.openInLightroom(lockFile: lock)) { try LightroomCatalog(url: fixture.url) }

        let before = try checksums(of: directory.url)
        let dataBefore = try checksums(of: directory.url.appending(path: "Test.lrcat-data"))
        // Let modification times differ measurably if anything were to write.
        Thread.sleep(forTimeInterval: 0.05)

        let snapshotPath: String
        do {
            let catalog = try LightroomCatalog(url: fixture.url, access: .snapshot)
            #expect(catalog.isSnapshot)
            #expect(try catalog.keywords().map(\.name) == ["Animals", "Dog", "Wal only"])
            var count = 0
            try catalog.images { count += $0.count }
            #expect(count == 3)
            snapshotPath = catalog.url.path(percentEncoded: false)
            #expect(snapshotPath == fixture.url.path(percentEncoded: false))
        }

        #expect(try checksums(of: directory.url) == before)
        #expect(try checksums(of: directory.url.appending(path: "Test.lrcat-data")) == dataBefore)
        // The temporary copy is gone once the catalog is released.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path(percentEncoded: false))
            .filter { $0.hasPrefix("PixelLoupe-LightroomSnapshot-") }
        #expect(leftovers.isEmpty)
    }

    @Test("Opening an unlocked catalog doesn't touch its files either")
    func directOpenIsReadOnly() throws {
        let (directory, fixture) = try makeCatalog()
        let before = try checksums(of: directory.url)
        Thread.sleep(forTimeInterval: 0.05)
        do {
            let catalog = try LightroomCatalog(url: fixture.url)
            var count = 0
            try catalog.images { count += $0.count }
            try catalog.developSettings { count += $0.count }
            #expect(count == 5)
        }
        #expect(try checksums(of: directory.url) == before)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.path(percentEncoded: false))
        #expect(names == ["Test.lrcat"])
    }

    /// Point PIXELLOUPE_LR_CATALOG at a .lrcat to run this (xcodebuild: TEST_RUNNER_PIXELLOUPE_LR_CATALOG=…).
    @Test(
        "A real catalog: parse every develop setting",
        .enabled(if: ProcessInfo.processInfo.environment["PIXELLOUPE_LR_CATALOG"] != nil))
    func realCatalog() throws {
        let path = try #require(ProcessInfo.processInfo.environment["PIXELLOUPE_LR_CATALOG"])
        let url = URL(fileURLWithPath: path)
        let access: LightroomCatalogAccess = LightroomCatalog.isOpenInLightroom(url) ? .snapshot : .direct
        let catalog = try LightroomCatalog(url: url, access: access)
        let started = ContinuousClock.now
        var photos = 0
        var parsed = 0
        var failures: [String] = []
        try catalog.developSettings(batchSize: 500) { batch in
            for item in batch {
                photos += 1
                do {
                    if try item.parsed() != nil { parsed += 1 }
                } catch {
                    failures.append("\(item.image): \(error)")
                }
            }
        }
        let elapsed = ContinuousClock.now - started
        print("LR catalog \(url.lastPathComponent): \(photos) settings records, \(parsed) parsed in \(elapsed)")
        #expect(failures.isEmpty, "\(failures.prefix(5))")
        #expect(elapsed < .seconds(10))

        var rules = 0
        for content in try catalog.collectionContents() where content.owningModule?.contains("smart") == true {
            _ = try content.parsed()
            rules += 1
        }
        var steps = 0
        try catalog.historySteps { batch in
            for step in batch { _ = try? step.parsed(); steps += 1 }
        }
        print("  \(rules) smart collection rules, \(steps) history steps")
    }
}
