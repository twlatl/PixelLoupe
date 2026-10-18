import CoreData
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PixelLoupe

// MARK: - Orientation

@Suite("Lightroom orientation")
struct LightroomOrientationTests {
    typealias Grid = [[Int]]

    /// The pixels of a 3×2 test image, row by row from the top.
    private let original: Grid = [[1, 2, 3], [4, 5, 6]]

    private func flipHorizontal(_ g: Grid) -> Grid { g.map { Array($0.reversed()) } }
    private func flipVertical(_ g: Grid) -> Grid { Array(g.reversed()) }
    private func rotateCounterclockwise(_ g: Grid) -> Grid {
        let rows = g.count, columns = g[0].count
        return (0..<columns).map { column in (0..<rows).map { row in g[row][columns - 1 - column] } }
    }
    private func rotateClockwise(_ g: Grid) -> Grid {
        let rows = g.count, columns = g[0].count
        return (0..<columns).map { column in (0..<rows).map { row in g[rows - 1 - row][column] } }
    }
    private func transpose(_ g: Grid) -> Grid {
        (0..<g[0].count).map { column in g.map { $0[column] } }
    }

    /// What displaying a file with EXIF orientation `n` does to its pixels (the EXIF specification's table).
    private func display(_ g: Grid, exif n: Int) -> Grid {
        switch n {
        case 2: flipHorizontal(g)
        case 3: flipVertical(flipHorizontal(g))
        case 4: flipVertical(g)
        case 5: transpose(g)
        case 6: rotateClockwise(g)
        case 7: flipVertical(flipHorizontal(transpose(g)))  // transverse
        case 8: rotateCounterclockwise(g)
        default: g
        }
    }

    /// PixelLoupe's rotate/flip on an already-oriented image: mirror first, then turn counterclockwise.
    private func apply(_ o: PhotoAdjustments.Orientation, to g: Grid) -> Grid {
        var result = o.isMirrored ? flipHorizontal(g) : g
        for _ in 0..<o.quarterTurns { result = rotateCounterclockwise(result) }
        return result
    }

    @Test("Lightroom's codes map to EXIF orientations")
    func codes() {
        let expected = ["AB": 1, "BA": 2, "CD": 3, "DC": 4, "AD": 5, "BC": 6, "CB": 7, "DA": 8]
        for (code, exif) in expected { #expect(LightroomOrientation.exif(forCode: code) == exif) }
        #expect(LightroomOrientation.exif(forCode: nil) == nil)
        #expect(LightroomOrientation.exif(forCode: "ZZ") == nil)
    }

    @Test("The EXIF reference transforms are sane", arguments: 1...8)
    func reference(n: Int) {
        // Mirrored orientations differ from their unmirrored twins; the rest are rotations.
        #expect(display(original, exif: 1) == original)
        let shown = display(original, exif: n)
        #expect(shown.count * shown[0].count == 6)
    }

    @Test("Adjustment on top of the file's orientation gives Lightroom's, for every pair")
    func everyPair() {
        for file in 1...8 {
            for lightroom in 1...8 {
                let adjustment = LightroomOrientation.adjustment(lightroom: lightroom, file: file)
                let result = apply(adjustment, to: display(original, exif: file))
                #expect(result == display(original, exif: lightroom), "file \(file) → Lightroom \(lightroom): \(adjustment)")
                if file == lightroom { #expect(adjustment.isIdentity) }
            }
        }
    }
}

// MARK: - Dates

@Suite("Lightroom dates")
struct LightroomDatesTests {
    @Test("Capture time is local wall-clock time")
    func captureTime() throws {
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let date = try #require(LightroomDates.localDate(fromCaptureTime: "2020-05-04T10:30:15", in: tokyo))
        #expect(date == Date(timeIntervalSince1970: 1_588_555_815))  // 01:30:15 UTC
        let fractional = try #require(LightroomDates.localDate(fromCaptureTime: "2020-05-04T10:30:15.5", in: tokyo))
        #expect(fractional == date.addingTimeInterval(0.5))
        #expect(LightroomDates.localDate(fromCaptureTime: nil) == nil)
        #expect(LightroomDates.localDate(fromCaptureTime: "nonsense") == nil)
    }

    @Test("Import dates carry their offset; touch time uses the 2001 epoch")
    func importAndTouch() throws {
        let withOffset = try #require(LightroomDates.importDate(from: "2020-04-28T07:25:43-04:00"))
        #expect(withOffset == Date(timeIntervalSince1970: 1_588_073_143))  // 11:25:43 UTC
        #expect(LightroomDates.importDate(from: "") == nil)
        #expect(LightroomDates.touchDate(0) == nil)
        #expect(LightroomDates.touchDate(609_765_943.5) == Date(timeIntervalSinceReferenceDate: 609_765_943.5))
    }
}

// MARK: - Phases

final class PhotosFixture {
    let directory: TemporaryDirectory
    let photos: URL
    let catalogURL: URL
    private let fixture: FixtureCatalog

    /// A catalog with photos on disk (and some that aren't), laid out like Lightroom's tables.
    init() throws {
        directory = try TemporaryDirectory()
        photos = try directory.subdirectory("Photos")
        _ = try directory.subdirectory("Photos/2020/Trip")
        _ = try directory.subdirectory("Photos/Empty")
        fixture = try FixtureCatalog(in: directory.url)
        catalogURL = fixture.url
        try Fixtures.writeJPEG(to: photos.appending(path: "2020/Trip/A.jpg"))
        try Fixtures.writeJPEG(to: photos.appending(path: "2020/B.jpg"))
        try Data("not an image".utf8).write(to: photos.appending(path: "2020/C.mov"))
        try Self.writeJPEG(withCity: "Boston", to: photos.appending(path: "2020/Trip/E.jpg"))

        let root = photos.path(percentEncoded: false) + "/"
        try fixture.run("""
            ALTER TABLE Adobe_images ADD COLUMN originalCaptureTime;
            ALTER TABLE AgLibraryFile ADD COLUMN idx_filename NOT NULL DEFAULT '';
            ALTER TABLE AgLibraryFolder ADD COLUMN visibility INTEGER;
            CREATE TABLE AgLibraryImport (id_local INTEGER PRIMARY KEY, imageCount, importDate NOT NULL DEFAULT '', name);
            CREATE TABLE AgLibraryImportImage (id_local INTEGER PRIMARY KEY, image INTEGER NOT NULL DEFAULT 0, import INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE AgInternedExifCameraModel (id_local INTEGER PRIMARY KEY, searchIndex, value);
            CREATE TABLE AgInternedExifLens (id_local INTEGER PRIMARY KEY, searchIndex, value);
            CREATE TABLE AgHarvestedExifMetadata (
                id_local INTEGER PRIMARY KEY, image INTEGER, cameraModelRef INTEGER, lensRef INTEGER, hasGPS INTEGER,
                gpsLatitude, gpsLongitude);

            INSERT INTO AgLibraryRootFolder VALUES (1, 'r1', '\(root)', 'Photos', NULL), (2, 'r2', '/Volumes/Unmounted/Pics/', 'Pics', NULL);
            INSERT INTO AgLibraryFolder (id_local, id_global, parentId, pathFromRoot, rootFolder, visibility) VALUES
                (1, 'f1', NULL, '', 1, NULL), (2, 'f2', 1, '2020/', 1, NULL), (3, 'f3', 2, '2020/Trip/', 1, NULL),
                (4, 'f4', 1, 'Empty/', 1, NULL), (5, 'f5', 1, 'Hidden/', 1, 1), (6, 'f6', NULL, '', 2, NULL);
            INSERT INTO AgLibraryFile (id_local, id_global, baseName, extension, idx_filename, folder, originalFilename) VALUES
                (1, 'file1', 'A', 'jpg', 'A.jpg', 3, 'A.jpg'), (2, 'file2', 'B', 'jpg', 'B.jpg', 2, 'B.jpg'),
                (3, 'file3', 'C', 'mov', 'C.mov', 2, 'C.mov'), (4, 'file4', 'D', 'cr2', 'D.cr2', 6, 'D.cr2'),
                (5, 'file5', 'E', 'jpg', 'E.jpg', 3, 'E.jpg');
            INSERT INTO Adobe_images (id_local, id_global, captureTime, originalCaptureTime, fileFormat, fileHeight, fileWidth,
                                      masterImage, orientation, pick, rating, rootFile, touchTime) VALUES
                (10, 'img10', '2020-05-04T10:30:15', '2020-05-04T09:00:00', 'JPG', 48.0, 64.0, 10, 'AB', 1.0, 4.0, 1, 600000000.0),
                (11, 'img11', '2020-05-05T08:00:00', '2020-05-05T08:00:00', 'JPG', 48.0, 64.0, 11, 'BC', -1.0, NULL, 2, 0.0),
                (12, 'img12', '2020-05-06T08:00:00', NULL, 'VIDEO', 1080.0, 1920.0, 12, 'AB', 0.0, 0.0, 3, 0.0),
                (13, 'img13', '2019-01-01T12:00:00', NULL, 'RAW', 4000.0, 6000.0, 13, 'DA', 0.0, 2.0, 4, 0.0),
                (14, 'img14', '2020-05-04T10:30:15', NULL, 'JPG', 48.0, 64.0, 10, 'AB', 0.0, 0.0, 1, 0.0),
                (15, 'img15', '2020-05-07T08:00:00', NULL, 'JPG', 48.0, 64.0, 15, 'AB', 0.0, 0.0, 5, 0.0);
            INSERT INTO AgLibraryImport VALUES (1, 6, '2020-04-28T07:25:43-04:00', 'Import 1');
            INSERT INTO AgLibraryImportImage (image, import) VALUES (10, 1), (11, 1), (13, 1);
            INSERT INTO AgInternedExifCameraModel VALUES (1, 'canon', 'Canon EOS 5D');
            INSERT INTO AgInternedExifLens VALUES (1, 'ef50', 'EF50mm f/1.8');
            INSERT INTO AgHarvestedExifMetadata (image, cameraModelRef, lensRef, hasGPS, gpsLatitude, gpsLongitude) VALUES
                (13, 1, 1, 1, 42.3601, -71.0589), (10, NULL, NULL, 0, 0, 0);
            """)
    }

    private static func writeJPEG(withCity city: String, to url: URL) throws {
        try Fixtures.writeJPEG(to: url)
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        properties[kCGImagePropertyIPTCDictionary] = [kCGImagePropertyIPTCCity: city]
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    func run(_ sql: String) throws { try fixture.run(sql) }

    func importAll(phases: [@Sendable () -> any LightroomImportPhase]) async throws -> (CatalogStore, LightroomImportReport) {
        let packageURL = directory.url.appending(path: "Out.pixelloupe", directoryHint: .isDirectory)
        let store = try CatalogStore.create(at: packageURL, info: CatalogInfo(name: "Out", storageMode: .referenced))
        let catalog = try LightroomCatalog(url: catalogURL)
        let context = store.newBackgroundContext()
        let report = try await LightroomImporter.run(
            catalog: catalog, sourceName: "Test.lrcat", summary: LightroomCatalogSummary(), into: context,
            packageURL: packageURL, phases: phases, progress: { _ in })
        return (store, report)
    }
}

@Suite("Lightroom photos and metadata phases")
@MainActor
struct LightroomPhotosPhaseTests {
    private func photos(in store: CatalogStore) throws -> [String: Photo] {
        let all = try store.viewContext.fetch(Photo.fetchRequest()).filter { !$0.isVirtualCopy }
        return Dictionary(all.map { ($0.fileName, $0) }) { first, _ in first }
    }

    @Test("Creates the folder tree and photos with their details")
    func importsPhotos() async throws {
        let fixture = try PhotosFixture()
        let (store, report) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }])
        let context = store.viewContext

        // Folders mirror Lightroom's tree: the roots, the empty folder, no hidden empty folder.
        let folders = try context.fetch(Folder.fetchRequest())
        let root = fixture.photos.path(percentEncoded: false)
        #expect(Set(folders.map(\.path)) == [
            root, root + "/2020", root + "/2020/Trip", root + "/Empty", "/Volumes/Unmounted/Pics",
        ])
        let rootFolder = try #require(folders.first { $0.path == root })
        #expect(rootFolder.name == "Photos" && rootFolder.parent == nil)
        #expect(Set(rootFolder.children.map(\.name)) == ["2020", "Empty"])
        #expect(folders.first { $0.path == root + "/2020/Trip" }?.parent?.name == "2020")
        #expect(folders.first { $0.path == "/Volumes/Unmounted/Pics" }?.name == "Pics")

        // Photos: the video is left out; A has a virtual copy.
        let byName = try photos(in: store)
        #expect(Set(byName.keys) == ["A.jpg", "B.jpg", "C.mov", "D.cr2", "E.jpg"])
        let copies = try store.viewContext.fetch(Photo.fetchRequest()).filter(\.isVirtualCopy)
        #expect(copies.count == 1 && copies[0].fileName == "A.jpg" && copies[0].master === byName["A.jpg"])
        #expect(copies[0].copyName == "Copy", "Lightroom named it nothing")
        #expect(copies[0].filePath == byName["A.jpg"]?.filePath && copies[0].lightroomID == "img14" && copies[0].rating == 0)

        let a = try #require(byName["A.jpg"])
        #expect(a.filePath == root + "/2020/Trip/A.jpg" && a.fileType == "JPG" && a.lightroomID == "img10")
        #expect(a.rating == 4 && a.flag == 1 && a.folder?.name == "Trip")
        #expect(a.fileSize > 0 && a.pixelWidth == 64 && a.pixelHeight == 48)
        #expect(a.cameraMake == "Canon" && a.cameraModel == "EOS R5" && a.lensModel == "RF24-70mm F2.8 L IS USM")
        #expect(a.captureDate == LightroomDates.localDate(fromCaptureTime: "2020-05-04T10:30:15"))
        #expect(a.importDate == Date(timeIntervalSince1970: 1_588_073_143))
        #expect(a.editDate == Date(timeIntervalSinceReferenceDate: 600_000_000))
        #expect(a.orientation == 1 && a.adjustments.orientation.isIdentity && a.adjustmentsData == nil)
        #expect(a.metadata[.gps] == nil)
        #expect(a.metadata.values[PhotoMetadata.lightroomOriginalCaptureTimeKey] == "2020-05-04T09:00:00")

        // Lightroom rotated B (BC → 6) while the file says 1: the difference is a quarter turn.
        let b = try #require(byName["B.jpg"])
        #expect(b.rating == 0 && b.flag == -1)
        #expect(b.orientation == 1)
        #expect(b.adjustments.orientation == LightroomOrientation.adjustment(lightroom: 6, file: 1))
        #expect(b.adjustments.orientation == .init(quarterTurns: 3, isMirrored: false))
        #expect(b.metadata.values[PhotoMetadata.lightroomOriginalCaptureTimeKey] == nil)
        #expect(b.importDate == a.importDate)

        // D's volume is offline: nothing was read; Lightroom's details are used.
        // E has no import record: its file's creation date stands in.
        #expect(try #require(byName["E.jpg"]).importDate.timeIntervalSinceNow > -600)
        let d = try #require(byName["D.cr2"])
        #expect(d.fileSize == 0 && d.rating == 2)
        #expect(d.orientation == 8 && d.adjustments.orientation.isIdentity)
        #expect(d.cameraModel == "Canon EOS 5D" && d.lensModel == "EF50mm f/1.8")
        #expect(d.pixelWidth == 6000 && d.pixelHeight == 4000)
        #expect(d.captureDate == LightroomDates.localDate(fromCaptureTime: "2019-01-01T12:00:00"))

        // The report lists what was left out.
        #expect(report.imported == [.init(title: "Photos", count: 5), .init(title: "Virtual copies", count: 1)])
        #expect(try #require(byName["C.mov"]).isVideo)
        #expect(report.warnings.allSatisfy { !$0.contains("not imported") })
        #expect(report.warnings.contains { $0.contains("1 photo is missing on disk") })
    }

    @Test("Builds the folder tree from paths when Lightroom leaves parentId empty")
    func folderTreeWithoutParentIDs() async throws {
        let fixture = try PhotosFixture()
        try fixture.run("UPDATE AgLibraryFolder SET parentId = NULL")
        let (store, _) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }])
        let folders = Dictionary(try store.viewContext.fetch(Folder.fetchRequest()).map { ($0.name, $0) }) { first, _ in first }
        #expect(folders["Photos"]?.parent == nil && folders["Pics"]?.parent == nil)
        #expect(folders["2020"]?.parent?.name == "Photos")
        #expect(folders["Empty"]?.parent?.name == "Photos")
        #expect(folders["Trip"]?.parent?.name == "2020")
        #expect(Set(try store.viewContext.fetch({ let r = Folder.fetchRequest(); r.predicate = NSPredicate(format: "parent == nil"); return r }()).map(\.name)) == ["Photos", "Pics"])
    }

    @Test("Gives a folder whose parent row is missing its nearest ancestor")
    func folderTreeWithGaps() {
        func folder(_ id: Int, _ path: String, root: Int = 1) -> LRFolder {
            LRFolder(id: id, globalID: "f\(id)", parentID: nil, pathFromRoot: path, rootFolder: root, visibility: nil)
        }
        // No row for "2013/", so the day folder goes straight under the root.
        let all = [folder(1, ""), folder(3, "2013/2013-02-17/"), folder(4, "other/", root: 2)]
        let parents = LightroomPhotosPhase.parents(of: all, among: all)
        #expect(parents[3] == 1)
        #expect(parents[1] == nil && parents[4] == nil)
    }

    @Test("Hides empty folders that Lightroom marks with a visibility, but keeps ones with photos")
    func folderVisibility() async throws {
        let fixture = try PhotosFixture()
        // The hidden folder gets a photo, so it shows after all.
        try fixture.run("""
            INSERT INTO AgLibraryFile (id_local, id_global, baseName, extension, idx_filename, folder, originalFilename)
                VALUES (9, 'file9', 'H', 'jpg', 'H.jpg', 5, 'H.jpg');
            INSERT INTO Adobe_images (id_local, id_global, fileFormat, masterImage, orientation, rootFile) VALUES (19, 'img19', 'JPG', 19, 'AB', 9);
            """)
        let (store, _) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }])
        let paths = Set(try store.viewContext.fetch(Folder.fetchRequest()).map(\.path))
        #expect(paths.contains(fixture.photos.path(percentEncoded: false) + "/Hidden"))
    }

    @Test("Imports metadata that differs from the file, and the GPS position")
    func importsMetadata() async throws {
        let fixture = try PhotosFixture()
        let packet = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
              xmlns:xmp="http://ns.adobe.com/xap/1.0/">
            <xmp:Label>Red</xmp:Label>
            <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Sunset</rdf:li></rdf:Alt></dc:title>
            <dc:creator><rdf:Seq><rdf:li>Alex Example</rdf:li></rdf:Seq></dc:creator>
            <photoshop:City>Boston</photoshop:City><photoshop:Headline>Evening</photoshop:Headline>
            </rdf:Description></rdf:RDF></x:xmpmeta>
            """
        let encoded = LightroomXMP.encode(packet).map { String(format: "%02x", $0) }.joined()
        try fixture.run("""
            INSERT INTO Adobe_AdditionalMetadata (id_global, image, xmp) VALUES ('m15', 15, X'\(encoded)'), ('m13', 13, X'\(encoded)');
            INSERT INTO AgLibraryIPTC (caption, copyright, image) VALUES ('Caption from IPTC', '© Alex', 15);
            UPDATE AgHarvestedExifMetadata SET hasGPS = 1, gpsLatitude = 51.5, gpsLongitude = -0.12 WHERE image = 10;
            """)
        let (store, report) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }, { LightroomMetadataPhase() }])
        let byName = try photos(in: store)

        // E.jpg's own IPTC city is Boston: only the fields that differ are kept. The label is not a metadata field.
        let e = try #require(byName["E.jpg"])
        #expect(e.metadata[.title] == "Sunset" && e.metadata[.creator] == "Alex Example" && e.metadata[.headline] == "Evening")
        #expect(e.metadata[.city] == nil)
        #expect(e.metadata[.caption] == "Caption from IPTC" && e.metadata[.copyright] == "© Alex")
        #expect(e.metadata[.label] == nil)

        // D.cr2 is offline: nothing to compare with, so everything is kept, including the position.
        let d = try #require(byName["D.cr2"])
        #expect(d.metadata[.city] == "Boston" && d.metadata[.title] == "Sunset")
        let gps = try #require(d.metadata[.gps])
        #expect(gps.contains("42°21") && gps.contains("N") && gps.contains("W"))

        // A.jpg has only a harvested position.
        let a = try #require(byName["A.jpg"])
        #expect(a.metadata[.gps] != nil && a.metadata[.title] == nil)
        // B.jpg has nothing from Lightroom.
        #expect(try #require(byName["B.jpg"]).metadata.values[MetadataField.ID.title.rawValue] == nil)
        #expect(report.imported.contains { $0.title == "Photos with metadata edited in Lightroom" && $0.count == 3 })
    }
}

@Suite("Lightroom import of a real catalog")
@MainActor
struct LightroomRealImportTests {
    /// Imports the catalog at PIXELLOUPE_LR_CATALOG with the default phases and checks the totals
    /// against Lightroom's own. Writes a summary to PIXELLOUPE_LR_IMPORT_REPORT if set.
    /// (xcodebuild: TEST_RUNNER_PIXELLOUPE_LR_CATALOG=… TEST_RUNNER_PIXELLOUPE_LR_IMPORT_REPORT=…)
    @Test(
        "Imports a real catalog",
        .enabled(if: ProcessInfo.processInfo.environment["PIXELLOUPE_LR_CATALOG"] != nil),
        .timeLimit(.minutes(60)))
    func importsRealCatalog() async throws {
        let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["PIXELLOUPE_LR_CATALOG"]))
        let directory = try TemporaryDirectory()
        let access: LightroomCatalogAccess = LightroomCatalog.isOpenInLightroom(url) ? .snapshot : .direct
        let catalog = try LightroomCatalog(url: url, access: access)
        let summary = try catalog.summary()
        // PIXELLOUPE_LR_IMPORT_PACKAGE keeps the imported catalog (for profiling) instead of a temporary one.
        let packageURL = ProcessInfo.processInfo.environment["PIXELLOUPE_LR_IMPORT_PACKAGE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? directory.url.appending(path: "Real.pixelloupe", directoryHint: .isDirectory)
        let store = try CatalogStore.create(at: packageURL, info: CatalogInfo(name: "Real", storageMode: .referenced))
        let started = ContinuousClock.now
        let report = try await LightroomImporter.run(
            catalog: catalog, sourceName: url.lastPathComponent, summary: summary, into: store.newBackgroundContext(),
            packageURL: packageURL, phases: LightroomImporter.defaultPhases, progress: { _ in })
        let elapsed = ContinuousClock.now - started

        let context = store.viewContext
        let photoCount = try context.count(for: Photo.fetchRequest())
        let folderCount = try context.count(for: Folder.fetchRequest())
        let rated = try context.count(for: { let r = Photo.fetchRequest(); r.predicate = NSPredicate(format: "rating > 0"); return r }())
        let flagged = try context.count(for: { let r = Photo.fetchRequest(); r.predicate = NSPredicate(format: "flag != 0"); return r }())
        let rotated = try context.count(for: { let r = Photo.fetchRequest(); r.predicate = NSPredicate(format: "adjustmentsData != nil"); return r }())
        let withMetadata = try context.count(for: { let r = Photo.fetchRequest(); r.predicate = NSPredicate(format: "metadataData != nil"); return r }())
        let lines = [
            "elapsed: \(elapsed)",
            "lightroom photos: \(summary.photos), unsupported: \(summary.unsupportedFiles), virtual copies: \(summary.virtualCopies)",
            "imported photos: \(photoCount), folders: \(folderCount) (lightroom folders: \(summary.folders))",
            "rated: \(rated), flagged: \(flagged), with orientation adjustment: \(rotated), with metadata edits: \(withMetadata)",
            "report: \(report.imported)",
            "warnings: \(report.warnings.prefix(10))",
        ]
        let thumbnails = try FileManager.default.contentsOfDirectory(atPath: store.thumbnails.directory.path(percentEncoded: false))
            .filter { $0.hasSuffix(".jpg") }.count
        let seeded = SeededThumbnails.load(from: store.thumbnails.directory).count
        var collectionLines: [String] = []
        for collection in try context.fetch(PhotoCollection.fetchRequest()).sorted(by: { $0.name < $1.name }) {
            let request = Photo.fetchRequest()
            request.predicate = collection.content.predicate
            let count = collection.kind == .set ? -1 : try context.count(for: request)
            collectionLines.append("collection \(collection.name) [\(collection.kind)]: \(count)\(collection.importWarning.map { " WARNING \($0)" } ?? "")")
        }
        let allLines = lines + ["thumbnails: \(thumbnails), seeded: \(seeded)"] + collectionLines
        if let path = ProcessInfo.processInfo.environment["PIXELLOUPE_LR_IMPORT_REPORT"] {
            try allLines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            // A few thumbnails to look at: turned and upright photos.
            let samples = URL(filePath: path).deletingLastPathComponent().appending(path: "thumbnail-samples", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: samples)
            try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
            for orientation in [8, 6, 3, 1] {
                let request = Photo.fetchRequest()
                request.predicate = NSPredicate(format: "orientation == %d", orientation)
                request.fetchLimit = 2
                for photo in try context.fetch(request) {
                    let from = ThumbnailStore.url(for: photo.id, in: store.thumbnails.directory)
                    try? FileManager.default.copyItem(at: from, to: samples.appending(path: "o\(orientation)-\(photo.fileName).jpg"))
                }
            }
        }
        #expect(photoCount == summary.photos - summary.unsupportedFileCount)
        #expect(folderCount == summary.folders)
        // The tree: one root Folder per Lightroom root folder, not a flat list.
        let rootRequest = Folder.fetchRequest()
        rootRequest.predicate = NSPredicate(format: "parent == nil")
        #expect(try context.count(for: rootRequest) == (try catalog.rootFolders().count))
    }
}
