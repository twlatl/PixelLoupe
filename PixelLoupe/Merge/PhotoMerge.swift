import CoreData
import Foundation

/// Photo ▸ Photo Merge's kinds of merge. What the catalog does with the result is the same for both;
/// these are the differences.
nonisolated enum PhotoMergeKind: Sendable {
    case hdr
    case panorama

    /// What the merged file adds to the earliest photo's name, as Lightroom names them:
    /// `IMG_0001-HDR.dng`, `IMG_0001-Pano.dng`.
    var suffix: String {
        switch self {
        case .hdr: "HDR"
        case .panorama: "Pano"
        }
    }

    /// The Library's bottom bar while the merge runs.
    var progressTitle: String {
        switch self {
        case .hdr: "Merging HDR"
        case .panorama: "Merging Panorama"
        }
    }

    var cancelTitle: String {
        switch self {
        case .hdr: "Cancel HDR Merge"
        case .panorama: "Cancel Panorama Merge"
        }
    }
}

/// One of the photos to merge, with what the catalog knows about how it was taken.
nonisolated struct PhotoMergeSource: Sendable, Equatable {
    var url: URL
    /// Seconds, or 0 when unknown.
    var exposureTime: Double
    /// F-number, or 0.
    var aperture: Double
    var iso: Int
    var make: String?
    var model: String?
    var lensModel: String? = nil
    var focalLength = 0.0
    var captureDate: Date? = nil
    /// The photo's Lens Corrections in Develop: a panorama applies their lens profile before merging.
    var lensCorrections = PhotoAdjustments.LensCorrections()

    var name: String { url.lastPathComponent }

    /// The camera, as the merges compare it.
    var camera: String { "\(make ?? "")|\(model ?? "")".lowercased() }

    /// Why `sources` can't be merged, from what the catalog knows about them, or `nil` when they can
    /// be as far as that goes (unreadable files and photos of different sizes are found as they're read).
    static func problem(merging sources: [PhotoMergeSource]) -> PhotoMergeError? {
        guard sources.count >= 2 else { return .tooFewPhotos }
        if let photo = sources.first(where: { !SupportedImageTypes.isRaw($0.url) }) { return .notRaw(photo.name) }
        guard Set(sources.map(\.camera)).count == 1 else { return .differentCameras }
        return nil
    }
}

nonisolated enum PhotoMergeError: LocalizedError, Equatable {
    case tooFewPhotos
    case notRaw(String)
    case unreadable(String)
    case differentSizes
    case differentCameras

    var errorDescription: String? {
        switch self {
        case .tooFewPhotos: "Select at least two photos to merge."
        case .notRaw(let name): "“\(name)” isn’t a RAW photo. Photo Merge needs RAW files."
        case .unreadable(let name): "“\(name)” can’t be read."
        case .differentSizes: "The photos aren’t all the same size."
        case .differentCameras: "The photos weren’t all taken with the same camera."
        }
    }
}

/// What a finished merge hands back to the catalog.
nonisolated struct PhotoMergeOutput: Sendable {
    /// The new photo's id (its thumbnail is already written under it).
    var id: UUID
    var url: URL
    /// The photo whose settings and capture date the merged photo takes.
    var referenceURL: URL
    /// The source files in the order they go under the merged photo in a stack: darkest exposure
    /// first for HDR, in the order they were taken for a panorama.
    var stackOrder: [URL]
    var pixelWidth: Int
    var pixelHeight: Int
    var fileSize: Int64
    /// The merged photo's starting Develop settings (a panorama's Auto Crop and Auto Settings).
    var adjustments = PhotoAdjustments()
}

/// The full-resolution HDR merge, run off the main thread.
nonisolated enum HDRMergeRunner {
    /// Merges `sources` and writes the DNG to `destination` and its thumbnail. `progress` gets the
    /// fraction done. Cancelling stops it before anything is written.
    @concurrent
    static func run(
        sources: [PhotoMergeSource], options: HDRMergeOptions, destination: URL, thumbnailDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> PhotoMergeOutput {
        let merger = try HDRMerger(sources: sources)
        let result = try merger.merge(options: options, scale: 1) { progress($0 * 0.9) }
        try Task.checkCancellation()
        try LinearDNGWriter.write(result.image, metadata: merger.dngMetadata(), to: destination)

        let id = UUID()
        try? ThumbnailStore.generateThumbnail(from: destination, to: ThumbnailStore.url(for: id, in: thumbnailDirectory))
        let fileSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        progress(1)
        return PhotoMergeOutput(
            id: id, url: destination, referenceURL: merger.reference.url,
            stackOrder: merger.frames.map(\.source.url),
            pixelWidth: result.image.width, pixelHeight: result.image.height, fileSize: fileSize
        )
    }
}

/// The full-resolution panorama merge, run off the main thread.
nonisolated enum PanoramaMergeRunner {
    /// What a panorama merge made, and how many of the photos went into it.
    struct Result: Sendable {
        var output: PhotoMergeOutput
        var mergedCount: Int
        var photoCount: Int
    }

    /// Merges `sources` and writes the DNG to `destination` and its thumbnail, with the merged
    /// photo's starting Develop settings. Perspective falls back to Spherical for photos it can't
    /// show. `progress` gets the fraction done. Cancelling stops it before anything is written.
    @concurrent
    static func run(
        sources: [PhotoMergeSource], options: PanoramaMergeOptions, destination: URL, thumbnailDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Result {
        let result: PanoramaMergeResult, adjustments: PhotoAdjustments, metadata: DNGMetadata
        let mergedCount: Int, referenceURL: URL
        do {
            let merger = try PanoramaMerger(sources: sources)
            try Task.checkCancellation()
            progress(0.1)
            var options = options
            if options.projection == .perspective, !merger.allowsPerspective { options.projection = .spherical }
            let scratch = FileManager.default.temporaryDirectory.appending(path: "PixelLoupe-Panorama-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: scratch) }
            adjustments = try await merger.startingAdjustments(options: options, directory: scratch)
            progress(0.15)
            result = try merger.merge(options: options, scale: 1) { progress(0.15 + $0 * 0.75) }
            metadata = merger.dngMetadata()
            mergedCount = merger.mergedCount
            referenceURL = merger.reference.url
        }
        // The merger (its RAW decoders and Core Image caches) is gone before the DNG is written.
        try Task.checkCancellation()
        try LinearDNGWriter.write(result.image, metadata: metadata, to: destination)

        let id = UUID()
        try? ThumbnailStore.generateThumbnail(from: destination, to: ThumbnailStore.url(for: id, in: thumbnailDirectory))
        let fileSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        progress(1)
        let taken = sources.enumerated().sorted { a, b in
            (a.element.captureDate ?? .distantFuture, a.offset) < (b.element.captureDate ?? .distantFuture, b.offset)
        }
        let output = PhotoMergeOutput(
            id: id, url: destination, referenceURL: referenceURL, stackOrder: taken.map(\.element.url),
            pixelWidth: result.image.width, pixelHeight: result.image.height, fileSize: fileSize, adjustments: adjustments
        )
        return Result(output: output, mergedCount: mergedCount, photoCount: sources.count)
    }
}

/// Photo ▸ Photo Merge, the catalog side: what to merge, where the result goes, and adding it.
extension PhotoEditing {
    /// The photos to merge, as given (videos and repeated files left out).
    func photoMergeSources(_ ids: [NSManagedObjectID]) -> [PhotoMergeSource] {
        var seen = Set<String>()
        return photos(ids).filter { !$0.isVideo && seen.insert($0.filePath).inserted }.map { photo in
            PhotoMergeSource(
                url: photo.fileURL, exposureTime: photo.shutterSpeed, aperture: photo.aperture, iso: Int(photo.iso),
                make: photo.cameraMake, model: photo.cameraModel, lensModel: photo.lensModel,
                focalLength: photo.focalLength, captureDate: photo.captureDate,
                lensCorrections: photo.adjustments.lens
            )
        }
    }

    /// Where the merged photo goes: beside the earliest photo, named after it, `IMG_0001-HDR.dng`
    /// (then `-HDR-2`, `-HDR-3`… when that name is taken).
    func mergeDestination(for ids: [NSManagedObjectID], kind: PhotoMergeKind) -> URL? {
        guard let first = photos(ids).min(by: { $0.captureDate < $1.captureDate }) else { return nil }
        let folder = first.fileURL.deletingLastPathComponent()
        let base = first.fileURL.deletingPathExtension().lastPathComponent + "-" + kind.suffix
        var candidate = folder.appending(path: "\(base).dng")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = folder.appending(path: "\(base)-\(number).dng")
            number += 1
        }
        return candidate
    }

    /// Adds the merged photo to the catalog beside its sources: in the earliest photo's folder, with
    /// the reference photo's capture date and shooting details, every source's keywords, and its
    /// starting Develop settings. With `createsStack`, it goes on top of a stack with the sources (in
    /// the output's order): the stack they already share, or a new collapsed one.
    ///
    /// Like an import, this isn't undoable: undoing would leave the new file behind.
    @discardableResult
    func addMergedPhoto(_ output: PhotoMergeOutput, sources ids: [NSManagedObjectID], createsStack: Bool) -> NSManagedObjectID? {
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
        if !output.adjustments.isDefault { photo.adjustments = output.adjustments }

        if createsStack {
            // Virtual copies of a source (same file) follow the photos in order.
            let ordered = output.stackOrder.compactMap { url in sources.first { $0.fileURL == url } }
            let rest = sources.filter { !ordered.contains($0) }
            if let shared = sources.first?.stack, sources.allSatisfy({ $0.stack == shared }) {
                photo.stack = shared
                shared.renumber([photo] + shared.orderedPhotos.filter { $0 !== photo })
            } else {
                for member in sources { PhotoStack.remove(member, in: context) }
                let stack = PhotoStack(context: context)
                stack.isCollapsed = true
                let members = [photo] + ordered + rest
                for member in members { member.stack = stack }
                stack.renumber(members)
            }
        }
        store.save()
        // The thumbnail written with the file is the panorama as merged; redraw it with its settings.
        if !output.adjustments.isDefault {
            store.thumbnails.regenerate(id: output.id, source: PhotoSourceLocation(original: output.url), adjustments: output.adjustments)
        }
        return photo.objectID
    }
}
