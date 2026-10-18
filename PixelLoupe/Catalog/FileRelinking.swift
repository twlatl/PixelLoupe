import CoreData
import Foundation

/// Reconnects photos to their files after the files (or a whole folder) moved: rewrites
/// `Photo.filePath` and `Folder.path` as one undoable change.
nonisolated enum FileRelinking {
    /// What a folder relink would do, found by looking at the new location.
    struct Preview: Sendable, Equatable {
        var oldPath: String
        var newPath: String
        /// Photos in the folder (and its subfolders).
        var total: Int
        /// Photos whose file exists at the new location.
        var found: Int
        /// Of those found, how many have a different size from the cataloged one.
        var sizeMismatches: Int

        var missing: Int { total - found }
    }

    /// Looks for each of the folder's photos under `newPath` (same relative path), checking that the
    /// file exists and, where the catalog knows the size, that the size matches.
    @concurrent
    static func preview(folder oldPath: String, to newPath: String, context: NSManagedObjectContext) async -> Preview {
        let rows: [(path: String, size: Int64)] = await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "Photo")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["filePath", "fileSize"]
            request.predicate = NSPredicate(format: "filePath BEGINSWITH %@", oldPath + "/")
            return ((try? context.fetch(request)) ?? []).compactMap { row in
                guard let path = row["filePath"] as? String else { return nil }
                return (path, (row["fileSize"] as? NSNumber)?.int64Value ?? 0)
            }
        }
        var preview = Preview(oldPath: oldPath, newPath: newPath, total: rows.count, found: 0, sizeMismatches: 0)
        let fileManager = FileManager.default
        for row in rows {
            if Task.isCancelled { break }
            let candidate = newPath + String(row.path.dropFirst(oldPath.count))
            guard fileManager.fileExists(atPath: candidate) else { continue }
            preview.found += 1
            if row.size > 0,
               let size = (try? fileManager.attributesOfItem(atPath: candidate))?[.size] as? Int64, size != row.size {
                preview.sizeMismatches += 1
            }
        }
        return preview
    }

    /// Moves the folder `oldPath` (with its subfolders and photos) to `newPath` in the catalog, as
    /// a single undo step. Returns how many photos were rewritten. The main-actor context is used
    /// because that is where the undo manager lives.
    @MainActor
    @discardableResult
    static func relinkFolder(_ oldPath: String, to newPath: String, in store: CatalogStore) throws -> Int {
        let context = store.viewContext
        let undo = context.undoManager
        undo?.beginUndoGrouping()
        defer {
            undo?.setActionName("Find Missing Folder")
            undo?.endUndoGrouping()
        }

        let rewritten = try rewritePaths(of: oldPath, to: newPath, in: context)
        context.processPendingChanges()
        try context.save()
        store.availability.refresh()
        return rewritten
    }

    /// Rewrites the paths of the folder `oldPath`, its subfolders and their photos to start with
    /// `newPath`, without saving. Returns how many photos were rewritten.
    @discardableResult
    static func rewritePaths(of oldPath: String, to newPath: String, in context: NSManagedObjectContext) throws -> Int {
        let folderRequest = Folder.fetchRequest()
        folderRequest.predicate = NSPredicate(format: "path == %@ OR path BEGINSWITH %@", oldPath, oldPath + "/")
        for folder in try context.fetch(folderRequest) {
            folder.path = newPath + String(folder.path.dropFirst(oldPath.count))
            if folder.path == newPath { folder.name = (newPath as NSString).lastPathComponent }
        }

        var rewritten = 0
        let photoRequest = Photo.fetchRequest()
        photoRequest.predicate = NSPredicate(format: "filePath BEGINSWITH %@", oldPath + "/")
        photoRequest.fetchBatchSize = 500
        for photo in try context.fetch(photoRequest) {
            photo.filePath = newPath + String(photo.filePath.dropFirst(oldPath.count))
            rewritten += 1
        }
        return rewritten
    }

    /// Points one photo at the file the user chose, as one undo step.
    @MainActor
    static func locate(_ photo: Photo, at url: URL, in store: CatalogStore) throws {
        let context = store.viewContext
        let undo = context.undoManager
        undo?.beginUndoGrouping()
        defer {
            undo?.setActionName("Locate Photo")
            undo?.endUndoGrouping()
        }
        // A photo's virtual copies (and a copy's master) use the same file: they move together.
        let oldPath = photo.filePath
        let request = Photo.fetchRequest()
        request.predicate = NSPredicate(format: "filePath == %@", oldPath)
        let sharing = Set((try? context.fetch(request)) ?? []).union([photo])
        let newPath = url.standardizedFileURL.path(percentEncoded: false)
        let size = (try? FileManager.default.attributesOfItem(atPath: newPath))?[.size] as? Int64
        for sharer in sharing {
            sharer.filePath = newPath
            sharer.fileName = url.lastPathComponent
            if let size { sharer.fileSize = size }
        }
        context.processPendingChanges()
        try context.save()
        store.availability.refresh()
    }
}
