import AppKit
import CoreData

/// The Folders list's context menu actions that change the catalog (and, for Create Folder and
/// Rename, the disk). Each is one undo step.
struct FolderEditing {
    enum EditError: LocalizedError {
        case invalidName(String)
        case alreadyExists(String)
        case folderMissing(String)

        var errorDescription: String? {
            switch self {
            case .invalidName(let name): "“\(name)” can’t be used as a folder name."
            case .alreadyExists(let name): "A folder named “\(name)” already exists there."
            case .folderMissing(let name): "The folder “\(name)” can’t be found on disk."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .invalidName: "Folder names can’t be empty, start with a period or contain a slash or colon."
            case .alreadyExists: "Choose a different name."
            case .folderMissing: "Use Find Missing Folder… to tell PixelLoupe where it is."
            }
        }
    }

    let store: CatalogStore
    private var context: NSManagedObjectContext { store.viewContext }
    private var undoManager: UndoManager? { context.undoManager }

    func folder(at path: String) -> Folder? {
        let request = Folder.fetchRequest()
        request.predicate = NSPredicate(format: "path == %@", path)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    /// The photos in the folder and its subfolders (what the sidebar counts, and what the grid shows).
    func photos(in path: String) -> [Photo] {
        let request = Photo.fetchRequest()
        request.predicate = Self.subtreePredicate(path)
        request.fetchBatchSize = 500
        return (try? context.fetch(request)) ?? []
    }

    func photoCount(in path: String) -> Int {
        let request = Photo.fetchRequest()
        request.predicate = Self.subtreePredicate(path)
        return (try? context.count(for: request)) ?? 0
    }

    nonisolated static func subtreePredicate(_ path: String) -> NSPredicate {
        NSPredicate(format: "folder.path == %@ OR folder.path BEGINSWITH %@", path, path + "/")
    }

    private func commit(_ actionName: String) {
        undoManager?.setActionName(actionName)
        store.save()
    }

    /// Catalog changes that go with a change on disk: the disk change can't be undone by Core Data,
    /// so the caller registers its own undo instead.
    private func withoutAutomaticUndo(_ body: () throws -> Void) rethrows {
        context.processPendingChanges()
        undoManager?.disableUndoRegistration()
        defer {
            context.processPendingChanges()
            undoManager?.enableUndoRegistration()
        }
        try body()
    }

    static func validate(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("."), !trimmed.contains("/"), !trimmed.contains(":") else {
            throw EditError.invalidName(trimmed)
        }
        return trimmed
    }

    // MARK: - Create Folder Inside

    /// Makes a subfolder on disk and adds it to the catalog. Undo removes it again (and the directory,
    /// if it's still empty). Returns the new folder's path.
    @discardableResult
    func createFolder(named name: String, inside parentPath: String) throws -> String {
        let name = try Self.validate(name)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: parentPath) else {
            throw EditError.folderMissing((parentPath as NSString).lastPathComponent)
        }
        let path = (parentPath as NSString).appendingPathComponent(name)
        guard !fileManager.fileExists(atPath: path), folder(at: path) == nil else { throw EditError.alreadyExists(name) }
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: false)
        try withoutAutomaticUndo {
            let folder = Folder(context: context)
            folder.path = path
            folder.name = name
            folder.parent = self.folder(at: parentPath)
            try context.save()
        }
        undoManager?.registerUndo(withTarget: store) { store in
            FolderEditing(store: store).undoCreateFolder(at: path, inside: parentPath)
        }
        undoManager?.setActionName("Create Folder")
        return path
    }

    private func undoCreateFolder(at path: String, inside parentPath: String) {
        let name = (path as NSString).lastPathComponent
        withoutAutomaticUndo {
            if let folder = folder(at: path), folder.photos.isEmpty, folder.children.isEmpty {
                context.delete(folder)
                try? context.save()
            }
        }
        if (try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty == true {
            try? FileManager.default.removeItem(atPath: path)
        }
        undoManager?.registerUndo(withTarget: store) { store in
            _ = try? FolderEditing(store: store).createFolder(named: name, inside: parentPath)
        }
    }

    // MARK: - Rename

    /// Renames the folder on disk and in the catalog (its subfolders and photos follow). Undo renames
    /// it back. Returns the new path.
    @discardableResult
    func rename(_ path: String, to name: String) throws -> String {
        let name = try Self.validate(name)
        let oldName = (path as NSString).lastPathComponent
        guard name != oldName else { return path }
        let newPath = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { throw EditError.folderMissing(oldName) }
        // A change of case only is the same path on a case-insensitive disk.
        if fileManager.fileExists(atPath: newPath), name.lowercased() != oldName.lowercased() {
            throw EditError.alreadyExists(name)
        }
        try fileManager.moveItem(atPath: path, toPath: newPath)
        try withoutAutomaticUndo {
            try FileRelinking.rewritePaths(of: path, to: newPath, in: context)
            try context.save()
        }
        store.availability.refresh()
        undoManager?.registerUndo(withTarget: store) { store in
            _ = try? FolderEditing(store: store).rename(newPath, to: oldName)
        }
        undoManager?.setActionName("Rename Folder")
        return newPath
    }

    // MARK: - Remove

    /// Removes the folder, its subfolders and their photos from the catalog. Files stay on disk.
    func remove(_ path: String) {
        guard let folder = folder(at: path) else { return }
        for photo in photos(in: path) { context.delete(photo) }
        // Subfolders go with it (the relationship cascades).
        context.delete(folder)
        commit("Remove Folder")
    }

    // MARK: - Favorites and labels

    func setFavorite(_ isFavorite: Bool, at path: String) {
        guard let folder = folder(at: path), folder.isFavorite != isFavorite else { return }
        folder.isFavorite = isFavorite
        commit(isFavorite ? "Add to Favorites" : "Remove from Favorites")
    }

    func setLabel(_ label: ColorLabel, at path: String) {
        guard let folder = folder(at: path), folder.label != label else { return }
        folder.label = label
        commit("Folder Color Label")
    }

    // MARK: - Hide This Parent / Show Parent Folder

    /// Hide This Parent: a top-level folder with subfolders and no photos of its own; its subfolders
    /// become top-level folders.
    func canHideParent(_ path: String) -> Bool {
        guard let folder = folder(at: path) else { return false }
        return folder.parent == nil && !folder.children.isEmpty && folder.photos.isEmpty
    }

    func hideParent(_ path: String) {
        guard canHideParent(path), let folder = folder(at: path) else { return }
        for child in folder.children { child.parent = nil }
        context.delete(folder)
        commit("Hide This Parent")
    }

    /// Show Parent Folder: a top-level folder that isn't at the top of the disk.
    func canShowParent(_ path: String) -> Bool {
        guard let folder = folder(at: path), folder.parent == nil else { return false }
        let parentPath = (path as NSString).deletingLastPathComponent
        return parentPath != "/" && !parentPath.isEmpty
    }

    /// Adds the folder's parent directory to the catalog, with every top-level folder in it as its
    /// subfolders. Returns the parent's path.
    @discardableResult
    func showParent(_ path: String) -> String? {
        guard canShowParent(path) else { return nil }
        let parentPath = (path as NSString).deletingLastPathComponent
        let parent = folder(at: parentPath) ?? {
            let parent = Folder(context: context)
            parent.path = parentPath
            parent.name = (parentPath as NSString).lastPathComponent
            return parent
        }()
        let request = Folder.fetchRequest()
        request.predicate = NSPredicate(format: "parent == nil AND path BEGINSWITH %@", parentPath + "/")
        for root in (try? context.fetch(request)) ?? [] where (root.path as NSString).deletingLastPathComponent == parentPath {
            root.parent = parent
        }
        commit("Show Parent Folder")
        return parentPath
    }

    // MARK: - Collections from a folder

    /// Create Collection "Folder": a collection of the folder's photos, subfolders included.
    @discardableResult
    func createCollection(from path: String) -> PhotoCollection? {
        guard let folder = folder(at: path) else { return nil }
        return CollectionEditing(store: store).create(.collection, named: folder.name, in: nil, photos: photos(in: path).map(\.objectID))
    }

    /// Create Collection Set "Folder": a set mirroring the folder. Its own photos go in a collection of
    /// the same name; each subfolder becomes a collection, or a set when it has subfolders of its own.
    @discardableResult
    func createCollectionSet(from path: String) -> PhotoCollection? {
        guard let folder = folder(at: path) else { return nil }
        func mirror(_ folder: Folder, in parent: PhotoCollection?, asSet: Bool) -> PhotoCollection {
            guard asSet || !folder.children.isEmpty else {
                let collection = PhotoCollection.make(.collection, named: folder.name, in: parent, context: context)
                collection.photos = folder.photos
                return collection
            }
            let set = PhotoCollection.make(.set, named: folder.name, in: parent, context: context)
            if !folder.photos.isEmpty {
                PhotoCollection.make(.collection, named: folder.name, in: set, context: context).photos = folder.photos
            }
            for child in folder.sortedChildren { _ = mirror(child, in: set, asSet: false) }
            return set
        }
        let set = mirror(folder, in: nil, asSet: true)
        commit("New Collection Set")
        return set
    }
}
