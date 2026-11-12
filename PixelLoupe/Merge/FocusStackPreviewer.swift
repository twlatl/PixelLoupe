import CoreImage
import Foundation
import ImageIO

/// The focus stack sheet's preview, rendered off the main thread.
nonisolated struct FocusStackPreview: @unchecked Sendable {
    /// The stacked photo as it will first look in PixelLoupe (Display P3).
    let image: CGImage
    /// The depth map the frames were chosen by: the first frame black, the last one white.
    let depthMap: CGImage
    /// How many frames went into it.
    let mergedCount: Int
}

extension FocusStackPreviewer {
    /// A picture on its way to the main thread (CGImage is immutable).
    nonisolated struct Picture: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
}

/// Renders previews for the focus stack sheet. The photos are lined up once. A preview is the stack at
/// preview size, with the frames kept in memory at that size so another Radius or Smoothing doesn't read
/// every photo again. A stack of RAW photos is drawn through the shared Develop pipeline from a temporary
/// DNG, as the other merges' previews are; a stack of other photos is drawn as it is, because that's how
/// its TIFF will look. Zoomed in, a region is stacked at full resolution from the frames that are sharp
/// around there.
actor FocusStackPreviewer {
    private let merger: FocusStackMerger
    /// The frames in the order they were taken.
    nonisolated let sources: [PhotoMergeSource]
    /// The photo's full-resolution size.
    nonisolated let photoSize: CGSize
    private let directory: URL

    private struct Key: Equatable {
        var method: FocusStackOptions.Method
        var radius: Int
        var smoothing: Int
        var excluding: Set<URL>
        var maxPixels: CGFloat
    }
    private var cached: (key: Key, preview: FocusStackPreview, depth: FocusDepthMap)?

    /// The most memory the frames kept for previews may take; the preview is made smaller to fit.
    static let frameBudget: Double = 1_500_000_000

    init(sources: [PhotoMergeSource]) throws {
        merger = try FocusStackMerger(sources: sources)
        self.sources = merger.frames.map(\.source)
        photoSize = merger.nativeSize
        directory = FileManager.default.temporaryDirectory
            .appending(path: "PixelLoupe-FocusPreview-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Lines the photos up (once), and says which didn't. `progress` gets the fraction done.
    func align(progress: @escaping @Sendable (Double) -> Void) throws -> [URL] {
        try merger.align(progress: progress)
        return merger.skipped.map(\.url)
    }

    /// The largest preview, on its long edge, whose frames fit the memory budget.
    private func fitting(_ maxPixels: CGFloat) -> CGFloat {
        let aspect = min(photoSize.width, photoSize.height) / max(photoSize.width, photoSize.height, 1)
        let perFrame = Self.frameBudget / Double(max(sources.count, 1)) / 8
        let longest = (perFrame / Double(max(aspect, 0.1))).squareRoot()
        return min(maxPixels, max(600, (CGFloat(longest) / 200).rounded(.down) * 200))
    }

    /// The whole stack, at most `maxPixels` on the long edge. `depthProgress` gets the depth map as it
    /// builds, a frame at a time.
    func render(
        options: FocusStackOptions, excluding: Set<URL>, maxPixels: CGFloat,
        depthProgress: @escaping @Sendable (CGImage) -> Void = { _ in }
    ) throws -> FocusStackPreview {
        let size = fitting(maxPixels)
        let key = Key(method: options.method, radius: options.radius, smoothing: options.smoothing, excluding: excluding, maxPixels: size)
        if let cached, cached.key == key { return cached.preview }
        let scale = min(1, size / max(photoSize.width, photoSize.height, 1))
        merger.keptScale = scale
        let result = try merger.merge(options: options, scale: scale, excluding: excluding, depthMap: { map in
            if let image = Self.image(of: map) { depthProgress(image) }
        })
        try Task.checkCancellation()
        guard let depth = Self.image(of: result.depthMap) else { throw PhotoMergeError.unreadable(merger.reference.name) }
        let preview = FocusStackPreview(image: try draw(result.image, name: "preview"), depthMap: depth, mergedCount: result.mergedCount)
        cached = (key, preview, result.depthMap)
        return preview
    }

    /// The part of the stack at 100% (one pixel per photo pixel) around `center` (fractions of the
    /// photo from the top left), `pixels` in size. Only the frames the preview's depth map chose around
    /// there (and a few either side) are read: reading every photo at full size for a small part of
    /// the picture would take as long as the whole merge.
    func renderDetail(
        options: FocusStackOptions, excluding: Set<URL>, center: CGPoint, pixels: CGSize, maxPixels: CGFloat
    ) throws -> CGImage {
        _ = try render(options: options, excluding: excluding, maxPixels: maxPixels)
        let size = CGSize(width: min(pixels.width.rounded(), photoSize.width), height: min(pixels.height.rounded(), photoSize.height))
        let origin = CGPoint(
            x: (center.x * photoSize.width - size.width / 2).clamped(to: 0...(photoSize.width - size.width)).rounded(),
            y: (center.y * photoSize.height - size.height / 2).clamped(to: 0...(photoSize.height - size.height)).rounded()
        )
        let region = CGRect(origin: origin, size: size)
        var leftOut = excluding
        if let depth = cached?.depth {
            let stacked = merger.frames.filter { $0.transform != nil && !excluding.contains($0.source.url) }.map(\.source.url)
            let range = Self.frames(in: depth, region: region, photoSize: photoSize, count: stacked.count)
            for (number, url) in stacked.enumerated() where !range.contains(number) { leftOut.insert(url) }
        }
        let result = try merger.merge(options: options, scale: 1, excluding: leftOut, region: region)
        try Task.checkCancellation()
        return try draw(result.image, name: "detail")
    }

    /// The frames (by their place among the `count` stacked) the depth map names inside `region`, and
    /// `margin` either side: at least two.
    static func frames(in depth: FocusDepthMap, region: CGRect, photoSize: CGSize, count: Int, margin: Int = 3) -> ClosedRange<Int> {
        guard count > 1, depth.width > 0, depth.height > 0, photoSize.width > 0, photoSize.height > 0 else { return 0...max(count - 1, 0) }
        let x0 = max(0, min(depth.width - 1, Int(region.minX / photoSize.width * CGFloat(depth.width))))
        let x1 = max(x0, min(depth.width - 1, Int(region.maxX / photoSize.width * CGFloat(depth.width))))
        let y0 = max(0, min(depth.height - 1, Int(region.minY / photoSize.height * CGFloat(depth.height))))
        let y1 = max(y0, min(depth.height - 1, Int(region.maxY / photoSize.height * CGFloat(depth.height))))
        var low = UInt8.max, high = UInt8.min
        for y in y0...y1 {
            for x in x0...x1 {
                let value = depth.pixels[y * depth.width + x]
                low = min(low, value)
                high = max(high, value)
            }
        }
        let last = Double(count - 1)
        var first = Int((Double(low) / 255 * last).rounded(.down)) - margin
        var final = Int((Double(high) / 255 * last).rounded(.up)) + margin
        first = max(0, first)
        final = min(count - 1, final)
        if final - first < 1 { first = max(0, final - 1); final = min(count - 1, first + 1) }
        return first...final
    }

    /// One of the photos as it is, at most `maxPixels` on the long edge: the sheet's Original.
    nonisolated func original(_ url: URL, maxPixels: CGFloat) -> CGImage? {
        guard let file = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixels),
        ]
        return CGImageSourceCreateThumbnailAtIndex(file, 0, options as CFDictionary)
    }

    /// The stack as PixelLoupe will first show it.
    private func draw(_ image: LinearDNGImage, name: String) throws -> CGImage {
        try Task.checkCancellation()
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) else { throw PhotoMergeError.unreadable(merger.reference.name) }
        if !merger.isRaw {
            guard let drawn = FocusStackTIFFWriter.encoded(image, format: .RGBA8, colorSpace: colorSpace) else {
                throw PhotoMergeError.unreadable(merger.reference.name)
            }
            return drawn
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(name).dng")
        try LinearDNGWriter.write(image, metadata: merger.dngMetadata(), to: url)
        guard let source = DevelopSource(url: url) else { throw PhotoMergeError.unreadable(merger.reference.name) }
        let developed = source.image(with: PhotoAdjustments(), scale: 1)
        guard let drawn = PhotoRenderer.context.createCGImage(developed, from: developed.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw PhotoMergeError.unreadable(merger.reference.name)
        }
        return drawn
    }

    /// A depth map as a gray image.
    static func image(of map: FocusDepthMap) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(map.pixels) as CFData) else { return nil }
        return CGImage(
            width: map.width, height: map.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: map.width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
