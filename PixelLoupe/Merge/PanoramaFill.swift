import CoreImage
import Foundation
import Metal
import simd

/// Photo Merge ▸ Panorama's Fill Edges (RAW-106): fills where the photos don't reach with content-aware fill, so
/// nothing has to be cropped away. Each pixel near the hole is matched to a 7 × 7 patch of the photos' own pixels
/// (PatchMatch, Barnes et al. 2009), and the matches overlapping a hole pixel vote for its color; that repeats, from a
/// coarse image pyramid up to the solve's resolution (Wexler et al. 2007). Colors are compared as log2, so a stop of
/// difference counts alike in sky and shadow.
///
/// The matching runs as Metal compute shaders, compiled at runtime by the system's Metal compiler as Lens
/// Corrections' are (``LensKernel``), on the whole image at once: it is solved at no more than `maxPixels`, then
/// ``Field/fill(from:)`` copies the matches' pixels from an image of any resolution, region by region, so full
/// resolution can be rendered in blocks. The random search is seeded, so the same input always fills the same.
nonisolated enum PanoramaFill {
    /// A solved fill: the fill at the solve's resolution and the matches behind it.
    struct Solution: @unchecked Sendable {
        /// Fill colors at the solve's resolution over the input's extent (scaled to it), scene-linear and opaque.
        /// Only meaningful where the photos don't fully cover: lay it under the panorama with ``composite``.
        let fill: CIImage
        let field: Field
    }

    /// Each solved pixel near the hole's match: where the patch it copies sits, in solved pixels from the top left.
    struct Field: Sendable {
        let width: Int
        let height: Int
        /// The input's extent, which the field spans.
        let extent: CGRect
        /// Per solved pixel, top row first: the matched patch's center (x, y), its weight, and 1 where there is a match.
        let entries: [SIMD4<Float>]
        /// The smallest and largest offset to a match (x, y; in solved pixels) per `cellSize` square of the field.
        fileprivate let cells: [SIMD4<Float>]
        fileprivate let cellColumns: Int

        static let cellSize = 32

        /// The fill at `color`'s resolution: each pixel takes the pixels its nearby matches point to in `color`
        /// (offsets scaled to `color`'s extent), weighted by how well they match and how near they are.
        func fill(from color: CIImage) -> CIImage {
            let target = color.extent
            let scale = CGSize(width: target.width / CGFloat(width), height: target.height / CGFloat(height))
            let image = fieldImage()
            let fieldBounds = image.extent
            let field = self
            let arguments: [Any] = [
                color.clampedToExtent(), image.samplingNearest(),
                CIVector(x: scale.width, y: scale.height, z: CGFloat(width), w: CGFloat(height)),
                CIVector(x: target.minX, y: target.minY),
            ]
            return PanoramaKernels.fillReconstruct.apply(extent: target, roiCallback: { index, rect in
                let local = CGRect(x: (rect.minX - target.minX) / scale.width, y: (rect.minY - target.minY) / scale.height,
                                   width: rect.width / scale.width, height: rect.height / scale.height).insetBy(dx: -2, dy: -2)
                if index == 1 { return local.intersection(fieldBounds) }
                guard let offsets = field.offsets(in: local) else { return rect.insetBy(dx: -1, dy: -1) }
                return CGRect(x: rect.minX + CGFloat(offsets.x) * scale.width, y: rect.minY + CGFloat(offsets.y) * scale.height,
                              width: rect.width + CGFloat(offsets.z - offsets.x) * scale.width,
                              height: rect.height + CGFloat(offsets.w - offsets.y) * scale.height)
                    .insetBy(dx: -scale.width - 2, dy: -scale.height - 2)
            }, arguments: arguments) ?? CIImage.empty()
        }

        /// The field as a Core Image image from (0, 0), one pixel per solved pixel: the match's center in Core Image's
        /// coordinates (from the bottom left), its weight, and 1 where there is a match.
        func fieldImage() -> CIImage {
            var pixels = [Float](repeating: 0, count: width * height * 4)
            for row in 0..<height {
                for column in 0..<width {
                    let entry = entries[row * width + column]
                    guard entry.w > 0.5 else { continue }
                    let index = (row * width + column) * 4
                    pixels[index] = entry.x + 0.5
                    pixels[index + 1] = Float(height) - entry.y - 0.5
                    pixels[index + 2] = entry.z
                    pixels[index + 3] = 1
                }
            }
            let data = pixels.withUnsafeBytes { Data($0) }
            return CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                           format: .RGBAf, colorSpace: nil)
        }

        /// The smallest and largest offset to a match (in Core Image's direction, y up) of the solved pixels in
        /// `rect` (solved pixels in Core Image's coordinates), or nil where none has a match.
        func offsets(in rect: CGRect) -> SIMD4<Float>? {
            let size = Self.cellSize
            let rows = (height + size - 1) / size
            // Core Image's y runs up; the cells' rows run down.
            let top = Int((CGFloat(height) - rect.maxY).rounded(.down)), bottom = Int((CGFloat(height) - rect.minY).rounded(.up))
            let columnRange = max(0, Int(rect.minX.rounded(.down)) / size)...min(cellColumns - 1, max(0, Int(rect.maxX.rounded(.up)) / size))
            let rowRange = max(0, top / size)...min(rows - 1, max(0, bottom / size))
            var result: SIMD4<Float>?
            for row in rowRange {
                for column in columnRange {
                    let cell = cells[row * cellColumns + column]
                    guard cell.x <= cell.z else { continue }
                    // Down in the field is negative y in Core Image.
                    let flipped = SIMD4(cell.x, -cell.w, cell.z, -cell.y)
                    result = result.map { SIMD4(min($0.x, flipped.x), min($0.y, flipped.y), max($0.z, flipped.z), max($0.w, flipped.w)) } ?? flipped
                }
            }
            return result
        }

        fileprivate init(width: Int, height: Int, extent: CGRect, entries: [SIMD4<Float>]) {
            self.width = width
            self.height = height
            self.extent = extent
            self.entries = entries
            let size = Self.cellSize
            cellColumns = (width + size - 1) / size
            let rows = (height + size - 1) / size
            var cells = [SIMD4<Float>](repeating: SIMD4(.infinity, .infinity, -.infinity, -.infinity), count: cellColumns * rows)
            for row in 0..<height {
                for column in 0..<width {
                    let entry = entries[row * width + column]
                    guard entry.w > 0.5 else { continue }
                    let offset = SIMD2(entry.x - Float(column), entry.y - Float(row))
                    let index = (row / size) * cellColumns + column / size
                    cells[index] = SIMD4(min(cells[index].x, offset.x), min(cells[index].y, offset.y),
                                         max(cells[index].z, offset.x), max(cells[index].w, offset.y))
                }
            }
            self.cells = cells
        }
    }

    enum Failure: Error {
        case noGPU
    }

    /// The patch radius: patches are 7 × 7.
    static let patchRadius = 3
    /// How far in from the photos' edge (in solved pixels) the fill still counts as hole, so it blends across the
    /// panorama's feathered edge rather than butting against it.
    static let edgeErosion = 2
    /// The pyramid halves until its short side would drop below this, so the hole at the coarsest level is only a few
    /// pixels deep and its matches lock onto the photos' edge; finer levels inherit them.
    static let coarsestSide = 24
    /// How much a worse match's vote fades, in mean squared log2 difference per pixel.
    static let voteFalloff: Float = 0.05
    /// How much a match is held to the photos' edge colors carried smoothly into the hole (the guide): its patch's mean
    /// against the guide, squared, counts this much beside the patch's own difference. It keeps the fill's broad
    /// colors continuing from the edge, so the hole doesn't drift brighter or darker or take in far-off objects.
    static let guidance: Float = 0.05
    /// Pairs of smoothing passes the guide gets per level (four times as many at the coarsest). Few: the guide is the
    /// edge grown outward, which keeps each row's (or column's) color running on; smoothing it toward a membrane
    /// would flatten gradients toward the image's sides.
    static let guideSmoothing = 2

    /// Solves the fill for `color` (scene-linear, opaque) where `coverage` (red) says the photos don't fully cover,
    /// at no more than `maxPixels`. `color` is ignored where coverage is below 1. Throws `CancellationError` when
    /// `isCancelled` says so between passes.
    static func solve(color: CIImage, coverage: CIImage, context: CIContext, maxPixels: Int = 4_000_000,
                      isCancelled: () -> Bool = { false }) throws -> Solution {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = Pipelines.queue(device),
              let pipelines = Pipelines.pipelines(device) else { throw Failure.noGPU }
        let extent = color.extent.integral
        let ratio = min(1, sqrt(Double(maxPixels) / Double(extent.width * extent.height)))
        let width = max(1, Int((Double(extent.width) * ratio).rounded()))
        let height = max(1, Int((Double(extent.height) * ratio).rounded()))
        let input = rendered(color: color, coverage: coverage, extent: extent, width: width, height: height, context: context)

        var solver = Solver(device: device, queue: queue, pipelines: pipelines, width: width, height: height)
        let (fill, entries) = try solver.run(input, isCancelled: isCancelled)
        let fillData = fill.withUnsafeBytes { Data($0) }
        let fillImage = CIImage(bitmapData: fillData, bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                                format: .RGBAf, colorSpace: nil)
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height))
                .translatedBy(x: extent.minX * CGFloat(width) / extent.width, y: extent.minY * CGFloat(height) / extent.height))
        return Solution(fill: fillImage, field: Field(width: width, height: height, extent: extent, entries: entries))
    }

    /// `color` where `coverage` (red) says the photos cover, `fill` where they don't, mixed across partial coverage.
    static func composite(_ color: CIImage, coverage: CIImage, fill: CIImage) -> CIImage {
        color.applyingFilter("CIBlendWithRedMask", parameters: [
            kCIInputBackgroundImageKey: fill.cropped(to: color.extent),
            kCIInputMaskImageKey: coverage,
        ]).cropped(to: color.extent)
    }

    /// `color` and `coverage` scaled to `width` × `height`, as RGBA floats top row first, coverage in alpha.
    private static func rendered(color: CIImage, coverage: CIImage, extent: CGRect, width: Int, height: Int, context: CIContext) -> [Float] {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        func scaled(_ image: CIImage) -> CIImage {
            let moved = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            guard width != Int(extent.width) || height != Int(extent.height) else { return moved }
            return moved.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: CGFloat(height) / extent.height,
                kCIInputAspectRatioKey: (CGFloat(width) / extent.width) / (CGFloat(height) / extent.height),
            ]).cropped(to: bounds)
        }
        var colors = [Float](repeating: 0, count: width * height * 4)
        var covers = [Float](repeating: 0, count: width * height * 4)
        context.render(scaled(color), toBitmap: &colors, rowBytes: width * 16, bounds: bounds, format: .RGBAf, colorSpace: nil)
        context.render(scaled(coverage), toBitmap: &covers, rowBytes: width * 16, bounds: bounds, format: .RGBAf, colorSpace: nil)
        for index in stride(from: 0, to: colors.count, by: 4) {
            colors[index + 3] = covers[index]
        }
        return colors
    }

    /// The solve on the GPU: the image pyramid, then matching and voting from the coarsest level up.
    private struct Solver {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipelines: [String: MTLComputePipelineState]
        let width: Int
        let height: Int

        /// The shaders' parameters (see `FillParams` in the shader source).
        struct Params {
            var size: SIMD2<Int32> = .zero
            var coarseSize: SIMD2<Int32> = .zero
            var seed: UInt32 = 0
            var step: Int32 = 0
            var radius: Int32 = 0
            var searches: Int32 = 0
            var falloff: Float = 0
            var hasCoarse: Int32 = 0
            var guidance: Float = 0
        }

        struct Level {
            let width: Int
            let height: Int
            /// log2 colors, alpha: coverage at the finest level, known (0 or 1) above it.
            let color: MTLTexture
            /// red: known, green: a patch centered here is all known (may be copied), blue: near the hole (is matched).
            let masks: MTLTexture
        }

        /// Matching and voting passes per pyramid level, coarsest first: (votes, matching passes per vote).
        static func iterations(level: Int, of count: Int) -> (votes: Int, passes: Int) {
            switch count - 1 - level {
            case 0: (8, 2)
            case 1, 2: (6, 2)
            default: level == 0 ? (3, 1) : (4, 1)
            }
        }

        mutating func run(_ input: [Float], isCancelled: () -> Bool) throws -> (fill: [Float], entries: [SIMD4<Float>]) {
            let inputTexture = texture(width, height, .rgba32Float, shared: true)
            inputTexture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: input, bytesPerRow: width * 16)

            // The pyramid.
            var levels: [Level] = []
            var buffer = queue.makeCommandBuffer()!
            var size = (width, height)
            while true {
                let level = Level(width: size.0, height: size.1, color: texture(size.0, size.1, .rgba16Float),
                                  masks: texture(size.0, size.1, .rgba8Unorm))
                let scratch = texture(size.0, size.1, .rgba8Unorm)
                if let finer = levels.last {
                    dispatch(buffer, "fillDownsample", [finer.color, finer.masks, level.color], size: size, params(level, coarse: finer))
                    dispatch(buffer, "fillKnown", [level.color, scratch], size: size, params(level, radius: 0))
                } else {
                    dispatch(buffer, "fillPrepare", [inputTexture, level.color], size: size, params(level))
                    dispatch(buffer, "fillKnown", [level.color, scratch], size: size, params(level, radius: PanoramaFill.edgeErosion))
                }
                dispatch(buffer, "fillRegions", [scratch, level.masks], size: size, params(level, radius: PanoramaFill.patchRadius))
                levels.append(level)
                if min(size.0, size.1) / 2 < PanoramaFill.coarsestSide { break }
                size = ((size.0 + 1) / 2, (size.1 + 1) / 2)
            }
            try finish(buffer, isCancelled)

            // Coarse to fine.
            var nnf: (MTLTexture, MTLTexture)?
            var estimate: (MTLTexture, MTLTexture)!
            var guide: MTLTexture?
            var seed: UInt32 = 0x9E37_79B9
            for index in levels.indices.reversed() {
                let level = levels[index]
                let levelSize = (level.width, level.height)
                let current = (texture(level.width, level.height, .rgba32Float, shared: true),
                               texture(level.width, level.height, .rgba32Float, shared: true))
                let estimates = (texture(level.width, level.height, .rgba16Float), texture(level.width, level.height, .rgba16Float))
                buffer = queue.makeCommandBuffer()!
                let levelGuide = texture(level.width, level.height, .rgba16Float)
                var p = params(level)
                p.seed = seed
                p.guidance = PanoramaFill.guidance
                if let coarser = nnf, let coarseGuide = guide, index + 1 < levels.count {
                    // Matches from the level below, doubled; their first vote counts them all alike. The guide is
                    // the level below's, enlarged and smoothed.
                    p.coarseSize = SIMD2(Int32(levels[index + 1].width), Int32(levels[index + 1].height))
                    p.hasCoarse = 1
                    dispatch(buffer, "fillGuide", [level.color, level.masks, coarseGuide, estimates.1], size: levelSize, p)
                    for _ in 0..<PanoramaFill.guideSmoothing {
                        dispatch(buffer, "fillSmooth", [estimates.1, level.masks, levelGuide], size: levelSize, p)
                        dispatch(buffer, "fillSmooth", [levelGuide, level.masks, estimates.1], size: levelSize, p)
                    }
                    dispatch(buffer, "fillSmooth", [estimates.1, level.masks, levelGuide], size: levelSize, p)
                    dispatch(buffer, "fillUpsample", [coarser.0, level.masks, current.0], size: levelSize, p)
                    dispatch(buffer, "fillVote", [level.color, level.masks, current.0, estimates.0], size: levelSize, p)
                } else {
                    // The coarsest level starts from the photos grown outward and smoothed, and random matches.
                    dispatch(buffer, "fillSeed", [level.color, level.masks, estimates.0], size: levelSize, p)
                    for _ in 0..<((level.width + level.height + 1) / 2) {
                        dispatch(buffer, "fillGrow", [estimates.0, estimates.1], size: levelSize, p)
                        dispatch(buffer, "fillGrow", [estimates.1, estimates.0], size: levelSize, p)
                    }
                    for _ in 0..<(4 * PanoramaFill.guideSmoothing) {
                        dispatch(buffer, "fillSmooth", [estimates.0, level.masks, estimates.1], size: levelSize, p)
                        dispatch(buffer, "fillSmooth", [estimates.1, level.masks, estimates.0], size: levelSize, p)
                    }
                    dispatch(buffer, "fillSmooth", [estimates.0, level.masks, levelGuide], size: levelSize, p)
                    dispatch(buffer, "fillUpsample", [current.1, level.masks, current.0], size: levelSize, p)
                }
                try finish(buffer, isCancelled)
                var matches = current
                var votes = estimates
                let (voteCount, passes) = Self.iterations(level: index, of: levels.count)
                for _ in 0..<voteCount {
                    buffer = queue.makeCommandBuffer()!
                    dispatch(buffer, "fillDistance", [votes.0, level.masks, matches.0, matches.1, levelGuide], size: levelSize, p)
                    swap(&matches.0, &matches.1)
                    for _ in 0..<passes {
                        for step in [4, 2, 1] {
                            seed = seed &* 747_796_405 &+ 2_891_336_453
                            p.seed = seed
                            p.step = Int32(step)
                            p.searches = step == 1 ? 1 : 0
                            dispatch(buffer, "fillPropagate", [votes.0, level.masks, matches.0, matches.1, levelGuide], size: levelSize, p)
                            swap(&matches.0, &matches.1)
                        }
                    }
                    p.falloff = PanoramaFill.voteFalloff
                    dispatch(buffer, "fillVote", [level.color, level.masks, matches.0, votes.1], size: levelSize, p)
                    swap(&votes.0, &votes.1)
                    try finish(buffer, isCancelled)
                }
                nnf = matches
                estimate = votes
                guide = levelGuide
            }

            // Back to linear, and the matches read back.
            let output = texture(width, height, .rgba32Float, shared: true)
            buffer = queue.makeCommandBuffer()!
            dispatch(buffer, "fillFinish", [estimate.0, output], size: (width, height), params(levels[0]))
            try finish(buffer, isCancelled)
            var fill = [Float](repeating: 0, count: width * height * 4)
            output.getBytes(&fill, bytesPerRow: width * 16, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            var entries = [SIMD4<Float>](repeating: .zero, count: width * height)
            nnf!.0.getBytes(&entries, bytesPerRow: width * 16, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            for index in entries.indices where entries[index].w > 0.5 {
                entries[index].z = 1 / (0.01 + entries[index].z)
            }
            return (fill, entries)
        }

        private func params(_ level: Level, coarse: Level? = nil, radius: Int = 0) -> Params {
            var p = Params()
            p.size = SIMD2(Int32(level.width), Int32(level.height))
            if let coarse { p.coarseSize = SIMD2(Int32(coarse.width), Int32(coarse.height)) }
            p.radius = Int32(radius)
            return p
        }

        private func texture(_ width: Int, _ height: Int, _ format: MTLPixelFormat, shared: Bool = false) -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = shared ? .shared : .private
            return device.makeTexture(descriptor: descriptor)!
        }

        private func dispatch(_ buffer: MTLCommandBuffer, _ name: String, _ textures: [MTLTexture], size: (Int, Int), _ params: Params) {
            guard let pipeline = pipelines[name], let encoder = buffer.makeComputeCommandEncoder() else { return }
            encoder.setComputePipelineState(pipeline)
            for (index, texture) in textures.enumerated() {
                encoder.setTexture(texture, index: index)
            }
            var params = params
            encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
            let width = pipeline.threadExecutionWidth
            let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
            encoder.dispatchThreads(MTLSize(width: size.0, height: size.1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
            encoder.endEncoding()
        }

        private func finish(_ buffer: MTLCommandBuffer, _ isCancelled: () -> Bool) throws {
            buffer.commit()
            buffer.waitUntilCompleted()
            if isCancelled() { throw CancellationError() }
        }
    }

    /// The command queue and compiled pipelines, per GPU.
    private enum Pipelines {
        nonisolated(unsafe) private static var queues: [UInt64: MTLCommandQueue] = [:]
        nonisolated(unsafe) private static var cache: [UInt64: [String: MTLComputePipelineState]] = [:]
        private static let lock = NSLock()
        static let names = ["fillPrepare", "fillKnown", "fillRegions", "fillDownsample", "fillSeed", "fillGrow", "fillSmooth", "fillGuide",
                            "fillUpsample", "fillDistance", "fillPropagate", "fillVote", "fillFinish"]

        static func queue(_ device: MTLDevice) -> MTLCommandQueue? {
            lock.withLock {
                if let queue = queues[device.registryID] { return queue }
                let queue = device.makeCommandQueue()
                queues[device.registryID] = queue
                return queue
            }
        }

        static func pipelines(_ device: MTLDevice) -> [String: MTLComputePipelineState]? {
            lock.withLock {
                if let pipelines = cache[device.registryID] { return pipelines.count == names.count ? pipelines : nil }
                var pipelines: [String: MTLComputePipelineState] = [:]
                if let library = try? device.makeLibrary(source: shaderSource, options: nil) {
                    for name in names {
                        if let function = library.makeFunction(name: name),
                           let pipeline = try? device.makeComputePipelineState(function: function) {
                            pipelines[name] = pipeline
                        }
                    }
                }
                cache[device.registryID] = pipelines
                return pipelines.count == names.count ? pipelines : nil
            }
        }
    }
}

nonisolated extension PanoramaFill {
    /// Textures run top row first, in whole pixels. Colors are log2 (of linear + 1/1024) in half floats; a match is
    /// (x, y) of the copied patch's center, its distance (mean squared log2 difference per pixel), and 1 where set.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant int R = 3;
    constant float BIG = 1e30;

    struct FillParams {
        int2 size;
        int2 coarseSize;
        uint seed;
        int step;
        int radius;
        int searches;
        float falloff;
        int hasCoarse;
        float guidance;
    };

    static uint hash(uint x) {
        x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
        return x;
    }

    static float random01(int2 q, uint salt, uint seed) {
        return float(hash(uint(q.x) * 1973u + hash(uint(q.y) * 9277u + hash(salt * 26699u + seed)))) / 4294967296.0;
    }

    static bool inside(int2 q, int2 size) {
        return q.x >= 0 && q.y >= 0 && q.x < size.x && q.y < size.y;
    }

    static bool isValid(texture2d<half, access::read> masks, int2 s, int2 size) {
        return inside(s, size) && masks.read(uint2(s)).g > 0.5h;
    }

    /// Mean squared difference between the patches centered at `t` and `s`, over the target's pixels in the image,
    /// plus the squared difference between the copied patch's mean and the guide at `t`, times `guidance`.
    static float patchDistance(texture2d<half, access::read> estimate, texture2d<half, access::read> guide, int2 t, int2 s,
                               int2 size, float guidance) {
        float total = 0.0, count = 0.0;
        float3 mean = float3(0.0);
        for (int dy = -R; dy <= R; dy++) {
            for (int dx = -R; dx <= R; dx++) {
                int2 a = t + int2(dx, dy);
                if (!inside(a, size)) { continue; }
                float3 copied = float3(estimate.read(uint2(s + int2(dx, dy))).rgb);
                float3 d = float3(estimate.read(uint2(a)).rgb) - copied;
                total += dot(d, d);
                mean += copied;
                count += 1.0;
            }
        }
        count = max(count, 1.0);
        float3 g = mean / count - float3(guide.read(uint2(t)).rgb);
        return total / count + guidance * dot(g, g);
    }

    /// Linear color and coverage (alpha) to log2 color.
    kernel void fillPrepare(texture2d<float, access::read> input [[texture(0)]], texture2d<half, access::write> color [[texture(1)]],
                            constant FillParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (!inside(int2(gid), p.size)) { return; }
        float4 c = input.read(gid);
        color.write(half4(half3(log2(max(c.rgb, 0.0) + 1.0 / 1024.0)), half(clamp(c.a, 0.0, 1.0))), gid);
    }

    /// Known (red): fully covered within `radius`.
    kernel void fillKnown(texture2d<half, access::read> color [[texture(0)]], texture2d<half, access::write> masks [[texture(1)]],
                          constant FillParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int2 q = int2(gid);
        if (!inside(q, p.size)) { return; }
        half known = 1.0h;
        for (int dy = -p.radius; dy <= p.radius; dy++) {
            for (int dx = -p.radius; dx <= p.radius; dx++) {
                int2 a = clamp(q + int2(dx, dy), int2(0), p.size - 1);
                if (color.read(uint2(a)).a < 0.999h) { known = 0.0h; }
            }
        }
        masks.write(half4(known, 0.0h, 0.0h, 1.0h), gid);
    }

    /// Green: a patch centered here lies in the image and is all known. Blue: the patch here overlaps the hole.
    kernel void fillRegions(texture2d<half, access::read> known [[texture(0)]], texture2d<half, access::write> masks [[texture(1)]],
                            constant FillParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int2 q = int2(gid);
        if (!inside(q, p.size)) { return; }
        bool all = q.x >= R && q.y >= R && q.x < p.size.x - R && q.y < p.size.y - R;
        bool any = false;
        for (int dy = -R; dy <= R; dy++) {
            for (int dx = -R; dx <= R; dx++) {
                int2 a = q + int2(dx, dy);
                if (!inside(a, p.size)) { continue; }
                if (known.read(uint2(a)).r < 0.5h) { all = false; any = true; }
            }
        }
        masks.write(half4(known.read(gid).r, all ? 1.0h : 0.0h, any ? 1.0h : 0.0h, 1.0h), gid);
    }

    /// Half size: the mean of the known pixels below, known (alpha) only where all four are.
    kernel void fillDownsample(texture2d<half, access::read> fine [[texture(0)]], texture2d<half, access::read> fineMasks [[texture(1)]],
                               texture2d<half, access::write> coarse [[texture(2)]],
                               constant FillParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int2 q = int2(gid);
        if (!inside(q, p.size)) { return; }
        float3 sum = float3(0.0);
        float count = 0.0, known = 1.0;
        for (int i = 0; i < 4; i++) {
            int2 a = min(q * 2 + int2(i & 1, i >> 1), p.coarseSize - 1);
            float k = float(fineMasks.read(uint2(a)).r);
            sum += k * float3(fine.read(uint2(a)).rgb);
            count += k;
            known = min(known, k);
        }
        coarse.write(half4(half3(count > 0.0 ? sum / count : float3(0.0)), half(known)), gid);
    }

    /// The coarsest level's start: known pixels as they are (alpha 1), the hole empty (alpha 0).
    kernel void fillSeed(texture2d<half, access::read> color [[texture(0)]], texture2d<half, access::read> masks [[texture(1)]],
                         texture2d<half, access::write> estimate [[texture(2)]],
                         constant FillParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (!inside(int2(gid), p.size)) { return; }
        bool known = masks.read(gid).r > 0.5h;
        estimate.write(known ? half4(color.read(gid).rgb, 1.0h) : half4(0.0h), gid);
    }

    /// Grows the filled pixels (alpha 1) one pixel into the hole: an empty pixel takes its filled neighbors' mean.
    kernel void fillGrow(texture2d<half, access::read> source [[texture(0)]], texture2d<half, access::write> destination [[texture(1)]],
                         constant FillParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int2 q = int2(gid);
        if (!inside(q, p.size)) { return; }
        half4 here = source.read(gid);
        if (here.a > 0.5h) { destination.write(here, gid); return; }
        float3 sum = float3(0.0);
        float count = 0.0;
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                int2 a = q + int2(dx, dy);
                if (!inside(a, p.size)) { continue; }
                half4 c = source.read(uint2(a));
                if (c.a > 0.5h) { sum += float3(c.rgb); count += 1.0; }
            }
        }
        destination.write(count > 0.0 ? half4(half3(sum / count), 1.0h) : half4(0.0h), gid);
    }

    /// Smooths the hole (3 × 3 mean), leaving known pixels.
    kernel void fillSmooth(texture2d<half, access::read> source [[texture(0)]], texture2d<half, access::read> masks [[texture(1)]],
                           texture2d<half, access::write> destination [[texture(2)]],
                           constant FillParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int2 q = int2(gid);
        if (!inside(q, p.size)) { return; }
        if (masks.read(gid).r > 0.5h) { destination.write(source.read(gid), gid); return; }
        float3 sum = float3(0.0);
        float count = 0.0;
        for (int dy = -1; dy <= 1; dy++) {
            for (int dx = -1; dx <= 1; dx++) {
                int2 a = q + int2(dx, dy);
                if (!inside(a, p.size)) { continue; }
                sum += float3(source.read(uint2(a)).rgb);
                count += 1.0;
            }
        }
        destination.write(half4(half3(sum / count), 1.0h), gid);
    }

    /// The guide: known pixels as they are; the hole from the coarser level's guide, enlarged (bilinear).
    kernel void fillGuide(texture2d<half, access::read> color [[texture(0)]], texture2d<half, access::read> masks [[texture(1)]],
                          texture2d<half, access::read> coarse [[texture(2)]], texture2d<half, access::write> guide [[texture(3)]],
                          constant FillParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int2 q = int2(gid);
        if (!inside(q, p.size)) { return; }
        if (masks.read(gid).r > 0.5h) { guide.write(half4(color.read(gid).rgb, 1.0h), gid); return; }
        float2 c = (float2(q) + 0.5) * 0.5 - 0.5;
        int2 c0 = int2(floor(c));
        float2 f = c - float2(c0);
        int2 hi = p.coarseSize - 1;
        float3 a = float3(coarse.read(uint2(clamp(c0, int2(0), hi))).rgb);
        float3 b = float3(coarse.read(uint2(clamp(c0 + int2(1, 0), int2(0), hi))).rgb);
        float3 d = float3(coarse.read(uint2(clamp(c0 + int2(0, 1), int2(0), hi))).rgb);
        float3 e = float3(coarse.read(uint2(clamp(c0 + int2(1, 1), int2(0), hi))).rgb);
        guide.write(half4(half3(mix(mix(a, b, f.x), mix(d, e, f.x), f.y)), 1.0h), gid);
    }

    /// Starting matches near the hole: the coarser level's, doubled, where valid; otherwise random valid patches.
    kernel void fillUpsample(texture2d<float, access::read> coarse [[texture(0)]], texture2d<half, access::read> masks [[texture(1)]],
                             texture2d<float, access::write> nnf [[texture(2)]],
                             constant FillParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int2 q = int2(gid);
        if (!inside(q, p.size)) { return; }
        if (masks.read(gid).b < 0.5h) { nnf.write(float4(-1.0, -1.0, BIG, 0.0), gid); return; }
        int2 s = int2(-1);
        if (p.hasCoarse != 0) {
            int2 c = min(q / 2, p.coarseSize - 1);
            float4 e = coarse.read(uint2(c));
            if (e.w > 0.5) { s = int2(e.xy) * 2 + (q - c * 2); }
        }
        for (uint i = 0; i < 64 && !isValid(masks, s, p.size); i++) {
            s = int2(float2(random01(q, i * 2u, p.seed), random01(q, i * 2u + 1u, p.seed)) * float2(p.size));
        }
        bool valid = isValid(masks, s, p.size);
        nnf.write(float4(float2(s), BIG, valid ? 1.0 : 0.0), gid);
    }

    /// Each match's distance against the current estimate.
    kernel void fillDistance(texture2d<half, access::read> estimate [[texture(0)]], texture2d<half, access::read> masks [[texture(1)]],
                             texture2d<float, access::read> source [[texture(2)]], texture2d<float, access::write> nnf [[texture(3)]],
                             texture2d<half, access::read> guide [[texture(4)]],
                             constant FillParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int2 q = int2(gid);
        if (!inside(q, p.size)) { return; }
        float4 e = source.read(gid);
        if (e.w > 0.5) { e.z = patchDistance(estimate, guide, q, int2(e.xy), p.size, p.guidance); }
        nnf.write(e, gid);
    }

    static void consider(texture2d<half, access::read> estimate, texture2d<half, access::read> masks,
                         texture2d<half, access::read> guide, int2 q, int2 s, constant FillParams &p, thread float4 &best) {
        if (!isValid(masks, s, p.size) || (best.w > 0.5 && all(s == int2(best.xy)))) { return; }
        float d = patchDistance(estimate, guide, q, s, p.size, p.guidance);
        if (d < best.z) { best = float4(float2(s), d, 1.0); }
    }

    /// One PatchMatch pass: tries the neighbors' matches `step` pixels away, shifted, then (with `searches`) random
    /// patches around the best, from the image's size down to a pixel.
    kernel void fillPropagate(texture2d<half, access::read> estimate [[texture(0)]], texture2d<half, access::read> masks [[texture(1)]],
                              texture2d<float, access::read> source [[texture(2)]], texture2d<float, access::write> nnf [[texture(3)]],
                              texture2d<half, access::read> guide [[texture(4)]],
                              constant FillParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int2 q = int2(gid);
        if (!inside(q, p.size)) { return; }
        float4 best = source.read(gid);
        if (masks.read(gid).b < 0.5h) { nnf.write(best, gid); return; }
        const int2 directions[4] = { int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1) };
        for (int i = 0; i < 4; i++) {
            int2 n = q + directions[i] * p.step;
            if (!inside(n, p.size)) { continue; }
            float4 e = source.read(uint2(n));
            if (e.w > 0.5) { consider(estimate, masks, guide, q, int2(e.xy) + (q - n), p, best); }
        }
        if (p.searches > 0) {
            float radius = float(max(p.size.x, p.size.y));
            for (uint i = 0; radius >= 1.0 && i < 16; i++, radius *= 0.5) {
                float2 r = float2(random01(q, i * 2u, p.seed), random01(q, i * 2u + 1u, p.seed)) * 2.0 - 1.0;
                int2 center = best.w > 0.5 ? int2(best.xy) : q;
                int2 s = clamp(center + int2(round(r * radius)), int2(R), p.size - 1 - R);
                consider(estimate, masks, guide, q, s, p, best);
            }
        }
        nnf.write(best, gid);
    }

    /// The hole's colors: the mean of what every match overlapping each pixel copies there, better matches counting
    /// more (`falloff`; 0 counts all alike). Known pixels stay as they are.
    kernel void fillVote(texture2d<half, access::read> color [[texture(0)]], texture2d<half, access::read> masks [[texture(1)]],
                         texture2d<float, access::read> nnf [[texture(2)]], texture2d<half, access::write> estimate [[texture(3)]],
                         constant FillParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int2 q = int2(gid);
        if (!inside(q, p.size)) { return; }
        half4 c = color.read(gid);
        if (masks.read(gid).r > 0.5h) { estimate.write(half4(c.rgb, 1.0h), gid); return; }
        float least = BIG;
        for (int dy = -R; dy <= R; dy++) {
            for (int dx = -R; dx <= R; dx++) {
                int2 n = q + int2(dx, dy);
                if (!inside(n, p.size)) { continue; }
                float4 e = nnf.read(uint2(n));
                if (e.w > 0.5) { least = min(least, e.z); }
            }
        }
        float3 sum = float3(0.0);
        float total = 0.0;
        for (int dy = -R; dy <= R; dy++) {
            for (int dx = -R; dx <= R; dx++) {
                int2 n = q + int2(dx, dy);
                if (!inside(n, p.size)) { continue; }
                float4 e = nnf.read(uint2(n));
                if (e.w < 0.5) { continue; }
                float w = p.falloff > 0.0 ? exp(-(e.z - least) / p.falloff) : 1.0;
                sum += w * float3(color.read(uint2(int2(e.xy) - int2(dx, dy))).rgb);
                total += w;
            }
        }
        estimate.write(half4(total > 0.0 ? half3(sum / total) : c.rgb, 1.0h), gid);
    }

    /// Back to linear.
    kernel void fillFinish(texture2d<half, access::read> estimate [[texture(0)]], texture2d<float, access::write> output [[texture(1)]],
                           constant FillParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (!inside(int2(gid), p.size)) { return; }
        float3 c = max(exp2(float3(estimate.read(gid).rgb)) - 1.0 / 1024.0, float3(0.0));
        output.write(float4(c, 1.0), gid);
    }
    """
}
