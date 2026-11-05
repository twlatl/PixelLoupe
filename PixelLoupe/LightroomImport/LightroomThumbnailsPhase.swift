import Foundation

/// Seeds the new catalog's thumbnails from Lightroom's own previews, which already show the user's
/// edits, without reading any original file. It finishes in seconds for a catalog of 55,000 photos
/// and works for photos on an unplugged drive.
///
/// Seeded thumbnails are noted in ``SeededThumbnails`` so ``ThumbnailMaintenance`` can later redraw
/// the ones whose edits PixelLoupe renders itself. Photos without a Lightroom preview get theirs from
/// the original in the background, when the catalog is open.
nonisolated final class LightroomThumbnailsPhase: LightroomImportPhase {
    let title = "Importing thumbnails"

    private static let batchSize = 400
    private static let maximumConcurrentWrites = 8

    private var cursor: LightroomRowCursor<LightroomPreviews.Entry>?
    private var database: SQLiteDatabase?
    private var previewsFolder: URL?
    /// Lightroom Classic 15's per-level previews, by `uuid-digest`; nil for an older previews folder.
    private var pyramids: [String: Pyramid]?
    private var seeded = 0
    private var lowResolution = 0
    private var unreadable = 0

    func prepare(_ context: LightroomImportContext) async throws -> Int {
        let folder = LightroomPreviews.folder(forCatalog: context.catalog.url)
        let indexURL = folder.appending(path: "previews.db")
        guard FileManager.default.fileExists(atPath: indexURL.path(percentEncoded: false)),
              let database = try? SQLiteDatabase(readingFrom: indexURL, immutable: true),
              let statement = try? database.prepare("SELECT imageId, uuid, digest, orientation FROM ImageCacheEntry ORDER BY imageId"),
              let count = try? database.scalarInt("SELECT COUNT(*) FROM ImageCacheEntry") else {
            context.report.addWarning("No Lightroom previews were found next to the catalog, so thumbnails are made from the original photos.")
            return 0
        }
        self.database = database
        previewsFolder = folder
        if (try? database.hasTable("PyramidLevel")) == true {
            pyramids = Self.loadPyramids(database)
        }
        cursor = LightroomRowCursor(statement: statement) { row in
            LightroomPreviews.Entry(
                imageID: row.int(at: 0) ?? 0, uuid: row.string(at: 1) ?? "", digest: row.string(at: 2) ?? "", orientation: row.string(at: 3))
        }
        return count
    }

    func importBatch(_ context: LightroomImportContext) async throws -> Int {
        guard let cursor, let previewsFolder else { return 0 }
        let entries = try cursor.next(Self.batchSize)
        guard !entries.isEmpty else { return 0 }
        let directory = CatalogPackage.thumbnailsURL(in: context.packageURL)

        var jobs: [Job] = []
        for entry in entries {
            guard let photoID = context.idMap.photoID(forLightroomID: entry.imageID) else { continue }
            let preview: Preview
            if let pyramids {
                guard let pyramid = pyramids[entry.uuid.uppercased() + "-" + entry.digest],
                      let file = LightroomPreviewFile.levels(
                        uuid: entry.uuid, digest: entry.digest, levels: pyramid.levels, cropped: pyramid.cropped, in: previewsFolder)
                else { continue }
                preview = .levels(file)
            } else {
                preview = .lrprev(LightroomPreviews.previewURL(uuid: entry.uuid, digest: entry.digest, in: previewsFolder))
            }
            jobs.append(Job(
                photoID: photoID, orientation: entry.orientation, preview: preview,
                destination: ThumbnailStore.url(for: photoID, in: directory)))
        }
        let outcomes = await Self.write(jobs)
        let done = zip(jobs, outcomes).filter { $0.1 == .written || $0.1 == .writtenSmall }.map(\.0.photoID)
        let small = zip(jobs, outcomes).filter { $0.1 == .writtenSmall }.map(\.0.photoID)
        SeededThumbnails.append(done, in: directory)
        SeededThumbnails.append(small, in: directory, origin: .lowResolution)
        seeded += done.count
        lowResolution += small.count
        unreadable += outcomes.filter { $0 == .unreadable }.count
        return entries.count
    }

    func finish(_ context: LightroomImportContext) async throws {
        database = nil
        pyramids = nil
        context.report.addImported("Thumbnails from Lightroom previews", count: seeded)
        if lowResolution > 0 {
            context.report.addWarning("\(lowResolution.formatted()) Lightroom preview\(lowResolution == 1 ? " was" : "s were") smaller than a thumbnail. They show until PixelLoupe redraws them from the original photos in the background.")
        }
        let without = max(0, context.idMap.count - seeded)
        if without > 0 {
            context.report.addWarning("\(without.formatted()) photo\(without == 1 ? " has" : "s have") no Lightroom preview. Thumbnails for those are made from the original photos in the background when the catalog is open.")
        }
        if unreadable > 0 {
            context.report.addWarning("\(unreadable.formatted()) Lightroom preview\(unreadable == 1 ? " was" : "s were") damaged and skipped.")
        }
    }

    /// `writtenSmall`: from a preview smaller than a thumbnail.
    private enum Outcome: Sendable { case written, writtenSmall, none, unreadable }

    private enum Preview: Sendable {
        /// Before Lightroom Classic 15: one file per photo, which may not exist.
        case lrprev(URL)
        /// Lightroom Classic 15: one file per level.
        case levels(LightroomPreviewFile)
    }

    private struct Job: Sendable {
        var photoID: UUID
        var orientation: String?
        var preview: Preview
        var destination: URL
    }

    /// An image's preview levels and the frame they were rendered for, from `Pyramid`/`PyramidLevel`.
    private struct Pyramid {
        var levels: [(width: Int, height: Int)] = []
        var cropped: (width: Int, height: Int)?
    }

    /// Reads every level listed in a Lightroom Classic 15 index: a few rows per photo, read once.
    private static func loadPyramids(_ database: SQLiteDatabase) -> [String: Pyramid] {
        var pyramids: [String: Pyramid] = [:]
        if let statement = try? database.prepare("SELECT uuid, digest, width, height FROM PyramidLevel") {
            while (try? statement.step()) == true {
                guard let uuid = statement.string(at: 0), let digest = statement.string(at: 1),
                      let width = statement.int(at: 2), let height = statement.int(at: 3), width > 0, height > 0 else { continue }
                pyramids[uuid.uppercased() + "-" + digest, default: Pyramid()].levels.append((width, height))
            }
        }
        if let statement = try? database.prepare("SELECT uuid, digest, croppedWidth, croppedHeight FROM Pyramid") {
            while (try? statement.step()) == true {
                guard let uuid = statement.string(at: 0), let digest = statement.string(at: 1),
                      let width = statement.int(at: 2), let height = statement.int(at: 3) else { continue }
                let key = uuid.uppercased() + "-" + digest
                if pyramids[key] != nil { pyramids[key]?.cropped = (width, height) }
            }
        }
        return pyramids
    }

    @concurrent
    private static func write(_ jobs: [Job]) async -> [Outcome] {
        await withTaskGroup(of: (Int, Outcome).self) { group in
            var results = [Outcome](repeating: .none, count: jobs.count)
            var next = 0
            func addNext() {
                guard next < jobs.count else { return }
                let index = next
                let job = jobs[index]
                next += 1
                group.addTask {
                    // A preview Lightroom never made isn't a failure, just a photo without one.
                    let file: LightroomPreviewFile
                    switch job.preview {
                    case .lrprev(let url):
                        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return (index, .none) }
                        guard let read = try? LightroomPreviewFile.read(at: url) else { return (index, .unreadable) }
                        file = read
                    case .levels(let levels):
                        guard let level = levels.bestLevel(minimumLongEdge: LightroomPreviews.thumbnailSize),
                              FileManager.default.fileExists(atPath: level.url.path(percentEncoded: false)) else { return (index, .none) }
                        file = levels
                    }
                    guard let isFullSize = try? LightroomPreviews.writeThumbnail(from: file, orientation: job.orientation, to: job.destination)
                    else { return (index, .unreadable) }
                    return (index, isFullSize ? .written : .writtenSmall)
                }
            }
            for _ in 0..<min(maximumConcurrentWrites, jobs.count) { addNext() }
            while let (index, outcome) = await group.next() {
                results[index] = outcome
                addNext()
            }
            return results
        }
    }
}
