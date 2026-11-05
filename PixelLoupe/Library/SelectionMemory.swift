import CoreData

/// A Library source whose selection is remembered (RAW-259).
nonisolated enum SelectionSource: Codable, Hashable, Sendable {
    case allPhotos
    case folder(path: String)
    /// A collection, smart collection or collection set.
    case collection(id: UUID)
    /// Previous Import, for one import: a newer import starts with nothing remembered.
    case previousImport(id: UUID)
    case publishService(id: UUID)
    case publishAlbum(id: UUID)

    /// The source a grid scope is; nil for one that isn't remembered (a Lightroom import's differences).
    init?(_ scope: LibraryFilter.Scope) {
        switch scope {
        case .allPhotos: self = .allPhotos
        case .folder(let path): self = .folder(path: path)
        case .collection(let id, _): self = .collection(id: id)
        case .previousImport(let id): self = .previousImport(id: id)
        case .publishService(let id): self = .publishService(id: id)
        case .publishAlbum(let id, _, _): self = .publishAlbum(id: id)
        case .importDifference: return nil
        }
    }
}

/// One source's remembered selection, as saved in the catalog's view state.
nonisolated struct RememberedSelection: Codable, Equatable, Sendable {
    var source: SelectionSource
    /// `Photo.id`s, the active photo first.
    var photos: [UUID]
}

/// The selection each Library source last had, so coming back to a folder or collection selects (and shows) the
/// photos it had selected (RAW-259).
///
/// The grid shows only what the filter bar and collapsed stacks let it, so the selection on screen can be a part of
/// the one remembered: the remembered selection changes only when the person (or a command) changes the
/// selection, not when a filter hides some of it.
final class SelectionMemory {
    /// How many sources are remembered; the ones visited longest ago are forgotten first.
    static let maximumSources = 200

    private struct Entry {
        var source: SelectionSource
        var photos: [UUID]
        /// The photos as objects, once looked up or remembered in this session.
        var objectIDs: [NSManagedObjectID]?
    }

    private let context: NSManagedObjectContext
    /// Most recently selected in first.
    private var entries: [Entry]

    /// The selections saved with the catalog, without those for folders, collections, publish services and albums
    /// that are gone, or for an import that's no longer the latest.
    init(saved: [RememberedSelection], context: NSManagedObjectContext) {
        self.context = context
        entries = Self.existing(saved, in: context).prefix(Self.maximumSources).map {
            Entry(source: $0.source, photos: $0.photos, objectIDs: nil)
        }
    }

    /// What to save with the catalog.
    var saved: [RememberedSelection] {
        entries.map { RememberedSelection(source: $0.source, photos: $0.photos) }
    }

    /// The selection `scope` remembers, the active photo first; nil if it remembers none.
    func selection(for scope: LibraryFilter.Scope) -> [NSManagedObjectID]? {
        guard let source = SelectionSource(scope), let index = entries.firstIndex(where: { $0.source == source }) else { return nil }
        if let objectIDs = entries[index].objectIDs { return objectIDs }
        let request = Photo.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", entries[index].photos)
        let byID = Dictionary(((try? context.fetch(request)) ?? []).map { ($0.id, $0.objectID) }) { first, _ in first }
        let objectIDs = entries[index].photos.compactMap { byID[$0] }
        entries[index].objectIDs = objectIDs
        return objectIDs
    }

    /// The `Photo.id`s `scope` remembers, the active photo first; nil if it remembers none.
    func photos(for scope: LibraryFilter.Scope) -> [UUID]? {
        guard let source = SelectionSource(scope) else { return nil }
        return entries.first { $0.source == source }?.photos
    }

    /// Remembers `selection` (the active photo first) as `scope`'s.
    func remember(_ selection: [NSManagedObjectID], for scope: LibraryFilter.Scope) {
        guard let source = SelectionSource(scope) else { return }
        let saved = Array(selection.prefix(CatalogViewState.maximumSavedSelection))
        if let first = entries.first, first.source == source, first.objectIDs == saved { return }
        let photos = saved.compactMap { (try? context.existingObject(with: $0) as? Photo)?.id }
        entries.removeAll { entry in
            entry.source == source || {
                // Only the latest import is remembered.
                if case .previousImport = source, case .previousImport = entry.source { return true }
                return false
            }()
        }
        entries.insert(Entry(source: source, photos: photos, objectIDs: saved), at: 0)
        if entries.count > Self.maximumSources { entries.removeLast(entries.count - Self.maximumSources) }
    }

    /// Moves what a folder (and the folders inside it) remember to its new path after a rename, move or relink.
    func renameFolder(from oldPath: String, to newPath: String) {
        for index in entries.indices {
            guard case .folder(let path) = entries[index].source, path == oldPath || path.hasPrefix(oldPath + "/") else { continue }
            entries[index].source = .folder(path: newPath + String(path.dropFirst(oldPath.count)))
        }
        // Relinking onto a folder that's already remembered keeps whichever was selected in more recently.
        var seen = Set<SelectionSource>()
        entries.removeAll { !seen.insert($0.source).inserted }
    }

    /// The saved selections whose sources still exist.
    private static func existing(_ saved: [RememberedSelection], in context: NSManagedObjectContext) -> [RememberedSelection] {
        func ids<T: NSManagedObject>(_ type: T.Type, key: String, among values: [Any]) -> Set<AnyHashable> {
            guard !values.isEmpty else { return [] }
            let request = NSFetchRequest<NSDictionary>(entityName: T.entity().name ?? "")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = [key]
            request.predicate = NSPredicate(format: "%K IN %@", key, values)
            return Set(((try? context.fetch(request)) ?? []).compactMap { $0[key] as? AnyHashable })
        }
        var folders: [String] = [], collections: [UUID] = [], services: [UUID] = [], albums: [UUID] = []
        for entry in saved {
            switch entry.source {
            case .folder(let path): folders.append(path)
            case .collection(let id): collections.append(id)
            case .publishService(let id): services.append(id)
            case .publishAlbum(let id): albums.append(id)
            case .allPhotos, .previousImport: break
            }
        }
        let existingFolders = ids(Folder.self, key: "path", among: folders)
        let existingCollections = ids(PhotoCollection.self, key: "id", among: collections)
        let existingServices = ids(PublishService.self, key: "id", among: services)
        let existingAlbums = ids(PublishAlbum.self, key: "id", among: albums)
        let latestImport = saved.contains { if case .previousImport = $0.source { true } else { false } } ? Photo.latestImportID(in: context) : nil
        var seen = Set<SelectionSource>()
        return saved.filter { entry in
            guard seen.insert(entry.source).inserted else { return false }
            switch entry.source {
            case .allPhotos: return true
            case .folder(let path): return existingFolders.contains(path)
            case .collection(let id): return existingCollections.contains(id)
            case .publishService(let id): return existingServices.contains(id)
            case .publishAlbum(let id): return existingAlbums.contains(id)
            case .previousImport(let id): return id == latestImport
            }
        }
    }
}
