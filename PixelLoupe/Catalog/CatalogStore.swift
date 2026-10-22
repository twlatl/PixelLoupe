import AppKit
import CoreData
import OSLog

enum CatalogError: LocalizedError {
    case alreadyExists(URL)
    case notACatalog(URL)
    case unsupportedVersion(Int)
    case missingStorageLocation

    var errorDescription: String? {
        switch self {
        case .alreadyExists(let url):
            "A catalog named “\(url.lastPathComponent)” already exists."
        case .notACatalog(let url):
            "“\(url.lastPathComponent)” is not a PixelLoupe catalog."
        case .unsupportedVersion(let version):
            "This catalog was created by a newer version of PixelLoupe (format \(version))."
        case .missingStorageLocation:
            "Choose a folder where imported photos will be stored."
        }
    }
}

/// An open catalog: its package on disk, settings, Core Data stack and thumbnail cache.
///
/// Each catalog is a self-contained `.pixelloupe` package holding its own SQLite store and
/// thumbnails, so catalogs can be moved, backed up or opened independently.
final class CatalogStore: NSObject {
    let packageURL: URL
    private(set) var info: CatalogInfo
    let container: NSPersistentContainer
    let thumbnails: ThumbnailStore
    /// Stand-ins for originals that can't be read (see ``SmartPreviewStore``).
    let smartPreviews: SmartPreviewStore
    /// Which photos and folders can't be found on disk (see ``FileAvailability``).
    private(set) lazy var availability = FileAvailability(store: self)
    /// Draws missing thumbnails and redraws Lightroom-seeded ones in the background.
    private(set) lazy var thumbnailMaintenance = ThumbnailMaintenance(store: self)
    /// Writes Smart Previews in the background.
    private(set) lazy var smartPreviewBuilder = SmartPreviewBuilder(store: self)
    /// Scores photos for Assisted Culling in the background.
    private(set) lazy var cullingAnalysis = CullingAnalysis(store: self)
    /// Reads the locations of photos from before model v16 (see ``LocationBackfill``).
    private(set) lazy var locationBackfill = LocationBackfill(store: self)
    /// Brings back edits other apps save to files sent with Photo ▸ Edit In (see ``ExternalEditMonitor``).
    private(set) lazy var externalEdits = ExternalEditMonitor(store: self)

    private static let logger = Logger(subsystem: "net.pixegen.PixelLoupe", category: "Catalog")

    /// Loaded once; multiple models describing the same entities confuse Core Data's class mapping.
    static let managedObjectModel: NSManagedObjectModel = {
        guard let url = Bundle(for: Photo.self).url(forResource: "PixelLoupe", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: url) else {
            fatalError("PixelLoupe.momd missing from bundle")
        }
        return model
    }()

    var viewContext: NSManagedObjectContext { container.viewContext }
    var name: String { info.name }

    /// Window state saved in the package, such as which sidebar folders are expanded.
    var viewState: CatalogViewState {
        didSet {
            guard viewState != oldValue else { return }
            do {
                try viewState.save(to: packageURL)
            } catch {
                Self.logger.error("Failed to save view state: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private init(packageURL: URL, info: CatalogInfo, inMemory: Bool) throws {
        self.packageURL = packageURL
        self.info = info
        self.viewState = CatalogViewState.load(from: packageURL)
        self.thumbnails = ThumbnailStore(directory: CatalogPackage.thumbnailsURL(in: packageURL))
        self.smartPreviews = SmartPreviewStore(directory: CatalogPackage.smartPreviewsURL(in: packageURL))

        container = NSPersistentContainer(name: "PixelLoupe", managedObjectModel: Self.managedObjectModel)
        let description = NSPersistentStoreDescription(
            url: inMemory ? URL(filePath: "/dev/null") : CatalogPackage.databaseURL(in: packageURL)
        )
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]
        super.init()

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }

        // Keywords from before they had a tree get their paths.
        Tag.backfillPathKeys(in: container.viewContext)
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        container.viewContext.undoManager = UndoManager()

        NotificationCenter.default.addObserver(
            self, selector: #selector(viewContextObjectsDidChange(_:)),
            name: .NSManagedObjectContextObjectsDidChange, object: container.viewContext
        )
    }

    /// Re-renders thumbnails when a photo's Develop settings change, including through undo.
    @objc private func viewContextObjectsDidChange(_ notification: Notification) {
        let updated = notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? []
        for case let photo as Photo in updated
        where photo.changedValuesForCurrentEvent()[#keyPath(Photo.adjustmentsData)] != nil {
            thumbnails.regenerate(id: photo.id, source: sourceLocation(of: photo), adjustments: photo.adjustments)
        }
    }

    /// Creates a new catalog package at `packageURL` and opens it.
    static func create(at packageURL: URL, info: CatalogInfo) throws -> CatalogStore {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: packageURL.path(percentEncoded: false)) {
            throw CatalogError.alreadyExists(packageURL)
        }
        if info.storageMode == .managed {
            guard let storageURL = info.storageURL else { throw CatalogError.missingStorageLocation }
            try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
        }
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: CatalogPackage.thumbnailsURL(in: packageURL), withIntermediateDirectories: true)
        try writeInfo(info, to: packageURL)
        logger.info("Created catalog at \(packageURL.path(percentEncoded: false), privacy: .public)")
        return try CatalogStore(packageURL: packageURL, info: info, inMemory: false)
    }

    /// Closes the catalog and deletes its package, e.g. when an import into it is cancelled. The
    /// store must not be used afterwards.
    func closeAndDelete() {
        NotificationCenter.default.removeObserver(self)
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores { try? coordinator.remove(store) }
        try? FileManager.default.removeItem(at: packageURL)
    }

    /// Opens an existing catalog package.
    static func open(at packageURL: URL) throws -> CatalogStore {
        let infoURL = CatalogPackage.infoURL(in: packageURL)
        guard let data = try? Data(contentsOf: infoURL) else { throw CatalogError.notACatalog(packageURL) }
        let info = try PropertyListDecoder().decode(CatalogInfo.self, from: data)
        guard info.formatVersion <= CatalogInfo.currentFormatVersion else {
            throw CatalogError.unsupportedVersion(info.formatVersion)
        }
        try FileManager.default.createDirectory(
            at: CatalogPackage.thumbnailsURL(in: packageURL), withIntermediateDirectories: true
        )
        return try CatalogStore(packageURL: packageURL, info: info, inMemory: false)
    }

    /// An in-memory catalog for tests and previews. Thumbnails go to `packageURL`.
    static func inMemory(info: CatalogInfo, packageURL: URL) throws -> CatalogStore {
        try FileManager.default.createDirectory(
            at: CatalogPackage.thumbnailsURL(in: packageURL), withIntermediateDirectories: true
        )
        return try CatalogStore(packageURL: packageURL, info: info, inMemory: true)
    }

    private static func writeInfo(_ info: CatalogInfo, to packageURL: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(info).write(to: CatalogPackage.infoURL(in: packageURL), options: .atomic)
    }

    /// Deletes cached thumbnails and Smart Previews of photos no longer in the catalog. Removed photos
    /// keep theirs while the app runs, so undoing a removal shows them straight away; this runs when
    /// the catalog opens, in the background.
    func pruneOrphanedPreviews() {
        let context = newBackgroundContext()
        let directory = thumbnails.directory, smartPreviews = smartPreviews.directory
        context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "Photo")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id"]
            // Only after a successful fetch: an empty answer must never mean "delete everything".
            guard let rows = try? context.fetch(request) else { return }
            let kept = Set(rows.compactMap { $0["id"] as? UUID })
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jpg" {
                guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !kept.contains(id) else { continue }
                try? FileManager.default.removeItem(at: file)
            }
            SmartPreviewStore.pruneOrphans(in: smartPreviews, keeping: kept)
        }
    }

    func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        return context
    }

    func save() {
        guard viewContext.hasChanges else { return }
        do {
            try viewContext.save()
        } catch {
            Self.logger.error("Failed to save catalog: \(error.localizedDescription, privacy: .public)")
            NSApp?.presentError(error)
        }
    }
}
