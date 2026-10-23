import CoreData
import Foundation

/// Publish for one service: sends its new and modified photos, and removes its deleted ones, a few at a
/// time, recording where each went. Nothing is asked here; the Library confirms removals before it runs.
@MainActor
enum PublishRun {
    struct Result {
        var published = 0
        var removed = 0
        /// "IMG_0001.CR3: why", for each photo that couldn't be published or removed.
        var failures: [String] = []
    }

    /// One photo's work, captured so the publisher never touches Core Data.
    nonisolated struct Job: Sendable {
        enum Work: Sendable {
            case publish(PublishItem, fingerprint: String)
            case remove(RemotePhoto)
        }

        let entry: NSManagedObjectID
        let fileName: String
        let work: Work
    }

    /// Publishes `service`, reporting progress (completed, total). `publisher` replaces the kind's, for tests.
    static func run(_ service: PublishService, store: CatalogStore, publisher: (any Publisher)? = nil,
                    progress: @escaping @MainActor (Int, Int) -> Void = { _, _ in }) async -> Result {
        let context = store.viewContext
        let settings = service.settings
        let publisher = publisher ?? service.kind.publisher(settings: settings, watermark: PhotoExporter.Watermark(settings.export))
        var result = Result()
        let jobs = withoutUndo(context) { jobs(for: service, store: store, settings: settings, failures: &result.failures) }
        let started = Date()
        await perform(jobs, with: publisher, concurrency: service.kind.concurrency) { job, outcome, completed in
            withoutUndo(context) { apply(outcome, of: job, at: started, in: context, to: &result) }
            progress(completed, jobs.count)
        }
        store.save()
        return result
    }

    /// The work for a service's photos, marking those that can't be published (videos) as failed.
    private static func jobs(for service: PublishService, store: CatalogStore, settings: PublishSettings,
                             failures: inout [String]) -> [Job] {
        service.pruneUnpublishedOrphans()
        var jobs: [Job] = []
        let toPublish = service.entries(in: .new) + service.entries(in: .modified)
        for (index, entry) in toPublish.enumerated() {
            guard let photo = entry.photo else { continue }
            if photo.isVideo {
                entry.lastError = "Videos can’t be published yet."
                failures.append("\(photo.fileName): \(entry.lastError!)")
                continue
            }
            let item = ExportItem(photo, smartPreview: store.smartPreviews.file(for: photo))
            let publish = PublishItem(export: item, title: settings.title(for: item), remote: entry.remote,
                                      hasEdits: entry.publishedDate == nil || entry.hasEditsSincePublished,
                                      index: index, total: toPublish.count)
            jobs.append(Job(entry: entry.objectID, fileName: photo.fileName,
                            work: .publish(publish, fingerprint: PublishedPhoto.fingerprint(item))))
        }
        for entry in service.entries(in: .deleted) {
            if let remote = entry.remote {
                jobs.append(Job(entry: entry.objectID, fileName: entry.fileName, work: .remove(remote)))
            } else {
                service.managedObjectContext?.delete(entry)
            }
        }
        return jobs
    }

    /// Runs the jobs, `concurrency` at a time, handing each outcome back on the main actor as it finishes.
    /// Cancelling stops starting new ones.
    private nonisolated static func perform(
        _ jobs: [Job], with publisher: any Publisher, concurrency: Int,
        outcome: @escaping @MainActor (Job, Swift.Result<RemotePhoto?, Error>, Int) -> Void
    ) async {
        await withTaskGroup(of: (Job, Swift.Result<RemotePhoto?, Error>).self) { group in
            var pending = jobs.makeIterator()
            func addNext() -> Bool {
                guard let job = pending.next() else { return false }
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        switch job.work {
                        case .publish(let item, _): return (job, .success(try await publisher.publish(item)))
                        case .remove(let remote): try await publisher.remove(remote); return (job, .success(nil))
                        }
                    } catch {
                        return (job, .failure(error))
                    }
                }
                return true
            }
            for _ in 0..<concurrency where !addNext() { break }
            var completed = 0
            for await (job, result) in group {
                completed += 1
                await outcome(job, result, completed)
                if !Task.isCancelled { _ = addNext() }
            }
        }
    }

    private static func apply(_ outcome: Swift.Result<RemotePhoto?, Error>, of job: Job, at started: Date,
                              in context: NSManagedObjectContext, to result: inout Result) {
        guard let entry = try? context.existingObject(with: job.entry) as? PublishedPhoto, !entry.isDeleted else { return }
        switch (outcome, job.work) {
        case (.failure(let error), _):
            guard !(error is CancellationError) else { return }
            entry.lastError = error.localizedDescription
            result.failures.append("\(job.fileName): \(error.localizedDescription)")
        case (.success(let remote), .publish(_, let fingerprint)):
            entry.remoteID = remote?.id
            entry.remoteURL = remote?.url?.absoluteString
            // When the publish started, so edits made while it ran still show the photo as modified.
            entry.publishedDate = started
            entry.metadataFingerprint = fingerprint
            entry.lastError = nil
            result.published += 1
        case (.success, .remove):
            context.delete(entry)
            result.removed += 1
        }
    }

    /// Publishing's bookkeeping isn't something to undo.
    private static func withoutUndo<T>(_ context: NSManagedObjectContext, _ body: () -> T) -> T {
        context.processPendingChanges()
        context.undoManager?.disableUndoRegistration()
        defer {
            context.processPendingChanges()
            context.undoManager?.enableUndoRegistration()
        }
        return body()
    }
}
