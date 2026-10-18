import CoreData
import Foundation
import ImageIO
import Testing
import SQLite3
import UniformTypeIdentifiers
@testable import PixelLoupe

/// A throwaway writable SQLite file, for building fixture indexes.
nonisolated final class FixtureDatabase {
    private var db: OpaquePointer?

    init(creating url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path(percentEncoded: false), &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw SQLiteError(code: 1, message: "cannot create fixture database")
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
}

/// Builds `.lrprev` files the way Lightroom lays them out.
enum PreviewFixture {
    static func jpeg(width: Int, height: Int, red: Double = 0.8) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: red, green: 0.3, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private static func block(name: String, flags: UInt32, data: Data, padding: Int) -> Data {
        var block = Data("AgHg".utf8)
        withUnsafeBytes(of: flags.bigEndian) { block.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(data.count).bigEndian) { block.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(padding).bigEndian) { block.append(contentsOf: $0) }
        var nameBytes = Array(name.utf8)
        nameBytes += [UInt8](repeating: 0, count: 8 - nameBytes.count)
        block.append(contentsOf: nameBytes)
        block.append(data)
        block.append(Data(count: padding))
        return block
    }

    /// A preview with levels of the given sizes (smallest first), named level_1…
    static func preview(sizes: [(Int, Int)], cropped: (Int, Int)? = nil, uuid: String = "B2E38E9D-AB94-4062-887D-0E55CDEA1B75") -> Data {
        let levels = sizes.map { "\t\t{\n\t\t\theight = \($0.1),\n\t\t\twidth = \($0.0),\n\t\t},\n" }.joined()
        let crop = cropped.map { "\tcroppedHeight = \($0.1),\n\tcroppedWidth = \($0.0),\n" } ?? ""
        let header = "pyramid = {\n\tcolorProfile = \"sRGB\",\n\(crop)\tlevels = {\n\(levels)\t},\n\tquality = \"bigThumbnail\",\n\tuuid = \"\(uuid)\",\n}\n"
        var file = block(name: "header", flags: 0x200000, data: Data(header.utf8), padding: 6)
        for (index, size) in sizes.enumerated() {
            file.append(block(name: "level_\(index + 1)", flags: 0x200100, data: jpeg(width: size.0, height: size.1), padding: index % 3))
        }
        return file
    }

    @discardableResult
    static func write(_ sizes: [(Int, Int)], cropped: (Int, Int)? = nil, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try preview(sizes: sizes, cropped: cropped).write(to: url)
        return url
    }

    static func size(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}

@Suite("Lightroom previews")
struct LightroomPreviewTests {
    private let sizes = [(80, 60), (400, 300), (800, 600), (1600, 1200)]

    @Test("Reads the levels of a preview file without its pixels")
    func readsLevels() throws {
        let directory = try TemporaryDirectory()
        let url = try PreviewFixture.write(sizes, to: directory.url.appending(path: "p.lrprev"))
        let file = try LightroomPreviewFile.read(at: url)
        #expect(file.levels.map(\.name) == ["level_1", "level_2", "level_3", "level_4"])
        #expect(file.levels.map(\.width) == [80, 400, 800, 1600])
        #expect(file.levels.map(\.height) == [60, 300, 600, 1200])
        // Each level's data really is that JPEG.
        for level in file.levels {
            let data = try file.jpegData(for: level)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            #expect(properties[kCGImagePropertyPixelWidth] as? Int == level.width)
        }
    }

    @Test("Picks the smallest level that is big enough, else the largest")
    func bestLevel() throws {
        let directory = try TemporaryDirectory()
        let file = try LightroomPreviewFile.read(at: try PreviewFixture.write(sizes, to: directory.url.appending(path: "p.lrprev")))
        #expect(file.bestLevel(minimumLongEdge: 768)?.width == 800)
        #expect(file.bestLevel(minimumLongEdge: 400)?.width == 400)
        #expect(file.bestLevel(minimumLongEdge: 2000)?.width == 1600)
        #expect(file.bestLevel(minimumLongEdge: 1)?.width == 80)
    }

    @Test("Rejects files that aren't previews")
    func rejects() throws {
        let directory = try TemporaryDirectory()
        let junk = directory.url.appending(path: "junk.lrprev")
        try Data("this is not a preview file at all, nothing like one".utf8).write(to: junk)
        #expect(throws: LightroomPreviewFile.ReadError.self) { try LightroomPreviewFile.read(at: junk) }
        let empty = directory.url.appending(path: "empty.lrprev")
        try Data().write(to: empty)
        #expect(throws: LightroomPreviewFile.ReadError.self) { try LightroomPreviewFile.read(at: empty) }
        let truncated = directory.url.appending(path: "cut.lrprev")
        try PreviewFixture.preview(sizes: sizes).prefix(40).write(to: truncated)
        #expect(throws: (any Error).self) { try LightroomPreviewFile.read(at: truncated) }
    }

    @Test("Finds a preview from its image's uuid and digest")
    func locations() {
        let catalog = URL(filePath: "/Photos/Lee Family Catalog-v12.lrcat")
        let folder = LightroomPreviews.folder(forCatalog: catalog)
        #expect(folder.path(percentEncoded: false).hasPrefix("/Photos/Lee Family Catalog-v12 Previews.lrdata"))
        let url = LightroomPreviews.previewURL(uuid: "b2e38e9d-ab94-4062-887d-0e55cdea1b75", digest: "7cc1", in: folder)
        #expect(url.path(percentEncoded: false)
            == "/Photos/Lee Family Catalog-v12 Previews.lrdata/B/B2E3/B2E38E9D-AB94-4062-887D-0E55CDEA1B75-7cc1.lrprev")
    }

    @Test("Writes the thumbnail: copied when it fits, scaled and turned otherwise")
    func writesThumbnails() throws {
        let directory = try TemporaryDirectory()
        let url = try PreviewFixture.write(sizes, to: directory.url.appending(path: "p.lrprev"))
        let file = try LightroomPreviewFile.read(at: url)

        // Upright, and the 800-pixel level is within a few percent of 768: byte for byte.
        let copied = directory.url.appending(path: "copied.jpg")
        try LightroomPreviews.writeThumbnail(from: file, orientation: "AB", to: copied)
        #expect(try Data(contentsOf: copied) == file.jpegData(for: file.levels[2]))

        // A level that is too big is scaled to 768.
        let big = try LightroomPreviewFile.read(at: try PreviewFixture.write([(100, 75), (3000, 2000)], to: directory.url.appending(path: "big.lrprev")))
        let scaled = directory.url.appending(path: "scaled.jpg")
        try LightroomPreviews.writeThumbnail(from: big, orientation: "AB", to: scaled)
        let scaledSize = try #require(PreviewFixture.size(of: scaled))
        #expect(scaledSize.width == 768 && scaledSize.height == 512)

        // Lightroom's DA (a quarter turn) swaps width and height; it is re-encoded at the thumbnail size.
        let turned = directory.url.appending(path: "turned.jpg")
        try LightroomPreviews.writeThumbnail(from: file, orientation: "DA", to: turned)
        let turnedSize = try #require(PreviewFixture.size(of: turned))
        #expect(turnedSize.width == 576 && turnedSize.height == 768)
        let flipped = directory.url.appending(path: "flipped.jpg")
        try LightroomPreviews.writeThumbnail(from: file, orientation: "CD", to: flipped)
        #expect(PreviewFixture.size(of: flipped)?.width == 768)

        // A preview saved already turned (portrait levels for a landscape frame) isn't turned again,
        // while one drawn in the photo's own frame is.
        let pre = try LightroomPreviewFile.read(at: try PreviewFixture.write([(300, 400), (600, 800)], cropped: (800, 600), to: directory.url.appending(path: "pre.lrprev")))
        let preTurned = directory.url.appending(path: "pre.jpg")
        try LightroomPreviews.writeThumbnail(from: pre, orientation: "DA", to: preTurned)
        #expect(PreviewFixture.size(of: preTurned).map { $0.width < $0.height } == true)
        let own = try LightroomPreviewFile.read(at: try PreviewFixture.write([(400, 300), (800, 600)], cropped: (800, 600), to: directory.url.appending(path: "own.lrprev")))
        let ownTurned = directory.url.appending(path: "own.jpg")
        try LightroomPreviews.writeThumbnail(from: own, orientation: "DA", to: ownTurned)
        #expect(PreviewFixture.size(of: ownTurned).map { $0.width < $0.height } == true)
        #expect(PreviewFixture.size(of: preTurned)?.height == 800)  // the 800-pixel level, copied as it is

        // With only small levels, the biggest is used as it is.
        let tiny = try LightroomPreviewFile.read(at: try PreviewFixture.write([(40, 30), (200, 150)], to: directory.url.appending(path: "tiny.lrprev")))
        let small = directory.url.appending(path: "small.jpg")
        try LightroomPreviews.writeThumbnail(from: tiny, orientation: nil, to: small)
        #expect(PreviewFixture.size(of: small)?.width == 200)
    }

    @Test("The seeded list appends, loads and shrinks")
    func seededList() throws {
        let directory = try TemporaryDirectory()
        #expect(SeededThumbnails.load(from: directory.url).isEmpty)
        let ids = (0..<5).map { _ in UUID() }
        SeededThumbnails.append(Array(ids[0..<3]), in: directory.url)
        SeededThumbnails.append(Array(ids[3...]), in: directory.url)
        #expect(SeededThumbnails.load(from: directory.url) == Set(ids))
        SeededThumbnails.save(Set(ids[0..<2]), to: directory.url)
        #expect(SeededThumbnails.load(from: directory.url) == Set(ids[0..<2]))
        SeededThumbnails.save([], to: directory.url)
        #expect(SeededThumbnails.load(from: directory.url).isEmpty)
    }
}

@Suite("Lightroom thumbnail seeding")
@MainActor
struct LightroomThumbnailsPhaseTests {
    @Test("Seeds thumbnails from Lightroom's previews, including for photos that are offline")
    func seeds() async throws {
        let fixture = try PhotosFixture()
        // Previews next to the catalog: A (upright), D (offline, turned), E (no entry in the index).
        let previews = fixture.directory.url.appending(path: "Test Previews.lrdata")
        let sizes = [(100, 75), (900, 600)]
        func uuid(_ n: Int) -> String { String(format: "%08X-0000-0000-0000-000000000000", n) }
        for (n, digest) in [(1, "aaaa"), (2, "bbbb")] {
            try PreviewFixture.write(sizes, to: LightroomPreviews.previewURL(uuid: uuid(n), digest: digest, in: previews))
        }
        let index = previews.appending(path: "previews.db")
        let database = try FixtureDatabase(creating: index)
        try database.run("""
            CREATE TABLE ImageCacheEntry ( imageId NOT NULL, uuid NOT NULL, digest NOT NULL, orientation );
            INSERT INTO ImageCacheEntry VALUES (10, '\(uuid(1))', 'aaaa', 'AB'), (13, '\(uuid(2))', 'bbbb', 'DA'), (99, '\(uuid(3))', 'cccc', 'AB');
            """)
        _ = database

        let (store, report) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }, { LightroomThumbnailsPhase() }])
        let photos = Dictionary(try store.viewContext.fetch(Photo.fetchRequest()).filter { !$0.isVirtualCopy }.map { ($0.fileName, $0) }) { first, _ in first }
        let directory = store.thumbnails.directory

        let a = try #require(photos["A.jpg"]), d = try #require(photos["D.cr2"])
        let aThumbnail = ThumbnailStore.url(for: a.id, in: directory)
        let dThumbnail = ThumbnailStore.url(for: d.id, in: directory)
        #expect(FileManager.default.fileExists(atPath: aThumbnail.path(percentEncoded: false)))
        #expect(PreviewFixture.size(of: aThumbnail)?.width == 768)
        // D's file is offline but keeps its Lightroom preview, turned to portrait.
        let dSize = try #require(PreviewFixture.size(of: dThumbnail))
        #expect(dSize.height == 768 && dSize.width < dSize.height)
        // Photos without an index entry get none yet; a preview for an image that wasn't imported is ignored.
        for name in ["B.jpg", "E.jpg"] {
            let photo = try #require(photos[name])
            #expect(!FileManager.default.fileExists(atPath: ThumbnailStore.url(for: photo.id, in: directory).path(percentEncoded: false)))
        }

        #expect(SeededThumbnails.load(from: directory) == [a.id, d.id])
        #expect(report.imported.contains(.init(title: "Thumbnails from Lightroom previews", count: 2)))
        #expect(report.warnings.contains { $0.contains("4 photos have no Lightroom preview") })
    }

    @Test("A catalog without previews is imported with a warning")
    func noPreviews() async throws {
        let fixture = try PhotosFixture()
        let (_, report) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }, { LightroomThumbnailsPhase() }])
        #expect(report.warnings.contains { $0.contains("No Lightroom previews were found") })
    }
}

@Suite("Thumbnail maintenance")
@MainActor
struct ThumbnailMaintenanceTests {
    @Test("Draws missing thumbnails and redraws seeded ones that have edits; leaves the rest")
    func maintains() async throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let context = store.viewContext
        func photo(_ name: String, exists: Bool = true, edited: Bool = false) throws -> Photo {
            let url = directory.url.appending(path: name)
            if exists { try Fixtures.writeJPEG(to: url, width: 1200, height: 800) }
            let photo = Photo(context: context)
            photo.id = UUID()
            photo.fileName = name
            photo.filePath = url.path(percentEncoded: false)
            photo.captureDate = Date()
            photo.importDate = Date()
            photo.editDate = Date()
            if edited {
                var adjustments = PhotoAdjustments()
                adjustments.orientation = .init(quarterTurns: 1, isMirrored: false)
                photo.adjustments = adjustments
            }
            return photo
        }
        let thumbnails = store.thumbnails.directory
        func lightroomCopy(for photo: Photo) throws {
            try PreviewFixture.jpeg(width: 768, height: 512).write(to: ThumbnailStore.url(for: photo.id, in: thumbnails))
        }

        let missing = try photo("missing-thumb.jpg")                      // no thumbnail: drawn
        let seededEdited = try photo("seeded-edited.jpg", edited: true)   // Lightroom copy + edits: redrawn
        let seededPlain = try photo("seeded-plain.jpg")                   // Lightroom copy, no edits: kept
        let offline = try photo("offline.jpg", exists: false)             // file gone: left alone
        let offlineSeeded = try photo("offline-seeded.jpg", exists: false, edited: true)
        try context.save()
        for photo in [seededEdited, seededPlain, offlineSeeded] { try lightroomCopy(for: photo) }
        SeededThumbnails.append([seededEdited.id, seededPlain.id, offlineSeeded.id], in: thumbnails)
        let plainBefore = try Data(contentsOf: ThumbnailStore.url(for: seededPlain.id, in: thumbnails))
        let offlineBefore = try Data(contentsOf: ThumbnailStore.url(for: offlineSeeded.id, in: thumbnails))

        store.thumbnailMaintenance.start(after: .zero)
        await store.thumbnailMaintenance.waitUntilIdle()

        func url(_ photo: Photo) -> URL { ThumbnailStore.url(for: photo.id, in: thumbnails) }
        func exists(_ photo: Photo) -> Bool { FileManager.default.fileExists(atPath: url(photo).path(percentEncoded: false)) }
        #expect(exists(missing))
        #expect(PreviewFixture.size(of: url(missing))?.width == 768)
        // The edit (a quarter turn) was rendered by PixelLoupe: portrait now.
        let redrawn = try #require(PreviewFixture.size(of: url(seededEdited)))
        #expect(redrawn.height > redrawn.width)
        #expect(try Data(contentsOf: url(seededPlain)) == plainBefore)
        #expect(!exists(offline))
        #expect(try Data(contentsOf: url(offlineSeeded)) == offlineBefore)
        // Done ones leave the seeded list; the ones still waiting stay.
        #expect(SeededThumbnails.load(from: thumbnails) == [seededPlain.id, offlineSeeded.id])
    }
}
