import Accelerate
import CoreImage
import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers

/// Photo ▸ Photo Merge ▸ Focus Stack's settings. The last ones used are remembered for the next stack.
nonisolated struct FocusStackOptions: Codable, Equatable, Sendable {
    /// How the frames' sharp parts are put together.
    enum Method: Int, Codable, CaseIterable, Sendable {
        case weightedAverage, depthMap, pyramid

        var title: String {
            switch self {
            case .weightedAverage: "Weighted Average"
            case .depthMap: "Depth Map"
            case .pyramid: "Pyramid"
            }
        }
    }

    static let radiusRange = 1...50
    static let smoothingRange = 0...10

    var method = Method.depthMap
    /// The neighborhood a pixel's contrast is measured over, in pixels of the full-size photo.
    var radius = 8
    /// How softly the sharp areas of different frames run into each other.
    var smoothing = 4
    var createsStack = true

    init() {}

    // Settings saved by an earlier version may lack some of these, or hold values no longer allowed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = FocusStackOptions()
        method = (try? container.decodeIfPresent(Method.self, forKey: .method)) ?? defaults.method
        radius = try container.decodeIfPresent(Int.self, forKey: .radius) ?? defaults.radius
        smoothing = try container.decodeIfPresent(Int.self, forKey: .smoothing) ?? defaults.smoothing
        createsStack = try container.decodeIfPresent(Bool.self, forKey: .createsStack) ?? defaults.createsStack
        radius = min(max(radius, Self.radiusRange.lowerBound), Self.radiusRange.upperBound)
        smoothing = min(max(smoothing, Self.smoothingRange.lowerBound), Self.smoothingRange.upperBound)
    }

    /// Reset: the method and its sliders back to their defaults (Create Stack stays as it is).
    mutating func resetRendering() {
        let defaults = FocusStackOptions()
        method = defaults.method
        radius = defaults.radius
        smoothing = defaults.smoothing
    }

    private static let defaultsKey = "FocusStackOptions"

    static func load(from defaults: UserDefaults = Defaults.store) -> FocusStackOptions {
        guard let data = defaults.data(forKey: defaultsKey),
              let options = try? JSONDecoder().decode(FocusStackOptions.self, from: data) else { return FocusStackOptions() }
        return options
    }

    func save(to defaults: UserDefaults = Defaults.store) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}

nonisolated enum FocusStackError: LocalizedError, Equatable {
    case mixedKinds
    case tooFewAligned
    case methodUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .mixedKinds: "A focus stack can’t mix RAW photos with other kinds of photo."
        case .tooFewAligned: "Fewer than two of the photos line up with each other."
        case .methodUnavailable(let title): "The \(title) method isn’t available yet."
        }
    }
}

/// Which frame is sharpest where, as a gray picture: the first frame black, the last one white. Top row first.
nonisolated struct FocusDepthMap: Sendable, Equatable {
    var width: Int
    var height: Int
    var pixels: [UInt8]
}

nonisolated struct FocusStackResult: Sendable {
    var image: LinearDNGImage
    /// The depth map the frames were chosen by, after smoothing.
    var depthMap: FocusDepthMap
    /// How many frames went into the result.
    var mergedCount: Int
}

/// Merges photos of one scene focused at different distances into one that's sharp throughout.
///
/// The frames are taken in the order they were shot. Each is lined up with the one before it (focusing
/// changes a lens's magnification, so a frame is moved, scaled and turned to fit: corners matched by
/// ``PanoramaAligner`` and a similarity fitted to them), and the moves add up to put every frame on the
/// first. A frame that doesn't line up is left out. Each frame's brightness is matched to the first's.
/// The result covers what every frame shows.
///
/// Depth Map: every pixel's contrast is measured in each frame (the size of its brightness's Laplacian,
/// averaged over Radius), and the frame where it's highest is that pixel's depth. Flat areas, where no
/// frame stands out, and faint detail beside strong edges (where a frame far out of focus would win: a
/// halo) take their depth from the detail around them. The depth map is smoothed
/// (Smoothing), and each pixel is taken from the frame its depth names, or from the two frames a depth
/// falls between.
///
/// RAW frames are decoded linearly with the first frame's white balance, as the other merges do; the
/// photos' Develop settings play no part. Frames are read one at a time, twice (once to find the depth
/// map, once to take the pixels), so a deep stack needs no more memory than a short one. The pixel work
/// runs on the GPU, in Core Image kernels (FocusStackKernels.ci.metal).
///
/// Not thread-safe: use one instance per task.
nonisolated final class FocusStackMerger {
    struct Frame {
        let source: PhotoMergeSource
        /// Takes the frame's pixels onto the first frame's (full size, Core Image's axes); nil for a
        /// frame that doesn't line up, and before ``align(progress:)``.
        fileprivate(set) var transform: CGAffineTransform?
        /// What the frame is multiplied by to be as bright as the first.
        fileprivate(set) var gain = 1.0
    }

    /// The frames in the order they were taken.
    private(set) var frames: [Frame]
    /// The first frame: the others are lined up with it, and its metadata is the result's.
    var reference: PhotoMergeSource { frames[0].source }
    let nativeSize: CGSize
    let isRaw: Bool

    private var neutral: (temperature: Float, tint: Float) = (0, 0)
    private var cameraBaselineExposure = 0.0
    private var isAligned = false
    // Full floats: the depth map's weights run from faint grain to crisp edges, more than half floats hold.
    private let context = CIContext(options: [
        .workingColorSpace: HDRMerger.colorSpace, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
    ])

    /// The long side of the copies frames are lined up at.
    static let alignmentSide: CGFloat = 1536
    /// How close (pixels, at that size) a matched corner must land to where the fit puts it.
    static let inlierTolerance = 2.0
    /// The most one frame differs from the one before it: in scale, in turn (radians), and in shift (a
    /// fraction of the long side). More than that is another picture, not the next focus step.
    static let largestScaleChange = 0.1
    static let largestTurn = 3.0 * Double.pi / 180
    static let largestShift = 0.05

    /// Why `sources` can't be stacked, from what the catalog knows about them, or nil when they can be
    /// as far as that goes (unreadable files and photos of different sizes are found as they're read).
    static func problem(merging sources: [PhotoMergeSource]) -> (any Error)? {
        guard sources.count >= 2 else { return PhotoMergeError.tooFewPhotos }
        guard Set(sources.map { SupportedImageTypes.isRaw($0.url) }).count == 1 else { return FocusStackError.mixedKinds }
        return nil
    }

    /// `sources` in the order they were taken (by name where the times are the same or unknown).
    static func ordered(_ sources: [PhotoMergeSource]) -> [PhotoMergeSource] {
        sources.sorted { a, b in
            let first = a.captureDate ?? .distantFuture, second = b.captureDate ?? .distantFuture
            return first != second ? first < second : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    init(sources: [PhotoMergeSource]) throws {
        if let problem = Self.problem(merging: sources) { throw problem }
        let ordered = Self.ordered(sources)
        isRaw = SupportedImageTypes.isRaw(ordered[0].url)
        var size: CGSize?
        for (index, source) in ordered.enumerated() {
            let extent: CGRect
            if isRaw {
                guard let filter = CIRAWFilter(imageURL: source.url), let output = filter.outputImage else {
                    throw PhotoMergeError.unreadable(source.name)
                }
                extent = output.extent
                if index == 0 {
                    neutral = (filter.neutralTemperature, filter.neutralTint)
                    cameraBaselineExposure = Double(filter.baselineExposure)
                }
            } else {
                guard let image = CIImage(contentsOf: source.url, options: [.applyOrientationProperty: true]) else {
                    throw PhotoMergeError.unreadable(source.name)
                }
                extent = image.extent
            }
            guard size == nil || size == extent.size else { throw PhotoMergeError.differentSizes }
            size = extent.size
        }
        nativeSize = size ?? .zero
        frames = ordered.map { Frame(source: $0) }
    }

    /// The kind of file a stack of `sources` is saved as: a Linear DNG for RAW photos, like the other
    /// merges, and a 16-bit TIFF for the rest. Photos that aren't RAW already have their look in them;
    /// as a DNG the RAW engine would add its own on top (more contrast, the highlights gone).
    static func fileExtension(for sources: [PhotoMergeSource]) -> String {
        sources.contains { SupportedImageTypes.isRaw($0.url) } ? "dng" : "tif"
    }

    /// What the merged DNG records about the shot: the first frame's.
    func dngMetadata() -> DNGMetadata {
        let source = reference
        return DNGMetadata(
            make: source.make, model: source.model, lensModel: source.lensModel, captureDate: source.captureDate,
            exposureTime: source.exposureTime, aperture: source.aperture, iso: source.iso,
            focalLength: source.focalLength, baselineExposure: cameraBaselineExposure
        )
    }

    /// The frames left out because they don't line up with the others (none before ``align(progress:)``).
    var skipped: [PhotoMergeSource] {
        isAligned ? frames.filter { $0.transform == nil }.map(\.source) : []
    }

    // MARK: - Decoding

    /// A frame at `scale`, scene-linear, with its origin at zero and exactly `scale` times the full size.
    private func decoded(_ index: Int, scale: CGFloat) throws -> CIImage {
        let source = frames[index].source
        var image: CIImage?
        if isRaw {
            if let filter = CIRAWFilter(imageURL: source.url) {
                filter.scaleFactor = Float(scale)
                filter.exposure = 0
                filter.baselineExposure = 0
                filter.boostAmount = 0
                filter.shadowBias = 0
                filter.isGamutMappingEnabled = false
                filter.neutralTemperature = neutral.temperature
                filter.neutralTint = neutral.tint
                image = filter.outputImage
            }
        } else if scale >= 1 {
            image = CIImage(contentsOf: source.url, options: [.applyOrientationProperty: true])
        } else if let file = CGImageSourceCreateWithURL(source.url as CFURL, nil) {
            // ImageIO scales a JPEG as it decodes it, far quicker than decoding it whole.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int((max(nativeSize.width, nativeSize.height) * scale).rounded(.up)),
            ]
            image = CGImageSourceCreateThumbnailAtIndex(file, 0, options as CFDictionary).map { CIImage(cgImage: $0) }
        }
        guard let image, !image.extent.isEmpty, !image.extent.isInfinite else { throw PhotoMergeError.unreadable(source.name) }
        let extent = image.extent
        return image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(
                scaleX: nativeSize.width * scale / extent.width, y: nativeSize.height * scale / extent.height
            )))
    }

    // MARK: - Alignment

    /// A move, scale and turn: a point p goes to (a·p.x − b·p.y, b·p.x + a·p.y) + t.
    struct Similarity: Equatable, Sendable {
        var a = 1.0
        var b = 0.0
        var t = SIMD2<Double>(0, 0)

        var scale: Double { hypot(a, b) }
        var turn: Double { atan2(b, a) }

        func apply(_ p: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2(a * p.x - b * p.y, b * p.x + a * p.y) + t
        }
    }

    /// Lines every frame up with the first, and measures the gain that matches its brightness. Each
    /// frame is fitted to the nearest frame before it that lined up. Done once; `progress` gets the
    /// fraction done.
    func align(progress: (Double) -> Void = { _ in }) throws {
        guard !isAligned else { return }
        let scale = min(1, Self.alignmentSide / max(nativeSize.width, nativeSize.height, 1))
        // From full-size Core Image coordinates to the aligner's (from the center, y down) and back.
        // The aligner numbers pixels by their corners; Core Image puts their centers on the half.
        let toAligner = CGAffineTransform(translationX: -nativeSize.width / 2, y: -nativeSize.height / 2)
            .concatenating(CGAffineTransform(scaleX: scale, y: -scale))
            .concatenating(CGAffineTransform(translationX: -0.5, y: -0.5))
        let fromAligner = toAligner.inverted()
        let longSide = Double(max(nativeSize.width, nativeSize.height) * scale)

        var referenceBrightness = 0.0
        var anchor: (features: PanoramaAligner.Features, detail: Detail, transform: CGAffineTransform)?
        for index in frames.indices {
            try Task.checkCancellation()
            let (image, brightness) = try autoreleasepool { try alignmentImage(index, scale: scale) }
            let features = PanoramaAligner.detectFeatures(image)
            let detail = Detail(image)
            if let previous = anchor {
                let matches = PanoramaAligner.match(features, previous.features)
                if let rough = Self.similarity(matches),
                   case let fit = Self.refined(rough, floating: detail, target: previous.detail),
                   abs(fit.scale - 1) <= Self.largestScaleChange, abs(fit.turn) <= Self.largestTurn,
                   simd_length(fit.t) <= Self.largestShift * longSide {
                    let step = CGAffineTransform(a: fit.a, b: fit.b, c: -fit.b, d: fit.a, tx: fit.t.x, ty: fit.t.y)
                    let transform = toAligner.concatenating(step).concatenating(fromAligner).concatenating(previous.transform)
                    frames[index].transform = transform
                    if brightness > 0 { frames[index].gain = min(max(referenceBrightness / brightness, 0.8), 1.25) }
                    anchor = (features, detail, transform)
                }
            } else {
                frames[index].transform = .identity
                referenceBrightness = brightness
                anchor = (features, detail, .identity)
            }
            progress(Double(index + 1) / Double(frames.count))
        }
        isAligned = true
    }

    /// A frame as the aligner sees it (gamma-encoded gray), and its mean brightness (linear).
    private func alignmentImage(_ index: Int, scale: CGFloat) throws -> (PanoramaAlignmentImage, Double) {
        let image = try decoded(index, scale: scale)
        let width = Int(image.extent.width.rounded(.down)), height = Int(image.extent.height.rounded(.down))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        context.render(
            image, toBitmap: &pixels, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBAf, colorSpace: HDRMerger.colorSpace
        )
        var gray = [Float](repeating: 0, count: width * height)
        var total = 0.0
        for i in 0..<(width * height) {
            let luminance = max(0, 0.2627 * pixels[i * 4] + 0.6780 * pixels[i * 4 + 1] + 0.0593 * pixels[i * 4 + 2])
            total += Double(luminance)
            gray[i] = pow(min(luminance, 1), 1 / 2.2)
        }
        let alignment = PanoramaAlignmentImage(width: width, height: height, pixels: gray, focalLength: nil)
        return (alignment, total / Double(max(width * height, 1)))
    }

    /// The similarity most matches agree with, taking their first points to their second (RANSAC on
    /// pairs of matches, then least squares over all that agree), or nil when too few do.
    static func similarity(_ matches: [PanoramaAligner.Match]) -> Similarity? {
        guard matches.count >= 12 else { return nil }
        var generator = PanoramaAligner.SplitMix(seed: UInt64(matches.count))
        func inliers(_ fit: Similarity) -> [PanoramaAligner.Match] {
            matches.filter { simd_distance(fit.apply($0.first), $0.second) < inlierTolerance }
        }
        var best: [PanoramaAligner.Match] = []
        var iterations = 0, limit = 500
        while iterations < limit {
            iterations += 1
            let i = Int(generator.next() % UInt64(matches.count)), j = Int(generator.next() % UInt64(matches.count))
            guard i != j, let fit = similarity(fitting: [matches[i], matches[j]]) else { continue }
            let agreeing = inliers(fit)
            if agreeing.count > best.count {
                best = agreeing
                // Enough tries to draw two inliers at least once with 99.9% confidence.
                let ratio = Double(agreeing.count) / Double(matches.count)
                let needed = log(0.001) / log(max(1e-9, 1 - ratio * ratio))
                limit = min(limit, max(30, Int(needed.rounded(.up))))
            }
        }
        guard var fit = similarity(fitting: best) else { return nil }
        for _ in 0..<2 {
            let agreeing = inliers(fit)
            guard let refit = similarity(fitting: agreeing) else { break }
            best = agreeing
            fit = refit
        }
        guard best.count >= 12, Double(best.count) >= 0.3 * Double(matches.count) else { return nil }
        return fit
    }

    /// The least-squares similarity through `matches` (two or more, not all at one point).
    static func similarity(fitting matches: [PanoramaAligner.Match]) -> Similarity? {
        guard matches.count >= 2 else { return nil }
        let count = Double(matches.count)
        let from = matches.reduce(SIMD2<Double>(0, 0)) { $0 + $1.first } / count
        let to = matches.reduce(SIMD2<Double>(0, 0)) { $0 + $1.second } / count
        var dot = 0.0, cross = 0.0, spread = 0.0
        for match in matches {
            let p = match.first - from, q = match.second - to
            dot += p.x * q.x + p.y * q.y
            cross += p.x * q.y - p.y * q.x
            spread += simd_length_squared(p)
        }
        // Points too close together say nothing about scale or turn.
        guard spread > 100 else { return nil }
        var fit = Similarity(a: dot / spread, b: cross / spread)
        fit.t = to - fit.apply(from)
        return fit
    }

    /// A frame's middle-sized detail (what's left between a light blur and a heavy one) and its slopes,
    /// for ``refined(_:floating:target:)``. The light blur evens out how sharp two frames are; the heavy
    /// one takes out differences in brightness. The detail is divided by how strong it is nearby, so a
    /// place that's sharp in one frame and soft in the next is as strong in both: detail that's weaker
    /// in one frame fits better a little smaller or larger, which would pass for a change of scale.
    struct Detail {
        let width: Int
        let height: Int
        let values: [Float]
        let slopeX: [Float]
        let slopeY: [Float]

        init(_ image: PanoramaAlignmentImage) {
            let width = image.width, height = image.height
            let fine = PanoramaAligner.gaussianBlur(image.pixels, width: width, height: height, sigma: 2)
            let coarse = PanoramaAligner.gaussianBlur(image.pixels, width: width, height: height, sigma: 8)
            var values = [Float](repeating: 0, count: width * height)
            vDSP_vsub(coarse, 1, fine, 1, &values, 1, vDSP_Length(width * height))
            var squares = [Float](repeating: 0, count: width * height)
            vDSP_vsq(values, 1, &squares, 1, vDSP_Length(width * height))
            let strength = PanoramaAligner.gaussianBlur(squares, width: width, height: height, sigma: 8)
            // Flat areas hold only noise: the floor keeps it from being brought up to full strength.
            for i in values.indices { values[i] /= sqrt(strength[i] + 1e-5) }
            var slopeX = [Float](repeating: 0, count: width * height), slopeY = slopeX
            values.withUnsafeBufferPointer { v in
                for y in 1..<max(1, height - 1) {
                    for x in 1..<max(1, width - 1) {
                        let i = y * width + x
                        slopeX[i] = (v[i + 1] - v[i - 1]) / 2
                        slopeY[i] = (v[i + width] - v[i - width]) / 2
                    }
                }
            }
            self.width = width
            self.height = height
            self.values = values
            self.slopeX = slopeX
            self.slopeY = slopeY
        }
    }

    /// `start` (from matched corners, good to a pixel or so) made exact: the similarity that best lays
    /// `floating`'s detail over `target`'s, found by Gauss–Newton on the difference between them at a
    /// grid of points. Where the two differ a lot (something sharp in one and not the other) counts for
    /// little. Returns `start` if this wanders off from it.
    static func refined(_ start: Similarity, floating: Detail, target: Detail) -> Similarity {
        let width = floating.width, height = floating.height
        guard width == target.width, height == target.height, width > 64, height > 64 else { return start }
        let centerX = Double(width) / 2, centerY = Double(height) / 2
        let spacing = 3, margin = 12
        var fit = start
        for _ in 0..<20 {
            var ata = [Double](repeating: 0, count: 16), atb = [Double](repeating: 0, count: 4)
            floating.values.withUnsafeBufferPointer { values in
                for row in stride(from: margin, to: height - margin, by: spacing) {
                    for column in stride(from: margin, to: width - margin, by: spacing) {
                        let x = Double(column) - centerX, y = Double(row) - centerY
                        let q = fit.apply(SIMD2(x, y))
                        let u = Float(q.x + centerX), v = Float(q.y + centerY)
                        guard u >= 1, v >= 1, u < Float(width - 2), v < Float(height - 2) else { continue }
                        let difference = Double(PanoramaAligner.bilinear(target.values, width: width, height: height, x: u, y: v) - values[row * width + column])
                        let gx = Double(PanoramaAligner.bilinear(target.slopeX, width: width, height: height, x: u, y: v))
                        let gy = Double(PanoramaAligner.bilinear(target.slopeY, width: width, height: height, x: u, y: v))
                        let weight = 1 / (1 + (difference / 0.5) * (difference / 0.5))
                        let slopes = [gx * x + gy * y, gy * x - gx * y, gx, gy]
                        for i in 0..<4 {
                            atb[i] -= weight * slopes[i] * difference
                            for j in 0..<4 { ata[i * 4 + j] += weight * slopes[i] * slopes[j] }
                        }
                    }
                }
            }
            guard let change = PanoramaAligner.solve(ata, atb, size: 4) else { break }
            fit.a += change[0]
            fit.b += change[1]
            fit.t += SIMD2(change[2], change[3])
            let reach = max(centerX, centerY)
            if max(abs(change[0]), abs(change[1])) * reach < 0.002, max(abs(change[2]), abs(change[3])) < 0.002 { break }
        }
        // The corners matched to within a few pixels; a fit further off than that followed something else.
        for corner in [SIMD2(-centerX, -centerY), SIMD2(centerX, -centerY), SIMD2(-centerX, centerY), SIMD2(centerX, centerY)] {
            let moved = simd_distance(fit.apply(corner), start.apply(corner))
            guard moved.isFinite, moved <= 4 else { return start }
        }
        return fit
    }

    // MARK: - Merging

    /// The frames that go into a stack: those that lined up, less `excluding`.
    private func included(excluding: Set<URL>) -> [Int] {
        frames.indices.filter { frames[$0].transform != nil && !excluding.contains(frames[$0].source.url) }
    }

    /// What every one of `indices`' frames shows, in the first frame's pixels at `scale` (whole pixels).
    func commonRect(_ indices: [Int], scale: CGFloat) -> CGRect {
        var left = 0.0, bottom = 0.0, right = Double(nativeSize.width), top = Double(nativeSize.height)
        for index in indices {
            guard let transform = frames[index].transform else { continue }
            func corner(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(transform) }
            let bl = corner(0, 0), br = corner(nativeSize.width, 0)
            let tl = corner(0, nativeSize.height), tr = corner(nativeSize.width, nativeSize.height)
            left = max(left, bl.x, tl.x)
            right = min(right, br.x, tr.x)
            bottom = max(bottom, bl.y, br.y)
            top = min(top, tl.y, tr.y)
        }
        let minX = (left * scale).rounded(.up), minY = (bottom * scale).rounded(.up)
        let maxX = (right * scale).rounded(.down), maxY = (top * scale).rounded(.down)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// Stacks the frames at `scale` (1 = full resolution), leaving out `excluding`. `region` (pixels at
    /// that scale, from the top left of the whole result) limits it to part of the picture, for zooming
    /// in; the depth map is then worked out from that part alone. `progress` gets the fraction done.
    /// `depthMap` gets the depth map as it stands after each frame is looked at, then once more
    /// smoothed. Throws `CancellationError` when the task is cancelled.
    func merge(
        options: FocusStackOptions, scale: CGFloat, excluding: Set<URL> = [], region: CGRect? = nil,
        progress: (Double) -> Void = { _ in }, depthMap: ((FocusDepthMap) -> Void)? = nil
    ) throws -> FocusStackResult {
        guard options.method == .depthMap else { throw FocusStackError.methodUnavailable(options.method.title) }
        try align()
        let indices = included(excluding: excluding)
        guard indices.count >= 2 else { throw FocusStackError.tooFewAligned }
        var canvas = commonRect(indices, scale: scale)
        if let region {
            // Core Image's origin is the bottom left.
            canvas = CGRect(x: canvas.minX + region.minX, y: canvas.maxY - region.maxY, width: region.width, height: region.height)
                .integral.intersection(canvas)
        }
        guard canvas.width >= 1, canvas.height >= 1 else { throw FocusStackError.tooFewAligned }
        let last = Float(indices.count - 1)

        // The depth map: the sharpest frame so far at every pixel, a frame at a time.
        var state = try materialized(Self.blank(canvas), canvas, format: .RGBAh, bytesPerPixel: 8)
        for (number, index) in indices.enumerated() {
            try Task.checkCancellation()
            state = try autoreleasepool {
                let contrast = contrast(of: try warped(index, scale: scale, canvas: canvas), radius: options.radius, scale: scale)
                let picked = FocusStackKernels.pick.apply(extent: canvas, arguments: [state, contrast, Float(number)]) ?? state
                return try materialized(picked, canvas, format: .RGBAh, bytesPerPixel: 8)
            }
            progress(0.5 * Double(number + 1) / Double(indices.count))
            if let depthMap { depthMap(depthGray(state, last: last)) }
        }
        let depth = try materialized(filledDepth(state, radius: options.radius, smoothing: options.smoothing, scale: scale), canvas, format: .Rh, bytesPerPixel: 2)
        let finalDepth = depthGray(depth, last: last)
        depthMap?(finalDepth)

        // The pixels: each frame added where the depth map chooses it.
        var sum = try materialized(Self.blank(canvas), canvas, format: .RGBAh, bytesPerPixel: 8)
        for (number, index) in indices.enumerated() {
            try Task.checkCancellation()
            sum = try autoreleasepool {
                let frame = try warped(index, scale: scale, canvas: canvas)
                let added = FocusStackKernels.accumulate.apply(extent: canvas, arguments: [sum, frame, depth, Float(number)]) ?? sum
                return try materialized(added, canvas, format: .RGBAh, bytesPerPixel: 8)
            }
            progress(0.5 + 0.45 * Double(number + 1) / Double(indices.count))
        }

        // Stored with the brightest value at 1; the DNG's BaselineExposure brings it back.
        let peak = peakValue(of: sum)
        var finished = sum
        if peak > 1 {
            let k = CGFloat(1 / peak)
            finished = finished.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            ])
        }
        finished = finished.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
        try Task.checkCancellation()
        let width = Int(canvas.width), height = Int(canvas.height)
        var rgba = try pixelData(finished, canvas, format: .RGBAh, bytesPerPixel: 8)
        var pixels = [Float16](repeating: 0, count: width * height * 3)
        rgba.withUnsafeMutableBytes { source in
            pixels.withUnsafeMutableBytes { destination in
                var from = vImage_Buffer(data: source.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 8)
                var to = vImage_Buffer(data: destination.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 6)
                vImageConvert_RGBA16UtoRGB16U(&from, &to, vImage_Flags(kvImageNoFlags))
            }
        }
        progress(1)
        let image = LinearDNGImage(width: width, height: height, pixels: pixels, headroom: LinearDNGWriter.headroom(peak: peak))
        return FocusStackResult(image: image, depthMap: finalDepth, mergedCount: indices.count)
    }

    /// A frame at `scale`, moved onto the first frame and as bright as it, over `canvas`.
    private func warped(_ index: Int, scale: CGFloat, canvas: CGRect) throws -> CIImage {
        let image = try decoded(index, scale: scale)
        let full = frames[index].transform ?? .identity
        // The same move in pixels at this scale, turned around: from the result back to the frame.
        let inverse = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale).concatenating(full)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale)).inverted()
        let arguments: [Any] = [
            image.clampedToExtent(),
            CIVector(x: inverse.a, y: inverse.c, z: inverse.tx), CIVector(x: inverse.b, y: inverse.d, z: inverse.ty),
            frames[index].gain,
        ]
        let result = FocusStackKernels.warp.apply(extent: canvas, roiCallback: { _, rect in
            rect.applying(inverse).insetBy(dx: -3, dy: -3)
        }, arguments: arguments)
        guard let result else { throw PhotoMergeError.unreadable(frames[index].source.name) }
        return result
    }

    /// How much detail each pixel of `frame` has, averaged over `radius` (full-size pixels), at two
    /// sizes. The fine one tells the sharpest frame from the nearly sharp. The coarse one is for edges
    /// that are a little soft in every frame: at the fine size the least soft of them scores next to
    /// nothing, no more than the rim a frame far out of focus leaves around the same edge (a halo), and
    /// at the coarse size it stands well clear of it.
    private func contrast(of frame: CIImage, radius: Int, scale: CGFloat) -> CIImage {
        let extent = frame.extent
        let luma = (FocusStackKernels.luma.apply(extent: extent, arguments: [frame]) ?? frame).clampedToExtent()
        func detail(blur: CGFloat, step: CGFloat) -> CIImage {
            let smooth = luma.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])
            return FocusStackKernels.contrast.apply(extent: extent, roiCallback: { _, rect in
                rect.insetBy(dx: -step - 1, dy: -step - 1)
            }, arguments: [smooth, step]) ?? frame
        }
        // Blurred a little first: moving a frame onto the first softens its finest grain, and the first
        // frame, which doesn't move, would otherwise win wherever there's nothing but grain.
        let fine = detail(blur: 1, step: max(1, (Self.fineStep * scale).rounded()))
        let coarse = detail(blur: max(1, Self.coarseStep * scale * 0.4), step: max(2, (Self.coarseStep * scale).rounded()))
        let both = FocusStackKernels.combine.apply(extent: extent, arguments: [fine, coarse, Self.coarseShare]) ?? fine
        return HDRMerger.filtered(both, "CIGaussianBlur", radius: max(0.5, CGFloat(radius) * scale))
    }

    /// How far apart (full-size pixels) the pixels compared for fine and for coarse detail are, and how
    /// much the coarse detail counts beside the fine (its band around an edge is that much wider).
    static let fineStep: CGFloat = 2
    static let coarseStep: CGFloat = 12
    static let coarseShare: Float = 1.0 / 8

    /// The depth map from its state. Each pixel's depth is weighed against the detail around it through
    /// a pyramid (see `focusFill`): crisp detail keeps its own depth and decides for the weaker detail
    /// and flat areas near it, and the nearest detail decides for flat areas however far away it is.
    /// Then the map is smoothed over `smoothing`.
    private func filledDepth(_ state: CIImage, radius: Int, smoothing: Int, scale: CGFloat) -> CIImage {
        let extent = state.extent
        var weighted = FocusStackKernels.weighted.apply(extent: extent, arguments: [state, noiseFloor(state)]) ?? state
        // Halos: weak detail within a few Radius of much stronger detail has no say (see `focusSuppress`).
        let strength = HDRMerger.filtered(weighted, "CIGaussianBlur", radius: max(1, Self.haloReach * CGFloat(radius) * scale))
        weighted = FocusStackKernels.suppress.apply(extent: extent, arguments: [weighted, strength]) ?? weighted
        var levels = [weighted]
        while let last = levels.last, max(last.extent.width, last.extent.height) > 8 {
            levels.append(PanoramaMerger.halved(last))
        }
        var filled = FocusStackKernels.depth.apply(extent: levels[levels.count - 1].extent, arguments: [levels[levels.count - 1]]) ?? state
        for index in (0..<(levels.count - 1)).reversed() {
            let level = levels[index]
            filled = FocusStackKernels.fill.apply(extent: level.extent, roiCallback: { sampler, rect in
                sampler == 0
                    ? CGRect(x: rect.minX / 2, y: rect.minY / 2, width: rect.width / 2, height: rect.height / 2).insetBy(dx: -1, dy: -1)
                    : rect
            }, arguments: [filled.clampedToExtent(), level, Self.fillReach]) ?? filled
        }
        guard smoothing > 0 else { return filled }
        let softened = FocusStackKernels.soften.apply(extent: extent, arguments: [filled]) ?? filled
        let blurred = HDRMerger.filtered(softened, "CIGaussianBlur", radius: max(0.5, Self.smoothingStep * CGFloat(smoothing) * scale))
        return FocusStackKernels.depth.apply(extent: extent, arguments: [blurred]) ?? filled
    }

    /// How far, in Radius, strong detail silences much weaker detail around it.
    static let haloReach: CGFloat = 6

    /// How much of a level's weight carries to the next finer one as the depth map is filled in.
    static let fillReach: Float = 0.6

    /// The contrast a pixel typically has out of focus: the median of the lowest contrast each pixel had
    /// in any frame (the state's blue), measured on a small copy.
    private func noiseFloor(_ state: CIImage) -> Float {
        let extent = state.extent
        let small = state.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: min(1, 256 / max(extent.width, extent.height)), kCIInputAspectRatioKey: 1,
            ])
        let width = max(1, Int(small.extent.width.rounded(.down))), height = max(1, Int(small.extent.height.rounded(.down)))
        var pixels = [Float](repeating: 0, count: width * height * 4)
        context.render(
            small, toBitmap: &pixels, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBAf, colorSpace: nil
        )
        let lowest = stride(from: 2, to: pixels.count, by: 4).map { pixels[$0] }.sorted()
        return max(lowest[lowest.count / 2], 1e-3)
    }

    /// How far (full-size pixels) each step of Smoothing spreads the depth map.
    static let smoothingStep: CGFloat = 6

    /// A depth map (frame numbers in red) as a gray picture, at most 2048 pixels on its long side.
    private func depthGray(_ depth: CIImage, last: Float) -> FocusDepthMap {
        let extent = depth.extent
        var gray = FocusStackKernels.depthGray.apply(extent: extent, arguments: [depth, last]) ?? depth
        gray = gray.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let shrink = min(1, 2048 / max(extent.width, extent.height))
        if shrink < 1 {
            gray = gray.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: shrink, kCIInputAspectRatioKey: 1])
        }
        let width = max(1, Int((extent.width * shrink).rounded(.down))), height = max(1, Int((extent.height * shrink).rounded(.down)))
        var pixels = [UInt8](repeating: 0, count: width * height)
        context.render(
            gray, toBitmap: &pixels, rowBytes: width, bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .R8, colorSpace: nil
        )
        return FocusDepthMap(width: width, height: height, pixels: pixels)
    }

    // MARK: - Rendering

    private static func blank(_ extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
    }

    /// `image` over `extent` as pixels, top row first, not color managed.
    private func pixelData(_ image: CIImage, _ extent: CGRect, format: CIFormat, bytesPerPixel: Int) throws -> Data {
        let rowBytes = Int(extent.width) * bytesPerPixel
        var data = Data(count: rowBytes * Int(extent.height))
        data.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: rowBytes, bounds: extent, format: format, colorSpace: nil)
        }
        return data
    }

    /// `image` drawn once and kept as pixels, so what's built on it doesn't draw every frame before it again.
    private func materialized(_ image: CIImage, _ extent: CGRect, format: CIFormat, bytesPerPixel: Int) throws -> CIImage {
        let data = try pixelData(image, extent, format: format, bytesPerPixel: bytesPerPixel)
        return CIImage(
            bitmapData: data, bytesPerRow: Int(extent.width) * bytesPerPixel, size: extent.size, format: format, colorSpace: nil
        ).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// The brightest value in any channel, measured at 1024 pixels across, where single hot pixels average out.
    private func peakValue(of image: CIImage) -> Float {
        let extent = image.extent
        let small = image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: min(1, 1024 / max(extent.width, extent.height)), kCIInputAspectRatioKey: 1,
        ])
        let capped = small.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 60_000, y: 60_000, z: 60_000, w: 1),
        ])
        let maximum = capped.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: small.extent)])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(maximum, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        let peak = max(pixel[0], pixel[1], pixel[2])
        return peak.isFinite ? peak : 1
    }
}

/// Writes a stack of photos that aren't RAW as a 16-bit TIFF, in the first photo's color space and with
/// its metadata, so it looks like the photos it was made from.
nonisolated enum FocusStackTIFFWriter {
    /// `image` (linear Rec. 2020, 0…1) as a TIFF at `url`, taking the color space and the metadata of the
    /// photo at `source`. Written to a temporary file and moved into place when it's complete.
    static func write(_ image: LinearDNGImage, like source: URL, to url: URL) throws {
        func failure() -> CocoaError { CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path(percentEncoded: false)]) }
        let file = CGImageSourceCreateWithURL(source as CFURL, nil)
        var space = file.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }?.colorSpace
        if space?.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB) }

        let data = image.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        guard let space, let provider = CGDataProvider(data: data as CFData),
              let linear = CGImage(
                  width: image.width, height: image.height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: image.width * 6,
                  space: HDRMerger.colorSpace, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { throw failure() }
        let context = CIContext(options: [.workingColorSpace: HDRMerger.colorSpace, .cacheIntermediates: false])
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let encoded = context.createCGImage(CIImage(cgImage: linear), from: extent, format: .RGBX16, colorSpace: space) else {
            throw failure()
        }

        // The first photo's metadata (camera, lens, exposure, where it was taken), less what's about its own pixels.
        var properties = file.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth, kCGImagePropertyColorModel,
                    kCGImagePropertyProfileName, kCGImagePropertyJFIFDictionary, kCGImagePropertyPNGDictionary] {
            properties[key] = nil
        }
        properties[kCGImagePropertyOrientation] = 1
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation] = 1
        tiff[kCGImagePropertyTIFFSoftware] = "PixelLoupe"
        tiff[kCGImagePropertyTIFFCompression] = 5  // LZW
        properties[kCGImagePropertyTIFFDictionary] = tiff
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = image.width
            exif[kCGImagePropertyExifPixelYDimension] = image.height
            properties[kCGImagePropertyExifDictionary] = exif
        }

        let temporary = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
                throw failure()
            }
            CGImageDestinationAddImage(destination, encoded, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw failure() }
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}

/// The Core Image kernels in FocusStackKernels.ci.metal.
nonisolated enum FocusStackKernels {
    static let warp = load(name: "focusWarp") { try CIKernel(functionName: $0, fromMetalLibraryData: $1) }
    static let contrast = load(name: "focusContrast") { try CIKernel(functionName: $0, fromMetalLibraryData: $1) }
    static let luma = color("focusLuma")
    static let pick = color("focusPick")
    static let combine = color("focusCombine")
    static let weighted = color("focusWeighted")
    static let suppress = color("focusSuppress")
    static let fill = load(name: "focusFill") { try CIKernel(functionName: $0, fromMetalLibraryData: $1) }
    static let soften = color("focusSoften")
    static let depth = color("focusDepth")
    static let accumulate = color("focusAccumulate")
    static let depthGray = color("focusDepthGray")

    private static let library: Data? = Bundle.main.url(forResource: "default", withExtension: "metallib")
        .flatMap { try? Data(contentsOf: $0) }

    private static func color(_ name: String) -> CIColorKernel {
        load(name: name) { try CIColorKernel(functionName: $0, fromMetalLibraryData: $1) }
    }

    private static func load<Kernel>(name: String, _ make: (String, Data) throws -> Kernel) -> Kernel {
        guard let library, let kernel = try? make(name, library) else {
            fatalError("The Core Image kernel \(name) is missing from the app's Metal library.")
        }
        return kernel
    }
}
