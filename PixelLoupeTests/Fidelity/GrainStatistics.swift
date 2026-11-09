import Accelerate
import CoreGraphics
import Foundation

/// Grain's statistics, for comparing PixelLoupe's grain with Lightroom's (RAW-283). Grain is random, so two apps'
/// grain can't match pixel by pixel; what should match is how strong it is at each grain size, whether it moves the
/// image's mean, and whether it's colored, at each tone.
///
/// The grain is measured alone: an image with grain minus the same image without (its base), so the photo underneath
/// drops out. Its luminance is split into spatial bands (differences of Gaussian blurs), and each band's standard
/// deviation is taken per tone bin, the tone being the base's luminance at that pixel. Values are in 8-bit levels.
enum GrainStatistics {
    /// The bands' edges as Gaussian sigmas in pixels: band i holds detail between edges i and i + 1 (0 is no blur).
    static let bandEdges: [Float] = [0, 0.7, 1.5, 3, 6]
    static var bandCount: Int { bandEdges.count - 1 }
    static let toneBins = 8
    /// Statistics are taken on about this many pixels, evenly spread (the blurs see every pixel).
    static let samples = 1_500_000
    /// A bin with fewer samples than this isn't reported.
    static let minimumSamples = 2000
    /// Pixels this close to clipping in the base are left out: grain can't show there.
    static let clipMargin: Float = 4

    struct Bin: Equatable {
        /// The bin's base luminance range, 0…255.
        var tone: ClosedRange<Int>
        var samples: Int
        /// Standard deviation of the grain's luminance in each band.
        var bands: [Double]
        /// Mean of the grain's luminance: how far grain moves the image's mean.
        var mean: Double
        /// Standard deviation of the grain's color (R − G and B − G, averaged): 0 for monochrome grain.
        var chroma: Double
    }

    struct Measurement: Equatable {
        var bins: [Bin]
    }

    /// Measures the grain in `image` against `base` (the same picture without grain, the same size).
    static func measure(image: CGImage, base: CGImage) -> Measurement {
        let width = min(image.width, base.width), height = min(image.height, base.height)
        let a = planes(image, width: width, height: height), b = planes(base, width: width, height: height)
        let count = width * height
        // Luminance as the channels' mean; grain's color as R − G and B − G.
        func luma(_ p: [[Float]]) -> [Float] {
            var sum = [Float](repeating: 0, count: count)
            vDSP.add(p[0], p[1], result: &sum)
            vDSP.add(sum, p[2], result: &sum)
            return vDSP.multiply(Float(1) / 3, sum)
        }
        let baseLuma = luma(b), grain = vDSP.subtract(luma(a), baseLuma)
        let redGrain = vDSP.subtract(vDSP.subtract(a[0], a[1]), vDSP.subtract(b[0], b[1]))
        let blueGrain = vDSP.subtract(vDSP.subtract(a[2], a[1]), vDSP.subtract(b[2], b[1]))

        // Blur the grain to each edge; band i is blur(edge i) − blur(edge i + 1).
        let blurred = bandEdges.map { sigma in sigma == 0 ? grain : blur(grain, width: width, height: height, sigma: sigma) }
        let bands = (0..<bandCount).map { vDSP.subtract(blurred[$0], blurred[$0 + 1]) }

        struct Sums { var n = 0; var mean = 0.0; var chroma = 0.0; var bands: [Double] }
        var sums = [Sums](repeating: Sums(bands: Array(repeating: 0, count: bandCount)), count: toneBins)
        // Keep away from the edges, where the blurs run out of picture.
        let margin = Int((bandEdges.last ?? 0) * 3) + 1
        guard width > 2 * margin, height > 2 * margin else { return Measurement(bins: []) }
        let stride = max(1, Int((Double(count) / Double(samples)).squareRoot()))
        for y in Swift.stride(from: margin, to: height - margin, by: stride) {
            for x in Swift.stride(from: margin, to: width - margin, by: stride) {
                let index = y * width + x, tone = baseLuma[index]
                guard tone > clipMargin, tone < 255 - clipMargin else { continue }
                let bin = min(Int(tone) * toneBins / 256, toneBins - 1)
                sums[bin].n += 1
                sums[bin].mean += Double(grain[index])
                sums[bin].chroma += Double(redGrain[index] * redGrain[index] + blueGrain[index] * blueGrain[index]) / 2
                for band in 0..<bandCount { sums[bin].bands[band] += Double(bands[band][index] * bands[band][index]) }
            }
        }
        let binWidth = 256 / toneBins
        let bins = sums.enumerated().compactMap { bin, s -> Bin? in
            guard s.n >= minimumSamples else { return nil }
            let n = Double(s.n)
            // The bands and chroma have mean ~0 by construction, so their RMS is their standard deviation.
            return Bin(tone: (bin * binWidth)...(bin * binWidth + binWidth - 1), samples: s.n,
                       bands: s.bands.map { ($0 / n).squareRoot() }, mean: s.mean / n, chroma: (s.chroma / n).squareRoot())
        }
        return Measurement(bins: bins)
    }

    // MARK: Comparing

    /// What PixelLoupe's grain has to match: each band's strength within `bandTolerance` of Lightroom's (or within
    /// `bandFloor` levels where both are faint), the mean within `meanTolerance` levels of Lightroom's, and its color
    /// no more than `chromaAllowance` levels above Lightroom's.
    struct Target: Equatable {
        var bandTolerance = 0.15
        var bandFloor = 0.15
        var meanTolerance = 0.5
        var chromaAllowance = 0.3
    }

    struct BinComparison: Equatable {
        var tone: ClosedRange<Int>
        var render: Bin
        var reference: Bin
        /// PixelLoupe's band strength over Lightroom's, per band.
        var bandRatios: [Double] { zip(render.bands, reference.bands).map { $0 / max($1, 1e-9) } }
    }

    struct Comparison: Equatable {
        var bins: [BinComparison]
        var target: Target

        func passes(_ bin: BinComparison) -> Bool {
            let bands = zip(bin.render.bands, bin.reference.bands).allSatisfy { abs($0 - $1) <= max(target.bandTolerance * $1, target.bandFloor) }
            return bands && abs(bin.render.mean - bin.reference.mean) <= target.meanTolerance
                && bin.render.chroma <= bin.reference.chroma + target.chromaAllowance
        }

        var passes: Bool { !bins.isEmpty && bins.allSatisfy(passes) }

        /// The band ratio furthest from 1, over every tone, as a ratio (1.65 for 65% too strong, 0.8 for 20% too weak).
        var worstBandRatio: Double {
            bins.flatMap(\.bandRatios).max(by: { abs(log($0)) < abs(log($1)) }) ?? 1
        }

        /// The largest difference in mean, in levels.
        var worstMeanShift: Double {
            bins.map { $0.render.mean - $0.reference.mean }.max(by: { abs($0) < abs($1) }) ?? 0
        }

        /// The largest excess of color over Lightroom's, in levels.
        var worstChroma: Double { bins.map { $0.render.chroma - $0.reference.chroma }.max() ?? 0 }
    }

    /// Lines up two measurements tone by tone (only tones both have).
    static func compare(render: Measurement, reference: Measurement, target: Target = Target()) -> Comparison {
        let bins = render.bins.compactMap { bin -> BinComparison? in
            guard let other = reference.bins.first(where: { $0.tone == bin.tone }) else { return nil }
            return BinComparison(tone: bin.tone, render: bin, reference: other)
        }
        return Comparison(bins: bins, target: target)
    }

    // MARK: Pixels

    /// R, G and B of `image` in Display P3 as Float planes in 8-bit levels (0…255), read at 16 bits so a 16-bit
    /// export or render isn't rounded to whole levels.
    static func planes(_ image: CGImage, width: Int, height: Int) -> [[Float]] {
        let count = width * height
        var rgba = [UInt16](repeating: 0, count: count * 4)
        rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 8,
                space: FidelityHarness.displayP3,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) else { return }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var planes = [[Float]](repeating: [Float](repeating: 0, count: count), count: 3)
        rgba.withUnsafeBufferPointer { source in
            for channel in 0..<3 {
                planes[channel].withUnsafeMutableBufferPointer { destination in
                    // Every fourth value from `channel`, widened to Float and scaled to 8-bit levels.
                    vDSP_vfltu16(source.baseAddress! + channel, 4, destination.baseAddress!, 1, vDSP_Length(count))
                    vDSP_vsmul(destination.baseAddress!, 1, [Float(255.0 / 65535.0)], destination.baseAddress!, 1, vDSP_Length(count))
                }
            }
        }
        return planes
    }

    /// `plane` blurred by a Gaussian of `sigma` pixels (edges extended).
    static func blur(_ plane: [Float], width: Int, height: Int, sigma: Float) -> [Float] {
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = (-radius...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var output = [Float](repeating: 0, count: plane.count)
        var input = plane
        input.withUnsafeMutableBufferPointer { inputPointer in
            output.withUnsafeMutableBufferPointer { outputPointer in
                var source = vImage_Buffer(data: inputPointer.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                var destination = vImage_Buffer(data: outputPointer.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                _ = vImageSepConvolve_PlanarF(&source, &destination, nil, 0, 0, kernel, UInt32(kernel.count), kernel, UInt32(kernel.count), 0, 0,
                                              vImage_Flags(kvImageEdgeExtend))
            }
        }
        return output
    }
}
