import CoreData
import Foundation
import OSLog

/// Draws a catalog's Standard previews (see ``StandardPreviewStore``) in the background at low priority, one photo at
/// a time: those an import or Library ▸ Previews ▸ Build Standard Previews asks for, which also get their grid
/// thumbnail drawn from the same render, and those made stale by an edit, about two seconds after the photo was last
/// changed. When the catalog opens, previews left stale by the last session are drawn again.
///
/// Only camera RAW files get Standard previews; other files' thumbnails are already decoded from the full image.
/// Closing the catalog stops it, dropping the photos still waiting.
@MainActor
final class StandardPreviewBuilder {
    /// How long a photo must go unedited before its stale Standard preview is drawn again, so dragging a slider
    /// doesn't keep re-rendering it.
    static let rebuildDelay: Duration = .seconds(2)

    private unowned let store: CatalogStore
    private var waiting: [UUID] = []
    /// Waiting photos, and whether each also wants its thumbnail drawn.
    private var queued: [UUID: Bool] = [:]
    private var isStarted = false
    /// Changed by `stop()`, so a run that outlives it ends quietly.
    private var generation = 0
    private var task: Task<Void, Never>?
    private var staleCheck: Task<Void, Never>?
    private var rebuilds: [UUID: Task<Void, Never>] = [:]
    var rebuildDelay = StandardPreviewBuilder.rebuildDelay
    private static let logger = Logger(subsystem: "net.pixegen.PixelLoupe", category: "StandardPreviews")

    /// The photos done and asked for since the builder was last idle, for the progress shown under the grid; nil
    /// while idle. Rebuilds after edits aren't counted.
    private(set) var progress: LibraryState.ImportStatus? {
        didSet { if progress != oldValue { onProgress(progress) } }
    }
    var onProgress: (LibraryState.ImportStatus?) -> Void = { _ in }

    init(store: CatalogStore) {
        self.store = store
    }

    /// Starts building what's asked for, and after `delay` (so opening the catalog stays snappy) redraws previews
    /// left stale by the last session.
    func start(after delay: Duration = .seconds(6)) {
        guard !isStarted else { return }
        isStarted = true
        staleCheck = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await store.standardPreviews.load()
            guard !Task.isCancelled else { return }
            let stale = store.standardPreviews.stale.sorted { $0.uuidString < $1.uuidString }
            guard !stale.isEmpty else { return }
            Self.logger.info("Redrawing \(stale.count) stale Standard previews")
            enqueue(stale, thumbnail: false, counted: false)
        }
        runIfNeeded()
    }

    func stop() {
        isStarted = false
        generation += 1
        task?.cancel()
        task = nil
        staleCheck?.cancel()
        staleCheck = nil
        rebuilds.values.forEach { $0.cancel() }
        rebuilds = [:]
        waiting = []
        queued = [:]
        progress = nil
    }

    /// Waits until nothing is waiting; used by tests.
    func waitUntilIdle() async {
        await staleCheck?.value
        while !rebuilds.isEmpty, let rebuild = rebuilds.values.first {
            await rebuild.value
        }
        while let task {
            await task.value
        }
    }

    /// Whether `photo` can have a Standard preview: a camera RAW still.
    static func isEligible(_ photo: Photo) -> Bool {
        !photo.isVideo && SupportedImageTypes.isRaw(photo.fileURL)
    }

    /// Queues Standard previews, with their thumbnails, for the eligible photos among `photos`.
    func build(_ photos: [Photo]) {
        enqueue(photos.filter(Self.isEligible).map(\.id), thumbnail: true, counted: true)
    }

    /// The photo was edited: its Standard preview (already marked stale) is drawn again once it has gone unedited
    /// for ``rebuildDelay``.
    func scheduleRebuild(_ id: UUID) {
        rebuilds[id]?.cancel()
        let delay = rebuildDelay
        rebuilds[id] = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            rebuilds[id] = nil
            enqueue([id], thumbnail: false, counted: false)
        }
    }

    private func enqueue(_ ids: [UUID], thumbnail: Bool, counted: Bool) {
        var added = 0
        for id in ids {
            if let wantsThumbnail = queued[id] {
                queued[id] = wantsThumbnail || thumbnail
            } else {
                queued[id] = thumbnail
                waiting.append(id)
                added += 1
            }
        }
        if counted, added > 0 {
            progress = LibraryState.ImportStatus(completed: progress?.completed ?? 0, total: (progress?.total ?? 0) + added)
        }
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
        while generation == self.generation, !waiting.isEmpty {
            let id = waiting.removeFirst()
            let thumbnail = queued[id] ?? false
            await draw(id, thumbnail: thumbnail)
            queued[id] = nil
            guard generation == self.generation else { return }
            if let progress, progress.completed < progress.total { self.progress?.completed += 1 }
            await Task.yield()
        }
        guard generation == self.generation else { return }
        task = nil
        progress = nil
    }

    private func draw(_ id: UUID, thumbnail: Bool) async {
        let request = Photo.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        guard let photo = try? store.viewContext.fetch(request).first, Self.isEligible(photo) else { return }
        let previews = store.standardPreviews
        // A preview that's current and not wanted for a thumbnail has nothing to do.
        if previews.isCurrent(id), !thumbnail { return }
        let adjustmentsData = photo.adjustmentsData
        let drawn = await StandardPreviewStore.draw(
            store.sourceLocation(of: photo), adjustments: photo.adjustments,
            to: previews.url(for: id), thumbnail: thumbnail ? store.thumbnails.url(for: id) : nil
        )
        guard let drawn else {
            Self.logger.info("No Standard preview for \(photo.fileName, privacy: .public)")
            return
        }
        guard !photo.isDeleted, photo.managedObjectContext != nil else { return }
        previews.didWrite(id)
        if drawn.wroteThumbnail { store.thumbnails.didRender(id, fromSmartPreview: drawn.fromSmartPreview) }
        // Edited while it was drawing: what was drawn is already out of date.
        if photo.adjustmentsData != adjustmentsData {
            previews.invalidate(id)
            scheduleRebuild(id)
        }
    }
}
