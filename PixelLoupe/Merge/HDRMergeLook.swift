import CoreImage
import Foundation

/// The merge sheet's deghost overlay.
nonisolated enum HDRMergeLook {
    /// Draws `mask`'s edge (where it crosses one half) over `image` in red: Show Deghost Overlay.
    /// `region` is the part of the photo `image` shows, as fractions of it (from the top left).
    static func overlaying(_ mask: GhostMask, on image: CIImage, region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> CIImage {
        let extent = image.extent
        // The mask for the whole photo at the image's scale, moved so the region lands on the image.
        let whole = CGSize(width: extent.width / region.width, height: extent.height / region.height)
        let shown = mask.image(size: whole)
            .transformed(by: CGAffineTransform(
                translationX: extent.minX - region.minX * whole.width,
                y: extent.minY - (1 - region.maxY) * whole.height
            ))
            .cropped(to: extent)
        // The outline is about two points wide at the preview's size.
        let reach = max(1, max(extent.width, extent.height) / 500)
        let eroded = HDRMerger.filtered(shown, "CIMorphologyMinimum", radius: reach)
        return HDRKernels.outline.apply(extent: extent, arguments: [image, shown, eroded]) ?? image
    }
}

/// The merge sheet's preview, rendered off the main thread.
nonisolated struct HDRMergePreview: @unchecked Sendable {
    /// The merged photo as it will first look in PixelLoupe (Display P3).
    let image: CGImage
}

/// Renders previews for the merge sheet: the merge at preview size, saved as a temporary DNG and
/// drawn through the shared Develop pipeline with the photo's starting settings, so the preview is
/// what Merge will produce. The merge is redone only when the options it depends on or the size
/// change. Zoomed in, a region is merged at full resolution the same way.
actor HDRMergePreviewer {
    private let merger: HDRMerger
    nonisolated let warning: String?
    /// The photo's full-resolution size.
    nonisolated let photoSize: CGSize
    private let directory: URL
    private struct Key: Equatable {
        var autoAlign: Bool
        var autoSettings: Bool
        var deghost: HDRMergeOptions.Deghost
        var maxPixels: CGFloat

        init(_ options: HDRMergeOptions, maxPixels: CGFloat) {
            autoAlign = options.autoAlign
            autoSettings = options.autoSettings
            deghost = options.deghost
            self.maxPixels = maxPixels
        }
    }
    private var cached: (key: Key, url: URL, mask: GhostMask?, headroom: Double?)?

    init(sources: [HDRMergeSource]) throws {
        merger = try HDRMerger(sources: sources)
        warning = merger.warning
        photoSize = merger.nativeSize
        directory = FileManager.default.temporaryDirectory
            .appending(path: "PixelLoupe-HDRPreview-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The whole photo, at most `maxPixels` on the long edge.
    func render(options: HDRMergeOptions, maxPixels: CGFloat) throws -> HDRMergePreview {
        let merged = try preview(options: options, maxPixels: maxPixels)
        return try draw(merged.url, mask: options.showsDeghostOverlay ? merged.mask : nil)
    }

    /// The part of the photo at 100% (one pixel per photo pixel) around `center` (fractions of the
    /// photo from the top left), `pixels` in size. The headroom comes from the preview at `maxPixels`,
    /// so the part looks as it does there.
    func renderDetail(options: HDRMergeOptions, center: CGPoint, pixels: CGSize, maxPixels: CGFloat) throws -> HDRMergePreview {
        let whole = try preview(options: options, maxPixels: maxPixels)
        let size = CGSize(width: min(pixels.width.rounded(), photoSize.width), height: min(pixels.height.rounded(), photoSize.height))
        let origin = CGPoint(
            x: (center.x * photoSize.width - size.width / 2).clamped(to: 0...(photoSize.width - size.width)).rounded(),
            y: (center.y * photoSize.height - size.height / 2).clamped(to: 0...(photoSize.height - size.height)).rounded()
        )
        let region = CGRect(origin: origin, size: size)
        let result = try merger.merge(options: options, scale: 1, region: region, headroom: whole.headroom)
        try Task.checkCancellation()
        let url = directory.appending(path: "detail.dng")
        try LinearDNGWriter.write(result.image, metadata: merger.dngMetadata(), to: url)
        let fraction = CGRect(
            x: region.minX / photoSize.width, y: region.minY / photoSize.height,
            width: region.width / photoSize.width, height: region.height / photoSize.height
        )
        return try draw(url, mask: options.showsDeghostOverlay ? result.ghostMask : nil, region: fraction)
    }

    private func preview(options: HDRMergeOptions, maxPixels: CGFloat) throws -> (url: URL, mask: GhostMask?, headroom: Double?) {
        let key = Key(options, maxPixels: maxPixels)
        if let cached, cached.key == key { return (cached.url, cached.mask, cached.headroom) }
        let scale = min(1, maxPixels / max(photoSize.width, photoSize.height, 1))
        let result = try merger.merge(options: options, scale: scale)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(UUID().uuidString).dng")
        try LinearDNGWriter.write(result.image, metadata: merger.dngMetadata(), to: url)
        if let old = cached?.url { try? FileManager.default.removeItem(at: old) }
        cached = (key, url, result.ghostMask, result.image.headroom)
        return (url, result.ghostMask, result.image.headroom)
    }

    /// The DNG drawn as PixelLoupe first shows a merged photo: default settings, with the camera's
    /// white balance (As Shot), as in Lightroom. Auto Settings' look is in the merge itself.
    private func draw(_ url: URL, mask: GhostMask?, region: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> HDRMergePreview {
        try Task.checkCancellation()
        guard let source = DevelopSource(url: url) else { throw HDRMergeError.unreadable(merger.reference.name) }
        var image = source.image(with: PhotoAdjustments(), scale: 1)
        if let mask { image = HDRMergeLook.overlaying(mask, on: image, region: region) }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let cgImage = PhotoRenderer.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace)
        else { throw HDRMergeError.unreadable(merger.reference.name) }
        return HDRMergePreview(image: cgImage)
    }
}
