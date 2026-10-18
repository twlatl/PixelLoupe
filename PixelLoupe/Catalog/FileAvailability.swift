import AppKit
import CoreData

/// Which of a catalog's photos and folders can't be found on disk right now.
///
/// The answer is computed in the background and cached here, so views (and the main thread) only
/// ever look up a set. It is recomputed when the catalog window opens, when a volume is mounted,
/// unmounted or renamed, when PixelLoupe becomes the active app, and for a folder's photos when the
/// folder is selected.
///
/// The same pass notices photos whose file was changed by another app (for example after Photo ▸
/// Edit In): a file newer than its thumbnail. Those are posted with `filesDidChangeNotification`.
@MainActor
final class FileAvailability {
    /// Posted (on the main thread, with this object) whenever the cached answer changes.
    nonisolated static let didChangeNotification = Notification.Name("FileAvailabilityDidChange")
    /// Posted (on the main thread, with this object) when a check finds files changed since their
    /// thumbnails were drawn. `userInfo["ids"]` is the photos' `Set<UUID>`.
    nonisolated static let filesDidChangeNotification = Notification.Name("FileAvailabilityFilesDidChange")

    private(set) var missingPhotoIDs = Set<UUID>()
    /// Paths of catalog folders whose directory doesn't exist.
    private(set) var offlineFolderPaths = Set<String>()
    /// Whether a first check has finished.
    private(set) var hasChecked = false

    private unowned let store: CatalogStore
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    private var debounce: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var activationObserver: NSObjectProtocol?

    init(store: CatalogStore) {
        self.store = store
    }

    func isMissing(_ id: UUID) -> Bool { missingPhotoIDs.contains(id) }
    func isOffline(folderPath: String) -> Bool { offlineFolderPaths.contains(folderPath) }

    // MARK: - Monitoring

    /// Checks everything now and again whenever a volume comes or goes, or the app becomes active
    /// (the user may have been saving in another app).
    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.volumesDidChange() }
            })
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.volumesDidChange() }
        }
        refresh()
    }

    func stop() {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
        debounce?.cancel()
        for task in refreshTasks.values { task.cancel() }
        refreshTasks = [:]
    }

    /// A volume appears a moment before its folders can be read, and several notifications can
    /// arrive together, so wait briefly and check once.
    private func volumesDidChange() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    // MARK: - Checking

    /// Rechecks every photo and folder, or only those under `folderPath`.
    func refresh(folderPath: String? = nil) {
        let key = folderPath ?? ""
        refreshTasks[key]?.cancel()
        let context = store.newBackgroundContext()
        let thumbnails = store.thumbnails.directory
        refreshTasks[key] = Task { [weak self] in
            let result = await Self.check(context: context, under: folderPath, thumbnails: thumbnails)
            guard let self, !Task.isCancelled else { return }
            refreshTasks[key] = nil
            apply(result, under: folderPath)
        }
    }

    /// Waits for checks in flight; used by tests.
    func waitForRefresh() async {
        for task in Array(refreshTasks.values) { await task.value }
    }

    struct Result: Sendable {
        /// Every photo the check covered, so a scoped check can replace just those.
        var checkedPhotos: Set<UUID>
        var missingPhotos: Set<UUID>
        var offlineFolders: Set<String>
        /// Photos whose file is newer than their thumbnail.
        var changedPhotos: Set<UUID> = []
    }

    private func apply(_ result: Result, under folderPath: String?) {
        var missing = missingPhotoIDs
        var offline = offlineFolderPaths
        if folderPath != nil {
            // A scoped check only knows about its own photos and folders: swap those in.
            missing.subtract(result.checkedPhotos)
            offline = offline.filter { !Self.isPath($0, under: folderPath!) }
        } else {
            missing = []
            offline = []
        }
        missing.formUnion(result.missingPhotos)
        offline.formUnion(result.offlineFolders)
        hasChecked = true
        if !result.changedPhotos.isEmpty {
            NotificationCenter.default.post(name: Self.filesDidChangeNotification, object: self, userInfo: ["ids": result.changedPhotos])
        }
        guard missing != missingPhotoIDs || offline != offlineFolderPaths else { return }
        missingPhotoIDs = missing
        offlineFolderPaths = offline
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    nonisolated private static func isPath(_ path: String, under folder: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }

    /// Replaces the cached state directly. For tests and for relinking, which knows the answer.
    func set(missing: Set<UUID>, offlineFolders: Set<String>) {
        missingPhotoIDs = missing
        offlineFolderPaths = offlineFolders
        hasChecked = true
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    @concurrent
    private static func check(context: NSManagedObjectContext, under folderPath: String?, thumbnails: URL) async -> Result {
        let (photos, videos, folders): ([(UUID, String)], Set<UUID>, [String]) = await context.perform {
            let photoRequest = NSFetchRequest<NSDictionary>(entityName: "Photo")
            photoRequest.resultType = .dictionaryResultType
            photoRequest.propertiesToFetch = ["id", "filePath", "isVideo"]
            let folderRequest = NSFetchRequest<NSDictionary>(entityName: "Folder")
            folderRequest.resultType = .dictionaryResultType
            folderRequest.propertiesToFetch = ["path"]
            if let folderPath {
                photoRequest.predicate = NSPredicate(format: "filePath BEGINSWITH %@", folderPath + "/")
                folderRequest.predicate = NSPredicate(format: "path == %@ OR path BEGINSWITH %@", folderPath, folderPath + "/")
            }
            let rows = (try? context.fetch(photoRequest)) ?? []
            let photos = rows.compactMap { row -> (UUID, String)? in
                guard let id = row["id"] as? UUID, let path = row["filePath"] as? String else { return nil }
                return (id, path)
            }
            let videos = Set(rows.compactMap { row in (row["isVideo"] as? Bool == true) ? row["id"] as? UUID : nil })
            let folders = ((try? context.fetch(folderRequest)) ?? []).compactMap { $0["path"] as? String }
            return (photos, videos, folders)
        }

        // Which directories exist, checked once each.
        var directories = Set(folders)
        for (_, path) in photos { directories.insert((path as NSString).deletingLastPathComponent) }
        let exists = await directoryExistence(Array(directories))

        // Files in directories that exist.
        var byDirectory: [String: [(UUID, String)]] = [:]
        var missing = Set<UUID>()
        for (id, path) in photos {
            let directory = (path as NSString).deletingLastPathComponent
            if exists[directory] == true {
                byDirectory[directory, default: []].append((id, path))
            } else {
                missing.insert(id)
            }
        }
        let thumbnailDates = thumbnailModificationDates(in: thumbnails)
        let files = await checkFiles(in: byDirectory, thumbnailDates: thumbnailDates, videos: videos)
        missing.formUnion(files.missing)
        return Result(
            checkedPhotos: Set(photos.map(\.0)), missingPhotos: missing, offlineFolders: Set(folders.filter { exists[$0] != true }),
            changedPhotos: files.changed
        )
    }

    /// When each thumbnail was last drawn, by photo id, from one listing of the thumbnail folder.
    nonisolated private static func thumbnailModificationDates(in directory: URL) -> [UUID: Date] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        var dates: [UUID: Date] = [:]
        for file in files where file.pathExtension == "jpg" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { continue }
            dates[id] = date
        }
        return dates
    }

    /// Whether a file changed after its thumbnail was drawn. A second's slack allows for file systems
    /// that keep coarse modification times.
    nonisolated static func isChanged(file: Date, thumbnail: Date) -> Bool {
        file.timeIntervalSince(thumbnail) > 1
    }

    nonisolated private static func directoryExistence(_ paths: [String]) async -> [String: Bool] {
        await withTaskGroup(of: (String, Bool).self) { group in
            var results: [String: Bool] = [:]
            var next = 0
            func addNext() {
                guard next < paths.count else { return }
                let path = paths[next]
                next += 1
                group.addTask {
                    var isDirectory: ObjCBool = false
                    return (path, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue)
                }
            }
            for _ in 0..<min(8, paths.count) { addNext() }
            while let (path, exists) = await group.next() {
                results[path] = exists
                addNext()
            }
            return results
        }
    }

    /// Which files are missing, and which (other than videos) changed after their thumbnail was
    /// drawn. One `stat` per file answers both.
    nonisolated private static func checkFiles(
        in byDirectory: [String: [(UUID, String)]], thumbnailDates: [UUID: Date], videos: Set<UUID>
    ) async -> (missing: Set<UUID>, changed: Set<UUID>) {
        let directories = Array(byDirectory.values)
        return await withTaskGroup(of: (missing: [UUID], changed: [UUID]).self) { group in
            var missing = Set<UUID>()
            var changed = Set<UUID>()
            var next = 0
            func addNext() {
                guard next < directories.count else { return }
                let files = directories[next]
                next += 1
                group.addTask {
                    var missing: [UUID] = [], changed: [UUID] = []
                    for (id, path) in files {
                        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                            missing.append(id)
                            continue
                        }
                        if !videos.contains(id), let thumbnail = thumbnailDates[id],
                           let modified = attributes[.modificationDate] as? Date, isChanged(file: modified, thumbnail: thumbnail) {
                            changed.append(id)
                        }
                    }
                    return (missing, changed)
                }
            }
            for _ in 0..<min(8, directories.count) { addNext() }
            while let result = await group.next() {
                missing.formUnion(result.missing)
                changed.formUnion(result.changed)
                addNext()
            }
            return (missing, changed)
        }
    }
}
