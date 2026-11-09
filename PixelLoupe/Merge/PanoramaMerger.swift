import Accelerate
import CoreImage
import Foundation
import simd

/// Photo ▸ Photo Merge ▸ Panorama's settings. The defaults are Lightroom's; the last ones used are
/// remembered for the next merge.
nonisolated struct PanoramaMergeOptions: Codable, Equatable, Sendable {
    var projection = PanoramaProjection.spherical
    /// 0…100: how far the panorama's edge is bent to fill the rectangle (see ``PanoramaBoundaryWarp``).
    var boundaryWarp = 0
    var autoCrop = false
    /// Fills where the photos don't reach with content-aware fill (``PanoramaFill``), so nothing has to be
    /// cropped away. Turns Auto Crop off while on, as in Lightroom.
    var fillEdges = false
    var autoSettings = true
    var createsStack = false

    /// Whether the merge is cropped to the rectangle the photos cover: Auto Crop, unless Fill Edges fills it.
    var cropsToCovered: Bool { autoCrop && !fillEdges }

    private static let defaultsKey = "PanoramaMergeOptions"

    init() {}

    /// Settings saved before an option existed load with that option's default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PanoramaMergeOptions()
        projection = try container.decodeIfPresent(PanoramaProjection.self, forKey: .projection) ?? defaults.projection
        boundaryWarp = try container.decodeIfPresent(Int.self, forKey: .boundaryWarp) ?? defaults.boundaryWarp
        autoCrop = try container.decodeIfPresent(Bool.self, forKey: .autoCrop) ?? defaults.autoCrop
        fillEdges = try container.decodeIfPresent(Bool.self, forKey: .fillEdges) ?? defaults.fillEdges
        autoSettings = try container.decodeIfPresent(Bool.self, forKey: .autoSettings) ?? defaults.autoSettings
        createsStack = try container.decodeIfPresent(Bool.self, forKey: .createsStack) ?? defaults.createsStack
    }

    static func load(from defaults: UserDefaults = Defaults.store) -> PanoramaMergeOptions {
        guard let data = defaults.data(forKey: defaultsKey),
              let options = try? JSONDecoder().decode(PanoramaMergeOptions.self, from: data) else { return PanoramaMergeOptions() }
        return options
    }

    func save(to defaults: UserDefaults = Defaults.store) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}

/// Where a merged panorama's photos cover it (0…1, top row first).
nonisolated struct PanoramaCoverage: Sendable {
    var width: Int
    var height: Int
    var values: [Float]
}

nonisolated struct PanoramaMergeResult: Sendable {
    /// The panorama, scene-linear at the photos' average exposure, white where the photos don't reach (or filled,
    /// with Fill Edges).
    var image: LinearDNGImage
    /// Auto Crop's crop (Develop's unit rectangle, origin bottom left), or nil with Auto Crop off (or Fill Edges on).
    var crop: CGRect?
    /// The largest rectangle the photos cover entirely (unit, origin bottom left): what Auto Settings
    /// measures, and Auto Crop's crop.
    var coveredRect: CGRect
    /// Where the photos cover the result, for the merge sheet's preview (nil at full resolution, and with Fill Edges,
    /// which covers it all).
    var coverage: PanoramaCoverage?
}

nonisolated enum PanoramaMergeError: LocalizedError, Equatable {
    case projectionNotPossible(PanoramaProjection)

    var errorDescription: String? {
        switch self {
        case .projectionNotPossible(let projection):
            "\(projection.title) can’t show photos spanning more than \(Int(PanoramaProjection.perspectiveLimit))°. Choose Spherical or Cylindrical."
        }
    }
}

/// Merges overlapping photos into a panorama, as Lightroom's Photo Merge ▸ Panorama (or, for HDR Panorama,
/// overlapping bracket sets, each merged by ``HDRMerger`` and treated as one photo; see ``init(brackets:)``).
///
/// Each photo is decoded linearly by the RAW engine with the reference photo's white balance (the
/// earliest photo's, whose settings and metadata the panorama takes), its lens profile applied, and
/// scaled by its exposure so they all match the photos' average exposure, as Lightroom's merges do. ``PanoramaAligner`` finds how they fit
/// together, on copies 1536 pixels long, and ``PanoramaLayout`` places them for a projection.
/// ``PanoramaSeams`` then works out, on a panorama 1536 pixels long, how much to even out each
/// photo's brightness and where each one shows; ``PanoramaBoundaryWarp`` bends the edges, and
/// ``PanoramaCrop`` finds Auto Crop's rectangle. Merging warps each photo onto the panorama and blends
/// them across their seams band by band (a Laplacian pyramid, six levels at full resolution), on the
/// GPU in Core Image kernels (PanoramaKernels.ci.metal). At full resolution it's drawn in blocks, so
/// Core Image only decodes the parts of the photos each block needs.
///
/// Not thread-safe: use one instance per task.
nonisolated final class PanoramaMerger {
    struct Frame {
        /// The photo, or a bracket set's reference (middle) exposure.
        let source: PhotoMergeSource
        fileprivate let filter: CIRAWFilter
        /// A bracket set's exposures, merged into one HDR frame (HDR Panorama), or nil for a single photo.
        fileprivate let bracket: HDRMerger?
        fileprivate let lens: LensSetup
        /// How much the photo's values are scaled to match the photos' average exposure (from
        /// shutter speed, aperture and ISO).
        let exposureGain: Double
    }

    private final class OpenedBrackets: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var results: [Result<HDRMerger, Error>?]

        init(count: Int) { results = Array(repeating: nil, count: count) }

        func store(_ result: Result<HDRMerger, Error>, at index: Int) { lock.withLock { results[index] = result } }
    }

    /// The photos decoded side by side (each with its own RAW filter), and what each produced.
    private final class DecodeJob: @unchecked Sendable {
        let frames: [Frame]
        private let lock = NSLock()
        private(set) var snapshots: [CIImage?]
        private(set) var images: [PanoramaAlignmentImage?]

        init(frames: [Frame], count: Int) {
            self.frames = frames
            snapshots = Array(repeating: nil, count: count)
            images = Array(repeating: nil, count: count)
        }

        func store(_ snapshot: CIImage, _ image: PanoramaAlignmentImage, at index: Int) {
            lock.withLock {
                snapshots[index] = snapshot
                images[index] = image
            }
        }
    }

    fileprivate enum LensSetup {
        /// The camera's own profile, applied by the RAW engine.
        case builtIn
        case profile(PhotoAdjustments.LensCorrections)
        case none
    }

    let frames: [Frame]
    /// The earliest photo: its white balance and metadata are the panorama's.
    let referenceIndex: Int
    var reference: PhotoMergeSource { frames[referenceIndex].source }
    /// Every photo's full-resolution size.
    let nativeSize: CGSize
    let alignment: PanoramaAlignment
    /// Lightroom's notice when some photo has no lens profile to apply, or nil.
    let lensWarning: String?
    let allowsPerspective: Bool

    var mergedCount: Int { alignment.mergedCount }

    static let lensNotice = "Unable to match a lens profile automatically. For best results, apply the appropriate lens profile to the photos before merging."
    static let colorSpace = HDRMerger.colorSpace
    /// The long side of the copies the photos are aligned on, and of the panorama the seams are worked out on.
    static let alignmentPixels: CGFloat = 1536
    static let analysisPixels: CGFloat = 1536
    /// Blend levels at full resolution (each halves the size): the coarsest blends over about 64 pixels.
    static let fullResolutionLevels = 6

    private let neutral: (temperature: Float, tint: Float)
    private let cameraBaselineExposure: Double
    private let context = CIContext(options: [.workingColorSpace: PanoramaMerger.colorSpace, .cacheIntermediates: false])
    /// The photos decoded at `alignmentScale` (linear, lens corrected, not scaled by exposure), kept
    /// as pixels so they don't depend on the RAW filters' changing settings.
    private let snapshots: [CIImage]
    private let alignmentScale: CGFloat
    private let alignedSizes: [CGSize]
    /// Each photo's brightness correction where they overlap, once measured.
    private var overlapGains: [Float]?
    /// The brightest value any photo reaches after its gains, once measured.
    private var peakValue: Float = 1
    private var analyses: [PanoramaProjection: Analysis] = [:]
    private var warps: [PanoramaProjection: PanoramaBoundaryWarp] = [:]
    private var warpMaps: [WarpKey: WarpMap] = [:]
    private var fills: [FillKey: PanoramaFill.Solution] = [:]
    /// The full-resolution panorama Fill Edges last copied from (see ``filled(_:analysis:warp:options:scale:canvas:drawn:)``).
    private var panoramaCopies: [CopyKey: (rect: CGRect, image: CIImage)] = [:]

    private struct CopyKey: Hashable {
        var fill: FillKey
        var scale: CGFloat
    }
    /// The largest scale merged from the small copies (normally just above their own); tests lower it, so small
    /// synthetic photos take the full-resolution path.
    var largestSnapshotScale: CGFloat?
    /// Bracket sets merged into memory-mapped files at a large scale (see ``materialized(_:scale:)``), by frame and scale.
    private var materializedBrackets: [MaterializedKey: CIImage] = [:]
    private let scratch = FileManager.default.temporaryDirectory
        .appending(path: "PixelLoupe-HDRPanorama-\(UUID().uuidString)", directoryHint: .isDirectory)

    private struct MaterializedKey: Hashable {
        var index: Int
        var scale: CGFloat
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
    }

    convenience init(sources: [PhotoMergeSource]) throws {
        if let problem = PhotoMergeSource.problem(merging: sources) { throw problem }
        try self.init(frames: sources, brackets: Array(repeating: nil, count: sources.count))
    }

    /// HDR Panorama: each bracket set (``HDRBrackets``) is one frame, its exposures merged by ``HDRMerger``
    /// (Auto Align, no deghosting or tone mapping) as Core Image needs them, at the scale each render needs.
    /// The set's reference exposure stands for it: its exposure, lens and metadata. The merged sets keep
    /// their brightness, and the panorama is stored scaled to its own peak, so they all match.
    convenience init(brackets: [[PhotoMergeSource]]) throws {
        if let problem = PhotoMergeSource.problem(merging: brackets.flatMap { $0 }) { throw problem }
        // Opened side by side: reading each set's files is most of it.
        let opened = OpenedBrackets(count: brackets.count)
        DispatchQueue.concurrentPerform(iterations: brackets.count) { index in
            opened.store(Result { try HDRMerger(sources: brackets[index]) }, at: index)
        }
        let mergers = try opened.results.map { try ($0 ?? .failure(PhotoMergeError.tooFewPhotos)).get() }
        try self.init(frames: mergers.map(\.reference), brackets: mergers)
    }

    private init(frames sources: [PhotoMergeSource], brackets: [HDRMerger?]) throws {
        var filters: [CIRAWFilter] = []
        var size: CGSize?
        for source in sources {
            guard let filter = CIRAWFilter(imageURL: source.url), let output = filter.outputImage else {
                throw PhotoMergeError.unreadable(source.name)
            }
            guard size == nil || size == output.extent.size else { throw PhotoMergeError.differentSizes }
            size = output.extent.size
            filters.append(filter)
        }
        nativeSize = size ?? .zero

        let reference = sources.indices.min { a, b in
            (sources[a].captureDate ?? .distantFuture, a) < (sources[b].captureDate ?? .distantFuture, b)
        } ?? 0
        referenceIndex = reference
        func exposure(_ source: PhotoMergeSource) -> Double? {
            guard source.exposureTime > 0, source.aperture > 0, source.iso > 0 else { return nil }
            return source.exposureTime * Double(source.iso) / (source.aperture * source.aperture)
        }
        // Brightness is matched to the photos' average exposure (the mean in stops), as Lightroom's
        // merges render; photos without exposure details are left as they are.
        let exposures = sources.compactMap(exposure)
        let averageExposure = exposures.count == sources.count
            ? exp2(exposures.reduce(0) { $0 + log2($1) } / Double(exposures.count)) : nil
        let shooting = sources.map { ShootingInfo.read(from: $0.url) }
        frames = sources.indices.map { index in
            let gain = averageExposure.flatMap { average in exposure(sources[index]).map { average / $0 } } ?? 1
            return Frame(source: sources[index], filter: filters[index], bracket: brackets[index],
                         lens: Self.lensSetup(for: sources[index], filter: filters[index], shooting: shooting[index]),
                         exposureGain: gain)
        }
        let referenceFilter = filters[reference]
        neutral = (referenceFilter.neutralTemperature, referenceFilter.neutralTint)
        cameraBaselineExposure = Double(referenceFilter.baselineExposure)
        lensWarning = frames.contains { if case .none = $0.lens { true } else { false } } ? Self.lensNotice : nil

        // Small copies to align on (decoded side by side), kept for the previews and seams.
        let scale = min(1, Self.alignmentPixels / max(nativeSize.width, nativeSize.height, 1))
        alignmentScale = scale
        let job = DecodeJob(frames: frames, count: frames.count)
        let neutral = neutral, context = context
        DispatchQueue.concurrentPerform(iterations: frames.count) { index in
            let frame = job.frames[index]
            // A bracket set's exposures decoded side by side, once, for its alignment and this copy.
            if let bracket = frame.bracket {
                Self.configure(bracket, for: frame, neutral: neutral)
                bracket.prepare(scale: scale)
            }
            defer { frame.bracket?.forgetPrepared() }
            let image = Self.decoded(frame, scale: scale, neutral: neutral)
            let extent = CGRect(origin: .zero, size: image.extent.integral.size)
            let rowBytes = Int(extent.width) * 8
            var data = Data(count: rowBytes * Int(extent.height))
            data.withUnsafeMutableBytes { buffer in
                context.render(image, toBitmap: buffer.baseAddress!, rowBytes: rowBytes, bounds: extent, format: .RGBAh, colorSpace: nil)
            }
            let snapshot = CIImage(bitmapData: data, bytesPerRow: rowBytes, size: extent.size, format: .RGBAh, colorSpace: nil)
            let aligned = Self.alignmentImage(
                data, width: Int(extent.width), height: Int(extent.height), gain: Float(frame.exposureGain),
                focalLength: Self.focalLength(frame.source, shooting: shooting[index], size: extent.size)
            )
            job.store(snapshot, aligned, at: index)
        }
        let snapshots = job.snapshots
        let images = job.images
        self.snapshots = snapshots.map { $0 ?? CIImage.empty() }
        alignedSizes = self.snapshots.map(\.extent.size)
        alignment = try PanoramaAligner.align(images.compactMap { $0 })
        allowsPerspective = PanoramaLayout.allowsPerspective(alignment: alignment, alignedSizes: alignedSizes)
    }

    /// What the merged DNG records about the shot: the reference photo's.
    func dngMetadata() -> DNGMetadata {
        let source = reference
        return DNGMetadata(
            make: source.make, model: source.model, lensModel: source.lensModel, captureDate: source.captureDate,
            exposureTime: source.exposureTime, aperture: source.aperture, iso: source.iso,
            focalLength: source.focalLength, baselineExposure: cameraBaselineExposure
        )
    }

    /// The panorama's full-resolution size for a projection.
    func size(for projection: PanoramaProjection) throws -> CGSize {
        try analysis(for: projection).layout.size
    }

    /// The scale (of full resolution) the seams are worked out at: merging there is cheap, so Auto
    /// Settings measures on it, the same for the preview and the full merge.
    func analysisScale(for projection: PanoramaProjection) throws -> CGFloat {
        let analysis = try analysis(for: projection)
        return CGFloat(analysis.scale)
    }

    // MARK: - Lens and exposure

    /// The lens correction a photo gets: the camera's built-in profile, the profile it has in
    /// Develop, or the LensFun profile matching its camera and lens (as Enable Profile Corrections
    /// would find), else none.
    fileprivate static func lensSetup(for source: PhotoMergeSource, filter: CIRAWFilter, shooting: ShootingInfo) -> LensSetup {
        if filter.isLensCorrectionSupported { return .builtIn }
        let own = source.lensCorrections
        if own.appliesProfile {
            var lens = PhotoAdjustments.LensCorrections()
            lens.enableProfileCorrections = true
            lens.profile = own.profile
            lens.distortionAmount = own.distortionAmount
            lens.vignettingAmount = own.vignettingAmount
            return .profile(lens)
        }
        let database = LensFunDatabase.shared
        guard let match = database.match(make: source.make, model: source.model, lens: source.lensModel) else { return .none }
        let cropFactor = database.camera(make: source.make, model: source.model)?.cropFactor ?? shooting.cropFactor
        var lens = PhotoAdjustments.LensCorrections()
        lens.enableProfileCorrections = true
        lens.profile = LensFunDatabase.profile(for: match, cropFactor: cropFactor, focalLength: shooting.focalLength,
                                               aperture: shooting.aperture, distance: shooting.subjectDistance)
        return .profile(lens)
    }

    /// The lens's focal length in pixels for the photo at `size`: from its 35 mm equivalent (or focal
    /// length and the camera's crop factor), measured along the diagonal; nil when unknown.
    static func focalLength(_ source: PhotoMergeSource, shooting: ShootingInfo, size: CGSize) -> Double? {
        let cropFactor = LensFunDatabase.shared.camera(make: source.make, model: source.model)?.cropFactor ?? shooting.cropFactor
        let focal = source.focalLength > 0 ? source.focalLength : shooting.focalLength ?? 0
        guard let equivalent = shooting.focalLength35mm ?? cropFactor.map({ focal * $0 }), equivalent > 0 else { return nil }
        return equivalent / hypot(36, 24) * hypot(Double(size.width), Double(size.height))
    }

    /// The photo (or bracket set, merged) decoded linearly at `scale` with the reference's white balance,
    /// its lens profile applied, origin at zero.
    fileprivate static func decoded(_ frame: Frame, scale: CGFloat, neutral: (temperature: Float, tint: Float)) -> CIImage {
        if let bracket = frame.bracket {
            configure(bracket, for: frame, neutral: neutral)
            var image = bracket.radiance(scale: scale)
            if case .profile(let lens) = frame.lens { image = LensCorrector.apply(lens, to: image) }
            let extent = image.extent
            return image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        }
        let filter = frame.filter
        filter.scaleFactor = Float(scale)
        filter.exposure = 0
        filter.baselineExposure = 0
        filter.boostAmount = 0
        filter.shadowBias = 0
        filter.isGamutMappingEnabled = false
        filter.neutralTemperature = neutral.temperature
        filter.neutralTint = neutral.tint
        if filter.isLensCorrectionSupported {
            if case .builtIn = frame.lens { filter.isLensCorrectionEnabled = true } else { filter.isLensCorrectionEnabled = false }
        }
        var image = filter.outputImage ?? CIImage.empty()
        if case .profile(let lens) = frame.lens { image = LensCorrector.apply(lens, to: image) }
        let extent = image.extent
        return image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }

    /// A bracket set decodes with the panorama's white balance, and the camera's built-in lens profile only when
    /// that's the frame's lens correction.
    fileprivate static func configure(_ bracket: HDRMerger, for frame: Frame, neutral: (temperature: Float, tint: Float)) {
        bracket.neutral = neutral
        if case .builtIn = frame.lens { bracket.builtInLensCorrection = true } else { bracket.builtInLensCorrection = false }
    }

    /// A photo's brightness for the aligner: luminance scaled by its exposure gain, gamma encoded.
    static func alignmentImage(_ data: Data, width: Int, height: Int, gain: Float, focalLength: Double?) -> PanoramaAlignmentImage {
        var pixels = [Float](repeating: 0, count: width * height)
        data.withUnsafeBytes { raw in
            let half = raw.bindMemory(to: Float16.self)
            for i in 0..<(width * height) {
                let l = (0.2627 * Float(half[i * 4]) + 0.6780 * Float(half[i * 4 + 1]) + 0.0593 * Float(half[i * 4 + 2])) * gain
                pixels[i] = pow(min(max(l, 0), 1), 1 / 2.2)
            }
        }
        return PanoramaAlignmentImage(width: width, height: height, pixels: pixels, focalLength: focalLength)
    }

    /// Each photo's total gain: its exposure's, times its brightness correction once measured.
    private func gain(_ index: Int) -> Double {
        frames[index].exposureGain * Double(overlapGains?[index] ?? 1)
    }

    // MARK: - Analysis

    /// What's worked out once per projection, on a panorama `analysisPixels` long.
    private struct Analysis {
        let layout: PanoramaLayout
        let width: Int
        let height: Int
        /// Of full resolution.
        let scale: Double
        /// Which photo each pixel comes from (frame index), or −1.
        let labels: [Int16]
        /// Each merged photo's mask: red 1 where it shows, at the small size, origin at zero.
        let masks: [Int: CIImage]
        /// Each merged photo's weight for the coarsest band of the blend (red; they add up to 1).
        let feathers: [Int: CIImage]
        let coverage: [Bool]
    }

    private func analysis(for projection: PanoramaProjection) throws -> Analysis {
        if let analysis = analyses[projection] { return analysis }
        guard let layout = PanoramaLayout(
            alignment: alignment, alignedSizes: alignedSizes,
            photoSizes: Array(repeating: nativeSize, count: frames.count), projection: projection
        ) else { throw PanoramaMergeError.projectionNotPossible(projection) }
        let scale = min(1, Double(Self.analysisPixels) / Double(max(layout.size.width, layout.size.height)))
        let width = max(1, Int((Double(layout.size.width) * scale).rounded()))
        let height = max(1, Int((Double(layout.size.height) * scale).rounded()))
        let extent = CGRect(x: 0, y: 0, width: width, height: height)

        // Each merged photo warped onto the small panorama, read back with where it covers and how
        // central each pixel is in it.
        let merged = frames.indices.filter { layout.cameras[$0] != nil }
        let sources = try sourceImages(scale: CGFloat(scale))
        // The photos are compared with whatever gains are known; the first time, none are yet.
        let gainsKnown = overlapGains != nil
        var photos: [PanoramaSeams.Photo] = []
        for index in merged {
            try Task.checkCancellation()
            let footprint = pixelRect(layout.footprint(of: index), scale: CGFloat(scale), extent: extent)
            guard !footprint.isEmpty else { continue }
            let warped = warpedPhoto(index, layout: layout, scale: CGFloat(scale), canvas: extent, sources: sources)
            let w = Int(footprint.width), h = Int(footprint.height)
            var pixels = [Float](repeating: 0, count: w * h * 4)
            context.render(warped, toBitmap: &pixels, rowBytes: w * 16, bounds: ciRect(footprint, canvasHeight: CGFloat(height)), format: .RGBAf, colorSpace: nil)
            let camera = layout.cameras[index]!
            var color = [SIMD3<Float>](repeating: .zero, count: w * h)
            var covered = [Bool](repeating: false, count: w * h)
            var centrality = [Float](repeating: 0, count: w * h)
            let half = SIMD2(Double(nativeSize.width) / 2, Double(nativeSize.height) / 2)
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    let alpha = pixels[i * 4 + 3]
                    guard alpha > 0.99 else { continue }
                    covered[i] = true
                    color[i] = SIMD3(pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2]) / alpha
                    let full = SIMD2(Double(Int(footprint.minX) + x) + 0.5, Double(Int(footprint.minY) + y) + 0.5) / scale
                    if let p = camera.project(layout.ray(at: full)) {
                        let edge = min(half.x - abs(p.x), half.y - abs(p.y)) / min(half.x, half.y)
                        centrality[i] = Float(max(0, edge))
                    }
                }
            }
            photos.append(PanoramaSeams.Photo(
                x: Int(footprint.minX), y: Int(footprint.minY), width: w, height: h,
                color: color, covered: covered, centrality: centrality
            ))
        }
        let photoFrames = merged.filter { !pixelRect(layout.footprint(of: $0), scale: CGFloat(scale), extent: extent).isEmpty }
        if overlapGains == nil {
            // Measured once (on the first projection asked for): exposure differences don't depend on it.
            let gains = PanoramaSeams.gains(photos)
            var all = [Float](repeating: 1, count: frames.count)
            for (photo, gain) in zip(photoFrames, gains) { all[photo] = gain }
            overlapGains = all
            peakValue = measuredPeak()
        }
        try Task.checkCancellation()
        let gains = photoFrames.map { gainsKnown ? 1 : overlapGains?[$0] ?? 1 }
        let seamLabels = PanoramaSeams.labels(photos, gains: gains, width: width, height: height)
        let labels = seamLabels.map { $0 < 0 ? Int16(-1) : Int16(photoFrames[Int($0)]) }

        var masks: [Int: CIImage] = [:]
        for (position, frame) in photoFrames.enumerated() {
            let photo = photos[position]
            var bytes = [UInt8](repeating: 0, count: photo.width * photo.height * 4)
            for y in 0..<photo.height {
                for x in 0..<photo.width {
                    let i = (y * photo.width + x) * 4
                    bytes[i] = labels[(photo.y + y) * width + photo.x + x] == Int16(frame) ? 255 : 0
                    bytes[i + 3] = 255
                }
            }
            let image = CIImage(bitmapData: Data(bytes), bytesPerRow: photo.width * 4,
                                size: CGSize(width: photo.width, height: photo.height), format: .RGBA8, colorSpace: nil)
            masks[frame] = image.transformed(by: CGAffineTransform(translationX: CGFloat(photo.x), y: CGFloat(height - photo.y - photo.height)))
        }
        // The coarsest band (the photos' broad brightness, vignetting included) is feathered instead:
        // each photo weighted by how far a pixel is from its edges, so it fades out across the overlap.
        var total = [Float](repeating: 0, count: width * height)
        for photo in photos {
            for y in 0..<photo.height {
                for x in 0..<photo.width where photo.covered[y * photo.width + x] {
                    total[(photo.y + y) * width + photo.x + x] += photo.centrality[y * photo.width + x]
                }
            }
        }
        var feathers: [Int: CIImage] = [:]
        for (position, frame) in photoFrames.enumerated() {
            let photo = photos[position]
            var values = [Float](repeating: 0, count: photo.width * photo.height * 4)
            for y in 0..<photo.height {
                for x in 0..<photo.width {
                    let i = y * photo.width + x
                    let sum = total[(photo.y + y) * width + photo.x + x]
                    values[i * 4] = photo.covered[i] && sum > 0 ? photo.centrality[i] / sum : 0
                    values[i * 4 + 3] = 1
                }
            }
            let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
            let image = CIImage(bitmapData: data, bytesPerRow: photo.width * 16,
                                size: CGSize(width: photo.width, height: photo.height), format: .RGBAf, colorSpace: nil)
            feathers[frame] = image.transformed(by: CGAffineTransform(translationX: CGFloat(photo.x), y: CGFloat(height - photo.y - photo.height)))
        }
        let analysis = Analysis(layout: layout, width: width, height: height, scale: scale, labels: labels,
                                masks: masks, feathers: feathers, coverage: labels.map { $0 >= 0 })
        analyses[projection] = analysis
        return analysis
    }

    /// The brightest value in any photo after its gains (at the alignment size, where single hot
    /// pixels average out), so the preview and the full merge are stored the same way.
    private func measuredPeak() -> Float {
        var peak: Float = 1
        for index in frames.indices where alignment.cameras[index] != nil {
            let image = snapshots[index]
            let maximum = image.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
            var pixel = [Float](repeating: 0, count: 4)
            context.render(maximum, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
            let value = max(pixel[0], pixel[1], pixel[2]) * Float(gain(index))
            if value.isFinite { peak = max(peak, value) }
        }
        return peak
    }

    // MARK: - Boundary Warp

    private struct WarpKey: Hashable {
        var projection: PanoramaProjection
        var amount: Int
    }

    /// Boundary Warp at one amount: the map image for the kernel (red, green: where on the unwarped
    /// panorama, as fractions; blue: whether anything lands), its values, and the warped coverage on
    /// the small panorama.
    private struct WarpMap {
        let image: CIImage
        let width: Int
        let height: Int
        let points: [SIMD2<Float>?]
        let coverage: [Bool]
    }

    private func warpMap(_ analysis: Analysis, projection: PanoramaProjection, amount: Int) -> WarpMap? {
        let key = WarpKey(projection: projection, amount: amount)
        if let map = warpMaps[key] { return map }
        if warps[projection] == nil {
            warps[projection] = PanoramaBoundaryWarp(coverage: analysis.coverage, width: analysis.width, height: analysis.height)
        }
        guard let warp = warps[projection] else { return nil }
        let map = warp.map(amount: Double(amount) / 100)
        var values = [Float](repeating: 0, count: map.width * map.height * 4)
        for (i, point) in map.points.enumerated() {
            guard let point else { continue }
            values[i * 4] = point.x
            values[i * 4 + 1] = point.y
            values[i * 4 + 2] = 1
            values[i * 4 + 3] = 1
        }
        // Coverage on the small panorama, from the nearest map sample.
        let width = analysis.width, height = analysis.height
        var coverage = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            let my = min(map.height - 1, y * map.height / height)
            for x in 0..<width {
                let mx = min(map.width - 1, x * map.width / width)
                guard let point = map.points[my * map.width + mx] else { continue }
                let sx = Int((point.x * Float(width)).rounded(.down)), sy = Int((point.y * Float(height)).rounded(.down))
                guard sx >= 0, sy >= 0, sx < width, sy < height else { continue }
                coverage[y * width + x] = analysis.coverage[sy * width + sx]
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        let image = CIImage(bitmapData: data, bytesPerRow: map.width * 16, size: CGSize(width: map.width, height: map.height), format: .RGBAf, colorSpace: nil)
        let result = WarpMap(image: image, width: map.width, height: map.height, points: map.points, coverage: coverage)
        // Kept for the amounts the slider passes through, within reason.
        if warpMaps.count > 24 { warpMaps.removeAll() }
        warpMaps[key] = result
        return result
    }

    // MARK: - Merging

    /// Merges the photos at `scale` (1 = full resolution), on the GPU. `region` (pixels at that
    /// scale, from the top left) limits it to part of the panorama, for zooming in. `progress` gets
    /// the fraction done. Throws `CancellationError` when the task is cancelled.
    func merge(
        options: PanoramaMergeOptions, scale: CGFloat, region: CGRect? = nil, progress: (Double) -> Void = { _ in }
    ) throws -> PanoramaMergeResult {
        let analysis = try analysis(for: options.projection)
        try Task.checkCancellation()
        let amount = min(max(options.boundaryWarp, 0), 100)
        let warp = amount > 0 ? warpMap(analysis, projection: options.projection, amount: amount) : nil
        let coverage = warp?.coverage ?? analysis.coverage
        let coveredRect = Self.coveredRect(coverage, width: analysis.width, height: analysis.height)
        progress(0.05)

        let layout = analysis.layout
        let width = max(1, Int((layout.size.width * scale).rounded())), height = max(1, Int((layout.size.height * scale).rounded()))
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        // Boundary Warp and Fill Edges sample the panorama far from where they draw.
        let drawn = region.flatMap { region -> CGRect? in
            guard warp == nil, !options.fillEdges else { return nil }
            return CGRect(x: region.minX, y: canvas.height - region.maxY, width: region.width, height: region.height).integral
        }
        let composite = try composite(analysis, scale: scale, canvas: canvas, warp: warp, region: drawn)

        var extent = canvas
        var image = composite.image
        var coverageImage = composite.coverage
        if options.fillEdges {
            let part = region.map { CGRect(x: $0.minX, y: canvas.height - $0.maxY, width: $0.width, height: $0.height).integral } ?? canvas
            image = try filled(composite, analysis: analysis, warp: warp, options: options, scale: scale, canvas: canvas,
                               drawn: part.intersection(canvas))
            progress(0.1)
        }
        if let region {
            // Core Image's origin is the bottom left.
            let part = CGRect(x: region.minX, y: canvas.height - region.maxY, width: region.width, height: region.height)
                .integral.intersection(canvas)
            let move = CGAffineTransform(translationX: -part.minX, y: -part.minY)
            image = image.cropped(to: part).transformed(by: move)
            coverageImage = coverageImage.cropped(to: part).transformed(by: move)
            extent = CGRect(origin: .zero, size: part.size)
        }
        let k = CGFloat(1 / peakValue)
        image = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
        ])
        let pixels = try renderRGB(image, extent: extent) { progress(0.05 + 0.95 * $0) }
        let result = LinearDNGImage(
            width: Int(extent.width), height: Int(extent.height), pixels: pixels,
            headroom: LinearDNGWriter.headroom(peak: peakValue)
        )
        let shownCoverage = (scale < 1 || region != nil) && !options.fillEdges ? renderCoverage(coverageImage, extent: extent) : nil
        return PanoramaMergeResult(
            image: result, crop: options.cropsToCovered ? coveredRect : nil, coveredRect: coveredRect, coverage: shownCoverage
        )
    }

    // MARK: - Fill Edges

    private struct FillKey: Hashable {
        var projection: PanoramaProjection
        var amount: Int
        var width: Int
        var height: Int
    }

    /// The most pixels Fill Edges is solved at; larger merges copy the solve's matches up (``PanoramaFill/Field``).
    var fillPixels = 4_000_000

    /// The composite with Fill Edges' fill where the photos don't reach (after Boundary Warp). The fill is solved on
    /// a merge of at most `fillPixels` (this one, if it's that small; cached per projection, warp and size) and
    /// copied up to `scale` from this merge's pixels.
    private func filled(_ composite: (image: CIImage, coverage: CIImage, blended: CIImage), analysis: Analysis, warp: WarpMap?,
                        options: PanoramaMergeOptions, scale: CGFloat, canvas: CGRect, drawn: CGRect) throws -> CIImage {
        let layout = analysis.layout
        let fullPixels = Double(layout.size.width * layout.size.height)
        let solveScale = min(scale, CGFloat(sqrt(Double(fillPixels) / fullPixels)))
        let solveCanvas = CGRect(x: 0, y: 0, width: max(1, Int((layout.size.width * solveScale).rounded())),
                                 height: max(1, Int((layout.size.height * solveScale).rounded())))
        let key = FillKey(projection: options.projection, amount: min(max(options.boundaryWarp, 0), 100),
                          width: Int(solveCanvas.width), height: Int(solveCanvas.height))
        let solution: PanoramaFill.Solution
        if let cached = fills[key] {
            solution = cached
        } else {
            let source = solveCanvas == canvas ? composite : try self.composite(analysis, scale: solveScale, canvas: solveCanvas, warp: warp)
            solution = try PanoramaFill.solve(color: source.image, coverage: source.coverage, context: context,
                                              maxPixels: fillPixels, isCancelled: { Task.isCancelled })
            // Kept for the settings the sheet goes back and forth between, within reason.
            if fills.count > 8 { fills.removeAll() }
            fills[key] = solution
        }
        guard solveCanvas != canvas else { return PanoramaFill.composite(composite.blended, coverage: composite.coverage, fill: solution.fill) }
        // The fill copies from anywhere in the panorama. Drawn from the merge itself, each block made Core Image
        // render most of the full-resolution panorama at once (RAW-225), so it copies from a tiled copy of what it
        // reads, written once (kept while the merge's settings and the part drawn stay within it).
        let reads = solution.field.sourceRect(for: drawn, target: canvas).union(drawn).integral.intersection(canvas)
        let copyKey = CopyKey(fill: key, scale: scale)
        let source: CIImage
        if let copy = panoramaCopies[copyKey], copy.rect.contains(reads) {
            source = copy.image
        } else {
            source = try tiledCopy(of: composite.image, in: reads, name: "panorama-\(UUID().uuidString)")
            panoramaCopies = [copyKey: (reads, source)]
        }
        let fill = solution.field.fill(from: source, target: canvas)
        return PanoramaFill.composite(composite.blended, coverage: composite.coverage, fill: fill)
    }

    /// Auto Crop's rectangle for these options (Develop's unit crop rectangle, origin bottom left):
    /// the largest one the photos cover entirely, after Boundary Warp.
    func coveredRect(options: PanoramaMergeOptions) throws -> CGRect {
        let analysis = try analysis(for: options.projection)
        let amount = min(max(options.boundaryWarp, 0), 100)
        let coverage = amount > 0 ? warpMap(analysis, projection: options.projection, amount: amount)?.coverage ?? analysis.coverage : analysis.coverage
        return Self.coveredRect(coverage, width: analysis.width, height: analysis.height)
    }

    /// The merged photo's starting Develop settings: Auto Settings' tone (Develop's Auto Settings,
    /// measured inside the rectangle the photos cover on a merge at the seams' size, so the preview
    /// and the full merge get the same) and Auto Crop's crop. `directory` holds the small merge's
    /// temporary DNG.
    func startingAdjustments(options: PanoramaMergeOptions, directory: URL) async throws -> PhotoAdjustments {
        var adjustments = PhotoAdjustments()
        let covered = try coveredRect(options: options)
        if options.autoSettings {
            let small = try merge(options: options, scale: analysisScale(for: options.projection))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: "\(UUID().uuidString).dng")
            defer { try? FileManager.default.removeItem(at: url) }
            try LinearDNGWriter.write(small.image, metadata: dngMetadata(), to: url)
            try Task.checkCancellation()
            if let auto = await AutoDevelop.settings(for: PhotoSourceLocation(original: url), adjustments: adjustments, region: covered) {
                adjustments = auto
            }
        }
        if options.cropsToCovered {
            adjustments.crop.rect = covered
            adjustments.crop.aspect = .custom
            adjustments.crop.isAspectLocked = false
        }
        return adjustments
    }

    /// The largest rectangle covered entirely, as Develop's unit crop rectangle (origin bottom left),
    /// a pixel in from each side so its edges never catch the panorama's.
    static func coveredRect(_ coverage: [Bool], width: Int, height: Int) -> CGRect {
        guard var rect = PanoramaCrop.largestRectangle(coverage, width: width, height: height) else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        if rect.width > 4, rect.height > 4 {
            rect = (rect.x + 1, rect.y + 1, rect.width - 2, rect.height - 2)
        }
        let w = Double(width), h = Double(height)
        return CGRect(x: Double(rect.x) / w, y: (h - Double(rect.y + rect.height)) / h, width: Double(rect.width) / w, height: Double(rect.height) / h)
    }

    /// The photos at `scale`: the small copies for previews, otherwise decoded at that scale (Core
    /// Image decodes only what a render needs). Bracket sets `needs` says the render draws are merged
    /// into files first (``materialized(_:scale:)``).
    private func sourceImages(scale: CGFloat, needs: (Int) -> Bool = { _ in false }) throws -> [CIImage] {
        if scale <= (largestSnapshotScale ?? alignmentScale * 1.05) {
            // Much smaller than the copies: shrink them first so the warp doesn't alias.
            let ratio = scale / alignmentScale
            guard ratio < 0.5 else { return snapshots }
            return snapshots.map { snapshot in
                snapshot.applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: ratio * 1.5, kCIInputAspectRatioKey: 1,
                ])
            }
        }
        return try frames.indices.map { index in
            guard frames[index].bracket != nil, needs(index) else { return Self.decoded(frames[index], scale: scale, neutral: neutral) }
            return try materialized(index, scale: scale)
        }
    }

    /// A bracket set merged at `scale` once, into a memory-mapped file, for the panorama to sample. Left to Core
    /// Image, every block of a full-resolution merge merged the set again (seven RAW decodes and the HDR kernels
    /// each time), and Core Image's cache of those intermediates grew until rendering crawled and the app stopped
    /// responding (RAW-225). Kept for the merger's life: the sheet's 100% view comes back to the same sets.
    private func materialized(_ index: Int, scale: CGFloat) throws -> CIImage {
        let key = MaterializedKey(index: index, scale: scale)
        if let image = materializedBrackets[key] { return image }
        let image = Self.decoded(frames[index], scale: scale, neutral: neutral)
        let pixels = try tiledCopy(of: image, in: CGRect(origin: .zero, size: image.extent.integral.size),
                                   name: "\(index)-\(Int(scale * 1000))")
        materializedBrackets[key] = pixels
        return pixels
    }

    /// `rect` of `image` rendered once, in blocks, into a memory-mapped file in RGBA half floats, and read back as
    /// Core Image asks for it, a tile at a time (a bitmap image would copy the whole file into memory, and Core Image
    /// would upload all of it). The file goes with the merger.
    private func tiledCopy(of image: CIImage, in rect: CGRect, name: String) throws -> CIImage {
        let width = Int(rect.width), height = Int(rect.height), rowBytes = width * 8
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let url = scratch.appending(path: "\(name).rgbah")
        guard FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil) else {
            throw PhotoMergeError.unreadable(name)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(rowBytes * height))
        let block = Self.copyBlock
        var buffer = Data(count: min(block, width) * min(block, height) * 8)
        // Top down, as a bitmap's rows go; Core Image's origin is the bottom left.
        for top in stride(from: 0, to: height, by: block) {
            let rows = min(block, height - top)
            for left in stride(from: 0, to: width, by: block) {
                try Task.checkCancellation()
                let columns = min(block, width - left)
                let bounds = CGRect(x: Int(rect.minX) + left, y: Int(rect.minY) + height - top - rows, width: columns, height: rows)
                try buffer.withUnsafeMutableBytes { pixels in
                    context.render(image, toBitmap: pixels.baseAddress!, rowBytes: columns * 8, bounds: bounds, format: .RGBAh, colorSpace: nil)
                    for row in 0..<rows {
                        try handle.seek(toOffset: UInt64((top + row) * rowBytes + left * 8))
                        try handle.write(contentsOf: UnsafeRawBufferPointer(rebasing: pixels[(row * columns * 8)..<((row + 1) * columns * 8)]))
                    }
                }
            }
        }
        try handle.close()
        context.clearCaches()
        let provider = MappedTiles(data: try Data(contentsOf: url, options: .alwaysMapped), rowBytes: rowBytes)
        return CIImage(imageProvider: provider, size: width, height, format: .RGBAh, colorSpace: nil,
                       options: [.providerTileSize: [Self.tileSize, Self.tileSize]])
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    /// The blocks a ``tiledCopy(of:in:name:)`` is rendered in, and the tiles it's read back in.
    private static let copyBlock = 2048
    private static let tileSize = 512

    /// A merged bracket set's pixels (RGBA half floats, top row first) in a memory-mapped file, handed to Core
    /// Image a tile at a time.
    private final class MappedTiles: NSObject, @unchecked Sendable {
        let data: Data
        let rowBytes: Int

        init(data: Data, rowBytes: Int) {
            self.data = data
            self.rowBytes = rowBytes
        }

        /// Core Image's image provider callback: the tile at `x`, `y` (from the top left), `width` × `height`.
        override func provideImageData(
            _ destination: UnsafeMutableRawPointer, bytesPerRow: Int, origin x: Int, _ y: Int, size width: Int, _ height: Int,
            userInfo info: Any?
        ) {
            data.withUnsafeBytes { source in
                guard let base = source.baseAddress else { return }
                for row in 0..<height {
                    memcpy(destination + row * bytesPerRow, base + (y + row) * rowBytes + x * 8, width * 8)
                }
            }
        }
    }

    /// Everything for one merge as Core Image images on `canvas`: the finished panorama (opaque,
    /// white beyond the photos), where the photos cover it (red), and the blend before it's finished (premultiplied,
    /// for Fill Edges).
    /// `region` (Core Image's axes) is the part a render draws, when that's all it samples, so only the bracket
    /// sets there are merged into files.
    private func composite(
        _ analysis: Analysis, scale: CGFloat, canvas: CGRect, warp: WarpMap?, region: CGRect? = nil
    ) throws -> (image: CIImage, coverage: CIImage, blended: CIImage) {
        let layout = analysis.layout
        let drawn = region ?? canvas
        let sources = try sourceImages(scale: scale) { [self] index in
            !ciRect(pixelRect(layout.footprint(of: index), scale: scale, extent: canvas), canvasHeight: canvas.height)
                .intersection(drawn).isEmpty
        }
        let maskScale = CGAffineTransform(scaleX: canvas.width / CGFloat(analysis.width), y: canvas.height / CGFloat(analysis.height))
        var photos: [BlendPhoto] = []
        for index in frames.indices where layout.cameras[index] != nil {
            guard let mask = analysis.masks[index], let feather = analysis.feathers[index] else { continue }
            let footprint = ciRect(pixelRect(layout.footprint(of: index), scale: scale, extent: canvas), canvasHeight: canvas.height)
            guard !footprint.isEmpty else { continue }
            let warped = warpedPhoto(index, layout: layout, scale: scale, canvas: canvas, sources: sources)
            photos.append(BlendPhoto(image: warped, mask: mask.transformed(by: maskScale).cropped(to: footprint),
                                     feather: feather.transformed(by: maskScale)))
        }
        let levels = max(1, Int((Double(Self.fullResolutionLevels) + log2(Double(scale))).rounded()))
        var blended = Self.blend(photos, canvas: canvas, levels: levels)
        var coverage = Self.blank(canvas)
        for photo in photos {
            coverage = PanoramaKernels.coverage.apply(extent: canvas, arguments: [coverage, photo.image]) ?? coverage
        }
        if let warp {
            blended = Self.boundaryWarped(blended, map: warp, canvas: canvas)
            coverage = Self.boundaryWarped(coverage, map: warp, canvas: canvas)
        }
        let fill = CIVector(x: CGFloat(peakValue), y: CGFloat(peakValue), z: CGFloat(peakValue))
        let finished = PanoramaKernels.finish.apply(extent: canvas, arguments: [blended, coverage, fill]) ?? blended
        return (finished, coverage, blended)
    }

    /// A photo warped onto the panorama at `scale`, scaled by its gains: premultiplied, its alpha
    /// where it covers.
    private func warpedPhoto(_ index: Int, layout: PanoramaLayout, scale: CGFloat, canvas: CGRect, sources: [CIImage]) -> CIImage {
        let source = sources[index]
        let size = source.extent.size
        let k = CGFloat(gain(index))
        let gained = source.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
        ])
        guard let fullCamera = layout.cameras[index] else { return CIImage.empty() }
        let camera = fullCamera.scaled(by: Double(size.width / nativeSize.width))
        let footprint = ciRect(pixelRect(layout.footprint(of: index), scale: scale, extent: canvas), canvasHeight: canvas.height)
        let mapping = WarpMapping(layout: layout, camera: camera, sourceSize: size, scale: Double(scale), canvasHeight: Double(canvas.height))
        let r = camera.rotation
        func row(_ i: Int) -> CIVector { CIVector(x: r[0, i], y: r[1, i], z: r[2, i]) }
        let arguments: [Any] = [
            row(0), row(1), row(2),
            CIVector(x: camera.focalLength, y: size.width / 2, z: size.height / 2, w: size.height),
            CIVector(x: layout.scale * Double(scale), y: layout.origin.x, z: layout.origin.y, w: Double(canvas.height)),
            layout.projection.kernelIndex,
        ]
        return PanoramaKernels.warp.apply(
            extent: footprint, roiCallback: { _, rect in mapping.sourceRect(for: rect) }, image: gained, arguments: arguments
        ) ?? CIImage.empty()
    }

    /// The CPU side of the warp kernel, for telling Core Image which part of a photo a region needs.
    struct WarpMapping: Sendable {
        let layout: PanoramaLayout
        let camera: PanoramaCamera
        let sourceSize: CGSize
        let scale: Double
        let canvasHeight: Double

        /// The photo's pixels (Core Image's axes) a region of the panorama (Core Image's axes) samples.
        func sourceRect(for rect: CGRect) -> CGRect {
            var low = SIMD2<Double>(repeating: .infinity), high = SIMD2<Double>(repeating: -.infinity)
            let steps = 8
            for i in 0...steps {
                for j in 0...steps {
                    let x = Double(rect.minX) + Double(rect.width) * Double(i) / Double(steps)
                    let y = Double(rect.minY) + Double(rect.height) * Double(j) / Double(steps)
                    let pixel = SIMD2(x, canvasHeight - y) / scale
                    guard let p = camera.project(layout.ray(at: pixel)) else { continue }
                    let source = SIMD2(Double(sourceSize.width) / 2 + p.x, Double(sourceSize.height) / 2 - p.y)
                    low = simd_min(low, source)
                    high = simd_max(high, source)
                }
            }
            // Core Image only provides the pixels asked for, and repeats the edge of what it provides
            // beyond that: asking for a few transparent pixels around the photo keeps it from
            // smearing its edges outward.
            let around = CGRect(origin: .zero, size: sourceSize).insetBy(dx: -4, dy: -4)
            guard low.x.isFinite else { return CGRect(x: around.minX, y: around.minY, width: 1, height: 1) }
            // A margin for interpolation, and for the curve between the sampled points.
            let margin = max(4, (high.x - low.x + high.y - low.y) * 0.02)
            let bounds = CGRect(x: low.x - margin, y: low.y - margin, width: high.x - low.x + 2 * margin, height: high.y - low.y + 2 * margin)
            let clipped = bounds.intersection(around)
            return clipped.isNull ? CGRect(x: around.minX, y: around.minY, width: 1, height: 1) : clipped
        }
    }

    /// A warped photo with its seam mask and coarsest-band weight, on the canvas.
    struct BlendPhoto {
        var image: CIImage
        var mask: CIImage
        var feather: CIImage
    }

    /// Multiband blending (Burt and Adelson): each photo's Laplacian pyramid, each level weighted by
    /// its mask blurred to that level, summed, and the pyramid collapsed. Fine detail switches photo
    /// sharply at the seam; broader brightness changes blend over wider bands, and the coarsest
    /// (vignetting, a sky's gradient) is feathered across the whole overlap.
    static func blend(_ photos: [BlendPhoto], canvas: CGRect, levels: Int) -> CIImage {
        guard !photos.isEmpty else { return blank(canvas) }
        var extents = [canvas]
        for _ in 0..<levels {
            let last = extents[extents.count - 1]
            extents.append(CGRect(x: last.minX / 2, y: last.minY / 2, width: last.width / 2, height: last.height / 2).integral)
        }
        func down(_ image: CIImage, to extent: CGRect) -> CIImage { halved(image).cropped(to: extent) }
        // Kernels reading a coarser level at half the coordinates: its rect is half the output's, and a pixel more.
        func upROI(coarserIndex: Int32) -> CIKernelROICallback {
            { index, rect in
                index == coarserIndex
                    ? CGRect(x: rect.minX / 2, y: rect.minY / 2, width: rect.width / 2, height: rect.height / 2).insetBy(dx: -1, dy: -1)
                    : rect
            }
        }
        var bands = extents.map { blank($0) }
        for photo in photos {
            var image = photo.image.cropped(to: canvas)
            var mask = photo.mask
            for level in 0..<levels {
                let next = down(image, to: extents[level + 1])
                bands[level] = PanoramaKernels.addBandUp.apply(
                    extent: extents[level], roiCallback: upROI(coarserIndex: 2),
                    arguments: [bands[level], image, next, mask]
                ) ?? bands[level]
                image = next
                if level + 1 < levels { mask = down(mask, to: extents[level + 1]) }
            }
            let scale = 1 / CGFloat(1 << levels)
            let feather = photo.feather.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).cropped(to: extents[levels])
            bands[levels] = PanoramaKernels.addLevel.apply(extent: extents[levels], arguments: [bands[levels], image, feather]) ?? bands[levels]
        }
        var result = bands[levels]
        for level in stride(from: levels - 1, through: 0, by: -1) {
            result = PanoramaKernels.addUp.apply(
                extent: extents[level], roiCallback: upROI(coarserIndex: 0), arguments: [result, bands[level]]
            ) ?? result
        }
        return result
    }

    /// `image` at half size for the blend's pyramid (see `panoramaHalve`). Beyond its edges it repeats them, so every
    /// level is defined wherever a kernel reads.
    static func halved(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let half = CGRect(x: extent.minX / 2, y: extent.minY / 2, width: extent.width / 2, height: extent.height / 2).integral
        return PanoramaKernels.halve.apply(extent: half, roiCallback: { _, rect in
            CGRect(x: rect.minX * 2, y: rect.minY * 2, width: rect.width * 2, height: rect.height * 2).insetBy(dx: -3, dy: -3)
        }, arguments: [image.clampedToExtent()]) ?? image
    }

    /// `image` bent by Boundary Warp's map.
    private static func boundaryWarped(_ image: CIImage, map: WarpMap, canvas: CGRect) -> CIImage {
        let points = map.points, mapWidth = map.width, mapHeight = map.height
        let canvasWidth = Double(canvas.width), canvasHeight = Double(canvas.height)
        let mx = Double(mapWidth) / canvasWidth, my = Double(mapHeight) / canvasHeight
        let mapExtent = map.image.extent
        let roi: CIKernelROICallback = { index, rect in
            guard index == 0 else { return mapExtent }
            // The unwarped points the map sends this region to.
            let top = canvasHeight - Double(rect.maxY), bottom = canvasHeight - Double(rect.minY)
            let x0 = max(0, Int((Double(rect.minX) * mx).rounded(.down)) - 1), x1 = min(mapWidth - 1, Int((Double(rect.maxX) * mx).rounded(.up)) + 1)
            let y0 = max(0, Int((top * my).rounded(.down)) - 1), y1 = min(mapHeight - 1, Int((bottom * my).rounded(.up)) + 1)
            guard x0 <= x1, y0 <= y1 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
            var low = SIMD2<Float>(repeating: .infinity), high = SIMD2<Float>(repeating: -.infinity)
            for y in y0...y1 {
                for x in x0...x1 {
                    guard let p = points[y * mapWidth + x] else { continue }
                    low = simd_min(low, p)
                    high = simd_max(high, p)
                }
            }
            guard low.x.isFinite else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
            let margin = 3 / mx
            let minX = Double(low.x) * canvasWidth - margin, maxX = Double(high.x) * canvasWidth + margin
            let minY = canvasHeight - Double(high.y) * canvasHeight - margin, maxY = canvasHeight - Double(low.y) * canvasHeight + margin
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        return PanoramaKernels.boundaryWarp.apply(
            extent: canvas, roiCallback: roi,
            arguments: [image, map.image, CIVector(x: canvas.width, y: canvas.height, z: CGFloat(mapWidth), w: CGFloat(mapHeight))]
        ) ?? image
    }

    static func blank(_ extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
    }

    /// A footprint (full-resolution pixels from the top left) at `scale`, in whole pixels, inside `extent`.
    private func pixelRect(_ rect: CGRect, scale: CGFloat, extent: CGRect) -> CGRect {
        guard !rect.isNull else { return .zero }
        let scaled = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        let r = scaled.insetBy(dx: -2, dy: -2).integral.intersection(extent)
        return r.isNull ? .zero : r
    }

    /// A rectangle from the top left as Core Image's (origin bottom left).
    private func ciRect(_ rect: CGRect, canvasHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: canvasHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    // MARK: - Rendering

    /// Renders `image` as interleaved RGB half floats, top row first, clipped to 0…1, in blocks (so
    /// Core Image decodes only the parts of the photos each needs, and for progress and cancellation).
    private func renderRGB(_ image: CIImage, extent: CGRect, progress: (Double) -> Void) throws -> [Float16] {
        let width = Int(extent.width), height = Int(extent.height)
        let clean = image.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
        let block = 4096
        var output = [Float16](repeating: 0, count: width * height * 3)
        let blockWidth = min(block, width)
        var buffer = [Float16](repeating: 0, count: blockWidth * min(block, height) * 4)
        var done = 0
        for top in stride(from: 0, to: height, by: block) {
            let rows = min(block, height - top)
            for left in stride(from: 0, to: width, by: block) {
                try Task.checkCancellation()
                let columns = min(block, width - left)
                // Core Image's origin is the bottom left; blocks go top down.
                let bounds = CGRect(x: left, y: height - top - rows, width: columns, height: rows)
                context.render(clean, toBitmap: &buffer, rowBytes: columns * 8, bounds: bounds, format: .RGBAh, colorSpace: Self.colorSpace)
                buffer.withUnsafeMutableBytes { source in
                    output.withUnsafeMutableBytes { destination in
                        var from = vImage_Buffer(data: source.baseAddress, height: vImagePixelCount(rows), width: vImagePixelCount(columns), rowBytes: columns * 8)
                        var to = vImage_Buffer(
                            data: destination.baseAddress! + (top * width + left) * 6, height: vImagePixelCount(rows),
                            width: vImagePixelCount(columns), rowBytes: width * 6
                        )
                        vImageConvert_RGBA16UtoRGB16U(&from, &to, vImage_Flags(kvImageNoFlags))
                    }
                }
                done += rows * columns
                progress(Double(done) / Double(width * height))
            }
        }
        return output
    }

    /// The coverage image's red, top row first.
    private func renderCoverage(_ image: CIImage, extent: CGRect) -> PanoramaCoverage {
        let width = Int(extent.width), height = Int(extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &pixels, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: nil)
        return PanoramaCoverage(width: width, height: height, values: stride(from: 0, to: pixels.count, by: 4).map { min(max(pixels[$0], 0), 1) })
    }
}

/// The Core Image kernels in PanoramaKernels.ci.metal.
nonisolated enum PanoramaKernels {
    static let warp = load(name: "panoramaWarp") { try CIWarpKernel(functionName: $0, fromMetalLibraryData: $1) }
    static let addLevel = color("panoramaAddLevel")
    static let add = color("panoramaAdd")
    static let coverage = color("panoramaCoverage")
    static let finish = color("panoramaFinish")
    static let halve = load(name: "panoramaHalve") { try CIKernel(functionName: $0, fromMetalLibraryData: $1) }
    static let addBandUp = load(name: "panoramaAddBandUp") { try CIKernel(functionName: $0, fromMetalLibraryData: $1) }
    static let addUp = load(name: "panoramaAddUp") { try CIKernel(functionName: $0, fromMetalLibraryData: $1) }
    static let boundaryWarp = load(name: "panoramaBoundaryWarp") { try CIKernel(functionName: $0, fromMetalLibraryData: $1) }
    static let fillMix = color("panoramaFillMix")
    static let fillReconstruct = load(name: "panoramaFillReconstruct") { try CIKernel(functionName: $0, fromMetalLibraryData: $1) }

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

