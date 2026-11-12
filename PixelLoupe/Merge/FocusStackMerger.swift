import Accelerate
import CoreImage
import Foundation
import ImageIO
import Metal
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

    var errorDescription: String? {
        switch self {
        case .mixedKinds: "A focus stack can’t mix RAW photos with other kinds of photo."
        case .tooFewAligned: "Fewer than two of the photos line up with each other."
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
    /// Which frame is sharpest where, after smoothing: what the Depth Map method chooses the frames by.
    /// Weighted Average doesn't use it, but has it all the same (it says which frames matter where).
    /// Pyramid has it only in a preview (at ``FocusStackMerger/keptScale``); otherwise nil.
    var depthMap: FocusDepthMap?
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
/// averaged over Radius and over a wider area, so that beside an edge the frame where the edge is sharp
/// wins and not one far out of focus: a halo), and the frame where it's highest is that pixel's depth.
/// Flat areas, where no frame stands out, take their depth from the detail around them. The depth map is smoothed
/// (Smoothing), and each pixel is taken from the frame its depth names, or from the two frames a depth
/// falls between.
///
/// Weighted Average: every pixel is the average of all the frames, each weighted by its contrast there
/// (the same measure) against the sharpest frame's, raised to a power so the sharp frames count for
/// nearly all of it. Smoothing blurs each frame's weights. No frame is chosen outright, so there are no
/// lines where one frame gives way to another and colors stay as they were, but a deep stack comes out
/// a little softer than with Depth Map, and edges in front of something far behind keep a faint halo.
///
/// Pyramid: every frame is split into bands of detail, fine to coarse (a Laplacian pyramid, on
/// gamma-encoded pixels), and at every pixel of every band the result takes the frame whose detail is
/// strongest there; what's left below the coarsest band is the frames' average. So detail at different
/// depths that overlaps (hairs, crossing branches) all comes through, where the other methods must
/// choose one depth per pixel. The price is more noise and contrast, and glare around bright edges.
/// It has no Radius or Smoothing.
///
/// RAW frames are decoded linearly with the first frame's white balance, as the other merges do; the
/// photos' Develop settings play no part. Frames are stacked one at a time, twice (once to find the depth
/// map, once to take the pixels), so a deep stack needs no more memory than a short one. The pixel work
/// runs on the GPU, in Core Image kernels (FocusStackKernels.ci.metal), and what's built up from frame
/// to frame stays there, in textures.
///
/// The rest is spread over the cores: lining up reads and fits a core's worth of frames at a time, and
/// while one frame is being stacked the next ones are already being decoded (photos that aren't RAW).
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
    private let context: CIContext
    /// The GPU the stacking runs on, when what's built up frame by frame can stay on it (see
    /// ``materialized(_:_:format:bytesPerPixel:)``); nil keeps it in main memory.
    private let device: MTLDevice?
    /// Whether what's built up frame by frame stays on the GPU. Off, it's read back to main memory and
    /// sent up again for every frame, which gives the same picture several times slower: for tests, and
    /// for a Mac whose GPU can't hold it.
    var staysOnGPU = true

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
                // From the file's header: opening it as an image reads far more of it, for every frame.
                guard let size = Self.orientedSize(of: source.url) else { throw PhotoMergeError.unreadable(source.name) }
                extent = CGRect(origin: .zero, size: size)
            }
            guard size == nil || size == extent.size else { throw PhotoMergeError.differentSizes }
            size = extent.size
        }
        nativeSize = size ?? .zero
        frames = ordered.map { Frame(source: $0) }
        let options: [CIContextOption: Any] = [
            .workingColorSpace: HDRMerger.colorSpace, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false,
        ]
        device = MTLCreateSystemDefaultDevice()
        context = device.map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }

    /// A photo's size in pixels as it's shown (turned as its orientation says), without decoding it.
    static func orientedSize(of url: URL) -> CGSize? {
        guard let file = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        // Orientations 5 to 8 lie on their side.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
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

    /// The scale whose decoded frames are kept in memory (and the depth map's state at it), so a preview
    /// redrawn with other settings doesn't read every photo again; nil keeps nothing. For previews only:
    /// at full size the frames are far too big to keep.
    var keptScale: CGFloat? {
        didSet {
            guard keptScale != oldValue else { return }
            keptFrames = [:]
            keptState = nil
        }
    }

    private var keptFrames: [Int: CIImage] = [:]
    private var keptState: (key: StateKey, state: CIImage)?

    /// What the depth map's state depends on.
    private struct StateKey: Equatable {
        var scale: CGFloat
        var radius: Int
        var indices: [Int]
        var canvas: CGRect
    }

    /// A frame at `scale`, scene-linear, with its origin at zero and `scale` times the full size (kept
    /// as pixels when that's the scale being kept).
    private func decoded(_ index: Int, scale: CGFloat) throws -> CIImage {
        guard scale == keptScale else { return try read(index, scale: scale) }
        if let kept = keptFrames[index] { return kept }
        let image = try read(index, scale: scale)
        let extent = CGRect(x: 0, y: 0, width: image.extent.width.rounded(.down), height: image.extent.height.rounded(.down))
        let kept = try materialized(image, extent, format: .RGBAh, bytesPerPixel: 8)
        keptFrames[index] = kept
        return kept
    }

    /// A frame from its file, or from the frames being read ahead when it's one of those.
    private func read(_ index: Int, scale: CGFloat) throws -> CIImage {
        if let ahead, ahead.scale == scale, let image = try ahead.take(index) { return image }
        return try decodedFromFile(index, scale: scale)
    }

    /// The frames being read ahead of the stacking, if any.
    private var ahead: FrameLookahead?

    /// Starts reading `indices`' frames ahead, in the order they'll be asked for: decoding a photo takes
    /// about as long as stacking it, so the next ones are decoded on other cores meanwhile. Small copies
    /// (a preview's) are quick to hold, and a core's worth are read at once; full-size frames are big,
    /// and decode no faster side by side, so only the next two are. RAW frames aren't read ahead:
    /// Core Image decodes them as it draws them.
    private func readAhead(_ indices: [Int], scale: CGFloat) {
        ahead?.finish()
        ahead = nil
        let waiting = scale == keptScale ? indices.filter { keptFrames[$0] == nil } : indices
        guard !isRaw, waiting.count > 1 else { return }
        let depth = scale < 1 ? max(2, ProcessInfo.processInfo.activeProcessorCount) : 2
        // The lookahead is stopped (and waited for) before the merger changes or goes away.
        nonisolated(unsafe) let merger = self
        ahead = FrameLookahead(order: waiting, scale: scale, depth: depth) { index in
            try merger.decodedFromFile(index, scale: scale)
        }
    }

    /// Stops reading ahead (the frames not yet asked for are dropped).
    private func stopReadingAhead() {
        ahead?.finish()
        ahead = nil
    }

    /// Safe to call for several frames at once: it changes nothing.
    private func decodedFromFile(_ index: Int, scale: CGFloat) throws -> CIImage {
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
            // Decoded here and now, not when Core Image first draws it: this may be running ahead of the
            // stacking, on another core (see ``FrameLookahead``).
            if let file = CGImageSourceCreateWithURL(source.url as CFURL, nil),
               let whole = CGImageSourceCreateImageAtIndex(file, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                let properties = CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any]
                let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init) ?? .up
                image = CIImage(cgImage: whole).oriented(orientation)
            }
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
    ///
    /// Reading a frame and finding its corners depends on no other frame, and fitting it to the one
    /// before depends only on those two, so both are done for several frames at a time, on every core.
    /// Only putting the fits together, one after another, has to go in order. The frames are taken a
    /// batch at a time: what's worked out for a frame (its corners and detail) is too big to hold for
    /// every frame of a deep stack at once.
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

        // Two steps a frame: read, and fitted.
        try withoutActuallyEscaping(progress) { progress in
            let steps = AlignmentSteps(total: 2 * frames.count, report: progress)
            try lineUp(scale: scale, toAligner: toAligner, fromAligner: fromAligner, longSide: longSide, steps: steps)
        }
        isAligned = true
    }

    private func lineUp(
        scale: CGFloat, toAligner: CGAffineTransform, fromAligner: CGAffineTransform, longSide: Double, steps: AlignmentSteps
    ) throws {
        let count = frames.count
        // Only read from the other cores, and only until each batch is done.
        nonisolated(unsafe) let merger = self
        var referenceBrightness = 0.0
        var anchor: (index: Int, frame: AlignmentFrame, transform: CGAffineTransform)?
        var before: AlignmentFrame?
        var start = 0
        while start < count {
            try Task.checkCancellation()
            let batch = start..<min(start + Self.alignmentBatch, count)
            let read = Slots<Result<AlignmentFrame, any Error>>(batch.count)
            DispatchQueue.concurrentPerform(iterations: batch.count) { offset in
                read.set(offset, Result { try autoreleasepool { try merger.alignmentFrame(batch.lowerBound + offset, scale: scale) } })
                steps.step()
            }
            let ready = try read.values.map { result -> AlignmentFrame in
                guard let result else { throw CancellationError() }
                return try result.get()
            }
            try Task.checkCancellation()

            // Each frame against the one just before it, which is nearly always the one it's fitted to.
            let last = before
            let fitted = Slots<Similarity>(batch.count)
            DispatchQueue.concurrentPerform(iterations: batch.count) { offset in
                if let previous = offset > 0 ? ready[offset - 1] : last,
                   let fit = Self.fit(ready[offset], to: previous, longSide: longSide) {
                    fitted.set(offset, fit)
                }
                steps.step()
            }
            let fits = fitted.values

            for (offset, frame) in ready.enumerated() {
                let index = batch.lowerBound + offset
                guard let previous = anchor else {
                    frames[index].transform = .identity
                    referenceBrightness = frame.brightness
                    anchor = (index, frame, .identity)
                    continue
                }
                // The frame before didn't line up: fitted to the last one that did.
                let fit = previous.index == index - 1 ? fits[offset] : Self.fit(frame, to: previous.frame, longSide: longSide)
                guard let fit else { continue }
                let step = CGAffineTransform(a: fit.a, b: fit.b, c: -fit.b, d: fit.a, tx: fit.t.x, ty: fit.t.y)
                let transform = toAligner.concatenating(step).concatenating(fromAligner).concatenating(previous.transform)
                frames[index].transform = transform
                if frame.brightness > 0 { frames[index].gain = min(max(referenceBrightness / frame.brightness, 0.8), 1.25) }
                anchor = (index, frame, transform)
            }
            before = ready.last
            start = batch.upperBound
        }
    }

    /// How many frames are read and fitted at a time: one for each core.
    static let alignmentBatch = max(2, ProcessInfo.processInfo.activeProcessorCount)

    /// What lining a frame up needs of it.
    private struct AlignmentFrame: @unchecked Sendable {
        let features: PanoramaAligner.Features
        let detail: Detail
        /// Its mean brightness (linear).
        let brightness: Double
    }

    private func alignmentFrame(_ index: Int, scale: CGFloat) throws -> AlignmentFrame {
        let (image, brightness) = try alignmentImage(index, scale: scale)
        return AlignmentFrame(features: PanoramaAligner.detectFeatures(image), detail: Detail(image), brightness: brightness)
    }

    /// The similarity that lays `frame` over `previous`, or nil when they don't line up: too few corners
    /// agree, or the fit is more of a change than focusing makes.
    private static func fit(_ frame: AlignmentFrame, to previous: AlignmentFrame, longSide: Double) -> Similarity? {
        let matches = PanoramaAligner.match(frame.features, previous.features)
        guard let rough = similarity(matches) else { return nil }
        let fit = refined(rough, floating: frame.detail, target: previous.detail)
        guard abs(fit.scale - 1) <= largestScaleChange, abs(fit.turn) <= largestTurn,
              simd_length(fit.t) <= largestShift * longSide else { return nil }
        return fit
    }

    /// A frame as the aligner sees it (gamma-encoded gray), and its mean brightness (linear). Safe to
    /// call for several frames at once: it keeps nothing.
    private func alignmentImage(_ index: Int, scale: CGFloat) throws -> (PanoramaAlignmentImage, Double) {
        let image = try decodedFromFile(index, scale: scale)
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

    /// ``PanoramaAligner/bilinear(_:width:height:x:y:)`` on a pointer to the pixels.
    private static func bilinear(_ pixels: UnsafeBufferPointer<Float>, width: Int, height: Int, x: Float, y: Float) -> Float {
        let fx = min(max(x, 0), Float(width - 1) - 0.001), fy = min(max(y, 0), Float(height - 1) - 0.001)
        let x0 = Int(fx), y0 = Int(fy), tx = fx - Float(x0), ty = fy - Float(y0)
        let i = y0 * width + x0
        let top = pixels[i] * (1 - tx) + pixels[i + 1] * tx
        let bottom = pixels[i + width] * (1 - tx) + pixels[i + width + 1] * tx
        return top * (1 - ty) + bottom * ty
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
            var slopes = [Double](repeating: 0, count: 4)
            // Written plainly, for a build that isn't optimized, where this is fitted for several frames
            // at once. Through pointers, target's too: the frame it belongs to is being fitted to its own
            // predecessor on another core, and such a build counts a reference to the array for every
            // point read, the two cores taking turns at the count. And with `while`, not `stride`, whose
            // every step there looks its types up in a table the cores have to queue for: that alone
            // made fitting fourteen frames side by side slower than one after another.
            floating.values.withUnsafeBufferPointer { values in
              target.values.withUnsafeBufferPointer { targetValues in
              target.slopeX.withUnsafeBufferPointer { targetSlopeX in
              target.slopeY.withUnsafeBufferPointer { targetSlopeY in
                var row = margin
                while row < height - margin {
                    defer { row += spacing }
                    var column = margin
                    while column < width - margin {
                        defer { column += spacing }
                        let x = Double(column) - centerX, y = Double(row) - centerY
                        let q = fit.apply(SIMD2(x, y))
                        let u = Float(q.x + centerX), v = Float(q.y + centerY)
                        guard u >= 1, v >= 1, u < Float(width - 2), v < Float(height - 2) else { continue }
                        let difference = Double(Self.bilinear(targetValues, width: width, height: height, x: u, y: v) - values[row * width + column])
                        let gx = Double(Self.bilinear(targetSlopeX, width: width, height: height, x: u, y: v))
                        let gy = Double(Self.bilinear(targetSlopeY, width: width, height: height, x: u, y: v))
                        let weight = 1 / (1 + (difference / 0.5) * (difference / 0.5))
                        slopes[0] = gx * x + gy * y
                        slopes[1] = gy * x - gx * y
                        slopes[2] = gx
                        slopes[3] = gy
                        var i = 0
                        while i < 4 {
                            atb[i] -= weight * slopes[i] * difference
                            var j = 0
                            while j < 4 {
                                ata[i * 4 + j] += weight * slopes[i] * slopes[j]
                                j += 1
                            }
                            i += 1
                        }
                    }
                }
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
    /// smoothed (the Depth Map method only). Throws `CancellationError` when the task is cancelled.
    func merge(
        options: FocusStackOptions, scale: CGFloat, excluding: Set<URL> = [], region: CGRect? = nil,
        progress: (Double) -> Void = { _ in }, depthMap: ((FocusDepthMap) -> Void)? = nil
    ) throws -> FocusStackResult {
        try stack(options: options, scale: scale, excluding: excluding, region: region, progress: progress, depthMap: depthMap, weights: nil)
    }

    /// Weighted Average's weights: for each stacked frame, its share of every pixel of the result (top
    /// row first; a pixel's shares add up to 1). For tests and for looking into a result.
    func weightMaps(
        options: FocusStackOptions, scale: CGFloat, excluding: Set<URL> = []
    ) throws -> (width: Int, height: Int, frames: [[Float]]) {
        var maps: [[Float]] = []
        var size = (width: 0, height: 0)
        var options = options
        options.method = .weightedAverage
        _ = try stack(options: options, scale: scale, excluding: excluding, region: nil, progress: { _ in }, depthMap: nil) { weight in
            let extent = weight.extent
            size = (Int(extent.width), Int(extent.height))
            var pixels = [Float](repeating: 0, count: size.width * size.height)
            self.context.render(weight, toBitmap: &pixels, rowBytes: size.width * 4, bounds: extent, format: .Rf, colorSpace: nil)
            maps.append(pixels)
        }
        for i in 0..<(size.width * size.height) {
            let total = maps.reduce(Float(0)) { $0 + $1[i] }
            guard total > 0 else { continue }
            for frame in maps.indices { maps[frame][i] /= total }
        }
        return (size.width, size.height, maps)
    }

    private func stack(
        options: FocusStackOptions, scale: CGFloat, excluding: Set<URL>, region: CGRect?,
        progress: (Double) -> Void, depthMap: ((FocusDepthMap) -> Void)?, weights: ((CIImage) -> Void)?
    ) throws -> FocusStackResult {
        // Only Depth Map has a depth map to show.
        let depthMap = options.method == .depthMap ? depthMap : nil
        try align()
        defer { stopReadingAhead() }
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

        // Pyramid has no use for a depth map, except in a preview: the 100% view reads only the frames
        // the map names around the part it shows.
        let wantsDepth = options.method != .pyramid || (scale == keptScale && region == nil)
        let depthShare = !wantsDepth ? 0 : options.method == .pyramid ? 0.3 : 0.5
        var state: CIImage?
        var depth: CIImage?
        var finalDepth: FocusDepthMap?
        if wantsDepth {
            // The depth map: the sharpest frame so far at every pixel, a frame at a time.
            let key = StateKey(scale: scale, radius: options.radius, indices: indices, canvas: canvas)
            var current: CIImage
            if let kept = keptState, kept.key == key {
                current = kept.state
                progress(depthShare)
            } else {
                current = try materialized(Self.blank(canvas), canvas, format: .RGBAh, bytesPerPixel: 8)
                readAhead(indices, scale: scale)
                for (number, index) in indices.enumerated() {
                    try Task.checkCancellation()
                    current = try autoreleasepool {
                        let contrast = try contrast(of: try warped(index, scale: scale, canvas: canvas), radius: options.radius, scale: scale)
                        let picked = FocusStackKernels.pick.apply(extent: canvas, arguments: [current, contrast, Float(number)]) ?? current
                        return try materialized(picked, canvas, format: .RGBAh, bytesPerPixel: 8)
                    }
                    progress(depthShare * Double(number + 1) / Double(indices.count))
                    if let depthMap { depthMap(depthGray(current, last: last)) }
                }
                if scale == keptScale, region == nil { keptState = (key, current) }
            }
            let filled = try materialized(filledDepth(current, smoothing: options.smoothing, scale: scale), canvas, format: .Rh, bytesPerPixel: 2)
            state = current
            depth = filled
            finalDepth = depthGray(filled, last: last)
            if let finalDepth { depthMap?(finalDepth) }
        }
        func pixelProgress(_ number: Int) {
            progress(depthShare + (0.95 - depthShare) * Double(number + 1) / Double(indices.count))
        }

        var sum = try materialized(Self.blank(canvas), canvas, format: .RGBAh, bytesPerPixel: 8)
        if options.method == .pyramid {
            sum = try pyramid(indices, scale: scale, canvas: canvas, progress: pixelProgress)
        } else if options.method == .weightedAverage, let state {
            // The pixels: every frame added by its weight, and the weights added up beside them.
            let floor = noiseFloor(state) * Self.shareFloor
            let spread = options.smoothing > 0 ? max(0.5, Self.smoothingStep * CGFloat(options.smoothing) * scale) : 0
            var total = try materialized(Self.blank(canvas), canvas, format: .Rf, bytesPerPixel: 4)
            readAhead(indices, scale: scale)
            for (number, index) in indices.enumerated() {
                try Task.checkCancellation()
                (sum, total) = try autoreleasepool {
                    // Kept as pixels: its contrast and the sum both read it.
                    let frame = try materialized(try warped(index, scale: scale, canvas: canvas), canvas, format: .RGBAh, bytesPerPixel: 8)
                    let contrast = try contrast(of: frame, radius: options.radius, scale: scale)
                    var weight = FocusStackKernels.share.apply(extent: canvas, arguments: [state, contrast, Self.sharePower, floor]) ?? contrast
                    if spread > 0 { weight = HDRMerger.filtered(weight, "CIGaussianBlur", radius: spread) }
                    // Kept as pixels: both sums read it.
                    weight = try materialized(weight, canvas, format: .Rh, bytesPerPixel: 2)
                    weights?(weight)
                    let added = FocusStackKernels.blend.apply(extent: canvas, arguments: [sum, frame, weight]) ?? sum
                    let counted = FocusStackKernels.total.apply(extent: canvas, arguments: [total, weight]) ?? total
                    return (
                        try materialized(added, canvas, format: .RGBAh, bytesPerPixel: 8),
                        try materialized(counted, canvas, format: .Rf, bytesPerPixel: 4)
                    )
                }
                pixelProgress(number)
            }
            let resolved = FocusStackKernels.resolve.apply(extent: canvas, arguments: [sum, total]) ?? sum
            sum = try materialized(resolved, canvas, format: .RGBAh, bytesPerPixel: 8)
        } else if let depth {
            // The pixels: each frame added where the depth map chooses it.
            readAhead(indices, scale: scale)
            for (number, index) in indices.enumerated() {
                try Task.checkCancellation()
                sum = try autoreleasepool {
                    let frame = try warped(index, scale: scale, canvas: canvas)
                    let added = FocusStackKernels.accumulate.apply(extent: canvas, arguments: [sum, frame, depth, Float(number)]) ?? sum
                    return try materialized(added, canvas, format: .RGBAh, bytesPerPixel: 8)
                }
                pixelProgress(number)
            }
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

    /// The Pyramid method's stack of `indices`' frames over `canvas`. The best band so far at every level
    /// is kept, with how strong it is, and each frame is folded into it in turn.
    private func pyramid(_ indices: [Int], scale: CGFloat, canvas: CGRect, progress: (Int) -> Void) throws -> CIImage {
        // Worked from the origin, so every level is half the one before it.
        let toOrigin = CGAffineTransform(translationX: -canvas.minX, y: -canvas.minY)
        var extents = [CGRect(origin: .zero, size: canvas.size)]
        // Down to the same coarseness whatever the size: the stack looks the same in the preview.
        while extents.count <= 12, let last = extents.last, max(last.width, last.height) > Self.pyramidBase {
            extents.append(CGRect(x: 0, y: 0, width: (last.width / 2).rounded(.up), height: (last.height / 2).rounded(.up)))
        }
        let levels = extents.count - 1
        let up: CIKernelROICallback = { index, rect in
            index == 0
                ? CGRect(x: rect.minX / 2, y: rect.minY / 2, width: rect.width / 2, height: rect.height / 2).insetBy(dx: -1, dy: -1)
                : rect
        }
        var bands = try extents.dropLast().map { try materialized(Self.blank($0), $0, format: .RGBAh, bytesPerPixel: 8) }
        var strengths = try extents.dropLast().map { try materialized(Self.blank($0), $0, format: .Rh, bytesPerPixel: 2) }
        var base = try materialized(Self.blank(extents[levels]), extents[levels], format: .RGBAf, bytesPerPixel: 16)
        // The darkest and brightest each pixel is in any frame (red, green).
        var range: CIImage?
        readAhead(indices, scale: scale)
        for (number, index) in indices.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let frame = try warped(index, scale: scale, canvas: canvas).transformed(by: toOrigin)
                let encoded = FocusStackKernels.encode.apply(extent: extents[0], arguments: [frame]) ?? frame
                var level = try materialized(encoded, extents[0], format: .RGBAh, bytesPerPixel: 8)
                let widened = FocusStackKernels.range.apply(extent: extents[0], arguments: [range ?? level, level, range == nil ? 1 : 0]) ?? level
                range = try materialized(widened, extents[0], format: .RGBAh, bytesPerPixel: 8)
                for l in 0..<levels {
                    let extent = extents[l]
                    let coarser = try materialized(PanoramaMerger.halved(level).cropped(to: extents[l + 1]), extents[l + 1], format: .RGBAh, bytesPerPixel: 8)
                    let detail = FocusStackKernels.band.apply(extent: extent, roiCallback: up, arguments: [coarser.clampedToExtent(), level]) ?? level
                    let band = try materialized(detail, extent, format: .RGBAh, bytesPerPixel: 8)
                    // A band's strength is taken over a few pixels, so neighbors come from the same frame
                    // and a frame isn't chosen for one pixel of noise.
                    let size = FocusStackKernels.strength.apply(extent: extent, arguments: [band]) ?? band
                    let strength = try materialized(HDRMerger.filtered(size, "CIGaussianBlur", radius: Self.pyramidSpread), extent, format: .Rh, bytesPerPixel: 2)
                    let stronger = FocusStackKernels.stronger.apply(extent: extent, arguments: [bands[l], band, strengths[l], strength]) ?? band
                    let most = FocusStackKernels.most.apply(extent: extent, arguments: [strengths[l], strength]) ?? strength
                    bands[l] = try materialized(stronger, extent, format: .RGBAh, bytesPerPixel: 8)
                    strengths[l] = try materialized(most, extent, format: .Rh, bytesPerPixel: 2)
                    level = coarser
                }
                let added = FocusStackKernels.add.apply(extent: extents[levels], arguments: [base, level]) ?? base
                base = try materialized(added, extents[levels], format: .RGBAf, bytesPerPixel: 16)
            }
            progress(number)
        }
        // Collapsed: the frames' average at the coarsest level, and each band added on the way up.
        var result = FocusStackKernels.mean.apply(extent: extents[levels], arguments: [base, Float(indices.count)]) ?? base
        for l in stride(from: levels - 1, through: 0, by: -1) {
            let collapsed = FocusStackKernels.collapse.apply(extent: extents[l], roiCallback: up, arguments: [result.clampedToExtent(), bands[l]]) ?? result
            result = try materialized(collapsed, extents[l], format: .RGBAh, bytesPerPixel: 8)
        }
        // Bands taken from different frames don't always fit together: beside a strong edge they can add
        // up to darker or brighter than the pixel is in any frame. Brought back inside what the frames have.
        if let range { result = FocusStackKernels.within.apply(extent: extents[0], arguments: [result, range]) ?? result }
        let decoded = FocusStackKernels.decode.apply(extent: extents[0], arguments: [result]) ?? result
        return try materialized(decoded.transformed(by: toOrigin.inverted()), canvas, format: .RGBAh, bytesPerPixel: 8)
    }

    /// The long side of the Pyramid method's coarsest level, below which the frames are just averaged.
    static let pyramidBase: CGFloat = 24
    /// How far (pixels of its level) a band's strength is spread before the frames are compared.
    static let pyramidSpread: CGFloat = 1.5

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

    /// How much detail there is at and around each pixel of `frame`, measured at two sizes and averaged
    /// over `radius` (full-size pixels) and a wider area. The fine one tells the sharpest frame from the nearly sharp. The coarse one is for edges
    /// that are a little soft in every frame: at the fine size the least soft of them scores next to
    /// nothing, no more than the rim a frame far out of focus leaves around the same edge (a halo), and
    /// at the coarse size it stands well clear of it.
    ///
    /// The brightness and the combined detail are each drawn once and kept (see
    /// ``materialized(_:_:format:bytesPerPixel:)``): both are read twice by what follows, and left as a
    /// recipe Core Image works each out again for every reader, the frame's warp and blurs included.
    /// That made this nearly three times slower at full size.
    private func contrast(of frame: CIImage, radius: Int, scale: CGFloat) throws -> CIImage {
        let extent = frame.extent
        let luma = try materialized(FocusStackKernels.luma.apply(extent: extent, arguments: [frame]) ?? frame, extent, format: .Rf, bytesPerPixel: 4)
            .clampedToExtent()
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
        let both = try materialized(
            FocusStackKernels.combine.apply(extent: extent, arguments: [fine, coarse, Self.coarseShare]) ?? fine, extent, format: .Rf, bytesPerPixel: 4
        ).clampedToExtent()
        // Averaged over Radius, and over several times Radius as well. Beside an edge, the frames far out
        // of focus are the only ones with any contrast of their own (the edge's blur spilling over), and
        // on the near average alone they'd be chosen there: a halo. The wide average takes in the edge
        // itself, which has far more contrast in the frame where it's sharp than its blur has in any other.
        let near = both.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.5, CGFloat(radius) * scale)])
        let wide = both.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(1, Self.wideReach * CGFloat(radius) * scale)])
        return (FocusStackKernels.combine.apply(extent: extent, arguments: [near, wide, 1]) ?? near).cropped(to: extent)
    }

    /// How many times Radius the wide average of contrast reaches.
    static let wideReach: CGFloat = 6

    /// How far apart (full-size pixels) the pixels compared for fine and for coarse detail are, and how
    /// much the coarse detail counts beside the fine (its band around an edge is that much wider).
    static let fineStep: CGFloat = 2
    static let coarseStep: CGFloat = 12
    static let coarseShare: Float = 1.0 / 8

    /// The depth map from its state. Each pixel's depth is weighed against the detail around it through
    /// a pyramid (see `focusFill`): crisp detail keeps its own depth and decides for the weaker detail
    /// and flat areas near it, and the nearest detail decides for flat areas however far away it is.
    /// Then the map is smoothed over `smoothing`.
    private func filledDepth(_ state: CIImage, smoothing: Int, scale: CGFloat) -> CIImage {
        let extent = state.extent
        var levels = [FocusStackKernels.weighted.apply(extent: extent, arguments: [state, noiseFloor(state)]) ?? state]
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

    /// Weighted Average: the power a frame's contrast, as a fraction of the sharpest frame's, is raised
    /// to for its weight. Higher is crisper and closer to choosing one frame outright; much lower, and a
    /// deep stack's many nearly sharp frames soften faint texture and leave a haze around bright edges.
    static let sharePower: Float = 32
    /// How much of the noise floor is added to both contrasts before they're compared, so frames with
    /// nothing but noise weigh alike. More than this, and faint texture is averaged away with the noise.
    static let shareFloor: Float = 0.1

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
    ///
    /// Drawn into a texture where that's possible, so the pixels never leave the GPU. Read back to main
    /// memory and sent up again, as it was first done, a full-size frame's worth of pixels crosses twice
    /// for every frame stacked, which took most of the time of a full-size stack.
    private func materialized(_ image: CIImage, _ extent: CGRect, format: CIFormat, bytesPerPixel: Int) throws -> CIImage {
        if staysOnGPU, let kept = try texture(of: image, extent, format: format) { return kept }
        let data = try pixelData(image, extent, format: format, bytesPerPixel: bytesPerPixel)
        return CIImage(
            bitmapData: data, bytesPerRow: Int(extent.width) * bytesPerPixel, size: extent.size, format: format, colorSpace: nil
        ).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// `image` drawn into a new texture, or nil when it can't be (no GPU, a format or size it doesn't take).
    private func texture(of image: CIImage, _ extent: CGRect, format: CIFormat) throws -> CIImage? {
        let pixelFormat: MTLPixelFormat
        switch format {
        case .RGBAh: pixelFormat = .rgba16Float
        case .RGBAf: pixelFormat = .rgba32Float
        case .Rh: pixelFormat = .r16Float
        case .Rf: pixelFormat = .r32Float
        default: return nil
        }
        let width = Int(extent.width), height = Int(extent.height)
        guard let device, width >= 1, height >= 1, max(width, height) <= Self.largestTexture else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
        // The numbers as they are: no color matching, no clamping to 0...1.
        destination.colorSpace = nil
        destination.isClamped = false
        destination.isDithered = false
        destination.isFlipped = false
        _ = try context.startTask(toRender: image, from: extent, to: destination, at: .zero).waitUntilCompleted()
        guard let kept = CIImage(mtlTexture: texture, options: [.colorSpace: NSNull()]) else { return nil }
        return kept.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    /// The longest side a texture can have (Metal's limit on every Mac this runs on).
    static let largestTexture = 16384

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

        guard let space, let encoded = encoded(image, format: .RGBX16, colorSpace: space) else { throw failure() }

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

nonisolated extension FocusStackTIFFWriter {
    /// `image` (linear Rec. 2020, 0…1) encoded in `colorSpace`: for the TIFF, and for showing a stack of
    /// photos that aren't RAW as it will look.
    static func encoded(_ image: LinearDNGImage, format: CIFormat, colorSpace: CGColorSpace) -> CGImage? {
        let data = image.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        guard let provider = CGDataProvider(data: data as CFData),
              let linear = CGImage(
                  width: image.width, height: image.height, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: image.width * 6,
                  space: HDRMerger.colorSpace, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }
        let context = CIContext(options: [.workingColorSpace: HDRMerger.colorSpace, .cacheIntermediates: false])
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return context.createCGImage(CIImage(cgImage: linear), from: extent, format: format, colorSpace: colorSpace)
    }
}

/// Results filled in from several cores at once, each in its own place.
nonisolated private final class Slots<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var filled: [Value?]

    init(_ count: Int) { filled = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ value: Value) {
        lock.lock()
        filled[index] = value
        lock.unlock()
    }

    var values: [Value?] {
        lock.lock()
        defer { lock.unlock() }
        return filled
    }
}

/// Counts the steps of lining up done on several cores, and reports the fraction done, one at a time.
nonisolated private final class AlignmentSteps: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int
    private let report: (Double) -> Void
    private var done = 0

    init(total: Int, report: @escaping (Double) -> Void) {
        self.total = total
        self.report = report
    }

    func step() {
        lock.lock()
        done += 1
        report(Double(done) / Double(max(total, 1)))
        lock.unlock()
    }
}

/// Decodes frames ahead of the one being stacked, on other cores, and hands them over in order.
nonisolated private final class FrameLookahead: @unchecked Sendable {
    let scale: CGFloat
    private let order: [Int]
    private let depth: Int
    private let decode: @Sendable (Int) throws -> CIImage
    private let condition = NSCondition()
    private let group = DispatchGroup()
    private let queue = DispatchQueue(label: "FocusStackMerger.lookahead", qos: .userInitiated, attributes: .concurrent)
    /// Guarded by `condition`.
    private var results: [Int: Result<CIImage, any Error>] = [:]
    private var position: [Int: Int] = [:]
    private var started = 0
    private var finished = false

    /// `order` is the frames in the order they'll be taken; `depth` is how many are decoded ahead.
    init(order: [Int], scale: CGFloat, depth: Int, decode: @escaping @Sendable (Int) throws -> CIImage) {
        self.order = order
        self.scale = scale
        self.depth = depth
        self.decode = decode
        for (place, index) in order.enumerated() where position[index] == nil { position[index] = place }
        condition.lock()
        start(through: depth - 1)
        condition.unlock()
    }

    /// Starts decoding the frames up to place `last` that haven't been started. Called with the lock held.
    private func start(through last: Int) {
        while started <= min(last, order.count - 1) {
            let index = order[started]
            started += 1
            queue.async(group: group) { [self] in
                condition.lock()
                let skip = finished
                condition.unlock()
                let result: Result<CIImage, any Error>? = skip ? nil : Result { try autoreleasepool { try decode(index) } }
                condition.lock()
                if let result, !finished { results[index] = result }
                condition.broadcast()
                condition.unlock()
            }
        }
    }

    /// Frame `index`, waiting for it if it's still being decoded, and starts the next ones. Nil for a
    /// frame that isn't being read ahead (or was taken already): the caller reads that one itself.
    func take(_ index: Int) throws -> CIImage? {
        condition.lock()
        defer { condition.unlock() }
        guard !finished, let place = position.removeValue(forKey: index) else { return nil }
        start(through: place + depth)
        while results[index] == nil, place < started, !finished { condition.wait() }
        guard let result = results.removeValue(forKey: index) else { return nil }
        return try result.get()
    }

    /// Drops what's been decoded and waits for the decoding under way to end, so nothing is still
    /// reading the merger's frames once this returns.
    func finish() {
        condition.lock()
        finished = true
        results = [:]
        condition.broadcast()
        condition.unlock()
        group.wait()
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
    static let fill = load(name: "focusFill") { try CIKernel(functionName: $0, fromMetalLibraryData: $1) }
    static let soften = color("focusSoften")
    static let depth = color("focusDepth")
    static let accumulate = color("focusAccumulate")
    static let share = color("focusShare")
    static let blend = color("focusBlend")
    static let total = color("focusTotal")
    static let resolve = color("focusResolve")
    static let add = color("focusAdd")
    static let mean = color("focusMean")
    static let encode = color("focusEncode")
    static let decode = color("focusDecode")
    static let band = load(name: "focusBand") { try CIKernel(functionName: $0, fromMetalLibraryData: $1) }
    static let strength = color("focusStrength")
    static let stronger = color("focusStronger")
    static let most = color("focusMost")
    static let range = color("focusRange")
    static let within = color("focusWithin")
    static let collapse = load(name: "focusCollapse") { try CIKernel(functionName: $0, fromMetalLibraryData: $1) }
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
