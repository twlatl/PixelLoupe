import CoreData
import Foundation
import OSLog

/// Scores photos for Assisted Culling (RAW-71) in the background at low priority, one at a time: those asked
/// for (the Assisted Culling panel's Analyze), and photos that were analyzed from their thumbnail alone once their
/// original or a Smart Preview can be read again, to measure their focus.
///
/// Scores are written with undo registration off, so they never become a step in Edit ▸ Undo, and saved every few
/// photos. (Saving them through a background context doesn't help: merging its changes registers them.) A virtual
/// copy is analyzed as its
/// master, and the scores go to both. Closing the catalog stops it, dropping the photos still waiting; a photo
/// that was never scored stays unanalyzed until asked for again.
@MainActor
final class CullingAnalysis {
    private unowned let store: CatalogStore
    /// The masters' IDs to analyze, in order.
    private var waiting: [UUID] = []
    private var queued = Set<UUID>()
    private var isStarted = false
    /// Changed by `stop()`, so a run that outlives it ends quietly.
    private var generation = 0
    private var task: Task<Void, Never>?
    private var pendingCheck: Task<Void, Never>?
    private var availabilityObserver: NSObjectProtocol?
    nonisolated private static let logger = Logger(subsystem: "net.pixegen.PixelLoupe", category: "Culling")
    /// Photos analyzed between saves.
    nonisolated static let saveInterval = 20

    /// The photos done and asked for since the analysis was last idle, for the Assisted Culling panel; nil while
    /// idle.
    private(set) var progress: LibraryState.ImportStatus? {
        didSet { if progress != oldValue { onProgress(progress) } }
    }
    var onProgress: (LibraryState.ImportStatus?) -> Void = { _ in }

    init(store: CatalogStore) {
        self.store = store
    }

    /// Starts analyzing what's asked for, and after `delay` (so opening the catalog stays snappy) measures the
    /// focus of photos analyzed from their thumbnail whose pixels can now be read.
    func start(after delay: Duration = .seconds(8)) {
        guard !isStarted else { return }
        isStarted = true
        availabilityObserver = NotificationCenter.default.addObserver(
            forName: FileAvailability.didChangeNotification, object: store.availability, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPending(after: .seconds(1)) }
        }
        checkPending(after: delay)
        runIfNeeded()
    }

    func stop() {
        isStarted = false
        generation += 1
        if let availabilityObserver { NotificationCenter.default.removeObserver(availabilityObserver) }
        availabilityObserver = nil
        task?.cancel()
        task = nil
        pendingCheck?.cancel()
        pendingCheck = nil
        waiting = []
        queued = []
        progress = nil
    }

    /// Waits until nothing is waiting; used by tests.
    func waitUntilIdle() async {
        await pendingCheck?.value
        while let task {
            await task.value
        }
    }

    /// Queues `photos` that haven't been analyzed by this version of the analyzer, or all of them when `again`
    /// (Re-analyze). Videos are skipped.
    func analyze(_ photos: [Photo], again: Bool = false) {
        let masters = photos.filter { !$0.isVideo }.map { $0.master ?? $0 }
        enqueue(masters.filter { again || $0.cullVersion != CullingAnalyzer.version }.map(\.id))
    }

    private func checkPending(after delay: Duration) {
        guard isStarted, pendingCheck == nil else { return }
        pendingCheck = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            pendingCheck = nil
            // Until the files have been checked every photo looks readable; the check's notification comes back here.
            guard store.availability.hasChecked else { return }
            let request = Photo.fetchRequest()
            request.predicate = NSPredicate(format: "cullFocusPending == YES AND master == nil")
            let pending = (try? store.viewContext.fetch(request)) ?? []
            let readable = pending.filter { store.sourceStatus(of: $0) != .missing }
            guard !readable.isEmpty else { return }
            Self.logger.info("Measuring the focus of \(readable.count) photos whose pixels came back")
            enqueue(readable.map(\.id))
        }
    }

    private func enqueue(_ ids: [UUID]) {
        let new = ids.filter { queued.insert($0).inserted }
        guard !new.isEmpty else { return }
        waiting += new
        progress = LibraryState.ImportStatus(completed: progress?.completed ?? 0, total: (progress?.total ?? 0) + new.count)
        runIfNeeded()
    }

    private func runIfNeeded() {
        guard isStarted, task == nil, !waiting.isEmpty else { return }
        let generation = generation
        task = Task(priority: .utility) { [weak self] in
            await self?.run(generation)
        }
    }

    private func run(_ generation: Int) async {
        var unsaved = 0
        while generation == self.generation, !waiting.isEmpty {
            let id = waiting.removeFirst()
            if await analyzePhoto(id) { unsaved += 1 }
            queued.remove(id)
            guard generation == self.generation else { break }
            if unsaved >= Self.saveInterval {
                store.save()
                unsaved = 0
            }
            progress?.completed += 1
            await Task.yield()
        }
        if unsaved > 0 { store.save() }
        guard generation == self.generation else { return }
        task = nil
        progress = nil
    }

    /// Analyzes the photo with `id` and writes its scores; false when it couldn't be.
    private func analyzePhoto(_ id: UUID) async -> Bool {
        let request = Photo.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        guard let photo = try? store.viewContext.fetch(request).first, !photo.isVideo else { return false }
        let location = store.sourceLocation(of: photo), thumbnail = store.thumbnails.url(for: id)
        guard let scores = await CullingAnalyzer.analyze(location, thumbnail: thumbnail) else {
            Self.logger.info("Couldn't analyze \(photo.fileName, privacy: .public)")
            return false
        }
        // Removed while it was being analyzed.
        guard !photo.isDeleted, let context = photo.managedObjectContext else { return false }
        context.processPendingChanges()
        context.undoManager?.disableUndoRegistration()
        scores.write(to: photo)
        context.processPendingChanges()
        context.undoManager?.enableUndoRegistration()
        return true
    }
}
