import CoreData
import Foundation

/// What a finished merge hands back to the catalog.
nonisolated struct HDRMergeOutput: Sendable {
    /// The new photo's id (its thumbnail is already written under it).
    var id: UUID
    var url: URL
    /// The exposure whose settings and capture date the merged photo takes.
    var referenceURL: URL
    /// The source files, darkest exposure first.
    var exposureOrder: [URL]
    var pixelWidth: Int
    var pixelHeight: Int
    var fileSize: Int64
}

/// The full-resolution merge, run off the main thread.
nonisolated enum HDRMergeRunner {
    /// Merges `sources` and writes the DNG to `destination` and its thumbnail. `progress` gets the
    /// fraction done. Cancelling stops it before anything is written.
    @concurrent
    static func run(
        sources: [HDRMergeSource], options: HDRMergeOptions, destination: URL, thumbnailDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> HDRMergeOutput {
        let merger = try HDRMerger(sources: sources)
        let result = try merger.merge(options: options, scale: 1) { progress($0 * 0.9) }
        try Task.checkCancellation()
        try LinearDNGWriter.write(result.image, metadata: merger.dngMetadata(), to: destination)

        let id = UUID()
        try? ThumbnailStore.generateThumbnail(from: destination, to: ThumbnailStore.url(for: id, in: thumbnailDirectory))
        let fileSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        progress(1)
        return HDRMergeOutput(
            id: id, url: destination, referenceURL: merger.reference.url,
            exposureOrder: merger.frames.map(\.source.url),
            pixelWidth: result.image.width, pixelHeight: result.image.height, fileSize: fileSize
        )
    }
}

/// Photo ▸ Photo Merge ▸ HDR, the catalog side: what to merge, where the result goes, and adding it.
extension PhotoEditing {
    /// The photos to merge, as given (videos and repeated files left out).
    func hdrMergeSources(_ ids: [NSManagedObjectID]) -> [HDRMergeSource] {
        var seen = Set<String>()
        return photos(ids).filter { !$0.isVideo && seen.insert($0.filePath).inserted }.map { photo in
            HDRMergeSource(
                url: photo.fileURL, exposureTime: photo.shutterSpeed, aperture: photo.aperture, iso: Int(photo.iso),
                make: photo.cameraMake, model: photo.cameraModel, lensModel: photo.lensModel,
                focalLength: photo.focalLength, captureDate: photo.captureDate
            )
        }
    }

    /// Where the merged photo goes: beside the earliest photo, named after it, `IMG_0001-HDR.dng`
    /// (then `-HDR-2`, `-HDR-3`… when that name is taken).
    func hdrDestination(for ids: [NSManagedObjectID]) -> URL? {
        guard let first = photos(ids).min(by: { $0.captureDate < $1.captureDate }) else { return nil }
        let folder = first.fileURL.deletingLastPathComponent()
        let base = first.fileURL.deletingPathExtension().lastPathComponent + "-HDR"
        var candidate = folder.appending(path: "\(base).dng")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = folder.appending(path: "\(base)-\(number).dng")
            number += 1
        }
        return candidate
    }

    /// Adds the merged photo to the catalog beside its sources: in the earliest photo's folder, with
    /// the reference exposure's capture date and shooting details, every source's keywords, and its
    /// starting Develop settings. With `createsStack`, it goes on top of a stack with the sources
    /// (darkest first): the stack they already share, or a new collapsed one.
    ///
    /// Like an import, this isn't undoable: undoing would leave the new file behind.
    @discardableResult
    func addMergedHDR(_ output: HDRMergeOutput, sources ids: [NSManagedObjectID], createsStack: Bool) -> NSManagedObjectID? {
        let sources = photos(ids)
        guard let earliest = sources.min(by: { $0.captureDate < $1.captureDate }) else { return nil }
        let reference = sources.first { $0.fileURL == output.referenceURL } ?? earliest
        let context = store.viewContext
        context.processPendingChanges()
        context.undoManager?.disableUndoRegistration()
        defer {
            context.processPendingChanges()
            context.undoManager?.enableUndoRegistration()
        }

        let photo = Photo(context: context)
        // The grid's fetched results must see the photo under the id it keeps after saving, or its cell
        // can't find the photo and the selection points at a photo the grid never showed.
        try? context.obtainPermanentIDs(for: [photo])
        let now = Date()
        photo.id = output.id
        photo.fileName = output.url.lastPathComponent
        photo.filePath = output.url.path(percentEncoded: false)
        photo.fileType = output.url.pathExtension.uppercased()
        photo.fileSize = output.fileSize
        photo.captureDate = reference.captureDate
        photo.dedupeKey = ImportService.dedupeKey(
            url: output.url, fileSize: output.fileSize, date: reference.captureDate, mode: store.info.storageMode
        )
        photo.importDate = now
        photo.editDate = now
        photo.cameraMake = reference.cameraMake
        photo.cameraModel = reference.cameraModel
        photo.lensModel = reference.lensModel
        photo.pixelWidth = Int32(output.pixelWidth)
        photo.pixelHeight = Int32(output.pixelHeight)
        photo.orientation = 1
        photo.iso = reference.iso
        photo.focalLength = reference.focalLength
        photo.aperture = reference.aperture
        photo.shutterSpeed = reference.shutterSpeed
        photo.folder = earliest.folder
        photo.tags = sources.reduce(into: Set<Tag>()) { $0.formUnion($1.tags) }

        if createsStack {
            // Virtual copies of a source (same file) follow the exposures.
            let byExposure = output.exposureOrder.compactMap { url in sources.first { $0.fileURL == url } }
            let rest = sources.filter { !byExposure.contains($0) }
            if let shared = sources.first?.stack, sources.allSatisfy({ $0.stack == shared }) {
                photo.stack = shared
                shared.renumber([photo] + shared.orderedPhotos.filter { $0 !== photo })
            } else {
                for member in sources { PhotoStack.remove(member, in: context) }
                let stack = PhotoStack(context: context)
                stack.isCollapsed = true
                let ordered = [photo] + byExposure + rest
                for member in ordered { member.stack = stack }
                stack.renumber(ordered)
            }
        }
        store.save()
        return photo.objectID
    }
}
