import Foundation

/// Content-aware fill from the photo's own patches: Remove's fill when Use Generative AI is off (RAW-260).
///
/// Multi-scale PatchMatch (Barnes et al. 2009) with Wexler-style voting (Wexler et al. 2007): from a coarse
/// copy of the image up, every patch touching the hole is matched to the most similar patch wholly outside
/// it, and each hole pixel becomes the weighted average of what the patches over it say it should be.
///
/// The same input and seed always give the same pixels (ADR 0004): every random choice comes from the
/// seed, and the work is split into a fixed number of bands, each with its own random stream, so how many
/// cores run it doesn't change the result.
nonisolated enum PatchInpainter {
    /// An image as linear RGB floats, rows from the bottom.
    struct Image {
        var width: Int
        var height: Int
        var pixels: [Float]

        init(width: Int, height: Int, pixels: [Float]) {
            precondition(pixels.count == width * height * 3)
            self.width = width
            self.height = height
            self.pixels = pixels
        }
    }

    /// Patch radius: patches are 7 × 7.
    static let patchRadius = 3
    private static let bands = 8

    /// `image` with the pixels where `hole` is true filled in.
    static func fill(_ image: Image, hole: [Bool], seed: UInt64) -> Image {
        precondition(hole.count == image.width * image.height)
        guard hole.contains(true), hole.contains(false) else { return image }

        // The pyramid, finest first, down to a few dozen pixels or a hole a few pixels across.
        var levels = [Level(image: image, hole: hole)]
        while let last = levels.last, max(last.image.width, last.image.height) > 48, last.holeExtent > 8,
              min(last.image.width, last.image.height) >= 4 * patchRadius + 4 {
            levels.append(last.downsampled())
        }

        var estimate = levels.last!.image
        Level.diffuse(&estimate, hole: levels.last!.hole)
        var field: Field?
        for index in stride(from: levels.count - 1, through: 0, by: -1) {
            let level = levels[index]
            if index != levels.count - 1 {
                // The coarser estimate, enlarged, fills this level's hole to start from.
                let up = Level.upsample(estimate, to: level.image.width, level.image.height)
                estimate = level.image
                for i in level.hole.indices where level.hole[i] {
                    estimate.pixels[i * 3] = up.pixels[i * 3]
                    estimate.pixels[i * 3 + 1] = up.pixels[i * 3 + 1]
                    estimate.pixels[i * 3 + 2] = up.pixels[i * 3 + 2]
                }
            }
            let context = level.matchingContext()
            guard !context.sources.isEmpty, !context.targets.isEmpty else { continue }
            var nnf = field.map { $0.upsampled(to: context, levelSeed: seed &+ UInt64(index)) }
                ?? Field.random(context, seed: seed &+ UInt64(index))
            // More rounds where the image is small and each is cheap.
            let rounds = index == levels.count - 1 ? 6 : (index == 0 ? 2 : 3)
            for round in 0..<rounds {
                nnf.search(in: estimate, context: context, sweeps: 2, seed: seed &+ UInt64(index * 977 + round * 31))
                vote(nnf, context: context, hole: level.hole, into: &estimate)
            }
            field = nnf
        }
        // Only the hole changes.
        var result = image
        for i in hole.indices where hole[i] {
            result.pixels[i * 3] = estimate.pixels[i * 3]
            result.pixels[i * 3 + 1] = estimate.pixels[i * 3 + 1]
            result.pixels[i * 3 + 2] = estimate.pixels[i * 3 + 2]
        }
        return result
    }

    // MARK: - Pyramid

    private struct Level {
        var image: Image
        var hole: [Bool]

        /// The hole's larger side, in pixels.
        var holeExtent: Int {
            var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
            for y in 0..<image.height {
                for x in 0..<image.width where hole[y * image.width + x] {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            return minX > maxX ? 0 : max(maxX - minX, maxY - minY) + 1
        }

        /// Half the size: each pixel the average of the known pixels under it, and part of the hole if any were.
        func downsampled() -> Level {
            let w = max(1, image.width / 2), h = max(1, image.height / 2)
            var pixels = [Float](repeating: 0, count: w * h * 3)
            var holes = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    var sum: (Float, Float, Float) = (0, 0, 0), count: Float = 0, anyHole = false
                    for dy in 0..<2 {
                        for dx in 0..<2 {
                            let sx = min(image.width - 1, x * 2 + dx), sy = min(image.height - 1, y * 2 + dy)
                            let i = sy * image.width + sx
                            if hole[i] { anyHole = true; continue }
                            sum.0 += image.pixels[i * 3]; sum.1 += image.pixels[i * 3 + 1]; sum.2 += image.pixels[i * 3 + 2]
                            count += 1
                        }
                    }
                    let o = y * w + x
                    holes[o] = anyHole
                    if count > 0 { pixels[o * 3] = sum.0 / count; pixels[o * 3 + 1] = sum.1 / count; pixels[o * 3 + 2] = sum.2 / count }
                }
            }
            return Level(image: Image(width: w, height: h, pixels: pixels), hole: holes)
        }

        /// Fills the hole from its edge inward, each pixel the average of its known neighbors: a smooth start
        /// for the coarsest level.
        static func diffuse(_ image: inout Image, hole: [Bool]) {
            var known = hole.map { !$0 }
            var remaining = hole.filter { $0 }.count
            let w = image.width, h = image.height
            while remaining > 0 {
                var next: [(Int, Float, Float, Float)] = []
                for y in 0..<h {
                    for x in 0..<w where !known[y * w + x] {
                        var sum: (Float, Float, Float) = (0, 0, 0), count: Float = 0
                        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                            let nx = x + dx, ny = y + dy
                            guard nx >= 0, nx < w, ny >= 0, ny < h, known[ny * w + nx] else { continue }
                            let i = (ny * w + nx) * 3
                            sum.0 += image.pixels[i]; sum.1 += image.pixels[i + 1]; sum.2 += image.pixels[i + 2]
                            count += 1
                        }
                        if count > 0 { next.append((y * w + x, sum.0 / count, sum.1 / count, sum.2 / count)) }
                    }
                }
                guard !next.isEmpty else { break }
                for (i, r, g, b) in next {
                    image.pixels[i * 3] = r; image.pixels[i * 3 + 1] = g; image.pixels[i * 3 + 2] = b
                    known[i] = true
                }
                remaining -= next.count
            }
        }

        /// `image` enlarged (bilinear) to `width` × `height`.
        static func upsample(_ image: Image, to width: Int, _ height: Int) -> Image {
            var pixels = [Float](repeating: 0, count: width * height * 3)
            let sx = Float(image.width) / Float(width), sy = Float(image.height) / Float(height)
            for y in 0..<height {
                let fy = max(0, min(Float(image.height - 1), (Float(y) + 0.5) * sy - 0.5))
                let y0 = Int(fy), y1 = min(image.height - 1, y0 + 1), ty = fy - Float(y0)
                for x in 0..<width {
                    let fx = max(0, min(Float(image.width - 1), (Float(x) + 0.5) * sx - 0.5))
                    let x0 = Int(fx), x1 = min(image.width - 1, x0 + 1), tx = fx - Float(x0)
                    for c in 0..<3 {
                        let a = image.pixels[(y0 * image.width + x0) * 3 + c], b = image.pixels[(y0 * image.width + x1) * 3 + c]
                        let d = image.pixels[(y1 * image.width + x0) * 3 + c], e = image.pixels[(y1 * image.width + x1) * 3 + c]
                        pixels[(y * width + x) * 3 + c] = (a * (1 - tx) + b * tx) * (1 - ty) + (d * (1 - tx) + e * tx) * ty
                    }
                }
            }
            return Image(width: width, height: height, pixels: pixels)
        }

        /// Where patches may come from (centers whose patch is inside the image and clear of the hole) and
        /// which need matching (centers whose patch is inside the image and touches the hole).
        func matchingContext() -> MatchingContext {
            let w = image.width, h = image.height, r = PatchInpainter.patchRadius
            // Distance to the nearest hole pixel within r (Chebyshev), by dilating the hole r times.
            var near = hole
            for _ in 0..<r {
                var grown = near
                for y in 0..<h {
                    for x in 0..<w where !near[y * w + x] {
                        if (x > 0 && near[y * w + x - 1]) || (x < w - 1 && near[y * w + x + 1])
                            || (y > 0 && near[(y - 1) * w + x]) || (y < h - 1 && near[(y + 1) * w + x])
                            || (x > 0 && y > 0 && near[(y - 1) * w + x - 1]) || (x < w - 1 && y < h - 1 && near[(y + 1) * w + x + 1])
                            || (x > 0 && y < h - 1 && near[(y + 1) * w + x - 1]) || (x < w - 1 && y > 0 && near[(y - 1) * w + x + 1]) {
                            grown[y * w + x] = true
                        }
                    }
                }
                near = grown
            }
            var sources: [Int32] = [], targets: [Int32] = []
            var targetIndex = [Int32](repeating: -1, count: w * h)
            for y in r..<max(r, h - r) {
                for x in r..<max(r, w - r) {
                    let i = y * w + x
                    if near[i] {
                        targetIndex[i] = Int32(targets.count)
                        targets.append(Int32(i))
                    } else {
                        sources.append(Int32(i))
                    }
                }
            }
            return MatchingContext(width: w, height: h, sources: sources, targets: targets, targetIndex: targetIndex,
                                   isSource: { var s = [Bool](repeating: false, count: w * h); for i in sources { s[Int(i)] = true }; return s }())
        }
    }

    struct MatchingContext {
        var width: Int
        var height: Int
        /// Patch centers clear of the hole (pixel indices).
        var sources: [Int32]
        /// Patch centers touching the hole, in rows from the bottom.
        var targets: [Int32]
        /// Each pixel's place in `targets`, or -1.
        var targetIndex: [Int32]
        var isSource: [Bool]
    }

    // MARK: - Nearest-neighbor field

    private struct Field {
        /// For each target, the source patch center it copies and how far that patch is from it.
        var match: [Int32]
        var distance: [Float]

        static func random(_ context: MatchingContext, seed: UInt64) -> Field {
            var rng = SeededGenerator(seed: seed)
            let match = context.targets.map { _ in context.sources[Int(rng.next() % UInt64(context.sources.count))] }
            return Field(match: match, distance: [Float](repeating: .infinity, count: match.count))
        }

        /// The coarser level's matches, doubled, for this level's targets; a target whose match lands off the
        /// sources gets a random one.
        func upsampled(to context: MatchingContext, levelSeed: UInt64) -> Field {
            var rng = SeededGenerator(seed: levelSeed ^ 0x9E37_79B9_7F4A_7C15)
            // The coarse targets' matches as offsets, looked up by coarse pixel.
            let coarseWidth = max(1, context.width / 2)
            var offsets: [Int: (Int, Int)] = [:]
            offsets.reserveCapacity(match.count)
            for (t, m) in zip(coarseTargets, match) {
                offsets[Int(t)] = (Int(m) % coarseWidth - Int(t) % coarseWidth, Int(m) / coarseWidth - Int(t) / coarseWidth)
            }
            var result = [Int32](repeating: 0, count: context.targets.count)
            for (k, t) in context.targets.enumerated() {
                let x = Int(t) % context.width, y = Int(t) / context.width
                let coarse = min(y / 2, context.height / 2 - 1) * coarseWidth + min(x / 2, coarseWidth - 1)
                if let (dx, dy) = offsets[coarse] {
                    let sx = x + dx * 2, sy = y + dy * 2
                    if sx >= 0, sx < context.width, sy >= 0, sy < context.height, context.isSource[sy * context.width + sx] {
                        result[k] = Int32(sy * context.width + sx)
                        continue
                    }
                }
                result[k] = context.sources[Int(rng.next() % UInt64(context.sources.count))]
            }
            return Field(match: result, distance: [Float](repeating: .infinity, count: result.count))
        }

        /// The coarser level's targets, kept so ``upsampled(to:levelSeed:)`` can read the matches by pixel.
        var coarseTargets: [Int32] = []

        init(match: [Int32], distance: [Float]) {
            self.match = match
            self.distance = distance
        }

        /// PatchMatch: each band of targets in turn takes a neighbor's match shifted by one when that's
        /// closer (propagation), then tries random matches ever nearer its own (search). Bands work at the
        /// same time and see each other's matches only as they were when the sweep began.
        mutating func search(in image: Image, context: MatchingContext, sweeps: Int, seed: UInt64) {
            let count = context.targets.count
            let pixels = image.pixels
            // Distances for the matches carried over (the image has changed since they were measured).
            pixels.withUnsafeBufferPointer { pixels in
                for k in 0..<count {
                    distance[k] = PatchInpainter.distance(pixels, context.width, Int(context.targets[k]), Int(match[k]), .infinity)
                }
            }
            let bandSize = (count + PatchInpainter.bands - 1) / PatchInpainter.bands
            for sweep in 0..<sweeps {
                let reverse = sweep % 2 == 1
                let snapshot = match, distances = distance
                let slots = (0..<PatchInpainter.bands).map { _ in BandSlot() }
                DispatchQueue.concurrentPerform(iterations: PatchInpainter.bands) { band in
                    let lower = band * bandSize, upper = min(count, lower + bandSize)
                    guard lower < upper else { return }
                    var localMatch = Array(snapshot[lower..<upper]), localDistance = Array(distances[lower..<upper])
                    var rng = SeededGenerator(seed: seed &+ UInt64(sweep) &* 0x2545_F491_4F6C_DD1D &+ UInt64(band))
                    pixels.withUnsafeBufferPointer { pixels in
                        PatchInpainter.sweep(pixels: pixels, context: context, lower: lower, upper: upper, reverse: reverse,
                                             snapshot: snapshot, match: &localMatch, distance: &localDistance, rng: &rng)
                    }
                    slots[band].lower = lower
                    slots[band].match = localMatch
                    slots[band].distance = localDistance
                }
                for slot in slots where !slot.match.isEmpty {
                    match.replaceSubrange(slot.lower..<slot.lower + slot.match.count, with: slot.match)
                    distance.replaceSubrange(slot.lower..<slot.lower + slot.distance.count, with: slot.distance)
                }
            }
            coarseTargets = context.targets
        }
    }

    /// One band's results from a sweep; each band writes only its own.
    private final class BandSlot: @unchecked Sendable {
        var lower = 0
        var match: [Int32] = []
        var distance: [Float] = []
    }

    /// One band's propagation and random search, in scan order (or reversed).
    private static func sweep(
        pixels: UnsafeBufferPointer<Float>, context: MatchingContext, lower: Int, upper: Int, reverse: Bool,
        snapshot: [Int32], match: inout [Int32], distance: inout [Float], rng: inout SeededGenerator
    ) {
        let w = context.width, h = context.height
        let step = reverse ? -1 : 1
        var k = reverse ? upper - 1 : lower
        // The current match of the target at pixel `i`: this band's own if it's in the band, else the snapshot's.
        func current(_ i: Int) -> Int? {
            let t = Int(context.targetIndex[i])
            guard t >= 0 else { return nil }
            return t >= lower && t < upper ? Int(match[t - lower]) : Int(snapshot[t])
        }
        while k >= lower && k < upper {
            let local = k - lower
            let target = Int(context.targets[k])
            let tx = target % w, ty = target / w
            var best = Int(match[local]), bestDistance = distance[local]
            // Propagation: the neighbor before this one (in the sweep's direction), shifted to line up.
            for (dx, dy) in [(-step, 0), (0, -step)] {
                let nx = tx + dx, ny = ty + dy
                guard nx >= 0, nx < w, ny >= 0, ny < h, let neighbor = current(ny * w + nx) else { continue }
                let sx = neighbor % w - dx, sy = neighbor / w - dy
                guard sx >= 0, sx < w, sy >= 0, sy < h else { continue }
                let candidate = sy * w + sx
                guard candidate != best, context.isSource[candidate] else { continue }
                let d = PatchInpainter.distance(pixels, w, target, candidate, bestDistance)
                if d < bestDistance { best = candidate; bestDistance = d }
            }
            // Random search in windows halving from the whole image.
            var radius = max(w, h)
            while radius >= 1 {
                let bx = best % w, by = best / w
                let rx = bx + Int(rng.next() % UInt64(2 * radius + 1)) - radius
                let ry = by + Int(rng.next() % UInt64(2 * radius + 1)) - radius
                if rx >= 0, rx < w, ry >= 0, ry < h {
                    let candidate = ry * w + rx
                    if candidate != best, context.isSource[candidate] {
                        let d = PatchInpainter.distance(pixels, w, target, candidate, bestDistance)
                        if d < bestDistance { best = candidate; bestDistance = d }
                    }
                }
                radius /= 2
            }
            match[local] = Int32(best)
            distance[local] = bestDistance
            k += step
        }
    }

    /// Sum of squared differences between the patches centered on pixels `a` and `b`, giving up (returning
    /// something at least `limit`) once it passes `limit`.
    @inline(__always)
    private static func distance(_ pixels: UnsafeBufferPointer<Float>, _ width: Int, _ a: Int, _ b: Int, _ limit: Float) -> Float {
        let r = patchRadius
        var sum: Float = 0
        for dy in -r...r {
            let rowA = (a + dy * width - r) * 3, rowB = (b + dy * width - r) * 3
            for i in 0..<((2 * r + 1) * 3) {
                let d = pixels[rowA + i] - pixels[rowB + i]
                sum += d * d
            }
            if sum >= limit { return sum }
        }
        return sum
    }

    /// Each hole pixel becomes the average of the pixels the matched patches over it would put there, the
    /// closer matches counting for more.
    private static func vote(_ field: Field, context: MatchingContext, hole: [Bool], into image: inout Image) {
        let w = context.width, r = patchRadius
        // Weights from how good each match is, relative to a typical one.
        let finite = field.distance.filter { $0.isFinite }.sorted()
        let typical = max(finite.isEmpty ? 1 : finite[finite.count * 3 / 4], 1e-6)
        var sums = [Float](repeating: 0, count: w * context.height * 3)
        var weights = [Float](repeating: 0, count: w * context.height)
        image.pixels.withUnsafeBufferPointer { pixels in
            for (k, target) in context.targets.enumerated() {
                let d = field.distance[k]
                let weight = d.isFinite ? exp(-d / (2 * typical)) : 1e-4
                let t = Int(target), s = Int(field.match[k])
                for dy in -r...r {
                    for dx in -r...r {
                        let p = t + dy * w + dx
                        guard hole[p] else { continue }
                        let q = s + dy * w + dx
                        sums[p * 3] += pixels[q * 3] * weight
                        sums[p * 3 + 1] += pixels[q * 3 + 1] * weight
                        sums[p * 3 + 2] += pixels[q * 3 + 2] * weight
                        weights[p] += weight
                    }
                }
            }
        }
        for p in hole.indices where hole[p] && weights[p] > 0 {
            image.pixels[p * 3] = sums[p * 3] / weights[p]
            image.pixels[p * 3 + 1] = sums[p * 3 + 1] / weights[p]
            image.pixels[p * 3 + 2] = sums[p * 3 + 2] / weights[p]
        }
    }
}

/// SplitMix64: a small, fast generator whose sequence depends only on its seed.
nonisolated struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
