import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A catalog's Standard previews (RAW-84): a rendering, 2560 px unless Catalog Settings ▸ Previews says otherwise, of a camera RAW photo with its Develop settings, in
/// Display P3, so the loupe, Develop, Compare and Survey have a large, accurate picture to show while the full render
/// runs. They're built when an import asks for Standard previews or with Library ▸ Previews ▸ Build Standard Previews.
///
/// Each is a JPEG in the package's `Previews` folder named by its photo's ID; the folder is the record of which
/// photos have one. Editing a photo makes its preview stale: the file is renamed to `<id>.stale` (never shown) until
/// ``StandardPreviewBuilder`` draws it again, so a photo keeps its Standard preview through edits and app restarts.
/// Virtual copies have their own settings, so each has its own.
///
/// Changing the size or quality in Catalog Settings (RAW-267) leaves the files alone: each preview records the
/// ``StandardPreviewFormat`` it was drawn at, and one drawn at another is *outdated*. It's still shown, and it's
/// drawn again when it's next viewed (or by Build Standard Previews). Viewing a preview also dates its file, so
/// Limit Preview Cache Size can remove the least recently viewed first.
@MainActor
final class StandardPreviewStore {
    nonisolated static let currentExtension = "jpg"
    nonisolated static let staleExtension = "stale"

    /// Posted (on the main thread, with this object) when photos get, lose or have a stale Standard preview.
    /// `userInfo["ids"]` is a `Set<UUID>`.
    nonisolated static let didChangeNotification = Notification.Name("StandardPreviewStoreDidChange")

    let directory: URL
    /// Photos with a Standard preview, current or stale.
    private(set) var ids = Set<UUID>()
    /// Photos whose Standard preview is waiting to be drawn again after an edit.
    private(set) var stale = Set<UUID>()
    /// Photos whose Standard preview was found, when viewed, to be drawn at a format other than ``format``.
    private(set) var outdated = Set<UUID>()
    /// The size and quality Standard previews are drawn at now, from Catalog Settings.
    var format = StandardPreviewFormat.original {
        didSet {
            guard format != oldValue else { return }
            // Shown previews are checked against the new format as they're decoded again.
            cache.removeAllObjects()
            outdated = []
        }
    }
    /// Called when a preview shown is found to be outdated, to have it drawn again.
    var onOutdated: (UUID) -> Void = { _ in }
    private var loading: Task<Void, Never>?
    private let cache = NSCache<NSUUID, CGImage>()
    private var inFlight: [UUID: Task<CGImage?, Never>] = [:]

    init(directory: URL) {
        self.directory = directory
        // The viewers only need the photos around the current one: six 2560 px previews (about 26 MB each
        // decoded), fewer when they're larger.
        cache.countLimit = 6
        cache.totalCostLimit = 160_000_000
    }

    nonisolated static func url(for id: UUID, in directory: URL) -> URL {
        directory.appending(path: "\(id.uuidString).\(currentExtension)")
    }

    nonisolated static func staleURL(for id: UUID, in directory: URL) -> URL {
        directory.appending(path: "\(id.uuidString).\(staleExtension)")
    }

    func url(for id: UUID) -> URL { Self.url(for: id, in: directory) }

    /// Lists the folder, off the main thread, when the catalog opens. Later calls wait for the first.
    func load() async {
        if loading == nil {
            let directory = directory
            loading = Task { [weak self] in
                let listed = await Self.list(directory)
                guard let self else { return }
                // Previews written or made stale while the folder was being listed are already recorded.
                let new = listed.current.union(listed.stale).subtracting(ids)
                ids.formUnion(new)
                stale.formUnion(listed.stale.intersection(new))
                post(new)
            }
        }
        await loading?.value
    }

    /// Whether the photo has a Standard preview, current or waiting to be redrawn.
    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// Whether the photo has a Standard preview that can be shown now.
    func isCurrent(_ id: UUID) -> Bool { ids.contains(id) && !stale.contains(id) }

    /// Whether the photo's Standard preview needs drawing: it has none, it's stale, or it's outdated.
    func needsDrawing(_ id: UUID) -> Bool { !isCurrent(id) || outdated.contains(id) }

    func cachedImage(for id: UUID) -> CGImage? {
        isCurrent(id) ? cache.object(forKey: id as NSUUID) : nil
    }

    /// The photo's current Standard preview, decoded off the main thread; nil when it has none or it's stale.
    func image(for id: UUID) async -> CGImage? {
        guard isCurrent(id) else { return nil }
        if let cached = cache.object(forKey: id as NSUUID) { return cached }
        if let task = inFlight[id] { return await task.value }
        let url = url(for: id)
        let task = Task<CGImage?, Never> { [weak self] in
            guard let (image, drawnAt) = await Self.decode(url) else { return nil }
            if let self, drawnAt != format, isCurrent(id), outdated.insert(id).inserted { onOutdated(id) }
            return image
        }
        inFlight[id] = task
        let image = await task.value
        inFlight[id] = nil
        // It may have gone stale while decoding.
        guard let image, isCurrent(id) else { return nil }
        cache.setObject(image, forKey: id as NSUUID, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Records a Standard preview just written for `id`.
    func didWrite(_ id: UUID) {
        ids.insert(id)
        outdated.remove(id)
        if stale.remove(id) != nil { try? FileManager.default.removeItem(at: Self.staleURL(for: id, in: directory)) }
        cache.removeObject(forKey: id as NSUUID)
        post([id])
    }

    /// Marks the photo's Standard preview stale after an edit, so it isn't shown until drawn again. Returns whether
    /// it has one (and so needs redrawing).
    @discardableResult
    func invalidate(_ id: UUID) -> Bool {
        guard ids.contains(id) else { return false }
        cache.removeObject(forKey: id as NSUUID)
        guard stale.insert(id).inserted else { return true }
        let current = url(for: id), staleURL = Self.staleURL(for: id, in: directory)
        try? FileManager.default.removeItem(at: staleURL)
        try? FileManager.default.moveItem(at: current, to: staleURL)
        post([id])
        return true
    }

    /// Deletes the Standard previews of `photoIDs`. Their edits are untouched, and it isn't undoable (as in
    /// Lightroom).
    func discard(_ photoIDs: some Sequence<UUID>) {
        var changed = Set<UUID>()
        for id in photoIDs where ids.contains(id) {
            try? FileManager.default.removeItem(at: url(for: id))
            try? FileManager.default.removeItem(at: Self.staleURL(for: id, in: directory))
            ids.remove(id)
            stale.remove(id)
            outdated.remove(id)
            cache.removeObject(forKey: id as NSUUID)
            changed.insert(id)
        }
        if !changed.isEmpty { post(changed) }
    }

    /// Deletes the Standard previews named by IDs not in `kept`, the catalog's photos. Like thumbnails, a removed
    /// photo's preview stays while the app runs so undoing the removal brings it back; this runs when the catalog
    /// opens.
    nonisolated static func pruneOrphans(in directory: URL, keeping kept: Set<UUID>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in names {
            let url = directory.appending(path: name)
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !kept.contains(id) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func post(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self, userInfo: ["ids": ids])
    }

    @concurrent
    nonisolated private static func list(_ directory: URL) async -> (current: Set<UUID>, stale: Set<UUID>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        var current = Set<UUID>(), stale = Set<UUID>()
        // Files being written start with a dot.
        for name in names where !name.hasPrefix(".") {
            let url = directory.appending(path: name)
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            switch url.pathExtension {
            case currentExtension: current.insert(id)
            case staleExtension: stale.insert(id)
            default: break
            }
        }
        // A crash between writing a preview and removing its stale file leaves both; the new one wins.
        return (current, stale.subtracting(current))
    }

    /// The preview at `url` and the format it was drawn at. Dates the file as viewed now, for
    /// ``leastRecentlyViewed(in:over:)``.
    @concurrent
    nonisolated private static func decode(_ url: URL) async -> (CGImage, StandardPreviewFormat)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let format = StandardPreviewFormat(tag: exif?[kCGImagePropertyExifUserComment] as? String) ?? .original
        var viewed = url
        var values = URLResourceValues()
        values.contentModificationDate = Date()
        try? viewed.setResourceValues(values)
        return (image, format)
    }

    // MARK: - Cache size

    /// The Standard previews in `directory` to remove, least recently viewed first, to bring the folder to
    /// `limit` bytes or under. Stale previews count too; files being written don't.
    @concurrent
    nonisolated static func leastRecentlyViewed(in directory: URL, over limit: Int64) async -> [UUID] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        var previews: [(id: UUID, size: Int64, viewed: Date)] = []
        for file in files where !file.lastPathComponent.hasPrefix(".") {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let values = try? file.resourceValues(forKeys: keys) else { continue }
            previews.append((id, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast))
        }
        var total = previews.reduce(0) { $0 + $1.size }
        var removed: [UUID] = []
        for preview in previews.sorted(by: { $0.viewed < $1.viewed }) where total > limit {
            removed.append(preview.id)
            total -= preview.size
        }
        return removed
    }

    // MARK: - Drawing

    /// What drawing a Standard preview produced.
    nonisolated struct Drawn: Sendable {
        /// Whether it was drawn from the photo's Smart Preview, the original being missing.
        var fromSmartPreview: Bool
        /// Whether the grid thumbnail was written too.
        var wroteThumbnail: Bool
    }

    nonisolated private static let renderContext = CIContext(options: [.cacheIntermediates: false])

    /// Draws the Standard preview of the photo at `location` to `destination`, and when `thumbnail` is given, the
    /// grid thumbnail from the same render (downscaled to ``ThumbnailStore/maxPixelSize``, in sRGB like the others).
    /// Runs on ``RenderQueue/thumbnails`` so it never competes with the photo on screen. Nil when the photo can't be
    /// read or the calling task is cancelled before its turn.
    nonisolated static func draw(
        _ location: PhotoSourceLocation, adjustments: PhotoAdjustments, format: StandardPreviewFormat = .original,
        to destination: URL, thumbnail: URL?
    ) async -> Drawn? {
        (try? await RenderQueue.thumbnails.run {
            drawNow(location, adjustments: adjustments, format: format, to: destination, thumbnail: thumbnail)
        }) ?? nil
    }

    nonisolated private static func drawNow(
        _ location: PhotoSourceLocation, adjustments: PhotoAdjustments, format: StandardPreviewFormat,
        to destination: URL, thumbnail: URL?
    ) -> Drawn? {
        guard let source = DevelopSource.open(location) else { return nil }
        let image = source.image(with: adjustments, scale: source.scale(toFit: CGFloat(format.pixelSize), adjustments: adjustments))
        guard !image.extent.isEmpty, !image.extent.isInfinite,
              let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let preview = renderContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: p3)
        else { return nil }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeJPEG(preview, quality: format.quality, comment: format.tag, replacing: destination)
        } catch {
            return nil
        }
        var drawn = Drawn(fromSmartPreview: source.isSmartPreview, wroteThumbnail: false)
        if let thumbnail, let small = downscaled(preview, toFit: ThumbnailStore.maxPixelSize) {
            drawn.wroteThumbnail = (try? writeJPEG(small, quality: 0.8, replacing: thumbnail)) != nil
        }
        return drawn
    }

    /// `image` scaled down to fit `pixels` on its long edge, in sRGB.
    nonisolated private static func downscaled(_ image: CGImage, toFit pixels: Int) -> CGImage? {
        let longEdge = max(image.width, image.height)
        let scale = min(1, CGFloat(pixels) / CGFloat(longEdge))
        let input = CIImage(cgImage: image)
        let filter = CIFilter(name: "CILanczosScaleTransform")
        filter?.setValue(input, forKey: kCIInputImageKey)
        filter?.setValue(scale, forKey: kCIInputScaleKey)
        filter?.setValue(1, forKey: kCIInputAspectRatioKey)
        guard let output = filter?.outputImage, let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let extent = output.extent.integral.intersection(output.extent)
        return renderContext.createCGImage(output, from: extent, format: .RGBA8, colorSpace: srgb)
    }

    /// Writes `image` as a JPEG to a temporary file beside `destination`, then swaps it in. `comment`, when given,
    /// goes in the EXIF UserComment field (the preview's ``StandardPreviewFormat``; ImageIO drops TIFF Software
    /// from JPEGs).
    nonisolated private static func writeJPEG(_ image: CGImage, quality: Double, comment: String? = nil, replacing destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let output = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: destination]) }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let comment { properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifUserComment: comment] }
        CGImageDestinationAddImage(output, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: destination]) }
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
}
