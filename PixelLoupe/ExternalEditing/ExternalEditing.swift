import CoreData
import Foundation

/// What Photo ▸ Edit In sends, as in Lightroom's Edit Photo dialog.
nonisolated enum ExternalEditMode: String, CaseIterable, Sendable {
    /// A new file with the photo's PixelLoupe edits applied (always, for raw photos and virtual copies).
    case copyWithAdjustments
    /// A byte-for-byte copy of the original file, without the edits.
    case copy
    /// The original file itself (only for files other apps can open: TIFF, PSD, JPEG, PNG, HEIC).
    case original

    var title: String {
        switch self {
        case .copyWithAdjustments: "Edit a Copy with PixelLoupe Adjustments"
        case .copy: "Edit a Copy"
        case .original: "Edit Original"
        }
    }

    var explanation: String {
        switch self {
        case .copyWithAdjustments: "Apply the PixelLoupe adjustments to a copy of the file and edit that one."
        case .copy: "Edit a copy of the original file. PixelLoupe adjustments will not be visible."
        case .original: "Edit the original file. PixelLoupe adjustments will not be visible."
        }
    }
}

/// One photo handed to an external editor: the file it opens, and (for copies) how it's made.
nonisolated struct ExternalEditJob: Sendable {
    let sourceID: NSManagedObjectID
    let item: ExportItem
    let mode: ExternalEditMode
    /// The file the editor opens: the new copy's name, or the original.
    let url: URL

    var makesCopy: Bool { mode != .original }
}

/// A job after its file has been written: the new photo's id (its thumbnail is already drawn) and
/// what the catalog records about the file.
nonisolated struct ExternalEditOutput: Sendable {
    let job: ExternalEditJob
    let id: UUID
    let pixelWidth: Int
    let pixelHeight: Int
    let orientation: Int
    let fileSize: Int64
}

/// Writes the copies for Edit In, off the main thread.
nonisolated enum ExternalEditRunner {
    struct Result: Sendable {
        var outputs: [ExternalEditOutput] = []
        var failures: [String] = []
    }

    /// Writes each job's copy (originals need nothing) and its thumbnail, reporting progress
    /// (completed, total). Cancelling stops before the next photo.
    static func run(
        _ jobs: [ExternalEditJob], settings: ExportSettings, thumbnailDirectory: URL,
        progress: @escaping @MainActor (Int, Int) -> Void
    ) async -> Result {
        let copies = jobs.filter(\.makesCopy)
        var result = Result()
        await progress(0, copies.count)
        for (index, job) in copies.enumerated() {
            guard !Task.isCancelled else { break }
            do {
                result.outputs.append(try await write(job, settings: settings, thumbnailDirectory: thumbnailDirectory))
            } catch {
                result.failures.append("\(job.item.fileName): \(error.localizedDescription)")
            }
            await progress(index + 1, copies.count)
        }
        return result
    }

    @concurrent
    static func write(_ job: ExternalEditJob, settings: ExportSettings, thumbnailDirectory: URL) async throws -> ExternalEditOutput {
        var settings = settings
        if job.mode == .copy { settings.format = .original }
        try await PhotoExporter.export(job.item, to: job.url, settings: settings, watermark: nil)
        let id = UUID()
        // Drawn after the file is written, so it's newer than the file (see FileAvailability).
        try? ThumbnailStore.generateThumbnail(from: job.url, to: ThumbnailStore.url(for: id, in: thumbnailDirectory))
        let metadata = ImageMetadata.read(from: job.url)
        let fileSize = (try? job.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return ExternalEditOutput(
            job: job, id: id, pixelWidth: metadata?.pixelWidth ?? 0, pixelHeight: metadata?.pixelHeight ?? 0,
            orientation: metadata?.orientation ?? 1, fileSize: fileSize
        )
    }
}

/// Photo ▸ Edit In, the catalog side: what each photo sends, the copies' names, and adding them.
extension PhotoEditing {
    /// Whether Edit In asks what to send for this photo. Raw files and virtual copies always send a
    /// copy with their edits; other images can also send a plain copy or the original.
    static func asksWhatToEdit(_ photo: Photo) -> Bool {
        !photo.isVideo && !photo.isVirtualCopy && !SupportedImageTypes.isRaw(photo.fileURL)
    }

    /// What a photo sends, given the choice made for photos that ask.
    static func externalEditMode(for photo: Photo, choice: ExternalEditMode) -> ExternalEditMode {
        asksWhatToEdit(photo) ? choice : .copyWithAdjustments
    }

    /// The photos Edit In can send (videos left out), in the order given.
    func externalEditPhotos(_ ids: [NSManagedObjectID]) -> [Photo] {
        photos(ids).filter { !$0.isVideo }
    }

    /// One job per photo. Copies go beside their originals, named by `naming` (Filename-Edit by
    /// default) with `-2`, `-3`… added when the name is taken on disk or by another copy.
    func externalEditJobs(
        _ ids: [NSManagedObjectID], choice: ExternalEditMode, settings: ExportSettings
    ) -> [ExternalEditJob] {
        var taken = Set<String>()
        var copyIndex = 0
        let photos = externalEditPhotos(ids)
        let copyCount = photos.filter { Self.externalEditMode(for: $0, choice: choice) != .original }.count
        return photos.map { photo in
            let mode = Self.externalEditMode(for: photo, choice: choice)
            let item = ExportItem(photo)
            guard mode != .original else {
                return ExternalEditJob(sourceID: photo.objectID, item: item, mode: mode, url: photo.fileURL)
            }
            var settings = settings
            if mode == .copy { settings.format = .original }
            let name = ExportNaming.fileName(for: item, index: copyIndex, total: copyCount, settings: settings)
            copyIndex += 1
            let first = photo.fileURL.deletingLastPathComponent().appending(path: name)
            var url = first
            var number = 2
            while taken.contains(url.path(percentEncoded: false).lowercased())
                    || FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                url = ExportNaming.numbered(first, number)
                number += 1
            }
            taken.insert(url.path(percentEncoded: false).lowercased())
            return ExternalEditJob(sourceID: photo.objectID, item: item, mode: mode, url: url)
        }
    }

    /// Adds the copies to the catalog beside their originals, in the same folder, with the
    /// original's rating, color label, keywords and metadata (not its flag), and default Develop
    /// settings (a copy with adjustments already has them in its pixels). With `stacksWithOriginal`,
    /// each goes into a stack just above its original. Copies of photos in the regular collection
    /// `collectionID` join it too.
    ///
    /// Like an import, this isn't undoable: undoing would leave the new files behind.
    @discardableResult
    func addExternalEdits(
        _ outputs: [ExternalEditOutput], stacksWithOriginal: Bool, collectionID: UUID?
    ) -> [NSManagedObjectID] {
        let context = store.viewContext
        let pairs = outputs.compactMap { output in photos([output.job.sourceID]).first.map { (output, $0) } }
        guard !pairs.isEmpty else { return [] }
        context.processPendingChanges()
        context.undoManager?.disableUndoRegistration()
        defer {
            context.processPendingChanges()
            context.undoManager?.enableUndoRegistration()
        }
        let collection = collectionID.flatMap { PhotoCollection.with(id: $0, in: context) }.flatMap { $0.kind == .collection ? $0 : nil }

        var added: [Photo] = []
        for (output, source) in pairs {
            let photo = Photo(context: context)
            // The grid's fetched results must see the photo under the id it keeps after saving (see addMergedPhoto).
            try? context.obtainPermanentIDs(for: [photo])
            let url = output.job.url
            let now = Date()
            photo.id = output.id
            photo.fileName = url.lastPathComponent
            photo.filePath = url.path(percentEncoded: false)
            photo.fileType = url.pathExtension.uppercased()
            photo.fileSize = output.fileSize
            photo.captureDate = source.captureDate
            photo.dedupeKey = ImportService.dedupeKey(url: url, fileSize: output.fileSize, date: source.captureDate, mode: store.info.storageMode)
            photo.importDate = now
            photo.editDate = now
            photo.rating = source.rating
            photo.colorLabel = source.colorLabel
            photo.labelText = source.labelText
            photo.cameraMake = source.cameraMake
            photo.cameraModel = source.cameraModel
            photo.lensModel = source.lensModel
            photo.pixelWidth = Int32(output.pixelWidth)
            photo.pixelHeight = Int32(output.pixelHeight)
            photo.orientation = Int16(output.orientation)
            photo.iso = source.iso
            photo.focalLength = source.focalLength
            photo.aperture = source.aperture
            photo.shutterSpeed = source.shutterSpeed
            photo.copyLocation(from: source)
            photo.metadataData = source.metadataData
            photo.titleText = source.titleText
            photo.captionText = source.captionText
            photo.creatorText = source.creatorText
            photo.copyrightText = source.copyrightText
            photo.folder = source.folder
            photo.tags = source.tags
            if stacksWithOriginal {
                // A virtual copy outside any stack stacks with its master.
                let anchor = source.stack == nil ? (source.master ?? source) : source
                Self.stack(photo, above: anchor, in: context)
            }
            if let collection, collection.photos.contains(source) { collection.photos.insert(photo) }
            added.append(photo)
        }
        store.save()
        return added.map(\.objectID)
    }

    /// Puts `photo` into `anchor`'s stack just above it, or makes a new stack of the two (expanded,
    /// so both stay in view). A collapsed stack opens when the photo doesn't land on top.
    static func stack(_ photo: Photo, above anchor: Photo, in context: NSManagedObjectContext) {
        if let stack = anchor.stack {
            var ordered = stack.orderedPhotos.filter { $0 !== photo }
            let index = ordered.firstIndex { $0 === anchor } ?? 0
            ordered.insert(photo, at: index)
            photo.stack = stack
            if stack.isCollapsed, index != 0 { stack.isCollapsed = false }
            stack.renumber(ordered)
        } else {
            let stack = PhotoStack(context: context)
            stack.isCollapsed = false
            photo.stack = stack
            anchor.stack = stack
            stack.renumber([photo, anchor])
        }
    }
}
