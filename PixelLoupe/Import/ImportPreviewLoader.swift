import CoreGraphics
import Foundation

/// Previews of files that aren't in the catalog yet, for the import window. Photos use their
/// embedded preview and movies a poster frame, decoded off the main thread and kept in memory only.
final class ImportPreviewLoader {
    /// Grid cells go up to 400 pt, so this is sharp on a Retina display at all but the largest size.
    static let gridPixelSize = 512
    static let enlargedPixelSize = 2560

    private let cache = NSCache<NSString, CGImage>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    init() {
        cache.countLimit = 600
    }

    func cachedImage(for url: URL, pixelSize: Int = gridPixelSize) -> CGImage? {
        cache.object(forKey: Self.key(url, pixelSize) as NSString)
    }

    func image(for url: URL, isVideo: Bool, pixelSize: Int = gridPixelSize) async -> CGImage? {
        let key = Self.key(url, pixelSize)
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let task = inFlight[key] { return await task.value }
        let task = Task { await Self.load(url, isVideo: isVideo, pixelSize: pixelSize) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }

    private static func key(_ url: URL, _ pixelSize: Int) -> String {
        "\(pixelSize)|\(url.path(percentEncoded: false))"
    }

    nonisolated private static func load(_ url: URL, isVideo: Bool, pixelSize: Int) async -> CGImage? {
        // A file on a camera or phone: its thumbnail, from the device.
        if ImportDevices.isDeviceURL(url) {
            return await ImportDevices.shared.thumbnail(for: url, maxPixelSize: pixelSize)
        }
        return await loadFile(url, isVideo: isVideo, pixelSize: pixelSize)
    }

    @concurrent
    nonisolated private static func loadFile(_ url: URL, isVideo: Bool, pixelSize: Int) async -> CGImage? {
        if isVideo {
            return try? await VideoSupport.posterImage(from: url, maxPixelSize: pixelSize)
        }
        return ThumbnailStore.previewImage(from: url, maxPixelSize: pixelSize)
    }
}
