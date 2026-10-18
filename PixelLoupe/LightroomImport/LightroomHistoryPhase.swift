import CoreData
import Foundation

/// Brings in each photo's Lightroom develop history and snapshots, only when the import sheet's
/// "Import develop history and snapshots" is on (a big catalog has tens of thousands of steps).
///
/// Lightroom's settings text is kept compressed with the step; it is converted to PixelLoupe
/// adjustments the first time the History panel shows the photo, not now, which keeps the import fast.
nonisolated final class LightroomHistoryPhase: LightroomImportPhase {
    let title = "Importing develop history"

    private static let batchSize = 500

    private var steps: LightroomRowCursor<LRHistoryStep>?
    private var snapshots: LightroomRowCursor<LRSnapshot>?
    private var stepsDone = false
    private var lastImage = -1
    private var sequence: Int32 = 0
    private var importedSteps = 0
    private var importedSnapshots = 0
    private var skippedBigData = 0

    func prepare(_ context: LightroomImportContext) async throws -> Int {
        steps = try context.catalog.historyStepsCursor()
        snapshots = try context.catalog.snapshotsCursor()
        let stepCount = steps == nil ? 0 : try context.catalog.scalar("SELECT COUNT(*) FROM Adobe_libraryImageDevelopHistoryStep", table: "Adobe_libraryImageDevelopHistoryStep")
        let snapshotCount = snapshots == nil ? 0 : try context.catalog.scalar("SELECT COUNT(*) FROM Adobe_libraryImageDevelopSnapshot", table: "Adobe_libraryImageDevelopSnapshot")
        return stepCount + snapshotCount
    }

    func importBatch(_ context: LightroomImportContext) async throws -> Int {
        let managed = context.managedObjectContext
        let importDate = context.importDate
        if !stepsDone, let steps {
            let rows = try steps.next(Self.batchSize)
            if rows.isEmpty { stepsDone = true } else {
                // Keep each photo's sequence going across batches.
                var prepared: [(row: LRHistoryStep, sequence: Int32)] = []
                for row in rows {
                    if row.image != lastImage { lastImage = row.image; sequence = 0 }
                    sequence += 1
                    prepared.append((row, sequence))
                }
                let batch = prepared
                let ids = Dictionary(uniqueKeysWithValues: batch.compactMap { entry in
                    context.idMap.photoID(forLightroomID: entry.row.image).map { (entry.row.image, $0) }
                }.uniqued(by: \.0))
                let (made, skipped): (Int, Int) = await managed.perform {
                    let request = Photo.fetchRequest()
                    request.predicate = NSPredicate(format: "id IN %@", Array(Set(ids.values)))
                    let photos = Dictionary(((try? managed.fetch(request)) ?? []).map { ($0.id, $0) }) { first, _ in first }
                    var made = 0, skipped = 0
                    for (row, number) in batch {
                        guard let photoID = ids[row.image], let photo = photos[photoID] else { continue }
                        guard !row.hasBigData, let text = row.text, !text.isEmpty else { skipped += 1; continue }
                        let step = DevelopHistoryStep(context: managed)
                        step.id = UUID()
                        step.date = row.dateCreated.flatMap(LightroomDates.touchDate) ?? importDate
                        step.name = row.name ?? ""
                        step.sequence = number
                        step.lightroomData = DevelopHistory.compress(Data(text.utf8))
                        step.photo = photo
                        made += 1
                    }
                    return (made, skipped)
                }
                importedSteps += made
                skippedBigData += skipped
                return rows.count
            }
        }
        guard let snapshots else { return 0 }
        let rows = try snapshots.next(Self.batchSize)
        guard !rows.isEmpty else { return 0 }
        let batch = rows
        let ids = Dictionary(uniqueKeysWithValues: batch.compactMap { row in
            context.idMap.photoID(forLightroomID: row.image).map { (row.image, $0) }
        }.uniqued(by: \.0))
        let made: Int = await managed.perform {
            let request = Photo.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", Array(Set(ids.values)))
            let photos = Dictionary(((try? managed.fetch(request)) ?? []).map { ($0.id, $0) }) { first, _ in first }
            var made = 0
            for row in batch {
                guard let photoID = ids[row.image], let photo = photos[photoID], !row.hasBigData, let text = row.text, !text.isEmpty else { continue }
                let snapshot = DevelopSnapshot(context: managed)
                snapshot.id = UUID()
                snapshot.date = importDate
                snapshot.name = row.name ?? "Snapshot"
                snapshot.lightroomData = DevelopHistory.compress(Data(text.utf8))
                snapshot.photo = photo
                made += 1
            }
            return made
        }
        importedSnapshots += made
        return rows.count
    }

    func finish(_ context: LightroomImportContext) async throws {
        if importedSteps > 0 { context.report.addImported("Develop history steps", count: importedSteps) }
        if importedSnapshots > 0 { context.report.addImported("Snapshots", count: importedSnapshots) }
        if skippedBigData > 0 {
            context.report.addWarning("\(skippedBigData.formatted()) history step\(skippedBigData == 1 ? "" : "s") kept their settings outside the catalog file and were not imported.")
        }
    }
}

nonisolated private extension Array {
    /// The first of the elements that share a key (here, one photo id per Lightroom image id).
    func uniqued<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert(key($0)).inserted }
    }
}
