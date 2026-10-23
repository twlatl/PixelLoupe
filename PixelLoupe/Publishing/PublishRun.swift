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
        /// Why Publish stopped before the end (the service needs signing in again), if it did.
        var stopReason: String?
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
        let publisher = publisher ?? service.publisher()
        var result = Result()
        let jobs = withoutUndo(context) { jobs(for: service, store: store, settings: settings, failures: &result.failures) }
        let started = Date()
        await perform(jobs, with: publisher, concurrency: service.kind.concurrency) { job, outcome, completed in
            withoutUndo(context) { apply(outcome, of: job, at: started, in: context, to: &result) }
            // Saved as each photo finishes: a photo already on the service must be known to be there
            // even if the app quits (or crashes) before the rest are done, or the next Publish sends it again.
            store.save()
            progress(completed, jobs.count)
        }
        if service.hasAlbums, let albums = publisher as? any AlbumPublisher, !Task.isCancelled, result.stopReason == nil {
            await publishAlbums(of: service, with: albums, store: store, to: &result)
        }
        store.save()
        return result
    }

    // MARK: - Albums

    /// Sends the service's album changes (RAW-185), after its photos so the albums can hold them: creates
    /// new albums, renames changed ones, and adds and removes this catalog's photos. Photos in an album that
    /// this catalog didn't put there are never touched, so an album can be shared with flickr.com and other
    /// catalogs. A deleted album, or one with none of this catalog's photos left, only loses this catalog's
    /// photos; it isn't deleted on Flickr.
    private static func publishAlbums(of service: PublishService, with publisher: any AlbumPublisher, store: CatalogStore,
                                      to result: inout Result) async {
        let context = store.viewContext
        let albums = service.albums.filter(\.hasChangesToPublish).sorted { $0.createdDate < $1.createdDate }
        for album in albums {
            guard !Task.isCancelled else { return }
            let name = album.name
            do {
                try await publish(album, with: publisher, context: context)
            } catch FlickrAPI.APIError.photoNotFound where album.remoteID != nil && !album.isDeletionPending {
                // Deleted on Flickr: made again.
                withoutUndo(context) { album.forgetPublished() }
                do {
                    try await publish(album, with: publisher, context: context)
                } catch {
                    fail(album: name, error, &result)
                }
            } catch {
                fail(album: name, error, &result)
            }
            store.save()
            if result.stopReason != nil { return }
        }
    }

    private static func publish(_ album: PublishAlbum, with publisher: any AlbumPublisher, context: NSManagedObjectContext) async throws {
        let name = album.name
        let description = album.albumDescription
        let photoIDs = album.isDeletionPending ? [] : album.publishedPhotoIDsToSend()
        if photoIDs.isEmpty {
            if let id = album.remoteID { try await send(photoIDs, to: id, of: album, with: publisher, context: context) }
            withoutUndo(context) { album.isDeletionPending ? context.delete(album) : album.forgetPublished() }
            return
        }
        let id: String
        if let existing = album.remoteID {
            id = existing
            if name != album.publishedName || description != album.publishedDescription {
                try await publisher.editAlbum(id, title: name, description: description)
            }
        } else {
            id = try await publisher.createAlbum(title: name, description: description, coverID: photoIDs[0])
            withoutUndo(context) {
                album.remoteID = id
                album.sentPhotoIDs = [photoIDs[0]]
            }
        }
        withoutUndo(context) {
            album.publishedName = name
            album.publishedDescription = description
        }
        try await send(photoIDs, to: id, of: album, with: publisher, context: context)
    }

    /// Adds the photos the album should have that this catalog hasn't put in it yet, in capture order, and takes
    /// out those it put in and shouldn't have any more. What's been sent is recorded photo by photo, so a
    /// Publish that fails part way carries on from there next time.
    private static func send(_ photoIDs: [String], to id: String, of album: PublishAlbum, with publisher: any AlbumPublisher,
                             context: NSManagedObjectContext) async throws {
        let wanted = Set(photoIDs)
        for photoID in album.sentPhotoIDs.subtracting(wanted).sorted() {
            try await publisher.removeAlbumPhoto(id, photoID: photoID)
            withoutUndo(context) { album.sentPhotoIDs.remove(photoID) }
        }
        for photoID in photoIDs where !album.sentPhotoIDs.contains(photoID) {
            try await publisher.addAlbumPhoto(id, photoID: photoID)
            withoutUndo(context) { album.sentPhotoIDs.insert(photoID) }
        }
    }

    private static func fail(album name: String, _ error: Error, _ result: inout Result) {
        guard !(error is CancellationError) else { return }
        if error is PublishStoppingError {
            result.stopReason = result.stopReason ?? error.localizedDescription
        } else {
            result.failures.append("Album “\(name)”: \(error.localizedDescription)")
        }
    }

    /// The work for a service's photos, marking those that can't be published (videos) as failed.
    private static func jobs(for service: PublishService, store: CatalogStore, settings: PublishSettings,
                             failures: inout [String]) -> [Job] {
        // A smart album's matches join the service, to be uploaded with the rest.
        service.add(service.smartAlbumPhotosToJoin())
        service.pruneUnpublishedOrphans()
        // Results are saved as they come in, which would leave temporary IDs (of entries not saved yet)
        // pointing at nothing.
        let unsaved = service.publishedPhotos.filter { $0.objectID.isTemporaryID }
        if !unsaved.isEmpty { try? service.managedObjectContext?.obtainPermanentIDs(for: Array(unsaved)) }
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
    /// Cancelling, or a ``PublishStoppingError``, stops starting new ones.
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
            var isStopped = false
            for await (job, result) in group {
                completed += 1
                await outcome(job, result, completed)
                if case .failure(let error) = result, error is PublishStoppingError { isStopped = true }
                if !Task.isCancelled, !isStopped { _ = addNext() }
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
            if error is PublishStoppingError {
                // Said once, for the whole Publish: every other photo would fail the same way.
                result.stopReason = result.stopReason ?? error.localizedDescription
            } else {
                result.failures.append("\(job.fileName): \(error.localizedDescription)")
            }
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
