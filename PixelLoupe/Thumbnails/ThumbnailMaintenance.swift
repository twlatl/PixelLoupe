import CoreData
import Foundation
import OSLog

/// Quietly keeps a catalog's thumbnails complete and true to PixelLoupe's rendering, in the
/// background at low priority, after the catalog opens:
///
/// - photos that have no thumbnail (no Lightroom preview, or one that failed) get one from the original;
/// - thumbnails copied from Lightroom's previews (see ``SeededThumbnails``) are redrawn by PixelLoupe
///   for photos whose edits PixelLoupe renders, so the grid matches Develop.
///
/// Photos whose file can't be found are left as they are (a Lightroom preview keeps showing).
/// Closing the catalog stops the pass; the next opening carries on where it left off.
@MainActor
final class ThumbnailMaintenance {
    private unowned let store: CatalogStore
    private var task: Task<Void, Never>?
    private static let logger = Logger(subsystem: "net.pixegen.PixelLoupe", category: "Thumbnails")

    init(store: CatalogStore) {
        self.store = store
    }

    /// Starts after `delay`, so opening the catalog and the first scroll stay snappy.
    func start(after delay: Duration = .seconds(4)) {
        guard task == nil else { return }
        task = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.run()
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

    /// Photos to draw: their id and whether the thumbnail exists only as a Lightroom copy.
    private struct Work: Sendable {
        var id: UUID
        var path: String
    }

    private func run() async {
        let directory = store.thumbnails.directory
        let context = store.newBackgroundContext()
        let work = await Self.plan(context: context, directory: directory)
        guard !work.isEmpty else { return }
        Self.logger.info("Drawing \(work.count) thumbnails in the background")

        var seeded = SeededThumbnails.load(from: directory)
        var sinceSave = 0
        for item in work {
            if Task.isCancelled { break }
            // Use the photo's current edits: they may have changed since the plan was made.
            let request = Photo.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", item.id as CVarArg)
            request.fetchLimit = 1
            guard let photo = try? store.viewContext.fetch(request).first else { continue }
            let ok = await store.thumbnails.render(id: item.id, source: photo.fileURL, adjustments: photo.adjustments)
            if ok, seeded.remove(item.id) != nil {
                sinceSave += 1
                if sinceSave >= 50 {
                    SeededThumbnails.save(seeded, to: directory)
                    sinceSave = 0
                }
            }
            await Task.yield()
        }
        SeededThumbnails.save(seeded, to: directory)
    }

    @concurrent
    private static func plan(context: NSManagedObjectContext, directory: URL) async -> [Work] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        let existing = Set(files.compactMap { name -> UUID? in
            name.hasSuffix(".jpg") ? UUID(uuidString: String(name.dropLast(4))) : nil
        })
        let seeded = SeededThumbnails.load(from: directory)

        let (photos, edited): ([(UUID, String)], Set<UUID>) = await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "Photo")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id", "filePath"]
            let photos = ((try? context.fetch(request)) ?? []).compactMap { row -> (UUID, String)? in
                guard let id = row["id"] as? UUID, let path = row["filePath"] as? String else { return nil }
                return (id, path)
            }
            let editedRequest = NSFetchRequest<NSDictionary>(entityName: "Photo")
            editedRequest.resultType = .dictionaryResultType
            editedRequest.propertiesToFetch = ["id"]
            editedRequest.predicate = NSPredicate(format: "adjustmentsData != nil")
            let edited = Set(((try? context.fetch(editedRequest)) ?? []).compactMap { $0["id"] as? UUID })
            return (photos, edited)
        }

        var work: [Work] = []
        for (id, path) in photos {
            if Task.isCancelled { return [] }
            let needsThumbnail = !existing.contains(id)
            let needsRedraw = seeded.contains(id) && edited.contains(id)
            guard needsThumbnail || needsRedraw, FileManager.default.fileExists(atPath: path) else { continue }
            work.append(Work(id: id, path: path))
        }
        return work
    }
}
