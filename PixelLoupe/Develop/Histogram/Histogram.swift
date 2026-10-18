import CoreImage
import Metal
import MetalPerformanceShaders

/// Red, green and blue histograms of a rendered photo, in display (gamma-encoded) values.
nonisolated struct Histogram: Equatable, Sendable {
    static let binCount = 256

    /// Pixel counts per bin for each channel.
    var red: [UInt32]
    var green: [UInt32]
    var blue: [UInt32]

    var channels: [[UInt32]] { [red, green, blue] }
    var pixelCount: UInt64 { red.reduce(0) { $0 + UInt64($1) } }

    /// Channels with more than `fraction` of the pixels clipped to black (`atBlack`) or white.
    func clippedChannels(atBlack: Bool, fraction: Double = 0.0002) -> ClippedChannels {
        let total = Double(pixelCount)
        guard total > 0 else { return [] }
        let bin = atBlack ? 0 : Self.binCount - 1
        var result: ClippedChannels = []
        for (channel, counts) in zip([ClippedChannels.red, .green, .blue], channels)
        where Double(counts[bin]) / total > fraction {
            result.insert(channel)
        }
        return result
    }

    struct ClippedChannels: OptionSet, Sendable {
        let rawValue: Int
        static let red = ClippedChannels(rawValue: 1)
        static let green = ClippedChannels(rawValue: 2)
        static let blue = ClippedChannels(rawValue: 4)
    }
}

/// Computes histograms on the GPU: a Core Image processor kernel hands the rendered photo's Metal
/// texture to `MPSImageHistogram`, so the photo never comes back to the CPU (only the 3 × 256 counts do).
nonisolated enum HistogramCalculator {
    /// The longest side the photo is reduced to first; plenty for a 256-bin histogram.
    static let maximumSide: CGFloat = 512

    /// A rendered photo handed to the calculator off the main thread (CIImage is an immutable recipe).
    struct Input: @unchecked Sendable {
        let image: CIImage
    }

    private static let device = MTLCreateSystemDefaultDevice()
    private static let context: CIContext? = device.map {
        CIContext(mtlDevice: $0, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
            .cacheIntermediates: false,
        ])
    }

    @concurrent
    static func histogram(of input: Input) async -> Histogram? {
        histogram(of: input.image)
    }

    static func histogram(of image: CIImage) -> Histogram? {
        guard let context, !image.extent.isEmpty, !image.extent.isInfinite else { return nil }
        let extent = image.extent
        let scale = min(1, maximumSide / max(extent.width, extent.height))
        // Display values (what the histogram describes), reduced in size, at whole pixels.
        let reduced = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = CGRect(x: 0, y: 0, width: (extent.width * scale).rounded(.down), height: (extent.height * scale).rounded(.down))
        guard bounds.width >= 1, bounds.height >= 1,
              let encoded = reduced.cropped(to: bounds).matchedFromWorkingSpace(to: CGColorSpace(name: CGColorSpace.displayP3)!)
        else { return nil }

        let result = HistogramKernel.Result()
        guard let output = try? HistogramKernel.apply(
            withExtent: CGRect(x: 0, y: 0, width: 1, height: 1), inputs: [encoded],
            arguments: [HistogramKernel.resultKey: result, HistogramKernel.extentKey: bounds]
        ) else { return nil }
        // Reading the output back waits for the GPU, so the counts are complete afterwards.
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: nil)
        return result.histogram()
    }
}

/// Runs `MPSImageHistogram` on its input's Metal texture. The output image is a 1 × 1 placeholder;
/// the counts land in the `Result` passed in the arguments.
nonisolated final class HistogramKernel: CIImageProcessorKernel {
    static let resultKey = "result"
    static let extentKey = "extent"

    /// Receives the histogram buffer from the kernel (which Core Image calls on its own queue).
    final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: MTLBuffer?

        func store(_ buffer: MTLBuffer) {
            lock.withLock { self.buffer = buffer }
        }

        func histogram() -> Histogram? {
            lock.withLock {
                guard let buffer, buffer.length >= 3 * Histogram.binCount * MemoryLayout<UInt32>.size else { return nil }
                let counts = buffer.contents().bindMemory(to: UInt32.self, capacity: 3 * Histogram.binCount)
                let n = Histogram.binCount
                return Histogram(
                    red: Array(UnsafeBufferPointer(start: counts, count: n)),
                    green: Array(UnsafeBufferPointer(start: counts + n, count: n)),
                    blue: Array(UnsafeBufferPointer(start: counts + 2 * n, count: n))
                )
            }
        }
    }

    override class var outputFormat: CIFormat { .RGBA8 }

    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }

    /// The whole photo is needed to produce the (1 × 1) output.
    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        arguments?[extentKey] as? CGRect ?? outputRect
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?, output: CIImageProcessorOutput) throws {
        guard let source = inputs?.first?.metalTexture,
              let commandBuffer = output.metalCommandBuffer,
              let result = arguments?[resultKey] as? Result else { return }
        // Values outside 0…1 (clipped) are counted in the end bins.
        var info = MPSImageHistogramInfo(
            numberOfHistogramEntries: Histogram.binCount, histogramForAlpha: false,
            minPixelValue: vector_float4(0, 0, 0, 0), maxPixelValue: vector_float4(1, 1, 1, 1)
        )
        let histogram = MPSImageHistogram(device: commandBuffer.device, histogramInfo: &info)
        let length = histogram.histogramSize(forSourceFormat: source.pixelFormat)
        guard let buffer = commandBuffer.device.makeBuffer(length: length, options: .storageModeShared) else { return }
        histogram.encode(to: commandBuffer, sourceTexture: source, histogram: buffer, histogramOffset: 0)
        result.store(buffer)
    }
}
