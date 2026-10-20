import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates, persists and caches grid thumbnails for a catalog.
///
/// Thumbnails are written once at import as JPEGs inside the catalog package, so scrolling never
/// touches the original (often RAW) files. Decoding happens off the main thread and decoded images
/// are kept in an in-memory cache for instant redisplay as the grid scrolls or resizes.
final class ThumbnailStore {
    /// Long-edge size of stored thumbnails, large enough for the biggest grid cells on Retina displays.
    nonisolated static let maxPixelSize = 768

    let directory: URL
    private let cache = NSCache<NSUUID, CGImage>()
    private var inFlight: [UUID: Task<CGImage?, Never>] = [:]

    init(directory: URL) {
        self.directory = directory
        cache.countLimit = 2_000
    }

    nonisolated static func url(for id: UUID, in directory: URL) -> URL {
        directory.appending(path: "\(id.uuidString).jpg")
    }

    func url(for id: UUID) -> URL { Self.url(for: id, in: directory) }

    func cachedImage(for id: UUID) -> CGImage? {
        cache.object(forKey: id as NSUUID)
    }

    /// Returns the decoded thumbnail for `id`, loading it from disk if needed.
    func image(for id: UUID) async -> CGImage? {
        if let cached = cachedImage(for: id) { return cached }
        if let task = inFlight[id] { return await task.value }

        let url = url(for: id)
        let task = Task<CGImage?, Never> { await Self.decode(url) }
        inFlight[id] = task
        let image = await task.value
        inFlight[id] = nil
        if let image { cache.setObject(image, forKey: id as NSUUID) }
        return image
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    /// Posted on the main thread after a thumbnail is rewritten. `userInfo["id"]` is the photo's UUID.
    static let didUpdateNotification = Notification.Name("ThumbnailStoreDidUpdate")

    private var regenerations: [UUID: Task<Void, Never>] = [:]

    /// Rewrites the thumbnail for a photo after its Develop settings change. Rapid successive
    /// changes for the same photo cancel earlier renders.
    func regenerate(id: UUID, source: PhotoSourceLocation, adjustments: PhotoAdjustments) {
        regenerations[id]?.cancel()
        let destination = url(for: id)
        regenerations[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let drawn = await Self.renderThumbnail(from: source, to: destination, adjustments: adjustments)
            guard let self, !Task.isCancelled else { return }
            regenerations[id] = nil
            guard let drawn else { return }
            didDraw(id, from: drawn)
        }
    }

    /// Redraws the thumbnail for a photo now (unlike ``regenerate(id:source:adjustments:)``, without
    /// waiting) and tells the grid. Returns whether it worked. For background passes.
    func render(id: UUID, source: PhotoSourceLocation, adjustments: PhotoAdjustments) async -> Bool {
        guard let drawn = await Self.renderThumbnail(from: source, to: url(for: id), adjustments: adjustments) else { return false }
        didDraw(id, from: drawn)
        return true
    }

    /// Photos whose thumbnail was drawn from their Smart Preview, while the original was missing.
    private(set) lazy var drawnFromSmartPreviews = SeededThumbnails.load(from: directory, origin: .smartPreview)

    private func didDraw(_ id: UUID, from drawn: Drawn) {
        let listed = drawn == .smartPreview ? drawnFromSmartPreviews.insert(id).inserted : drawnFromSmartPreviews.remove(id) != nil
        if listed { SeededThumbnails.save(drawnFromSmartPreviews, to: directory, origin: .smartPreview) }
        cache.removeObject(forKey: id as NSUUID)
        NotificationCenter.default.post(name: Self.didUpdateNotification, object: self, userInfo: ["id": id])
    }

    /// What a thumbnail was drawn from.
    private enum Drawn {
        case original, smartPreview
    }

    nonisolated private static let renderContext = CIContext(options: [.cacheIntermediates: false])

    @concurrent
    nonisolated private static func renderThumbnail(
        from location: PhotoSourceLocation, to destination: URL, adjustments: PhotoAdjustments
    ) async -> Drawn? {
        let temporary = destination.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = location.original
        var drawn = Drawn.original
        do {
            if SupportedImageTypes.isVideo(source) {
                try await VideoSupport.writeThumbnail(from: source, to: temporary)
            } else if adjustments.isDefault, (try? generateThumbnail(from: source, to: temporary)) != nil {
                // The embedded preview, or a quick decode.
            } else {
                guard let developSource = DevelopSource.open(location) else { return nil }
                let image = developSource.image(with: adjustments, scale: developSource.scale(toFit: CGFloat(maxPixelSize), adjustments: adjustments))
                guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                      let cgImage = renderContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace)
                else { return nil }
                try writeJPEG(cgImage, to: temporary)
                if developSource.isSmartPreview { drawn = .smartPreview }
            }
            if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            return drawn
        } catch {
            return nil
        }
    }

    @concurrent
    nonisolated private static func decode(_ url: URL) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    /// Creates a thumbnail JPEG for the image at `source`. Uses the embedded preview when it is
    /// large enough (fast for RAW files) and falls back to decoding the full image otherwise.
    nonisolated static func generateThumbnail(from source: URL, to destination: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: source])
        }
        var image = makeThumbnail(imageSource, fromImageAlways: false)
        if let candidate = image, max(candidate.width, candidate.height) < maxPixelSize * 3 / 4 {
            image = makeThumbnail(imageSource, fromImageAlways: true) ?? candidate
        }
        guard let image else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: source])
        }
        try writeJPEG(image, to: destination)
    }

    nonisolated private static func writeJPEG(_ image: CGImage, to destination: URL) throws {
        guard let destinationRef = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: destination])
        }
        let properties = [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        CGImageDestinationAddImage(destinationRef, image, properties)
        guard CGImageDestinationFinalize(destinationRef) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: destination])
        }
    }

    /// A quick preview of a file that isn't in a catalog (the import window's grid): its embedded
    /// preview when it has one, without writing anything.
    nonisolated static func previewImage(from source: URL, maxPixelSize: Int) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
        return makeThumbnail(imageSource, fromImageAlways: false, maxPixelSize: maxPixelSize)
    }

    nonisolated private static func makeThumbnail(_ source: CGImageSource, fromImageAlways: Bool, maxPixelSize: Int = maxPixelSize) -> CGImage? {
        let options: [CFString: Any] = [
            fromImageAlways ? kCGImageSourceCreateThumbnailFromImageAlways
                : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
