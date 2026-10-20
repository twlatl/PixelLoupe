import AppKit
import CoreData
import CoreServices

/// Watches folders for changes to the files in them. A protocol so tests can stand in for FSEvents.
protocol FolderWatching: AnyObject {
    /// Called on the main thread with the paths of changed files.
    var onChange: (([String]) -> Void)? { get set }
    /// Watches exactly these folders (replacing the previous set).
    func watch(_ folders: Set<String>)
    func stop()
}

/// Brings other apps' edits back into the catalog, the second half of Photo ▸ Edit In.
///
/// While the catalog is open, the folders of files handed to an editor are watched with FSEvents, so
/// a save shows up as soon as it lands (FSEvents also sees saves that write a temporary file and
/// rename it over the original). A change asks ``FileAvailability`` to recheck that folder, and any
/// check — including the ones when the catalog opens and when PixelLoupe becomes active — reports
/// files newer than their thumbnails. Those photos are reloaded here: the catalog's record of the
/// file is updated, the thumbnail is redrawn, and Develop and Compare reload the photo. Develop
/// settings are left alone (they still apply on top), and none of this is undoable: it follows the file.
final class ExternalEditMonitor {
    /// Posted (on the main thread, with this object) after a photo's file was reloaded.
    /// `userInfo["id"]` is the photo's UUID.
    static let photoFileDidChangeNotification = Notification.Name("ExternalEditPhotoFileDidChange")

    private unowned let store: CatalogStore
    private let watcher: FolderWatching
    /// Paths of files handed to an editor this session.
    private(set) var trackedPaths = Set<String>()
    private var pendingFolders = Set<String>()
    private var debounce: Task<Void, Never>?
    private var reloading = Set<UUID>()
    private var reloads: [Task<Void, Never>] = []
    private var observer: NSObjectProtocol?

    init(store: CatalogStore, watcher: FolderWatching = FSEventsFolderWatcher()) {
        self.store = store
        self.watcher = watcher
        watcher.onChange = { [weak self] paths in self?.filesChanged(paths) }
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: FileAvailability.filesDidChangeNotification, object: store.availability, queue: .main
        ) { [weak self] notification in
            let ids = notification.userInfo?["ids"] as? Set<UUID>
            MainActor.assumeIsolated {
                if let ids { self?.reload(ids) }
            }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        watcher.stop()
        debounce?.cancel()
        for task in reloads { task.cancel() }
        reloads = []
    }

    /// Starts watching files just handed to an editor.
    func track(_ urls: [URL]) {
        trackedPaths.formUnion(urls.map { $0.standardizedFileURL.path(percentEncoded: false) })
        watcher.watch(Set(trackedPaths.map { ($0 as NSString).deletingLastPathComponent }))
    }

    /// Editors write a file in several steps; wait for them to settle, then recheck those folders.
    private func filesChanged(_ paths: [String]) {
        let tracked = paths.map { URL(filePath: $0).standardizedFileURL.path(percentEncoded: false) }.filter(trackedPaths.contains)
        guard !tracked.isEmpty else { return }
        pendingFolders.formUnion(tracked.map { ($0 as NSString).deletingLastPathComponent })
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            let folders = pendingFolders
            pendingFolders = []
            for folder in folders { store.availability.refresh(folderPath: folder) }
        }
    }

    // MARK: - Reloading

    /// Updates the photos whose files changed and redraws their thumbnails.
    func reload(_ ids: Set<UUID>) {
        let ids = ids.subtracting(reloading)
        guard !ids.isEmpty else { return }
        reloading.formUnion(ids)
        let request = Photo.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", ids)
        let photos = (try? store.viewContext.fetch(request)) ?? []
        let urls = Array(Set(photos.map(\.fileURL)))
        let task = Task { [weak self] in
            let files = await Self.read(urls)
            guard let self, !Task.isCancelled else { return }
            apply(files, to: photos.map(\.objectID))
            for photo in photos where !photo.isDeleted {
                let id = photo.id
                _ = await store.thumbnails.render(id: id, source: store.sourceLocation(of: photo), adjustments: photo.adjustments)
                NotificationCenter.default.post(name: Self.photoFileDidChangeNotification, object: self, userInfo: ["id": id])
            }
            reloading.subtract(ids)
        }
        reloads.removeAll { $0.isCancelled }
        reloads.append(task)
    }

    /// Waits for reloads in flight; used by tests.
    func waitForReloads() async {
        for task in reloads { await task.value }
        reloads = []
    }

    nonisolated struct FileDetails: Sendable {
        var metadata: ImageMetadata?
        var fileSize: Int64?
    }

    @concurrent
    nonisolated private static func read(_ urls: [URL]) async -> [URL: FileDetails] {
        var details: [URL: FileDetails] = [:]
        for url in urls {
            details[url] = FileDetails(
                metadata: ImageMetadata.read(from: url),
                fileSize: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            )
        }
        return details
    }

    /// The editor may have cropped, resized or flattened the photo: the catalog follows the file.
    private func apply(_ files: [URL: FileDetails], to ids: [NSManagedObjectID]) {
        let context = store.viewContext
        context.processPendingChanges()
        context.undoManager?.disableUndoRegistration()
        defer {
            context.processPendingChanges()
            context.undoManager?.enableUndoRegistration()
        }
        for id in ids {
            guard let photo = try? context.existingObject(with: id) as? Photo, let file = files[photo.fileURL] else { continue }
            if let fileSize = file.fileSize, photo.fileSize != fileSize {
                photo.fileSize = fileSize
                photo.dedupeKey = ImportService.dedupeKey(
                    url: photo.fileURL, fileSize: fileSize, date: photo.captureDate, mode: store.info.storageMode
                )
            }
            if let metadata = file.metadata, metadata.pixelWidth > 0, metadata.pixelHeight > 0 {
                if photo.pixelWidth != Int32(metadata.pixelWidth) { photo.pixelWidth = Int32(metadata.pixelWidth) }
                if photo.pixelHeight != Int32(metadata.pixelHeight) { photo.pixelHeight = Int32(metadata.pixelHeight) }
                if photo.orientation != Int16(metadata.orientation) { photo.orientation = Int16(metadata.orientation) }
            }
        }
        if context.hasChanges { store.save() }
    }
}

/// ``FolderWatching`` with an FSEvents stream reporting file-level events, delivered on the main queue.
final class FSEventsFolderWatcher: FolderWatching {
    var onChange: (([String]) -> Void)?
    private var stream: FSEventStreamRef?
    private var folders = Set<String>()

    func watch(_ folders: Set<String>) {
        guard folders != self.folders else { return }
        stop()
        self.folders = folders
        guard !folders.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            let watcher = Unmanaged<FSEventsFolderWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange?(Array(changed.prefix(count))) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, Array(folders) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        folders = []
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        // FSEvents keeps an unretained pointer to the watcher.
        MainActor.assumeIsolated { stop() }
    }
}
