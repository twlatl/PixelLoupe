import CoreImage
import Foundation

/// Measures lateral chromatic aberration (Lightroom's Remove Chromatic Aberration when there's no
/// profile data): how much larger the red and blue images are than the green one.
///
/// Along edges that run across the radius (where lateral CA shows), it compares the red and blue
/// edge profiles with green's at a range of radial scales and keeps the scale that lines them up
/// best.
nonisolated enum ChromaticAberrationEstimator {
    struct Input: @unchecked Sendable {
        let image: CIImage
    }

    /// Scales tried, as offsets from 1: ±0.5%, the largest lateral CA real lenses show, finally in
    /// steps of 0.01%.
    static let searchRange = 0.005
    static let step = 0.0001
    /// Blur (pixels) before measuring, and how far either side of an edge its profile is taken.
    static let smoothing = 1.2
    static let reach = 1.5

    @concurrent
    static func estimate(_ input: Input) async -> PhotoAdjustments.LensCorrections.RadialScale? {
        estimate(input.image)
    }

    static func estimate(_ image: CIImage) -> PhotoAdjustments.LensCorrections.RadialScale? {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return nil }
        // Big enough to resolve sub-pixel shifts at the edges of the frame.
        let scale = min(1, 2000 / max(extent.width, extent.height))
        let width = Int((extent.width * scale).rounded(.down)), height = Int((extent.height * scale).rounded(.down))
        guard width > 64, height > 64 else { return nil }
        // Slightly softened: linear interpolation between pixels of very sharp edges pulls the
        // measured shifts toward whole pixels.
        let reduced = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: smoothing)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        PhotoRenderer.context.render(
            reduced, toBitmap: &pixels, rowBytes: width * 16,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        )
        let plane = Plane(pixels: pixels, width: width, height: height)
        let samples = plane.radialEdgeSamples()
        guard samples.count >= 200 else { return nil }
        guard let red = bestScale(channel: 0, plane: plane, samples: samples),
              let blue = bestScale(channel: 2, plane: plane, samples: samples) else { return nil }
        return .init(red: red, blue: blue)
    }

    /// A rendered photo's pixels; rows run top to bottom, which doesn't matter for radial scaling.
    struct Plane {
        let pixels: [Float]
        let width: Int
        let height: Int
        var center: (x: Double, y: Double) { (Double(width) / 2, Double(height) / 2) }

        func value(_ channel: Int, _ x: Double, _ y: Double) -> Double {
            let fx = x - 0.5, fy = y - 0.5
            let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
            guard x0 >= 0, y0 >= 0, x0 + 1 < width, y0 + 1 < height else { return .nan }
            let tx = fx - Double(x0), ty = fy - Double(y0)
            func at(_ x: Int, _ y: Int) -> Double { Double(pixels[(y * width + x) * 4 + channel]) }
            let top = at(x0, y0) * (1 - tx) + at(x0 + 1, y0) * tx
            let bottom = at(x0, y0 + 1) * (1 - tx) + at(x0 + 1, y0 + 1) * tx
            return top * (1 - ty) + bottom * ty
        }

        /// Points on strong green edges, away from the center, whose gradient points along the
        /// radius, with that radial direction.
        func radialEdgeSamples() -> [(x: Double, y: Double, dx: Double, dy: Double)] {
            var samples: [(x: Double, y: Double, dx: Double, dy: Double, strength: Double)] = []
            let (cx, cy) = center
            let halfDiagonal = hypot(cx, cy)
            for y in stride(from: 2, to: height - 2, by: 1) {
                for x in stride(from: 2, to: width - 2, by: 1) {
                    let px = Double(x) + 0.5, py = Double(y) + 0.5
                    let rx = px - cx, ry = py - cy, r = hypot(rx, ry)
                    guard r > 0.35 * halfDiagonal else { continue }
                    func g(_ x: Int, _ y: Int) -> Double { Double(pixels[(y * width + x) * 4 + 1]) }
                    let gx = g(x + 1, y) - g(x - 1, y), gy = g(x, y + 1) - g(x, y - 1)
                    let strength = hypot(gx, gy)
                    guard strength > 0.05 else { continue }
                    let along = abs(gx * rx + gy * ry) / (strength * r)
                    guard along > 0.8 else { continue }
                    samples.append((px, py, rx / r, ry / r, strength))
                }
            }
            // The strongest edges, at most 40,000 of them.
            samples.sort { $0.strength > $1.strength }
            return samples.prefix(40_000).map { ($0.x, $0.y, $0.dx, $0.dy) }
        }
    }

    /// Green's edge profile across each sample: the difference a pixel either side along the radius.
    static func greenProfiles(plane: Plane, samples: [(x: Double, y: Double, dx: Double, dy: Double)]) -> [Double] {
        samples.map { s in plane.value(1, s.x + s.dx * reach, s.y + s.dy * reach) - plane.value(1, s.x - s.dx * reach, s.y - s.dy * reach) }
    }

    /// How well a channel's edge profiles, looked up at `scale` times the radius, correlate with green's.
    static func score(channel: Int, scale k: Double, plane: Plane, samples: [(x: Double, y: Double, dx: Double, dy: Double)], green: [Double]) -> Double {
        let (cx, cy) = plane.center
        var dot = 0.0, channelEnergy = 0.0, greenEnergy = 0.0
        for (s, g) in zip(samples, green) where !g.isNaN {
            let x = cx + (s.x - cx) * k, y = cy + (s.y - cy) * k
            let d = plane.value(channel, x + s.dx * reach, y + s.dy * reach) - plane.value(channel, x - s.dx * reach, y - s.dy * reach)
            guard !d.isNaN else { continue }
            dot += d * g
            channelEnergy += d * d
            greenEnergy += g * g
        }
        return channelEnergy > 0 && greenEnergy > 0 ? dot / (channelEnergy * greenEnergy).squareRoot() : -1
    }

    /// The radial scale at which a channel's edges correlate best with green's: a coarse search
    /// over the whole range, then a fine one around the best.
    static func bestScale(channel: Int, plane: Plane, samples: [(x: Double, y: Double, dx: Double, dy: Double)]) -> Double? {
        let green = greenProfiles(plane: plane, samples: samples)
        func score(_ k: Double) -> Double {
            Self.score(channel: channel, scale: k, plane: plane, samples: samples, green: green)
        }
        func best(around center: Double, step: Double, steps: Int) -> (k: Double, score: Double, scores: [Double]) {
            let scores = (-steps...steps).map { score(center + Double($0) * step) }
            let index = scores.indices.max { scores[$0] < scores[$1] }!
            return (center + Double(index - steps) * step, scores[index], scores)
        }
        let coarseStep = step * 5
        let coarse = best(around: 1, step: coarseStep, steps: Int((searchRange / coarseStep).rounded()))
        let fine = best(around: coarse.k, step: step, steps: 5)
        guard fine.score > 0.5 else { return nil }
        // Refine between neighboring scales with a parabola through the peak.
        var k = fine.k
        if let index = fine.scores.firstIndex(of: fine.score), index > 0, index < fine.scores.count - 1 {
            let a = fine.scores[index - 1], b = fine.scores[index], c = fine.scores[index + 1]
            let denominator = a - 2 * b + c
            if denominator < 0 { k += 0.5 * (a - c) / denominator * step }
        }
        // Below a hundredth of a percent, there's nothing worth correcting.
        return abs(k - 1) < 0.0001 ? 1 : (k * 100_000).rounded() / 100_000
    }
}
