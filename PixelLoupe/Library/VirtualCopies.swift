import CoreData
import Foundation

/// Virtual copies (Photo ▸ Create Virtual Copy, ⌘'): another `Photo` that uses the same file but
/// has its own edits, rating, flag, label, keywords and metadata, as in Lightroom.
extension PhotoEditing {
    /// Makes a virtual copy of each photo, as one undoable step. A copy of a copy is another copy of
    /// the same master. Returns the new photos, in the order given.
    @discardableResult
    func createVirtualCopies(of ids: [NSManagedObjectID]) -> [NSManagedObjectID] {
        let sources = photos(ids)
        guard !sources.isEmpty else { return [] }
        let context = store.viewContext
        var copies: [Photo] = []
        for source in sources {
            let master = source.master ?? source
            let copy = Photo(context: context)
            copy.duplicate(from: source)
            // Named before it joins the master's copies, so it isn't counted among them.
            copy.copyName = Self.nextCopyName(for: master)
            copy.master = master
            copies.append(copy)
            // The copy shows its master's thumbnail until its own edits are drawn.
            let from = store.thumbnails.url(for: source.id), to = store.thumbnails.url(for: copy.id)
            try? FileManager.default.copyItem(at: from, to: to)
        }
        context.processPendingChanges()
        context.undoManager?.setActionName(copies.count == 1 ? "Create Virtual Copy" : "Create Virtual Copies")
        store.save()
        return copies.map(\.objectID)
    }

    /// "Copy 1", "Copy 2"…: one more than the highest number among the master's copies.
    static func nextCopyName(for master: Photo) -> String {
        let numbers = master.virtualCopies.compactMap { copy -> Int? in
            guard let name = copy.copyName, name.hasPrefix("Copy ") else { return nil }
            return Int(name.dropFirst(5))
        }
        return "Copy \((numbers.max() ?? master.virtualCopies.count) + 1)"
    }

    /// Swaps roles: the copy becomes the master, and the old master (and the other copies) become its copies.
    func setAsMaster(_ id: NSManagedObjectID) {
        guard let copy = photos([id]).first, let oldMaster = copy.master else { return }
        let others = oldMaster.virtualCopies.filter { $0 !== copy }
        edit([id], actionName: "Set Copy as Master") { copy in
            let copyName = copy.copyName ?? "Copy 1"
            copy.master = nil
            copy.copyName = nil
            oldMaster.master = copy
            oldMaster.copyName = copyName
            for other in others { other.master = copy }
        }
    }
}

nonisolated extension Photo {
    /// Copies everything a virtual copy carries over from `source`: the file's details, edits, rating,
    /// flag, label, keywords and metadata. (Not the master link, collections or Lightroom id.)
    func duplicate(from source: Photo) {
        id = UUID()
        fileName = source.fileName
        filePath = source.filePath
        originalPath = source.originalPath
        fileType = source.fileType
        fileSize = source.fileSize
        captureDate = source.captureDate
        importDate = source.importDate
        importID = source.importID
        editDate = Date()
        rating = source.rating
        flag = source.flag
        colorLabel = source.colorLabel
        labelText = source.labelText
        cameraMake = source.cameraMake
        cameraModel = source.cameraModel
        lensModel = source.lensModel
        pixelWidth = source.pixelWidth
        pixelHeight = source.pixelHeight
        orientation = source.orientation
        adjustmentsData = source.adjustmentsData
        metadataData = source.metadataData
        iso = source.iso
        focalLength = source.focalLength
        aperture = source.aperture
        shutterSpeed = source.shutterSpeed
        hasGPS = source.hasGPS
        isCropped = source.isCropped
        isBlackAndWhite = source.isBlackAndWhite
        titleText = source.titleText
        captionText = source.captionText
        creatorText = source.creatorText
        copyrightText = source.copyrightText
        folder = source.folder
        tags = source.tags
    }
}
