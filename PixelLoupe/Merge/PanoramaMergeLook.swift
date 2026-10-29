import CoreImage
import Foundation

/// The panorama sheet's preview, rendered off the main thread.
nonisolated struct PanoramaMergePreview: @unchecked Sendable {
    /// The panorama as it will first look in PixelLoupe (Display P3), with a checkerboard where the
    /// photos don't reach (none with Fill Edges, which fills them).
    let image: CGImage
    /// The full-resolution size of what `image` shows (the crop, with Auto Crop on).
    let photoSize: CGSize
}

/// Renders previews for the panorama sheet, as ``HDRMergePreviewer`` does for HDR: the merge at preview
/// size, saved as a temporary DNG and drawn through the shared Develop pipeline with the photo's
/// starting settings (Auto Settings' and Auto Crop's), so the preview is what Merge will produce.
/// The alignment and seams are worked out once (per projection) and reused; zoomed in, a region is
/// merged at full resolution the same way.
actor PanoramaMergePreviewer {
    private let merger: PanoramaMerger
    nonisolated let lensWarning: String?
    nonisolated let allowsPerspective: Bool
    nonisolated let mergedCount: Int
    nonisolated let photoCount: Int
    private let directory: URL
    private struct Key: Equatable {
        var projection: PanoramaProjection
        var boundaryWarp: Int
        var fillEdges: Bool
        var maxPixels: CGFloat
    }
    private struct SettingsKey: Hashable {
        var projection: PanoramaProjection
        var boundaryWarp: Int
        var autoSettings: Bool
        var autoCrop: Bool
        var fillEdges: Bool
    }
    private var cached: (key: Key, url: URL, result: PanoramaMergeResult, scale: CGFloat)?
    private var settings: [SettingsKey: PhotoAdjustments] = [:]

    init(sources: [PhotoMergeSource]) throws {
        merger = try PanoramaMerger(sources: sources)
        lensWarning = merger.lensWarning
        allowsPerspective = merger.allowsPerspective
        mergedCount = merger.mergedCount
        photoCount = sources.count
        directory = FileManager.default.temporaryDirectory
            .appending(path: "PixelLoupe-PanoramaPreview-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The whole panorama, at most `maxPixels` on the long edge (before Auto Crop).
    func render(options: PanoramaMergeOptions, maxPixels: CGFloat) async throws -> PanoramaMergePreview {
        let merged = try preview(options: options, maxPixels: maxPixels)
        let adjustments = try await startingAdjustments(options)
        let full = try merger.size(for: options.projection)
        let crop = adjustments.crop.rect
        let shown = CGSize(width: full.width * crop.width, height: full.height * crop.height)
        let image = try draw(merged.url, adjustments: adjustments, coverage: options.cropsToCovered ? nil : merged.result.coverage)
        return PanoramaMergePreview(image: image, photoSize: shown)
    }

    /// The part of the panorama at 100% (one pixel per panorama pixel) around `center` (fractions of
    /// what the preview shows, from the top left), `pixels` in size.
    func renderDetail(options: PanoramaMergeOptions, center: CGPoint, pixels: CGSize) async throws -> PanoramaMergePreview {
        let adjustments = try await startingAdjustments(options)
        let full = try merger.size(for: options.projection)
        // What the preview shows, in full-resolution pixels from the top left.
        let crop = adjustments.crop.rect
        let shown = CGRect(
            x: crop.minX * full.width, y: (1 - crop.maxY) * full.height,
            width: crop.width * full.width, height: crop.height * full.height
        )
        let size = CGSize(width: min(pixels.width.rounded(), shown.width.rounded(.down)), height: min(pixels.height.rounded(), shown.height.rounded(.down)))
        let origin = CGPoint(
            x: (shown.minX + center.x * shown.width - size.width / 2).clamped(to: shown.minX...(shown.maxX - size.width)).rounded(),
            y: (shown.minY + center.y * shown.height - size.height / 2).clamped(to: shown.minY...(shown.maxY - size.height)).rounded()
        )
        let result = try merger.merge(options: options, scale: 1, region: CGRect(origin: origin, size: size))
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "detail.dng")
        try LinearDNGWriter.write(result.image, metadata: merger.dngMetadata(), to: url)
        // The part is already cut out: its settings without the crop.
        var uncropped = adjustments
        uncropped.crop = PhotoAdjustments.Crop()
        let image = try draw(url, adjustments: uncropped, coverage: options.cropsToCovered ? nil : result.coverage)
        return PanoramaMergePreview(image: image, photoSize: shown.size)
    }

    /// Auto Settings' and Auto Crop's starting settings, worked out once for each combination.
    private func startingAdjustments(_ options: PanoramaMergeOptions) async throws -> PhotoAdjustments {
        let key = SettingsKey(projection: options.projection, boundaryWarp: options.boundaryWarp,
                              autoSettings: options.autoSettings, autoCrop: options.autoCrop, fillEdges: options.fillEdges)
        if let adjustments = settings[key] { return adjustments }
        let adjustments = try await merger.startingAdjustments(options: options, directory: directory)
        settings[key] = adjustments
        return adjustments
    }

    private func preview(options: PanoramaMergeOptions, maxPixels: CGFloat) throws -> (url: URL, result: PanoramaMergeResult) {
        let key = Key(projection: options.projection, boundaryWarp: options.boundaryWarp, fillEdges: options.fillEdges, maxPixels: maxPixels)
        if let cached, cached.key == key { return (cached.url, cached.result) }
        let size = try merger.size(for: options.projection)
        let scale = min(1, maxPixels / max(size.width, size.height, 1))
        let result = try merger.merge(options: options, scale: scale)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(UUID().uuidString).dng")
        try LinearDNGWriter.write(result.image, metadata: merger.dngMetadata(), to: url)
        if let old = cached?.url { try? FileManager.default.removeItem(at: old) }
        cached = (key, url, result, scale)
        return (url, result)
    }

    /// The DNG drawn as PixelLoupe first shows the panorama, with a checkerboard where `coverage`
    /// says the photos don't reach (as Lightroom's preview shows them).
    private func draw(_ url: URL, adjustments: PhotoAdjustments, coverage: PanoramaCoverage?) throws -> CGImage {
        try Task.checkCancellation()
        guard let source = DevelopSource(url: url) else { throw PhotoMergeError.unreadable(merger.reference.name) }
        var image = source.image(with: adjustments, scale: 1)
        if let coverage, coverage.width == Int(image.extent.width), coverage.height == Int(image.extent.height) {
            image = PanoramaMergeLook.checkered(image, coverage: coverage)
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let cgImage = PhotoRenderer.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace)
        else { throw PhotoMergeError.unreadable(merger.reference.name) }
        return cgImage
    }
}

/// The panorama sheet's checkerboard.
nonisolated enum PanoramaMergeLook {
    /// `image` over a light gray checkerboard, showing through where `coverage` (at the image's size)
    /// says the photos don't reach.
    static func checkered(_ image: CIImage, coverage: PanoramaCoverage) -> CIImage {
        let extent = image.extent
        var values = [Float](repeating: 1, count: coverage.values.count * 4)
        for (i, value) in coverage.values.enumerated() {
            values[i * 4] = value
            values[i * 4 + 1] = value
            values[i * 4 + 2] = value
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        let mask = CIImage(bitmapData: data, bytesPerRow: coverage.width * 16,
                           size: CGSize(width: coverage.width, height: coverage.height), format: .RGBAf, colorSpace: nil)
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        let square = max(4, (max(extent.width, extent.height) / 160).rounded())
        let generator = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputColor0": CIColor(red: 0.84, green: 0.84, blue: 0.84),
            "inputColor1": CIColor(red: 0.98, green: 0.98, blue: 0.98),
            "inputWidth": square, "inputSharpness": 1,
            kCIInputCenterKey: CIVector(x: extent.minX, y: extent.minY),
        ])
        let checkerboard = (generator?.outputImage ?? CIImage(color: .white)).cropped(to: extent)
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: checkerboard, kCIInputMaskImageKey: mask,
        ])
    }
}
