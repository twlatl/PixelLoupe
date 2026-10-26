import CoreImage
import Foundation
import ImageIO

/// Writes a web gallery's folder (Generate): the pages, stylesheet and each photo as two sRGB JPEGs,
/// rendered with its edits off the main thread through Export's pipeline.
///
/// The folder is built in a temporary folder and then moved into place, so a cancelled or failed run
/// leaves the destination as it was.
nonisolated enum WebGalleryWriter {
    static let largeFolder = WebGalleryHTML.largeFolder
    /// The large images' long edge, and the thumbnails' (enough for the widest cell at 2×).
    static let largeEdge: CGFloat = 2048
    static let thumbnailEdge: CGFloat = 800

    /// One photo to write: its snapshot for the pages, and what Export needs to render it.
    struct Photo: Sendable {
        let photo: ContactSheetPhoto
        let item: ExportItem
        /// Its cached thumbnail, used for both sizes when the photo itself can't be read.
        let fallback: URL?

        init(photo: ContactSheetPhoto, item: ExportItem? = nil, fallback: URL? = nil) {
            self.photo = photo
            // Without the catalog's (as in tests): the photo's own file, with no metadata from the catalog.
            self.item = item ?? ExportItem(source: photo.source.original, adjustments: photo.adjustments, metadata: PhotoMetadata(),
                                           keywords: [], rating: photo.rating, captureDate: photo.captureDate,
                                           smartPreview: photo.source.smartPreview)
            self.fallback = fallback
        }
    }

    struct Result: Sendable {
        /// The names of photos that couldn't be read or written, which the gallery leaves without an image.
        var failures: [String] = []
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// The files a gallery of `count` photos in `pages` pages writes, relative to its folder.
    static func files(count: Int, pages: Int) -> [String] {
        (0..<pages).map(WebGalleryPages.fileName(ofPage:))
            + [WebGalleryHTML.stylesheetName, WebGalleryHTML.photosScriptName, WebGalleryHTML.scriptName]
            + (0..<count).flatMap { index in
                let name = WebGalleryHTML.imageName(index: index, count: count)
                return ["\(WebGalleryHTML.thumbnailFolder)/\(name)", "\(largeFolder)/\(name)"]
            }
    }

    /// Writes the gallery into `folder` (which should be empty), reporting the fraction done on the
    /// main actor. Throws `CancellationError` when cancelled.
    @concurrent
    static func write(_ photos: [Photo], settings: WebGallerySettings, sourceName: String,
                      watermark: PhotoExporter.Watermark?, to folder: URL,
                      progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> Result {
        let fileManager = FileManager.default
        for path in [WebGalleryHTML.thumbnailFolder, largeFolder] {
            try fileManager.createDirectory(at: folder.appending(path: path), withIntermediateDirectories: true)
        }
        let snapshots = photos.map(\.photo)
        let pages = WebGalleryPages(photoCount: photos.count, photosPerPage: settings.photosPerPage)
        try Data(WebGalleryHTML.stylesheet(settings: settings).utf8).write(to: folder.appending(path: WebGalleryHTML.stylesheetName))
        try Data(WebGalleryHTML.photosScript(photos: snapshots, settings: settings).utf8)
            .write(to: folder.appending(path: WebGalleryHTML.photosScriptName))
        try Data(WebGalleryHTML.script.utf8).write(to: folder.appending(path: WebGalleryHTML.scriptName))
        for page in 0..<pages.count {
            let html = WebGalleryHTML.page(page, photos: snapshots, settings: settings, sourceName: sourceName)
            try Data(html.utf8).write(to: folder.appending(path: WebGalleryPages.fileName(ofPage: page)))
        }

        // A few at a time, as Export does.
        var result = Result()
        let limit = max(1, min(3, ProcessInfo.processInfo.activeProcessorCount / 3))
        try await withThrowingTaskGroup(of: String?.self) { group in
            var next = 0
            func addNext() {
                guard next < photos.count else { return }
                let index = next, photo = photos[index]
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    let name = WebGalleryHTML.imageName(index: index, count: photos.count)
                    let written = writeImages(photo, settings: settings, watermark: watermark,
                                              thumbnail: folder.appending(path: "\(WebGalleryHTML.thumbnailFolder)/\(name)"),
                                              large: folder.appending(path: "\(largeFolder)/\(name)"))
                    return written ? nil : photo.photo.fileName
                }
            }
            for _ in 0..<limit { addNext() }
            var done = 0
            for try await failure in group {
                if let failure { result.failures.append(failure) }
                done += 1
                await progress(Double(done) / Double(max(photos.count, 1)))
                addNext()
            }
        }
        try Task.checkCancellation()
        return result
    }

    /// Moves the gallery written in `temporary` into `folder`, replacing the files a gallery writes
    /// and leaving everything else in it alone. Pages and images an earlier, larger gallery left
    /// there (`page-9.html`, `images/large/120.jpg`) are removed, so they don't outlive it.
    @concurrent
    static func install(from temporary: URL, into folder: URL) async throws {
        let fileManager = FileManager.default
        func contents(_ path: String, in base: URL) -> [String] {
            (try? fileManager.contentsOfDirectory(atPath: base.appending(path: path).path(percentEncoded: false))) ?? []
        }
        for directory in ["", WebGalleryHTML.thumbnailFolder, largeFolder] {
            let written = Set(contents(directory, in: temporary))
            let destination = directory.isEmpty ? folder : folder.appending(path: directory)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for name in written.sorted() {
                let source = (directory.isEmpty ? temporary : temporary.appending(path: directory)).appending(path: name)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: source.path(percentEncoded: false), isDirectory: &isDirectory),
                      !isDirectory.boolValue else { continue }
                _ = try fileManager.replaceItemAt(destination.appending(path: name), withItemAt: source)
            }
            for name in contents(directory, in: folder) where !written.contains(name) {
                let isOurs = directory.isEmpty
                    ? WebGalleryPages.page(named: name).map { $0 > 0 } ?? false
                    : WebGalleryHTML.index(ofImageNamed: name) != nil
                if isOurs { try? fileManager.removeItem(at: destination.appending(path: name)) }
            }
        }
    }

    /// The export settings both sizes are written with: sRGB JPEG at the gallery's quality, screen
    /// sharpening, and only the copyright and creator from the metadata.
    static func exportSettings(quality: Double, longEdge: CGFloat) -> ExportSettings {
        var settings = ExportSettings()
        settings.format = .jpeg
        settings.colorSpace = .sRGB
        settings.quality = quality
        settings.resizes = true
        settings.resizeMode = .longEdge
        settings.sizeUnit = .pixels
        settings.edge = Double(longEdge)
        settings.doesNotEnlarge = true
        settings.resolution = 72
        settings.sharpens = true
        settings.sharpenMedium = .screen
        settings.sharpenAmount = .standard
        settings.metadata = .copyrightAndContact
        return settings
    }

    /// The photo's two images: the large one rendered once (edits, sizing and sharpening), the
    /// thumbnail scaled down from it before the watermark goes on. False when neither the photo nor
    /// its cached thumbnail could be used.
    private static func writeImages(_ photo: Photo, settings: WebGallerySettings, watermark: PhotoExporter.Watermark?,
                                    thumbnail: URL, large: URL) -> Bool {
        let largeSettings = exportSettings(quality: settings.jpegQuality, longEdge: largeEdge)
        let thumbnailSettings = exportSettings(quality: settings.jpegQuality, longEdge: thumbnailEdge)
        guard let rendered = try? PhotoExporter.render(photo.item, settings: largeSettings, watermark: nil) else {
            // Its cached thumbnail (edits applied) stands in at its own size, for both.
            guard let fallback = photo.fallback, let data = try? Data(contentsOf: fallback) else { return false }
            return (try? data.write(to: thumbnail)) != nil && (try? data.write(to: large)) != nil
        }
        let image = rendered.image
        let scale = min(1, thumbnailEdge / CGFloat(max(image.width, image.height)))
        guard let small = scale < 1 ? scaled(CIImage(cgImage: image), by: scale) : image else { return false }
        var big = image
        if let watermark {
            let marked = WatermarkRenderer.apply(watermark.settings, imageURL: watermark.imageURL, to: CIImage(cgImage: image))
            guard let flattened = context.createCGImage(marked, from: marked.extent, format: .RGBA8,
                                                        colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            else { return false }
            big = flattened
        }
        guard let smallData = encode(small, photo: photo.item, settings: thumbnailSettings),
              let largeData = encode(big, photo: photo.item, settings: largeSettings)
        else { return false }
        return (try? smallData.write(to: thumbnail)) != nil && (try? largeData.write(to: large)) != nil
    }

    private static func scaled(_ image: CIImage, by scale: CGFloat) -> CGImage? {
        let resized = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        let target = CGRect(x: 0, y: 0, width: max(1, (image.extent.width * scale).rounded()),
                            height: max(1, (image.extent.height * scale).rounded()))
        return context.createCGImage(resized.clampedToExtent().cropped(to: target), from: target, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// The image as a JPEG with the photo's copyright and creator, and nothing else from its
    /// metadata (no location, camera serial numbers or creator contact details).
    static func encode(_ image: CGImage, photo: ExportItem, settings: ExportSettings) -> Data? {
        let metadata = PhotoExporter.metadata(for: photo, settings: settings, size: CGSize(width: image.width, height: image.height))
        let published = CGImageMetadataCreateMutableCopy(metadata) ?? CGImageMetadataCreateMutable()
        for path in ["photoshop:AuthorsPosition", "Iptc4xmpCore:CreatorContactInfo"] {
            CGImageMetadataRemoveTagWithPath(published, nil, path as CFString)
        }
        return try? PhotoExporter.encode(image, metadata: published, settings: settings, name: photo.fileName)
    }
}
