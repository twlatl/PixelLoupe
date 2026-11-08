import AppKit
import OSLog

extension CatalogStore {
    /// Applies Catalog Settings ▸ Previews: the size and quality Standard previews are drawn at, and the cache
    /// limit. Runs when the catalog opens, when the settings change and when displays change (for Auto).
    func applyPreviewSettings() {
        standardPreviews.format = settings.standardPreviewFormat(autoPixelSize: Self.autoPreviewPixelSize())
        trimStandardPreviews()
    }

    /// Removes the least recently viewed Standard previews until the folder is within Limit Preview Cache Size.
    /// Does nothing without a limit. Runs when the catalog opens, when the limit changes and when a build finishes.
    func trimStandardPreviews() {
        guard let limit = settings.previewCacheLimitBytes else { return }
        let previews = standardPreviews
        Task {
            await previews.load()
            let removed = await StandardPreviewStore.leastRecentlyViewed(in: previews.directory, over: limit)
            guard !removed.isEmpty else { return }
            Self.logger.info("Removing \(removed.count) Standard previews to stay within the preview cache limit")
            previews.discard(removed)
        }
    }

    /// Standard Preview Size ▸ Auto: the long edge, in pixels, of the largest connected display (as Lightroom
    /// Classic does). The original 2560 when there's no display to measure.
    static func autoPreviewPixelSize(screens: [NSScreen] = NSScreen.screens) -> Int {
        let edges = screens.map { Int((max($0.frame.width, $0.frame.height) * $0.backingScaleFactor).rounded()) }
        return edges.max() ?? StandardPreviewFormat.original.pixelSize
    }
}
