import CoreData
import Foundation

/// Synchronize Folder: compares a folder in the catalog with what's on disk.
nonisolated enum FolderSync {
    struct Plan: Sendable {
        /// Supported files under the folder that the catalog doesn't have (sidecars paired with their
        /// raw file, as an import would).
        var newFiles: [ImportService.ImportSource] = []
        /// Photos under the folder whose file is gone.
        var missing: [NSManagedObjectID] = []
        /// Photos whose file changed (size, or modified after the photo was imported).
        var changed: [NSManagedObjectID] = []
    }

    private struct Row: Sendable {
        var objectID: NSManagedObjectID
        var path: String
        var sidecarPaths: [String]
        var size: Int64
        var importDate: Date
    }

    /// Looks at the folder on disk (and its subfolders). Runs off the main thread.
    @concurrent
    static func plan(folder path: String, info: CatalogInfo, context: NSManagedObjectContext) async -> Plan {
        let rows: [Row] = await context.perform {
            let request = Photo.fetchRequest()
            request.predicate = FolderEditing.subtreePredicate(path)
            request.fetchBatchSize = 500
            return ((try? context.fetch(request)) ?? []).map { photo in
                let base = (photo.filePath as NSString).deletingPathExtension
                let sidecars = (photo.sidecarExtensions ?? "").split(separator: ",").map { "\(base).\($0)" }
                return Row(objectID: photo.objectID, path: photo.filePath, sidecarPaths: sidecars,
                           size: photo.fileSize, importDate: photo.importDate)
            }
        }
        var plan = Plan()
        let known = Set(rows.flatMap { [$0.path] + $0.sidecarPaths }.map { $0.lowercased() })
        let sources = await ImportService.collectSources([URL(filePath: path, directoryHint: .isDirectory)], info: info)
        plan.newFiles = sources.filter { !known.contains($0.url.path(percentEncoded: false).lowercased()) }

        // Virtual copies share their master's file: each file is looked at once.
        var seen: [String: (exists: Bool, changed: Bool)] = [:]
        for row in rows {
            if Task.isCancelled { break }
            let status = seen[row.path] ?? {
                let url = URL(filePath: row.path)
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                    return (false, false)
                }
                let size = Int64(values.fileSize ?? 0)
                let modified = values.contentModificationDate ?? .distantPast
                return (true, (row.size > 0 && size != row.size) || modified > row.importDate)
            }()
            seen[row.path] = status
            if !status.exists {
                plan.missing.append(row.objectID)
            } else if status.changed {
                plan.changed.append(row.objectID)
            }
        }
        return plan
    }

    /// What a changed file says now.
    struct Update: Sendable {
        var objectID: NSManagedObjectID
        var metadata: ImageMetadata
        var fileSize: Int64
    }

    /// Re-reads the changed photos' files, off the main thread.
    @MainActor
    static func readUpdates(_ ids: [NSManagedObjectID], in context: NSManagedObjectContext) async -> [Update] {
        let files: [(NSManagedObjectID, URL)] = ids.compactMap { id in
            (try? context.existingObject(with: id) as? Photo).map { (id, $0.fileURL) }
        }
        return await read(files)
    }

    @concurrent
    private static func read(_ files: [(NSManagedObjectID, URL)]) async -> [Update] {
        files.compactMap { id, url in
            guard let metadata = ImageMetadata.read(from: url) else { return nil }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            return Update(objectID: id, metadata: metadata, fileSize: size)
        }
    }

    /// Brings the photos' file details (size, camera, lens, dimensions and shooting details) up to
    /// date; keywords in the file are added. Capture times, ratings, labels, edits and metadata typed
    /// in PixelLoupe aren't touched.
    @MainActor
    static func apply(_ updates: [Update], in context: NSManagedObjectContext) {
        for update in updates {
            guard let photo = try? context.existingObject(with: update.objectID) as? Photo else { continue }
            let metadata = update.metadata
            if update.fileSize > 0 { photo.fileSize = update.fileSize }
            photo.cameraMake = metadata.cameraMake
            photo.cameraModel = metadata.cameraModel
            photo.lensModel = metadata.lensModel
            photo.pixelWidth = Int32(metadata.pixelWidth)
            photo.pixelHeight = Int32(metadata.pixelHeight)
            photo.orientation = Int16(metadata.orientation)
            photo.apply(metadata.shooting)
            for keyword in metadata.keywords where !photo.tags.contains(where: { $0.name.lowercased() == keyword.lowercased() }) {
                photo.tags.insert(Tag.findOrCreate(named: keyword, in: context))
            }
        }
    }
}
