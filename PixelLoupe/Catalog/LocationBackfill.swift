import CoreData
import Foundation
import ImageIO
import OSLog

/// Brings photos from before model v16 up to date with numeric locations, in the background after the
/// catalog opens:
///
/// - the file's position is read into `fileLatitude`/`fileLongitude` for photos the import found GPS
///   in (`hasGPS`); photos it found none in are marked read without touching their files;
/// - a GPS position typed into the Metadata panel, stored as text before v16, becomes the photo's
///   location override.
///
/// Photos whose file can't be read stay unread and are tried again the next time the catalog opens.
/// Closing the catalog stops the pass; the next opening carries on where it left off.
@MainActor
final class LocationBackfill {
    private unowned let store: CatalogStore
    private var task: Task<Void, Never>?
    private static let logger = Logger(subsystem: "net.pixegen.PixelLoupe", category: "Catalog")
    nonisolated static let batchSize = 200

    init(store: CatalogStore) {
        self.store = store
    }

    /// Starts after `delay`, so opening the catalog and the first scroll stay snappy.
    func start(after delay: Duration = .seconds(2)) {
        guard task == nil else { return }
        let context = store.newBackgroundContext(), viewContext = store.viewContext
        task = Task(priority: .utility) {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let start = ContinuousClock.now
            let (read, unreadable) = await Self.run(in: context, mergingInto: [viewContext])
            if read > 0 || unreadable > 0 {
                Self.logger.info("Read the location of \(read) photos in \(ContinuousClock.now - start); \(unreadable) couldn't be read")
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Waits for the pass in flight to finish; used by tests.
    func waitUntilIdle() async {
        await task?.value
    }

    /// Converts every unread photo, a batch at a time. Returns how many were read, and how many
    /// files couldn't be. `viewContexts` learn of photos marked read without being fetched.
    nonisolated static func run(in context: NSManagedObjectContext, mergingInto viewContexts: [NSManagedObjectContext] = [])
        async -> (read: Int, unreadable: Int)
    {
        // Nothing to read or convert: the import found no GPS and nothing was typed.
        await context.perform {
            let request = NSBatchUpdateRequest(entityName: "Photo")
            request.predicate = NSPredicate(format: "locationRead == NO AND hasGPS == NO AND metadataData == nil")
            request.propertiesToUpdate = ["locationRead": true]
            request.resultType = .updatedObjectIDsResultType
            // A batch update bypasses the contexts, which would otherwise keep (and save back) the old value.
            if let ids = (try? context.execute(request) as? NSBatchUpdateResult)?.result as? [NSManagedObjectID], !ids.isEmpty {
                NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSUpdatedObjectsKey: ids], into: [context] + viewContexts)
            }
        }
        var read = 0
        var skipped: [NSManagedObjectID] = []
        while !Task.isCancelled {
            let excluded = skipped
            let batch: (done: Int, skipped: [NSManagedObjectID])? = await context.perform {
                let request = Photo.fetchRequest()
                request.predicate = NSPredicate(format: "locationRead == NO AND NOT (SELF IN %@)", excluded)
                request.fetchLimit = batchSize
                guard let photos = try? context.fetch(request), !photos.isEmpty else { return nil }
                var done = 0, unreadable: [NSManagedObjectID] = []
                for photo in photos {
                    if backfill(photo) { done += 1 } else { unreadable.append(photo.objectID) }
                }
                try? context.save()
                context.reset()
                return (done, unreadable)
            }
            guard let batch else { break }
            read += batch.done
            skipped += batch.skipped
        }
        return (read, skipped.count)
    }

    /// Brings one photo up to date; false when its file has to be read and can't be.
    nonisolated static func backfill(_ photo: Photo) -> Bool {
        // The import's answer, before converting the text below changes it.
        let fileHasGPS = photo.hasGPS
        if photo.metadataData != nil {
            // Setting the metadata moves GPS text into the location override.
            photo.metadata = photo.metadata
        }
        guard fileHasGPS else {
            photo.setFileLocation(nil, altitude: nil)
            return true
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(photo.fileURL as CFURL, options),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        else { return false }
        let (location, altitude) = ImageMetadata.location(properties)
        photo.setFileLocation(location, altitude: altitude)
        return true
    }
}
