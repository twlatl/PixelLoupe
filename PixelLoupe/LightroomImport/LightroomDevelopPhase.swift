import CoreData
import Foundation

/// Reads each photo's develop settings and stores the ones PixelLoupe can render as the photo's
/// adjustments (`adjustmentsData`), reporting the rest as import differences.
///
/// Parsing is the expensive part (a 55,000-photo catalog has 55,000 Lua tables of a few KB), so it
/// happens here on the import task, before the batch touches Core Data; a batch then fetches its
/// photos with one query.
nonisolated final class LightroomDevelopPhase: LightroomImportPhase {
    let title = "Importing develop settings"

    private static let batchSize = 500

    private var cursor: LightroomRowCursor<LRDevelopSettings>?
    private var withAdjustments = 0
    /// Differences that only go in the report's notes, with how many photos had each.
    private var notes: [String: (title: String, count: Int)] = [:]
    private var unreadable = 0

    func prepare(_ context: LightroomImportContext) async throws -> Int {
        guard try context.catalog.scalar("SELECT COUNT(*) FROM Adobe_imageDevelopSettings", table: "Adobe_imageDevelopSettings") > 0 else { return 0 }
        cursor = try context.catalog.developSettingsCursor()
        return try context.catalog.scalar("SELECT COUNT(*) FROM Adobe_imageDevelopSettings WHERE image IS NOT NULL")
    }

    private let lensResolver: LightroomLensResolver

    init(lensResolver: LightroomLensResolver = LightroomLensResolver()) {
        self.lensResolver = lensResolver
    }

    /// Counts the report-only differences found while a batch is mapped.
    private final class ReportOnlyNotes: @unchecked Sendable {
        var items: [String: (title: String, count: Int)] = [:]

        func add(_ difference: LightroomDevelopMapper.Difference) {
            items[difference.key, default: (difference.title, 0)].count += 1
        }
    }

    private struct Job: @unchecked Sendable {
        var photoID: UUID
        var settings: LuaTable
        var processVersion: String?
        var whiteBalance: String?
    }

    func importBatch(_ context: LightroomImportContext) async throws -> Int {
        guard let cursor else { return 0 }
        let rows = try cursor.next(Self.batchSize)
        guard !rows.isEmpty else { return 0 }

        var jobs: [Job] = []
        for row in rows {
            guard let photoID = context.idMap.photoID(forLightroomID: row.image) else { continue }
            let parsed: LuaValue?
            do { parsed = try row.parsed() } catch { unreadable += 1; continue }
            guard let table = parsed?.table else { continue }
            jobs.append(Job(photoID: photoID, settings: table, processVersion: row.processVersion, whiteBalance: row.whiteBalance))
        }
        guard !jobs.isEmpty else { return rows.count }

        let managed = context.managedObjectContext
        let report = context.report
        let resolver = lensResolver
        let reportOnly = ReportOnlyNotes()
        let batch = jobs
        let stored: Int = await managed.perform {
            let request = Photo.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", batch.map(\.photoID))
            request.returnsObjectsAsFaults = false
            let photos = Dictionary(((try? managed.fetch(request)) ?? []).map { ($0.id, $0) }) { first, _ in first }
            var stored = 0
            for job in batch {
                guard let photo = photos[job.photoID] else { continue }
                var adjustments = photo.adjustments
                let before = adjustments
                var input = LightroomDevelopMapper.Input(
                    settings: job.settings, processVersion: job.processVersion, whiteBalance: job.whiteBalance,
                    isRaw: SupportedImageTypes.isRaw(URL(filePath: "/x/" + photo.fileName)),
                    seed: Self.seed(for: photo.id), imageSize: photo.displayedPixelSize)
                input.cameraModel = photo.cameraModel
                if LightroomDevelopMapper.usesLensProfile(job.settings) {
                    input.lensProfile = resolver.profile(for: .init(
                        cameraMake: photo.cameraMake, cameraModel: photo.cameraModel, lensModel: photo.lensModel,
                        profileName: job.settings["LensProfileName"]?.string, profileFilename: job.settings["LensProfileFilename"]?.string,
                        focalLength: photo.focalLength, aperture: photo.aperture))
                }
                let differences = LightroomDevelopMapper.apply(input, to: &adjustments)
                if adjustments != before {
                    photo.adjustments = adjustments
                    stored += 1
                }
                for difference in differences {
                    if difference.reportOnly {
                        reportOnly.add(difference)
                    } else {
                        report.recordDifference(difference.key, title: difference.title, for: photo)
                    }
                }
            }
            return stored
        }
        withAdjustments += stored
        for (key, note) in reportOnly.items { notes[key, default: (note.title, 0)].count += note.count }
        return rows.count
    }

    /// A stable number from the photo's id (not `hashValue`, which changes between launches).
    nonisolated static func seed(for id: UUID) -> Int {
        let bytes = id.uuid
        return Int(bytes.0) << 16 | Int(bytes.1) << 8 | Int(bytes.2) | 1
    }

    func finish(_ context: LightroomImportContext) async throws {
        if withAdjustments > 0 { context.report.addImported("Photos with develop settings", count: withAdjustments) }
        for (_, note) in notes.sorted(by: { $0.key < $1.key }) {
            context.report.addWarning("\(note.count.formatted()) \(note.title)")
        }
        if unreadable > 0 {
            context.report.addWarning("\(unreadable.formatted()) photo\(unreadable == 1 ? "’s" : "s’") develop settings could not be read, so those photos have no adjustments.")
        }
    }
}
