import AppKit
import CoreData

/// Removes photos from the catalog (Photo ▸ Remove Photo and friends), optionally moving their files
/// to the Trash. Both are undoable as one step: undo puts the photos back in the catalog (with their
/// edits, flags and keywords) and moves the files back out of the Trash.
struct PhotoRemoval {
    let store: CatalogStore
    var trash = Trash.finder

    /// Where "Delete from Disk" puts files: the Finder's Trash (tests use a folder of their own).
    nonisolated struct Trash: Sendable {
        /// Moves a file to the trash and returns where it went.
        var move: @Sendable (URL) throws -> URL

        static let finder = Trash { file in
            var trashed: NSURL?
            try FileManager.default.trashItem(at: file, resultingItemURL: &trashed)
            return (trashed as URL?) ?? file
        }
    }

    struct Failure: Error, Equatable {
        /// Files that couldn't be moved to the Trash; their photos stay in the catalog.
        var fileNames: [String]
    }

    /// The files that go with a photo: the photo itself and any XMP sidecar next to it
    /// ("IMG_1.CR3" → "IMG_1.xmp", or "IMG_1.CR3.xmp").
    nonisolated static func files(for photo: URL, imageSidecars: [String] = []) -> [URL] {
        let manager = FileManager.default
        var files = [photo]
        let base = photo.deletingPathExtension()
        // A raw photo's JPEG (or other image) sidecar goes with it.
        let images = imageSidecars.flatMap { [base.appendingPathExtension($0), base.appendingPathExtension($0.lowercased())] }
        for candidate in images + [base.appendingPathExtension("xmp"), base.appendingPathExtension("XMP"),
                          photo.appendingPathExtension("xmp"), photo.appendingPathExtension("XMP")]
        where manager.fileExists(atPath: candidate.path(percentEncoded: false))
            && !files.contains(where: { $0.standardizedFileURL.path.lowercased() == candidate.standardizedFileURL.path.lowercased() }) {
            files.append(candidate)
        }
        return files
    }

    /// Whether a photo that stays in the catalog uses `photo`'s file.
    static func filesAreStillUsed(by photo: Photo, removing: Set<NSManagedObjectID>, in context: NSManagedObjectContext) -> Bool {
        let request = Photo.fetchRequest()
        request.predicate = NSPredicate(format: "filePath == %@ AND self != %@", photo.filePath, photo.objectID)
        return ((try? context.fetch(request)) ?? []).contains { !removing.contains($0.objectID) }
    }

    /// Removes the photos from the catalog; with `trash`, their files (and sidecars) go to the Trash
    /// first. A photo whose file can't be trashed stays in the catalog and is reported. A file that's
    /// already missing doesn't stop its photo being removed.
    @discardableResult
    func remove(_ ids: [NSManagedObjectID], trash: Bool, actionName: String) -> Failure? {
        let photos = ids.compactMap { try? store.viewContext.existingObject(with: $0) as? Photo }
        guard !photos.isEmpty else { return nil }
        var moved: [(original: URL, trashed: URL)] = []
        var failed: [String] = []
        var removable: [Photo] = []
        let removing = Set(photos.map(\.objectID))
        var trashedPaths = Set<String>()
        for photo in photos {
            guard trash else {
                removable.append(photo)
                continue
            }
            // A file that another photo still uses (a virtual copy or its master staying in the
            // catalog) is not trashed, and one shared by photos that all go is trashed once.
            if Self.filesAreStillUsed(by: photo, removing: removing, in: store.viewContext) || trashedPaths.contains(photo.filePath) {
                removable.append(photo)
                continue
            }
            trashedPaths.insert(photo.filePath)
            let files = Self.files(for: photo.fileURL, imageSidecars: photo.imageSidecars).filter {
                FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
            }
            do {
                for file in files {
                    moved.append((file, try self.trash.move(file)))
                }
                removable.append(photo)
            } catch {
                failed.append(photo.fileName)
            }
        }
        guard !removable.isEmpty else { return failed.isEmpty ? nil : Failure(fileNames: failed) }

        let context = store.viewContext
        removable.forEach(context.delete)
        if let undoManager = context.undoManager, !moved.isEmpty {
            Self.registerRestore(moved, trash: self.trash, with: undoManager)
        }
        context.undoManager?.setActionName(actionName)
        store.save()
        return failed.isEmpty ? nil : Failure(fileNames: failed)
    }

    /// Undo moves the files back from the Trash; redo trashes them again (and registers this again).
    private static func registerRestore(_ moved: [(original: URL, trashed: URL)], trash: Trash, with undoManager: UndoManager) {
        undoManager.registerUndo(withTarget: FileShuttle.shared) { shuttle in
            let restored = shuttle.restore(moved)
            // Redo: back to the Trash.
            undoManager.registerUndo(withTarget: shuttle) { shuttle in
                let retrashed = shuttle.trash(restored, with: trash)
                registerRestore(retrashed, trash: trash, with: undoManager)
            }
        }
    }

    /// The undo target that moves files in and out of the Trash.
    private final class FileShuttle {
        static let shared = FileShuttle()

        /// Moves trashed files back where they were; returns the files restored.
        func restore(_ moved: [(original: URL, trashed: URL)]) -> [URL] {
            moved.compactMap { item in
                try? FileManager.default.createDirectory(at: item.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                return (try? FileManager.default.moveItem(at: item.trashed, to: item.original)) != nil ? item.original : nil
            }
        }

        func trash(_ files: [URL], with trash: Trash) -> [(original: URL, trashed: URL)] {
            files.compactMap { file in
                (try? trash.move(file)).map { (file, $0) }
            }
        }
    }
}
