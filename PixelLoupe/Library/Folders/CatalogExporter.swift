import CoreData
import Foundation

/// Export this Folder as a Catalog: a new catalog holding the folder's photos (subfolders included)
/// with everything that goes with them: edits, history, snapshots, keywords, people, stacks, virtual
/// copies and the collections they're in.
enum CatalogExporter {
    struct Options: Sendable, Equatable {
        /// Lightroom's "Export negative files": copies the photos' files next to the new catalog,
        /// which then refers to the copies. Otherwise it refers to the files where they are.
        var copiesFiles = true
        /// "Include available previews": copies the thumbnails, so the catalog opens without
        /// redrawing them.
        var includesPreviews = true
    }

    struct Result: Sendable {
        var catalogURL: URL
        var photoCount: Int
        /// Files that couldn't be copied.
        var failures: [String] = []
    }

    /// Exports into a new folder at `directory`, named like it: `Trip/Trip.pixelloupe`, and with
    /// `copiesFiles`, `Trip/<folder name>/…` for the photos.
    static func export(folder path: String, from store: CatalogStore, to directory: URL, options: Options) async throws -> Result {
        let fileManager = FileManager.default
        let name = directory.lastPathComponent
        let packageURL = directory.appending(path: name + "." + CatalogPackage.fileExtension, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: directory.path(percentEncoded: false)) { throw CatalogError.alreadyExists(directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = try CatalogStore.create(at: packageURL, info: CatalogInfo(name: name, storageMode: .referenced))
        defer {
            let coordinator = target.container.persistentStoreCoordinator
            for persistentStore in coordinator.persistentStores { try? coordinator.remove(persistentStore) }
        }

        let newRoot = options.copiesFiles
            ? directory.appending(path: (path as NSString).lastPathComponent).path(percentEncoded: false).trimmingSuffix("/")
            : path
        let mapPath: @Sendable (String) -> String = { old in
            old == path ? newRoot : old.hasPrefix(path + "/") ? newRoot + String(old.dropFirst(path.count)) : old
        }

        let source = store.newBackgroundContext()
        let destination = target.newBackgroundContext()
        let manifest = try await copyGraph(folder: path, from: source, to: destination, mapPath: mapPath)

        var result = Result(catalogURL: packageURL, photoCount: manifest.photoCount)
        if options.copiesFiles {
            result.failures = await copyFiles(manifest.files, folders: manifest.folders, mapPath: mapPath)
        }
        if options.includesPreviews {
            await copyPreviews(manifest.photoIDs, from: store.thumbnails.directory, to: target.thumbnails.directory)
        }
        try CatalogViewState(expandedFolderPaths: [newRoot], folderPath: newRoot).save(to: packageURL)
        return result
    }

    private struct Manifest: Sendable {
        var photoCount = 0
        var photoIDs: [UUID] = []
        /// Every file to copy: photos (once, though virtual copies share them) and their sidecars.
        var files: [String] = []
        var folders: [String] = []
    }

    /// Copies the folder's objects into `destination` and saves it.
    @concurrent
    private static func copyGraph(
        folder path: String, from source: NSManagedObjectContext, to destination: NSManagedObjectContext,
        mapPath: @escaping @Sendable (String) -> String
    ) async throws -> Manifest {
        try await source.perform {
            let photoRequest = Photo.fetchRequest()
            photoRequest.predicate = FolderEditing.subtreePredicate(path)
            photoRequest.relationshipKeyPathsForPrefetching = ["tags", "collections", "faceRegions", "historySteps", "snapshots"]
            let photos = try source.fetch(photoRequest)
            let folderRequest = Folder.fetchRequest()
            folderRequest.predicate = NSPredicate(format: "path == %@ OR path BEGINSWITH %@", path, path + "/")
            let folders = try source.fetch(folderRequest)

            // What goes into the new catalog. Keywords and collection sets bring their parents (not
            // their other children); smart collections, which aren't tied to photos, stay behind.
            var included: [NSManagedObject] = []
            var includedIDs = Set<NSManagedObjectID>()
            func include(_ object: NSManagedObject) {
                if includedIDs.insert(object.objectID).inserted { included.append(object) }
            }
            func includeWithAncestors(_ object: NSManagedObject?) {
                var current = object
                while let object = current, !includedIDs.contains(object.objectID) {
                    include(object)
                    current = object.value(forKey: "parent") as? NSManagedObject
                }
            }
            (folders as [NSManagedObject] + photos).forEach(include)
            for photo in photos {
                photo.tags.forEach(includeWithAncestors)
                photo.collections.forEach(includeWithAncestors)
                for region in photo.faceRegions {
                    include(region)
                    includeWithAncestors(region.person)
                }
                if let stack = photo.stack { include(stack) }
                photo.historySteps.forEach(include)
                photo.snapshots.forEach(include)
            }

            var manifest = Manifest(photoCount: photos.count, photoIDs: photos.map(\.id), folders: folders.map(\.path))
            var files = Set<String>()
            for photo in photos {
                files.insert(photo.filePath)
                let base = (photo.filePath as NSString).deletingPathExtension
                for ext in (photo.sidecarExtensions ?? "").split(separator: ",") { files.insert("\(base).\(ext)") }
            }
            manifest.files = files.sorted()

            // Read only on the source context's queue, which this is (the destination's work waits for it).
            nonisolated(unsafe) let objects = included
            let objectIDs = includedIDs
            try destination.performAndWait {
                var copies: [NSManagedObjectID: NSManagedObject] = [:]
                for object in objects {
                    let copy = NSEntityDescription.insertNewObject(forEntityName: object.entity.name!, into: destination)
                    for name in object.entity.attributesByName.keys {
                        copy.setValue(object.value(forKey: name), forKey: name)
                    }
                    copies[object.objectID] = copy
                }
                for object in objects {
                    let copy = copies[object.objectID]!
                    for (name, relationship) in object.entity.relationshipsByName {
                        if relationship.isToMany {
                            // Many-to-many relationships are set from one side; the other follows.
                            if let inverse = relationship.inverseRelationship, inverse.isToMany,
                               (relationship.entity.name!, relationship.name) > (inverse.entity.name!, inverse.name) { continue }
                            // One-to-many relationships are set from the "one" side.
                            if relationship.inverseRelationship?.isToMany == false { continue }
                            let members = (object.value(forKey: name) as? Set<NSManagedObject> ?? [])
                                .filter { objectIDs.contains($0.objectID) }
                                .compactMap { copies[$0.objectID] }
                            copy.setValue(Set(members), forKey: name)
                        } else if let target = object.value(forKey: name) as? NSManagedObject {
                            copy.setValue(objectIDs.contains(target.objectID) ? copies[target.objectID] : nil, forKey: name)
                        }
                    }
                }
                for case let folder as Folder in copies.values { folder.path = mapPath(folder.path) }
                for case let photo as Photo in copies.values { photo.filePath = mapPath(photo.filePath) }
                try destination.save()
            }
            return manifest
        }
    }

    @concurrent
    private static func copyFiles(_ files: [String], folders: [String], mapPath: @Sendable (String) -> String) async -> [String] {
        let fileManager = FileManager.default
        for folder in folders { try? fileManager.createDirectory(atPath: mapPath(folder), withIntermediateDirectories: true) }
        var failures: [String] = []
        for file in files {
            let target = mapPath(file)
            do {
                try fileManager.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fileManager.copyItem(atPath: file, toPath: target)
            } catch {
                failures.append((file as NSString).lastPathComponent)
            }
        }
        return failures
    }

    @concurrent
    private static func copyPreviews(_ ids: [UUID], from source: URL, to destination: URL) async {
        let fileManager = FileManager.default
        for id in ids {
            let from = ThumbnailStore.url(for: id, in: source)
            guard fileManager.fileExists(atPath: from.path(percentEncoded: false)) else { continue }
            try? fileManager.copyItem(at: from, to: ThumbnailStore.url(for: id, in: destination))
        }
    }
}
