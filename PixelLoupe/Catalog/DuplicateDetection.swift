import CoreData
import CryptoKit
import Foundation
import OSLog

/// Catalog Settings ▸ Metadata ▸ Automatically detect duplicates (RAW-292). While it's on, every photo's original is
/// hashed (SHA-256 of the file's bytes, `Photo.contentHash`, model v21) in the background, a batch at a time, and
/// photos whose original has the same contents as another photo's are marked (`Photo.hasDuplicate`), which the
/// Catalog section's Duplicates shows.
///
/// New photos are hashed as they're saved, and the marks are worked out again whenever photos are added, removed or
/// hashed. Virtual copies share their master's file, so they're never hashed or marked; a RAW file and the JPEG next to
/// it have different contents, so they never match. Originals that can't be read (offline, missing) are tried again
/// the next time the catalog opens. Nothing is ever removed: Duplicates only shows them.
@MainActor
final class DuplicateDetection {
    private unowned let store: CatalogStore
    private var task: Task<Void, Never>?
    /// Something changed while a pass was running, so another runs after it.
    private var needsAnotherPass = false
    private static let logger = Logger(subsystem: "net.pixegen.PixelLoupe", category: "Duplicates")
    nonisolated static let batchSize = 50
    /// Posted (on the main thread, with the store) when photos are marked or unmarked. The marks are batch updates, which
    /// fetched results don't see, so the grid and sidebar fetch again.
    nonisolated static let didMarkNotification = Notification.Name("DuplicateDetectionDidMark")

    /// Photos hashed and to hash since the pass started, for the progress under the grid; nil while idle or when
    /// there's nothing to hash.
    private(set) var progress: LibraryState.ImportStatus? {
        didSet { if progress != oldValue { onProgress(progress) } }
    }
    var onProgress: (LibraryState.ImportStatus?) -> Void = { _ in }

    init(store: CatalogStore) {
        self.store = store
    }

    private var isEnabled: Bool { store.settings.detectsDuplicates }

    /// Starts a pass after `delay` when detection is on, so opening the catalog stays snappy.
    func start(after delay: Duration = .seconds(3)) {
        guard isEnabled else { return }
        run(after: delay)
    }

    /// Stops the pass in flight. Hashes already worked out are kept.
    func stop() {
        task?.cancel()
        task = nil
        needsAnotherPass = false
        progress = nil
    }

    /// Photos were added, removed or changed: hash the new ones and work the marks out again.
    func photosDidChange() {
        guard isEnabled else { return }
        if task != nil { needsAnotherPass = true } else { run(after: .zero) }
    }

    /// Waits until no pass is running; used by tests.
    func waitUntilIdle() async {
        while let task { await task.value }
    }

    private func run(after delay: Duration) {
        guard task == nil else { return }
        let context = store.newBackgroundContext(), viewContext = store.viewContext
        task = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let start = ContinuousClock.now
            let hashed = await Self.hashUnhashed(in: context) { completed, total in
                self?.progress = total > 0 ? LibraryState.ImportStatus(completed: completed, total: total) : nil
            }
            guard !Task.isCancelled else { return }
            let (marked, changed) = await Self.markDuplicates(in: context, mergingInto: [viewContext])
            if hashed > 0 { Self.logger.info("Hashed \(hashed) photos in \(ContinuousClock.now - start); \(marked) have a duplicate") }
            guard let self, !Task.isCancelled else { return }
            if changed { NotificationCenter.default.post(name: Self.didMarkNotification, object: store) }
            task = nil
            progress = nil
            if needsAnotherPass {
                needsAnotherPass = false
                run(after: .zero)
            }
        }
    }

    // MARK: - Hashing

    /// Hashes every photo without a hash (virtual copies aside), a batch at a time. Returns how many were hashed.
    /// `onProgress` gets how many are done of how many there were.
    nonisolated static func hashUnhashed(
        in context: NSManagedObjectContext, onProgress: @MainActor @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> Int {
        // Built inside each block: predicates aren't Sendable.
        let unhashedFormat = "contentHash == nil AND master == nil"
        let total: Int = await context.perform {
            let request = Photo.fetchRequest()
            request.predicate = NSPredicate(format: unhashedFormat)
            return (try? context.count(for: request)) ?? 0
        }
        guard total > 0 else { return 0 }
        await onProgress(0, total)
        var hashed = 0, attempted = 0
        var unreadable: [NSManagedObjectID] = []
        while !Task.isCancelled {
            let excluded = unreadable
            let batch: [(id: NSManagedObjectID, path: String)] = await context.perform {
                let request = NSFetchRequest<NSDictionary>(entityName: "Photo")
                request.resultType = .dictionaryResultType
                let objectID = NSExpressionDescription()
                objectID.name = "objectID"
                objectID.expression = .expressionForEvaluatedObject()
                objectID.expressionResultType = .objectIDAttributeType
                request.propertiesToFetch = [objectID, "filePath"]
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [NSPredicate(format: unhashedFormat), NSPredicate(format: "NOT (SELF IN %@)", excluded)])
                request.fetchLimit = batchSize
                return ((try? context.fetch(request)) ?? []).compactMap { row in
                    guard let id = row["objectID"] as? NSManagedObjectID, let path = row["filePath"] as? String else { return nil }
                    return (id, path)
                }
            }
            guard !batch.isEmpty else { break }
            var hashes: [NSManagedObjectID: String] = [:]
            for photo in batch {
                guard !Task.isCancelled else { break }
                if let hash = await contentHash(of: URL(filePath: photo.path)) { hashes[photo.id] = hash } else { unreadable.append(photo.id) }
            }
            let found = hashes
            await context.perform {
                for (id, hash) in found {
                    (try? context.existingObject(with: id) as? Photo)?.contentHash = hash
                }
                if context.hasChanges { try? context.save() }
            }
            hashed += hashes.count
            attempted += batch.count
            await onProgress(min(attempted, total), total)
        }
        return hashed
    }

    /// The SHA-256 of the file at `url`, in hex; nil when it can't be read. Reads it a few megabytes at a time.
    @concurrent
    nonisolated static func contentHash(of url: URL) async -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Marking

    /// Marks the photos whose hash another photo shares, and unmarks the rest. Returns how many are marked, and
    /// whether any mark changed.
    nonisolated static func markDuplicates(in context: NSManagedObjectContext, mergingInto viewContexts: [NSManagedObjectContext] = [])
        async -> (marked: Int, changed: Bool) {
        await context.perform {
            let shared = sharedHashes(in: context)
            var changed: [NSManagedObjectID] = []
            for (predicate, value) in [
                (NSPredicate(format: "hasDuplicate == NO AND master == nil AND contentHash IN %@", shared), true),
                (NSPredicate(format: "hasDuplicate == YES AND (master != nil OR contentHash == nil OR NOT (contentHash IN %@))", shared), false),
            ] {
                let request = NSBatchUpdateRequest(entityName: "Photo")
                request.predicate = predicate
                request.propertiesToUpdate = ["hasDuplicate": value]
                request.resultType = .updatedObjectIDsResultType
                changed += ((try? context.execute(request) as? NSBatchUpdateResult)?.result as? [NSManagedObjectID]) ?? []
            }
            // A batch update bypasses the contexts, which would otherwise keep (and save back) the old value.
            if !changed.isEmpty {
                NSManagedObjectContext.mergeChanges(fromRemoteContextSave: [NSUpdatedObjectsKey: changed], into: [context] + viewContexts)
            }
            let request = Photo.fetchRequest()
            request.predicate = NSPredicate(format: "hasDuplicate == YES")
            return ((try? context.count(for: request)) ?? 0, !changed.isEmpty)
        }
    }

    /// The hashes more than one photo (virtual copies aside) has.
    nonisolated private static func sharedHashes(in context: NSManagedObjectContext) -> [String] {
        let request = NSFetchRequest<NSDictionary>(entityName: "Photo")
        request.resultType = .dictionaryResultType
        let count = NSExpressionDescription()
        count.name = "count"
        count.expression = NSExpression(forFunction: "count:", arguments: [NSExpression(forKeyPath: "contentHash")])
        count.expressionResultType = .integer64AttributeType
        request.predicate = NSPredicate(format: "contentHash != nil AND master == nil")
        request.propertiesToFetch = ["contentHash", count]
        request.propertiesToGroupBy = ["contentHash"]
        return ((try? context.fetch(request)) ?? []).compactMap { row in
            guard let hash = row["contentHash"] as? String, (row["count"] as? Int ?? 0) > 1 else { return nil }
            return hash
        }
    }
}
