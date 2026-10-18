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
    private var seeded = 0
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
            jobs.append(Job(
                photoID: photoID, orientation: entry.orientation,
                preview: LightroomPreviews.previewURL(uuid: entry.uuid, digest: entry.digest, in: previewsFolder),
                destination: ThumbnailStore.url(for: photoID, in: directory)))
        }
        let outcomes = await Self.write(jobs)
        let done = zip(jobs, outcomes).filter { $0.1 == .written }.map(\.0.photoID)
        SeededThumbnails.append(done, in: directory)
        seeded += done.count
        unreadable += outcomes.filter { $0 == .unreadable }.count
        return entries.count
    }

    func finish(_ context: LightroomImportContext) async throws {
        database = nil
        context.report.addImported("Thumbnails from Lightroom previews", count: seeded)
        let without = max(0, context.idMap.count - seeded)
        if without > 0 {
            context.report.addWarning("\(without.formatted()) photo\(without == 1 ? " has" : "s have") no Lightroom preview. Thumbnails for those are made from the original photos in the background when the catalog is open.")
        }
        if unreadable > 0 {
            context.report.addWarning("\(unreadable.formatted()) Lightroom preview\(unreadable == 1 ? " was" : "s were") damaged and skipped.")
        }
    }

    private enum Outcome: Sendable { case written, none, unreadable }

    private struct Job: Sendable {
        var photoID: UUID
        var orientation: String?
        var preview: URL
        var destination: URL
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
                    guard FileManager.default.fileExists(atPath: job.preview.path(percentEncoded: false)) else { return (index, .none) }
                    guard let file = try? LightroomPreviewFile.read(at: job.preview),
                          (try? LightroomPreviews.writeThumbnail(from: file, orientation: job.orientation, to: job.destination)) != nil
                    else { return (index, .unreadable) }
                    return (index, .written)
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
