import Accelerate
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

/// Photo ▸ Photo Merge ▸ HDR's settings. The defaults are Lightroom's; the last ones used are
/// remembered for the next merge.
nonisolated struct HDRMergeOptions: Codable, Equatable, Sendable {
    enum Deghost: Int, Codable, CaseIterable, Sendable {
        case none, low, medium, high

        var title: String {
            switch self {
            case .none: "None"
            case .low: "Low"
            case .medium: "Medium"
            case .high: "High"
            }
        }

        /// The largest difference between two exposures' brightness (natural log of the radiance
        /// ratio) still taken as the same scene; more than that is something that moved.
        var tolerance: Float? {
            switch self {
            case .none: nil
            case .low: 0.7
            case .medium: 0.45
            case .high: 0.25
            }
        }
    }

    var autoAlign = true
    var autoSettings = true
    var deghost = Deghost.none
    var showsDeghostOverlay = false
    var createsStack = false

    private static let defaultsKey = "HDRMergeOptions"

    static func load(from defaults: UserDefaults = Defaults.store) -> HDRMergeOptions {
        guard let data = defaults.data(forKey: defaultsKey),
              let options = try? JSONDecoder().decode(HDRMergeOptions.self, from: data) else { return HDRMergeOptions() }
        return options
    }

    func save(to defaults: UserDefaults = Defaults.store) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}

/// Where the merge found something moving between exposures (Deghost), 0…1, top row first.
nonisolated struct GhostMask: @unchecked Sendable {
    var width: Int
    var height: Int
    var values: [Float]
    /// The same mask as an image (gray, origin at zero). CIImage is immutable.
    var image: CIImage

    /// The mask at a point given as fractions of the width and height (0…1, from the top left),
    /// interpolated between samples.
    func value(atX x: Double, y: Double) -> Float {
        let fx = Float(x) * Float(width) - 0.5, fy = Float(y) * Float(height) - 0.5
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = fx - Float(x0), ty = fy - Float(y0)
        func sample(_ x: Int, _ y: Int) -> Float {
            values[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
        }
        let top = sample(x0, y0) * (1 - tx) + sample(x0 + 1, y0) * tx
        let bottom = sample(x0, y0 + 1) * (1 - tx) + sample(x0 + 1, y0 + 1) * tx
        return top * (1 - ty) + bottom * ty
    }

    /// The mask stretched to `size`, origin at zero.
    func image(size: CGSize) -> CIImage {
        image.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: size.width / CGFloat(width), y: size.height / CGFloat(height)))
            .cropped(to: CGRect(origin: .zero, size: size))
    }
}

nonisolated struct HDRMergeResult: Sendable {
    /// Scene radiance relative to the reference exposure (its white is 1).
    var image: LinearDNGImage
    /// Where Deghost took one exposure alone; nil when Deghost is off.
    var ghostMask: GhostMask?
}

/// Merges bracketed RAW exposures into one high-dynamic-range image, as Lightroom's Photo Merge ▸ HDR.
///
/// Each exposure is decoded linearly by the RAW engine (no tone curve, shadow bias or baseline
/// exposure) with the reference exposure's white balance, then scaled by its exposure so they all
/// measure the same scene radiance. Every pixel is a weighted average: well-exposed values count most,
/// longer exposures count more (less noise), and values near clipping count for nothing. Auto Align
/// registers each exposure to the reference (a translation found by Vision). Deghost finds where
/// exposures disagree about the scene, because something moved, and uses one exposure alone there.
/// Auto Settings tone maps the result so its highlights and shadows both show, as Lightroom's HDR
/// merge does. The pixel work runs on the GPU, in Core Image kernels (HDRMergeKernels.ci.metal).
///
/// Not thread-safe: use one instance per task.
nonisolated final class HDRMerger {
    struct Frame {
        let source: PhotoMergeSource
        fileprivate let filter: CIRAWFilter
        /// How much brighter the exposure is than the reference (1 for the reference itself).
        fileprivate(set) var gain: Double
    }

    /// The exposures, darkest first.
    private(set) var frames: [Frame]
    /// The middle exposure: its white balance, look and metadata are the merged photo's.
    let referenceIndex: Int
    var reference: PhotoMergeSource { frames[referenceIndex].source }
    let nativeSize: CGSize
    /// Something worth knowing before merging (the exposures barely differ), or nil.
    let warning: String?

    /// The white balance every exposure is decoded with: the reference's, or a panorama's (see ``radiance(scale:)``).
    var neutral: (temperature: Float, tint: Float)
    /// Whether the RAW engine applies the camera's built-in lens profile, when it has one (nil leaves its default).
    var builtInLensCorrection: Bool?
    private let cameraBaselineExposure: Double
    private let context = CIContext(options: [
        .workingColorSpace: HDRMerger.colorSpace, .cacheIntermediates: false,
    ])
    /// Each frame's offset onto the reference, in full-resolution pixels, once found.
    private var offsets: [CGVector]?
    /// Auto Settings' tone mapping, once measured, with and without Auto Align.
    private var toneMaps: [Bool: ToneMap] = [:]
    /// The exposures decoded at one scale, as pixels (see ``prepare(scale:)``).
    private var prepared: (scale: CGFloat, images: [CIImage])?

    static let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!

    /// Values outside this range say little about the scene (noise, or near clipping).
    private static let usableRange: ClosedRange<Float> = 0.03...0.9
    private static let bandRows = 512

    init(sources: [PhotoMergeSource]) throws {
        if let problem = PhotoMergeSource.problem(merging: sources) { throw problem }
        var frames: [Frame] = []
        var size: CGSize?
        for source in sources {
            guard let filter = CIRAWFilter(imageURL: source.url), let output = filter.outputImage else {
                throw PhotoMergeError.unreadable(source.name)
            }
            guard size == nil || size == output.extent.size else { throw PhotoMergeError.differentSizes }
            size = output.extent.size
            frames.append(Frame(source: source, filter: filter, gain: 1))
        }
        nativeSize = size ?? .zero

        let metered = sources.allSatisfy { $0.exposureTime > 0 && $0.aperture > 0 && $0.iso > 0 }
        if metered {
            for index in frames.indices {
                let source = frames[index].source
                frames[index].gain = source.exposureTime * Double(source.iso) / (source.aperture * source.aperture)
            }
            frames.sort { $0.gain < $1.gain }
        } else {
            frames = Self.estimatingGains(frames)
        }
        referenceIndex = (frames.count - 1) / 2
        let referenceGain = frames[referenceIndex].gain
        for index in frames.indices { frames[index].gain /= referenceGain }
        self.frames = frames

        let spread = (frames.last?.gain ?? 1) / (frames.first?.gain ?? 1)
        warning = spread < pow(2, 0.3)
            ? "These photos have about the same exposure, so merging them adds little dynamic range."
            : nil

        let referenceFilter = frames[referenceIndex].filter
        neutral = (referenceFilter.neutralTemperature, referenceFilter.neutralTint)
        cameraBaselineExposure = Double(referenceFilter.baselineExposure)
    }

    /// What the merged DNG records about the shot: the reference exposure's.
    func dngMetadata() -> DNGMetadata {
        let source = reference
        return DNGMetadata(
            make: source.make, model: source.model, lensModel: source.lensModel, captureDate: source.captureDate,
            exposureTime: source.exposureTime, aperture: source.aperture, iso: source.iso,
            focalLength: source.focalLength, baselineExposure: cameraBaselineExposure
        )
    }

    /// Whether the RAW engine has a built-in lens profile for these photos.
    var isLensCorrectionSupported: Bool { frames[referenceIndex].filter.isLensCorrectionSupported }

    // MARK: - Merging

    /// Decodes every exposure at `scale` side by side (the RAW engine decodes several photos at once much
    /// faster than one after another) and keeps the pixels, for ``radiance(scale:)`` at that scale and for
    /// Auto Align, until ``forgetPrepared()``.
    func prepare(scale: CGFloat) {
        let images = PreparedImages(count: frames.count, filters: frames.map(\.filter))
        let neutral = neutral, lens = builtInLensCorrection, context = context
        DispatchQueue.concurrentPerform(iterations: frames.count) { index in
            // Each frame's own filter: no two threads share one.
            let image = Self.decoded(images.filters[index], scale: scale, neutral: neutral, lensCorrection: lens)
            let extent = CGRect(origin: image.extent.origin, size: image.extent.integral.size)
            let rowBytes = Int(extent.width) * 8
            var data = Data(count: rowBytes * Int(extent.height))
            data.withUnsafeMutableBytes { buffer in
                context.render(image, toBitmap: buffer.baseAddress!, rowBytes: rowBytes, bounds: extent, format: .RGBAh, colorSpace: nil)
            }
            let pixels = CIImage(bitmapData: data, bytesPerRow: rowBytes, size: extent.size, format: .RGBAh, colorSpace: nil)
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            images.store(pixels, at: index)
        }
        prepared = (scale, images.values.map { $0 ?? CIImage.empty() })
    }

    /// Lets go of the pixels ``prepare(scale:)`` kept.
    func forgetPrepared() {
        prepared = nil
    }

    /// The decoding side by side: each frame's filter, and what it produced.
    private final class PreparedImages: @unchecked Sendable {
        let filters: [CIRAWFilter]
        private let lock = NSLock()
        private(set) var values: [CIImage?]

        init(count: Int, filters: [CIRAWFilter]) {
            self.filters = filters
            values = Array(repeating: nil, count: count)
        }

        func store(_ image: CIImage, at index: Int) { lock.withLock { values[index] = image } }
    }

    /// The exposures merged at `scale`, for a panorama of bracket sets: aligned (Auto Align), without
    /// deghosting or tone mapping, at the reference exposure's brightness (not scaled to fit its peak, so
    /// sets merged this way stay comparable), origin at zero. Nothing is rendered but the alignment.
    func radiance(scale: CGFloat) -> CIImage {
        radiance(of: alignedImages(scale: scale, offsets: alignmentOffsets()))
    }

    /// Merges the exposures at `scale` (1 = full resolution), on the GPU. With Auto Settings the
    /// result is tone mapped (``ToneMap``). `region` (pixels at that scale, from the top left) limits
    /// it to part of the photo, for zooming in; `headroom` then gives the whole merge's, so the part
    /// renders as it does in the whole. `progress` gets the fraction done. Throws `CancellationError`
    /// when the task is cancelled.
    func merge(
        options: HDRMergeOptions, scale: CGFloat, region: CGRect? = nil, headroom: Double? = nil,
        progress: (Double) -> Void = { _ in }
    ) throws -> HDRMergeResult {
        let offsets = options.autoAlign ? alignmentOffsets() : Array(repeating: .zero, count: frames.count)
        try Task.checkCancellation()
        // What's measured at other scales first: decoding at another scale changes the RAW filters' settings.
        let mask = try options.deghost.tolerance.map { tolerance in
            try ghostMask(offsets: offsets, tolerance: tolerance, scale: scale)
        }
        let tone = options.autoSettings ? cachedToneMap(offsets: offsets, aligned: options.autoAlign) : nil
        try Task.checkCancellation()
        progress(0.1)

        let images = alignedImages(scale: scale, offsets: offsets)
        var extent = images[referenceIndex].extent
        var merged = radiance(of: images)
        if let mask {
            merged = deghosted(merged, images: images, mask: mask.image(size: extent.size))
        }
        if let tone { merged = tone.apply(to: merged) }
        if let region {
            // Core Image's origin is the bottom left.
            let part = CGRect(x: region.minX, y: extent.height - region.maxY, width: region.width, height: region.height)
                .integral.intersection(extent)
            merged = merged.cropped(to: part).transformed(by: CGAffineTransform(translationX: -part.minX, y: -part.minY))
            extent = CGRect(origin: .zero, size: part.size)
        }

        // Stored with the brightest value at 1; the DNG's BaselineExposure brings it back. The RAW
        // engine's default rendering depends on that headroom, so a tone-mapped merge gets a fixed one.
        // Otherwise the peak is measured at 1024 pixels across, where single hot pixels average out, so
        // the preview and the full merge get the same headroom. Anything brighter clips.
        let peak = tone != nil ? exp2(ToneMap.headroom)
            : headroom.map { Float(exp2($0)) }
            ?? peakValue(of: merged.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: min(1, 1024 / max(extent.width, extent.height)), kCIInputAspectRatioKey: 1,
            ]))
        if peak > 1 {
            let k = CGFloat(1 / peak)
            merged = merged.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            ])
        }
        let pixels = try renderRGB(merged, extent: extent) { progress(0.1 + 0.9 * $0) }
        let image = LinearDNGImage(
            width: Int(extent.width), height: Int(extent.height), pixels: pixels,
            headroom: LinearDNGWriter.headroom(peak: peak)
        )
        return HDRMergeResult(image: image, ghostMask: mask)
    }

    /// The order exposures are trusted in alone: the reference, then outward from it.
    private var preferenceOrder: [Int] {
        var order = [referenceIndex]
        for distance in 1..<max(frames.count, 2) {
            for index in [referenceIndex - distance, referenceIndex + distance] where frames.indices.contains(index) {
                order.append(index)
            }
        }
        return order
    }

    private func blank(_ extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
    }

    /// Every exposure's radiance, weighted: well-exposed values count most, longer exposures count
    /// more (less noise), values near clipping count for nothing. Where everything is clipped, the
    /// darkest exposure is all there is.
    private func radiance(of images: [CIImage]) -> CIImage {
        let extent = images[referenceIndex].extent
        var sum = blank(extent), total = blank(extent)
        for (index, image) in images.enumerated() {
            let gain = frames[index].gain
            sum = HDRKernels.accumulateColor.apply(extent: extent, arguments: [sum, image, gain]) ?? sum
            total = HDRKernels.accumulateWeight.apply(extent: extent, arguments: [total, image, gain]) ?? total
        }
        return HDRKernels.resolve.apply(extent: extent, arguments: [sum, total, images[0], frames[0].gain]) ?? sum
    }

    /// Where the mask is on, one exposure alone: the reference where it's usable, otherwise the
    /// nearest usable one (the darkest for a clipped highlight, the brightest for deep shadow).
    private func deghosted(_ merged: CIImage, images: [CIImage], mask: CIImage) -> CIImage {
        let extent = merged.extent
        var chosen = blank(extent), found = blank(extent)
        for index in preferenceOrder {
            chosen = HDRKernels.pickColor.apply(extent: extent, arguments: [chosen, found, images[index], frames[index].gain]) ?? chosen
            found = HDRKernels.pickFound.apply(extent: extent, arguments: [found, images[index]]) ?? found
        }
        let last = frames.count - 1
        let single = HDRKernels.pickFallback.apply(extent: extent, arguments: [
            chosen, found, images[referenceIndex], images[0], frames[0].gain, images[last], frames[last].gain,
        ]) ?? chosen
        return HDRKernels.blendGhost.apply(extent: extent, arguments: [merged, single, mask]) ?? merged
    }

    /// The brightest value in any channel (capped, so a stray infinity can't swamp the rest).
    private func peakValue(of image: CIImage) -> Float {
        let capped = image.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 60_000, y: 60_000, z: 60_000, w: 1),
        ])
        let maximum = capped.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(maximum, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: Self.colorSpace)
        let peak = max(pixel[0], pixel[1], pixel[2])
        return peak.isFinite ? peak : 1
    }

    /// Renders `image` as interleaved RGB half floats, top row first, in bands (for progress and
    /// cancellation). vImage drops the alpha channel.
    private func renderRGB(_ image: CIImage, extent: CGRect, progress: (Double) -> Void) throws -> [Float16] {
        let width = Int(extent.width), height = Int(extent.height)
        let clean = image.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
        var output = [Float16](repeating: 0, count: width * height * 3)
        var band = [Float16](repeating: 0, count: width * Self.bandRows * 4)
        for top in stride(from: 0, to: height, by: Self.bandRows) {
            try Task.checkCancellation()
            let rows = min(Self.bandRows, height - top)
            // Core Image's origin is the bottom left; bands go top down.
            let bounds = CGRect(x: 0, y: height - top - rows, width: width, height: rows)
            context.render(clean, toBitmap: &band, rowBytes: width * 8, bounds: bounds, format: .RGBAh, colorSpace: Self.colorSpace)
            band.withUnsafeMutableBytes { source in
                output.withUnsafeMutableBytes { destination in
                    var from = vImage_Buffer(data: source.baseAddress, height: vImagePixelCount(rows), width: vImagePixelCount(width), rowBytes: width * 8)
                    var to = vImage_Buffer(
                        data: destination.baseAddress! + top * width * 6, height: vImagePixelCount(rows),
                        width: vImagePixelCount(width), rowBytes: width * 6
                    )
                    vImageConvert_RGBA16UtoRGB16U(&from, &to, vImage_Flags(kvImageNoFlags))
                }
            }
            progress(Double(top + rows) / Double(height))
        }
        return output
    }

    // MARK: - Decoding

    /// The frame decoded linearly at `scale`, with the reference's white balance (from the prepared pixels when
    /// they're at that scale, or larger and this is for Auto Align).
    private func image(of index: Int, scale: CGFloat, forAlignment: Bool = false) -> CIImage {
        if let prepared {
            if prepared.scale == scale { return prepared.images[index] }
            if forAlignment, prepared.scale > scale {
                return prepared.images[index].applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: scale / prepared.scale, kCIInputAspectRatioKey: 1,
                ])
            }
        }
        return Self.decoded(frames[index].filter, scale: scale, neutral: neutral, lensCorrection: builtInLensCorrection)
    }

    private static func decoded(
        _ filter: CIRAWFilter, scale: CGFloat, neutral: (temperature: Float, tint: Float), lensCorrection: Bool?
    ) -> CIImage {
        filter.scaleFactor = Float(scale)
        filter.exposure = 0
        filter.baselineExposure = 0
        filter.boostAmount = 0
        filter.shadowBias = 0
        filter.isGamutMappingEnabled = false
        filter.neutralTemperature = neutral.temperature
        filter.neutralTint = neutral.tint
        if let lensCorrection, filter.isLensCorrectionSupported { filter.isLensCorrectionEnabled = lensCorrection }
        return filter.outputImage ?? CIImage.empty()
    }

    /// Every frame at `scale`, moved onto the reference and cropped to its frame (edges a frame
    /// doesn't cover repeat its edge pixels), with the origin at zero.
    private func alignedImages(scale: CGFloat, offsets: [CGVector]) -> [CIImage] {
        let raw = frames.indices.map { image(of: $0, scale: scale) }
        let extent = raw[referenceIndex].extent
        let frame = CGRect(x: 0, y: 0, width: extent.width.rounded(.down), height: extent.height.rounded(.down))
        return raw.enumerated().map { index, image in
            image
                .transformed(by: CGAffineTransform(
                    translationX: offsets[index].dx * scale - image.extent.minX,
                    y: offsets[index].dy * scale - image.extent.minY
                ))
                .clampedToExtent()
                .cropped(to: frame)
        }
    }

    // MARK: - Exposure

    /// Orders frames by brightness and measures each one's exposure from the pixels, for files that
    /// don't record shutter speed, aperture and ISO: the median ratio between neighbors where both
    /// are well exposed.
    private static func estimatingGains(_ frames: [Frame]) -> [Frame] {
        let context = CIContext(options: [.workingColorSpace: colorSpace, .cacheIntermediates: false])
        let samples: [[Float]] = frames.map { frame in
            let filter = frame.filter
            let size = filter.outputImage?.extent.size ?? .zero
            filter.scaleFactor = Float(min(1, 512 / max(size.width, size.height, 1)))
            filter.baselineExposure = 0
            filter.boostAmount = 0
            filter.shadowBias = 0
            guard let image = filter.outputImage else { return [] }
            let extent = image.extent.integral
            var pixels = [Float](repeating: 0, count: Int(extent.width) * Int(extent.height) * 4)
            context.render(image, toBitmap: &pixels, rowBytes: Int(extent.width) * 16, bounds: extent, format: .RGBAf, colorSpace: colorSpace)
            return stride(from: 0, to: pixels.count, by: 4).map { (pixels[$0] + pixels[$0 + 1] + pixels[$0 + 2]) / 3 }
        }
        let order = frames.indices.sorted { mean(samples[$0]) < mean(samples[$1]) }
        var result = order.map { frames[$0] }
        var gain = 1.0
        result[0].gain = gain
        for position in 1..<order.count {
            let darker = samples[order[position - 1]], brighter = samples[order[position]]
            var ratios: [Float] = []
            for i in 0..<min(darker.count, brighter.count)
            where usableRange.contains(darker[i]) && usableRange.contains(brighter[i]) {
                ratios.append(brighter[i] / darker[i])
            }
            ratios.sort()
            gain *= ratios.isEmpty ? 2 : Double(ratios[ratios.count / 2])
            result[position].gain = gain
        }
        return result
    }

    private static func mean(_ values: [Float]) -> Float {
        values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count)
    }

    // MARK: - Alignment

    /// Each frame's translation onto the reference, in full-resolution pixels (Core Image's axes),
    /// found by Vision on downscaled copies. Each frame is registered to its neighbor toward the
    /// reference (the next exposure, which shows the most of the same detail) and the shifts add up:
    /// a frame six stops from the reference shares too little with it to register directly. A shift
    /// beyond `largestShift` of the long side is a failed registration and counts as none (handheld
    /// brackets move by far less). Each frame is decoded once and the pairs registered side by side.
    /// Found once and reused.
    func alignmentOffsets() -> [CGVector] {
        if let offsets { return offsets }
        let scale = min(1, 1024 / max(nativeSize.width, nativeSize.height, 1))
        let limit = Self.largestShift * max(nativeSize.width, nativeSize.height)
        let grays = frames.indices.map { gray($0, scale: scale) }
        let pairs = frames.indices.filter { $0 != referenceIndex }.map { index in
            (index: index, neighbor: index < referenceIndex ? index + 1 : index - 1)
        }
        let shifts = AlignmentShifts(count: frames.count)
        let gains = frames.map(\.gain)
        DispatchQueue.concurrentPerform(iterations: pairs.count) { position in
            let (index, neighbor) = pairs[position]
            guard let target = grays[neighbor], let floating = grays[index] else { return }
            // Compared up to the brightness where the brighter of the two clips, so both show the
            // same detail.
            let ceiling = Float(min(1, 1 / max(gains[index], gains[neighbor])))
            guard let targetImage = target.image(gain: Float(gains[neighbor]), ceiling: ceiling),
                  let floatingImage = floating.image(gain: Float(gains[index]), ceiling: ceiling) else { return }
            let request = VNTranslationalImageRegistrationRequest(targetedCGImage: floatingImage)
            let handler = VNImageRequestHandler(cgImage: targetImage)
            guard (try? handler.perform([request])) != nil, let transform = request.results?.first?.alignmentTransform,
                  hypot(transform.tx / scale, transform.ty / scale) <= limit else { return }
            shifts.set(CGVector(dx: transform.tx / scale, dy: transform.ty / scale), at: index)
        }
        var result = Array(repeating: CGVector.zero, count: frames.count)
        // Outward from the reference, so each neighbor's offset is known first.
        for index in preferenceOrder where index != referenceIndex {
            let neighbor = index < referenceIndex ? index + 1 : index - 1
            let shift = shifts.values[index]
            result[index] = CGVector(dx: result[neighbor].dx + shift.dx, dy: result[neighbor].dy + shift.dy)
        }
        offsets = result
        return result
    }

    /// The most a frame registers as moving from the next exposure, as a fraction of the long side.
    static let largestShift: CGFloat = 0.03

    /// Registration results, written from several threads.
    private final class AlignmentShifts: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var values: [CGVector]

        init(count: Int) { values = Array(repeating: .zero, count: count) }

        func set(_ shift: CGVector, at index: Int) { lock.withLock { values[index] = shift } }
    }

    /// A frame's brightness (the mean of its channels, as it was exposed) at a small size, for registration.
    private struct Gray: @unchecked Sendable {
        let width: Int
        let height: Int
        let values: [Float]

        /// Radiance up to `ceiling` as gamma-encoded gray, clipped there.
        func image(gain: Float, ceiling: Float) -> CGImage? {
            let k = 1 / (gain * ceiling)
            var bytes = [UInt8](repeating: 0, count: width * height)
            for i in values.indices {
                bytes[i] = UInt8(pow(min(max(values[i] * k, 0), 1), 1 / 2.2) * 255 + 0.5)
            }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        }
    }

    private func gray(_ index: Int, scale: CGFloat) -> Gray? {
        let image = image(of: index, scale: scale, forAlignment: true)
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &pixels, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: Self.colorSpace)
        let values = (0..<(width * height)).map { (pixels[$0 * 4] + pixels[$0 * 4 + 1] + pixels[$0 * 4 + 2]) / 3 }
        return Gray(width: width, height: height, values: values)
    }

    // MARK: - Deghosting

    /// Marks where the usable exposures disagree with the one trusted alone (the reference where
    /// it's usable) by more than `tolerance`, at up to 768 pixels on the long edge. Brightness is
    /// smoothed a little first so noise isn't taken for movement; specks are dropped, and the marks
    /// grown and softened so whole objects are covered with a soft edge.
    private func ghostMask(offsets: [CGVector], tolerance: Float, scale: CGFloat) throws -> GhostMask {
        let maskScale = min(scale, 768 / max(nativeSize.width, nativeSize.height, 1))
        let images = alignedImages(scale: maskScale, offsets: offsets)
        let extent = images[referenceIndex].extent
        let levels = images.enumerated().map { index, image in
            let level = HDRKernels.level.apply(extent: extent, arguments: [image, frames[index].gain]) ?? image
            return Self.filtered(level, "CIBoxBlur", radius: 2)
        }
        var anchor = blank(extent)
        for index in preferenceOrder {
            anchor = HDRKernels.pickLevel.apply(extent: extent, arguments: [anchor, levels[index]]) ?? anchor
        }
        var marks = blank(extent)
        // The kernel's levels are log2; the tolerance is in natural log.
        let tolerance = tolerance / Float(M_LN2)
        for level in levels {
            marks = HDRKernels.markGhosts.apply(extent: extent, arguments: [marks, level, anchor, tolerance]) ?? marks
        }
        let radius = max(1, max(extent.width, extent.height) / 160)
        let despeckled = Self.filtered(Self.filtered(marks, "CIMorphologyMinimum", radius: 1), "CIMorphologyMaximum", radius: 1)
        let grown = Self.filtered(Self.filtered(despeckled, "CIMorphologyMaximum", radius: radius), "CIBoxBlur", radius: radius)
        try Task.checkCancellation()

        let snapshot = snapshot(grown, extent: extent)
        return GhostMask(width: Int(extent.width), height: Int(extent.height), values: render(snapshot, extent: extent), image: snapshot)
    }

    /// A neighborhood filter applied without darkening or growing the image's edges.
    static func filtered(_ image: CIImage, _ name: String, radius: CGFloat) -> CIImage {
        image.clampedToExtent().applyingFilter(name, parameters: [kCIInputRadiusKey: radius]).cropped(to: image.extent)
    }

    // MARK: - Tone mapping

    private func cachedToneMap(offsets: [CGVector], aligned: Bool) -> ToneMap {
        if let toneMap = toneMaps[aligned] { return toneMap }
        let toneMap = toneMap(offsets: offsets)
        toneMaps[aligned] = toneMap
        return toneMap
    }

    /// Auto Settings' tone mapping, measured on a merge at 1024 pixels across (the same for the
    /// preview and the full merge): the scene's brightness split into an edge-aware base layer and
    /// detail, the base layer's range compressed so highlights and shadows both fit, the detail kept.
    func toneMap(offsets: [CGVector]) -> ToneMap {
        let statsScale = min(1, 1024 / max(nativeSize.width, nativeSize.height, 1))
        let radiance = radiance(of: alignedImages(scale: statsScale, offsets: offsets))
        let extent = radiance.extent

        // Log luminance, from 2^-20 to 2^20, at 256 pixels across, to find the scene's range.
        let wide = (HDRKernels.logLuminance.apply(extent: extent, arguments: [radiance, -20, 40]) ?? radiance)
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: 256 / max(extent.width, extent.height), kCIInputAspectRatioKey: 1,
            ])
        let levels = render(wide, extent: wide.extent.integral).map { $0 * 40 - 20 }.sorted()
        let low = levels[levels.count / 200], high = levels[levels.count * 199 / 200]
        let range = max(high - low, 1)

        // The base layer: the brightness at 64 pixels across, blurred, then brought back up to this
        // size along the edges of the full picture.
        let guide = HDRKernels.logLuminance.apply(extent: extent, arguments: [radiance, low, range]) ?? radiance
        let small = guide.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: 64 / max(extent.width, extent.height), kCIInputAspectRatioKey: 1,
        ])
        let smallExtent = small.extent.integral
        let blurred = Self.filtered(small.cropped(to: smallExtent), "CIGaussianBlur", radius: 2)
        let smallBase = snapshot(blurred, extent: smallExtent)
        let coarse = render(smallBase, extent: smallBase.extent).sorted()
        func level(at fraction: Double) -> Float { coarse[Int(Double(coarse.count - 1) * fraction)] * range + low }
        let anchor = level(at: 0.5)
        let spread = max(level(at: 0.95) - level(at: 0.05), 0.5)

        let upsample = CIFilter.edgePreserveUpsample()
        upsample.inputImage = guide
        upsample.smallImage = smallBase
        upsample.spatialSigma = 5
        upsample.lumaSigma = 0.1
        let base = snapshot((upsample.outputImage ?? guide).cropped(to: extent), extent: extent)
        return ToneMap(
            low: low, range: range, anchor: anchor,
            target: log2(ToneMap.middle) - Float(cameraBaselineExposure),
            compression: min(max(ToneMap.targetSpread / spread, 0.3), 1),
            base: base
        )
    }

    /// `image` rendered once and kept as pixels (origin at zero, not color managed), so it no longer
    /// depends on the RAW filters, whose settings change as other scales are decoded.
    private func snapshot(_ image: CIImage, extent: CGRect) -> CIImage {
        let rowBytes = Int(extent.width) * 16
        var data = Data(count: rowBytes * Int(extent.height))
        data.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: rowBytes, bounds: extent, format: .RGBAf, colorSpace: nil)
        }
        return CIImage(bitmapData: data, bytesPerRow: rowBytes, size: extent.size, format: .RGBAf, colorSpace: nil)
    }

    /// One channel (red) of `image`, top row first.
    private func render(_ image: CIImage, extent: CGRect) -> [Float] {
        var pixels = [Float](repeating: 0, count: Int(extent.width) * Int(extent.height) * 4)
        context.render(image, toBitmap: &pixels, rowBytes: Int(extent.width) * 16, bounds: extent, format: .RGBAf, colorSpace: nil)
        return stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }
    }
}

/// Auto Settings' tone mapping for one merge (see ``HDRMerger``). The constants were matched to
/// Lightroom Classic's HDR merges with Auto Settings: brightness percentiles, saturation and color
/// balance of the same bracket rendered both ways.
nonisolated struct ToneMap {
    /// How many stops the base layer's middle 90% spans after compression.
    static let targetSpread: Float = 3.5
    /// Where the midtones land (linear), before the camera's own baseline exposure.
    static let middle: Float = 0.2
    /// Highlights more than this many stops over the midtones roll off…
    static let knee: Float = 1.5
    /// …rising by this much per stop.
    static let shoulder: Float = 0.4
    /// Stops above the reference white the merged DNG stores, the rest clipped. Fixed, because the RAW
    /// engine's default rendering depends on it (more headroom renders darker and more saturated).
    static let headroom: Float = 3

    var low: Float
    var range: Float
    var anchor: Float
    var target: Float
    var compression: Float
    /// The base layer at up to 1024 pixels across: log luminance mapped from low…low + range to 0…1.
    var base: CIImage

    func apply(to radiance: CIImage) -> CIImage {
        let extent = radiance.extent
        // The base layer is smooth, so stretching it (with linear sampling) loses nothing that matters.
        let fullBase = base.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: extent.width / base.extent.width, y: extent.height / base.extent.height))
            .cropped(to: extent)
        return HDRKernels.toneMap.apply(extent: extent, arguments: [
            radiance, fullBase, low, range, anchor, target, compression, Self.knee, Self.shoulder,
        ]) ?? radiance
    }
}

/// The Core Image kernels in HDRMergeKernels.ci.metal.
nonisolated enum HDRKernels {
    static let accumulateColor = kernel("hdrAccumulateColor")
    static let accumulateWeight = kernel("hdrAccumulateWeight")
    static let resolve = kernel("hdrResolve")
    static let pickColor = kernel("hdrPickColor")
    static let pickFound = kernel("hdrPickFound")
    static let pickFallback = kernel("hdrPickFallback")
    static let blendGhost = kernel("hdrBlendGhost")
    static let level = kernel("hdrLevel")
    static let pickLevel = kernel("hdrPickLevel")
    static let markGhosts = kernel("hdrMarkGhosts")
    static let logLuminance = kernel("hdrLogLuminance")
    static let toneMap = kernel("hdrToneMap")
    static let outline = kernel("hdrOutline")

    private static let library: Data? = Bundle.main.url(forResource: "default", withExtension: "metallib")
        .flatMap { try? Data(contentsOf: $0) }

    private static func kernel(_ name: String) -> CIColorKernel {
        guard let library, let kernel = try? CIColorKernel(functionName: name, fromMetalLibraryData: library) else {
            fatalError("The Core Image kernel \(name) is missing from the app's Metal library.")
        }
        return kernel
    }
}
