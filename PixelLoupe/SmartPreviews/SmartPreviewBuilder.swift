import CoreData
import Foundation
import OSLog

/// Writes a catalog's Smart Previews in the background at low priority, one photo at a time: those asked for with
/// Library ▸ Previews ▸ Build Smart Previews, and, shortly after the catalog opens, those whose original has changed
/// since (for example after Photo ▸ Edit In). A Smart Preview whose original is missing stays as it is.
///
/// Closing the catalog stops it, dropping the photos still waiting.
@MainActor
final class SmartPreviewBuilder {
    private unowned let store: CatalogStore
    /// The IDs to write Smart Previews under, in order.
    private var waiting: [UUID] = []
    private var queued = Set<UUID>()
    private var isStarted = false
    /// Changed by `stop()`, so a run that outlives it ends quietly.
    private var generation = 0
    private var task: Task<Void, Never>?
    private var staleCheck: Task<Void, Never>?
    private static let logger = Logger(subsystem: "net.pixegen.PixelLoupe", category: "SmartPreviews")

    /// The photos done and asked for since the builder was last idle, for the progress shown under the grid; nil
    /// while idle.
    private(set) var progress: LibraryState.ImportStatus? {
        didSet { if progress != oldValue { onProgress(progress) } }
    }
    var onProgress: (LibraryState.ImportStatus?) -> Void = { _ in }

    init(store: CatalogStore) {
        self.store = store
    }

    /// Starts building what's asked for, and after `delay` (so opening the catalog stays snappy) rebuilds Smart
    /// Previews whose original changed.
    func start(after delay: Duration = .seconds(6)) {
        guard !isStarted else { return }
        isStarted = true
        staleCheck = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await store.smartPreviews.load()
            let stale = await Self.stale(store.smartPreviews.files, context: store.newBackgroundContext())
            guard !Task.isCancelled, !stale.isEmpty else { return }
            Self.logger.info("Rebuilding \(stale.count) Smart Previews whose originals changed")
            enqueue(stale)
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
        waiting = []
        queued = []
        progress = nil
    }

    /// Waits until nothing is waiting; used by tests.
    func waitUntilIdle() async {
        await staleCheck?.value
        while let task {
            await task.value
        }
    }

    /// Queues Smart Previews for `photos`' files (a virtual copy's is its master's). Videos get none.
    func build(_ photos: [Photo]) {
        enqueue(photos.filter { !$0.isVideo }.map { ($0.master ?? $0).id })
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
        while generation == self.generation, !waiting.isEmpty {
            let id = waiting.removeFirst()
            await buildPreview(id)
            queued.remove(id)
            guard generation == self.generation else { return }
            progress?.completed += 1
            await Task.yield()
        }
        guard generation == self.generation else { return }
        task = nil
        progress = nil
    }

    private func buildPreview(_ id: UUID) async {
        let request = Photo.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        guard let photo = try? store.viewContext.fetch(request).first else { return }
        let smartPreviews = store.smartPreviews
        let existing = smartPreviews.file(for: photo)
        do {
            guard let written = try await Self.write(photo.fileURL, existing: existing, as: id, in: smartPreviews.directory)
            else { return }
            smartPreviews.didWrite(written, for: id, replacing: existing)
        } catch {
            Self.logger.info("No Smart Preview for \(photo.fileName, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Writes the Smart Preview of `original` named by `id` into `directory` (a catalog's Smart Previews folder),
    /// unless `existing` is current or the original is missing. Returns where it went, or nil when there was nothing to
    /// do.
    @concurrent
    nonisolated static func write(_ original: URL, existing: URL?, as id: UUID, in directory: URL) async throws -> URL? {
        guard FileManager.default.fileExists(atPath: original.path(percentEncoded: false)) else { return nil }
        if let existing, SmartPreviewInfo.read(from: existing)?.isCurrent(for: original) == true { return nil }
        guard let fileExtension = SmartPreviewWriter.fileExtension(for: original) else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = SmartPreviewStore.url(for: id, fileExtension: fileExtension, in: directory)

        // A camera RAW file gets its camera model's white-balance table, measured on the model's first Smart Preview.
        let tables = SmartPreviewWhiteBalance.directory(in: directory)
        let cameraModel = SmartPreviewWhiteBalance.cameraModel(of: original)
        let table = cameraModel.flatMap { SmartPreviewWhiteBalance.load(cameraModel: $0, in: tables) }
        let info = try SmartPreviewWriter.write(original: original, to: destination, whiteBalance: table)
        if table == nil, let cameraModel {
            let measured = try SmartPreviewWhiteBalance.measure(original: original, smartPreview: destination, smartPreviewScale: info.scale)
            try? measured.save(cameraModel: cameraModel, in: tables)
            try SmartPreviewWriter.write(original: original, to: destination, whiteBalance: measured)
        }
        return destination
    }

    /// The IDs of Smart Previews whose original is there and has changed since (or that can't be read).
    @concurrent
    nonisolated private static func stale(_ files: [UUID: URL], context: NSManagedObjectContext) async -> [UUID] {
        guard !files.isEmpty else { return [] }
        let paths: [UUID: String] = await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "Photo")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id", "filePath"]
            let rows = (try? context.fetch(request)) ?? []
            return Dictionary(rows.compactMap { row -> (UUID, String)? in
                guard let id = row["id"] as? UUID, let path = row["filePath"] as? String else { return nil }
                return (id, path)
            }, uniquingKeysWith: { first, _ in first })
        }
        var stale: [UUID] = []
        for (id, file) in files.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            if Task.isCancelled { return [] }
            guard let path = paths[id], FileManager.default.fileExists(atPath: path) else { continue }
            if SmartPreviewInfo.read(from: file)?.isCurrent(for: URL(filePath: path)) != true { stale.append(id) }
        }
        return stale
    }
}
