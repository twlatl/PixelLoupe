import Accelerate
import Foundation
import simd

/// One photo as the panorama aligner sees it: its brightness (gamma-encoded gray, exposure-matched
/// to the others), top row first.
nonisolated struct PanoramaAlignmentImage: Sendable {
    var width: Int
    var height: Int
    var pixels: [Float]
    /// The lens's focal length in pixels at this size, when the photo records it; otherwise the
    /// aligner estimates it from how the photos overlap.
    var focalLength: Double?
}

/// Where a photo points in the panorama: the camera's rotation and focal length. Camera axes are x
/// right, y down and z forward (along the lens), so a pixel at (u, v) from the photo's center sees
/// the direction (u, v, f) in camera space and `rotation`ᵀ · (u, v, f) in the panorama's.
nonisolated struct PanoramaCamera: Sendable, Equatable {
    /// World to camera.
    var rotation: simd_double3x3
    /// In pixels at the size the photo was aligned at (see ``scaled(by:)``).
    var focalLength: Double

    /// The same camera for the photo at `factor` times the size.
    func scaled(by factor: Double) -> PanoramaCamera {
        PanoramaCamera(rotation: rotation, focalLength: focalLength * factor)
    }

    /// The direction a pixel sees (unit length), from the photo's center in pixels, y down.
    func ray(_ point: SIMD2<Double>) -> SIMD3<Double> {
        simd_normalize(rotation.transpose * SIMD3(point.x, point.y, focalLength))
    }

    /// Where a direction lands in the photo (from its center, y down), or nil behind the camera.
    func project(_ ray: SIMD3<Double>) -> SIMD2<Double>? {
        let camera = rotation * ray
        guard camera.z > 1e-9 else { return nil }
        return SIMD2(camera.x, camera.y) * (focalLength / camera.z)
    }
}

nonisolated struct PanoramaAlignment: Sendable {
    /// Each photo's camera, nil for a photo that doesn't overlap the others (left out of the merge).
    var cameras: [PanoramaCamera?]
    /// How many matched points each pair of photos shares, for the pairs that overlap.
    var overlaps: [PanoramaAligner.Pair: Int]

    var mergedCount: Int { cameras.count { $0 != nil } }
}

nonisolated enum PanoramaAlignmentError: LocalizedError, Equatable {
    case noOverlap

    var errorDescription: String? {
        switch self {
        case .noOverlap: "The photos don’t overlap enough to be merged into a panorama."
        }
    }
}

/// Finds how panorama photos fit together, as a camera turning about one point (Lightroom's model):
///
/// 1. Corners in each photo (Harris), each described by the brightness around it: an 8 × 8 sample of
///    a 40-pixel patch, normalized for brightness and contrast, so differently exposed photos match.
/// 2. Every pair of photos' corners matched (nearest descriptor, clearly better than the next), and
///    the matches checked with RANSAC against a homography; a pair overlaps when enough agree.
/// 3. The overlapping photos' rotations and focal length, started from the strongest overlaps and
///    refined together (bundle adjustment) so the matched points' directions agree.
/// 4. The result levelled (Brown and Lowe's wave correction), so the horizon is straight and
///    verticals stand up, and turned so the panorama is centered on the photos.
///
/// Photos in the largest group of overlapping photos are merged; the others are left out.
nonisolated enum PanoramaAligner {
    /// Two photos, by index (`first` < `second`).
    struct Pair: Hashable, Sendable {
        var first: Int
        var second: Int
    }

    /// A point matched between two photos, in pixels from each photo's center (y down).
    struct Match: Sendable {
        var first: SIMD2<Double>
        var second: SIMD2<Double>
    }

    /// The most corners kept per photo.
    static let maximumFeatures = 2000
    /// How close (pixels) a match must land to where the homography puts it to count as agreeing.
    static let inlierTolerance = 3.0

    static func align(_ images: [PanoramaAlignmentImage]) throws -> PanoramaAlignment {
        let features = images.map(detectFeatures)
        var matches: [Pair: [Match]] = [:]
        var homographies: [Pair: simd_double3x3] = [:]
        for first in images.indices {
            for second in images.indices where second > first {
                let pair = Pair(first: first, second: second)
                let candidates = match(features[first], features[second])
                guard let fit = verifiedHomography(candidates) else { continue }
                matches[pair] = fit.inliers
                homographies[pair] = fit.homography
            }
        }
        let component = largestComponent(count: images.count, pairs: Array(matches.keys))
        guard component.count >= 2 else { throw PanoramaAlignmentError.noOverlap }
        let inComponent = Set(component)
        matches = matches.filter { inComponent.contains($0.key.first) && inComponent.contains($0.key.second) }

        let focal = initialFocalLength(images: images, component: component, homographies: homographies)
        var cameras = initialCameras(
            component: component, focal: focal, matches: matches, homographies: homographies, count: images.count
        )
        let sharesFocalLength = Set(component.map { images[$0].focalLength.map { ($0 * 1000).rounded() } ?? -1 }).count == 1
        refine(&cameras, matches: matches, sharedFocalLength: sharesFocalLength)
        level(&cameras)
        return PanoramaAlignment(cameras: cameras, overlaps: matches.mapValues(\.count))
    }

    // MARK: - Features

    struct Features: Sendable {
        /// From the photo's center, y down.
        var points: [SIMD2<Double>]
        /// 64 values per point, normalized to mean 0 and variance 1.
        var descriptors: [Float]
    }

    static let descriptorSide = 8
    static let descriptorSpacing: Float = 5

    /// Harris corners (the Noble measure), at most one per small cell so they cover the photo,
    /// the strongest kept, with their patch descriptors.
    static func detectFeatures(_ image: PanoramaAlignmentImage) -> Features {
        let width = image.width, height = image.height
        guard width > 64, height > 64 else { return Features(points: [], descriptors: []) }
        // The structure tensor's entries, smoothed, then Noble's det / trace (with vImage and vDSP).
        let smooth = gaussianBlur(image.pixels, width: width, height: height, sigma: 1)
        let gx = convolve(smooth, width: width, height: height, kernel: [-0.5, 0, 0.5], horizontal: true)
        let gy = convolve(smooth, width: width, height: height, kernel: [-0.5, 0, 0.5], horizontal: false)
        let pixelCount = vDSP_Length(width * height)
        var xx = [Float](repeating: 0, count: width * height), yy = xx, xy = xx
        vDSP_vmul(gx, 1, gx, 1, &xx, 1, pixelCount)
        vDSP_vmul(gy, 1, gy, 1, &yy, 1, pixelCount)
        vDSP_vmul(gx, 1, gy, 1, &xy, 1, pixelCount)
        xx = gaussianBlur(xx, width: width, height: height, sigma: 1.5)
        yy = gaussianBlur(yy, width: width, height: height, sigma: 1.5)
        xy = gaussianBlur(xy, width: width, height: height, sigma: 1.5)
        var determinant = [Float](repeating: 0, count: width * height), cross = determinant, trace = determinant
        vDSP_vmul(xx, 1, yy, 1, &determinant, 1, pixelCount)
        vDSP_vmul(xy, 1, xy, 1, &cross, 1, pixelCount)
        vDSP_vsub(cross, 1, determinant, 1, &determinant, 1, pixelCount)
        vDSP_vadd(xx, 1, yy, 1, &trace, 1, pixelCount)
        var tiny: Float = 1e-6
        vDSP_vsadd(trace, 1, &tiny, &trace, 1, pixelCount)
        var response = [Float](repeating: 0, count: width * height)
        vDSP_vdiv(trace, 1, determinant, 1, &response, 1, pixelCount)

        // The strongest local maximum in each cell, away from the edges (the patch must fit).
        let margin = Int(Float(descriptorSide) * descriptorSpacing / 2) + 3
        let cell = max(8, max(width, height) / 64)
        var candidates: [(x: Int, y: Int, response: Float)] = []
        for cellY in stride(from: margin, to: height - margin, by: cell) {
            for cellX in stride(from: margin, to: width - margin, by: cell) {
                var best: (x: Int, y: Int, response: Float)?
                for y in cellY..<min(cellY + cell, height - margin) {
                    for x in cellX..<min(cellX + cell, width - margin) {
                        let value = response[y * width + x]
                        if value > (best?.response ?? 0) { best = (x, y, value) }
                    }
                }
                guard let best else { continue }
                // A true local maximum, not the edge of a neighboring cell's corner.
                var isPeak = true
                for dy in -2...2 where isPeak {
                    for dx in -2...2 where dx != 0 || dy != 0 {
                        if response[(best.y + dy) * width + best.x + dx] > best.response { isPeak = false; break }
                    }
                }
                if isPeak { candidates.append(best) }
            }
        }
        // Flat areas (sky) have weak "corners" from noise: keep those well above the typical one.
        let sorted = candidates.map(\.response).sorted()
        let floor = sorted.isEmpty ? 0 : sorted[sorted.count / 2] * 0.1
        candidates = candidates.filter { $0.response > floor }.sorted { $0.response > $1.response }
        candidates = Array(candidates.prefix(maximumFeatures))

        let patches = gaussianBlur(image.pixels, width: width, height: height, sigma: descriptorSpacing / 2)
        var points: [SIMD2<Double>] = []
        var descriptors: [Float] = []
        let side = descriptorSide, count = side * side
        let start = -descriptorSpacing * Float(side - 1) / 2
        var patch = [Float](repeating: 0, count: count)
        let center = SIMD2(Double(width) / 2, Double(height) / 2)
        for candidate in candidates {
            var sum: Float = 0
            for row in 0..<side {
                for column in 0..<side {
                    let value = bilinear(patches, width: width, height: height,
                                         x: Float(candidate.x) + start + Float(column) * descriptorSpacing,
                                         y: Float(candidate.y) + start + Float(row) * descriptorSpacing)
                    patch[row * side + column] = value
                    sum += value
                }
            }
            let mean = sum / Float(count)
            var variance: Float = 0
            for i in 0..<count { patch[i] -= mean; variance += patch[i] * patch[i] }
            variance /= Float(count)
            guard variance > 1e-7 else { continue }
            let scale = 1 / sqrt(variance)
            points.append(SIMD2(Double(candidate.x), Double(candidate.y)) - center)
            descriptors.append(contentsOf: patch.map { $0 * scale })
        }
        return Features(points: points, descriptors: descriptors)
    }

    /// Each feature's best match in the other photo, kept when it's clearly better than the second
    /// best (Lowe's ratio test) and the two features choose each other.
    static func match(_ a: Features, _ b: Features) -> [Match] {
        let n = a.points.count, m = b.points.count, length = descriptorSide * descriptorSide
        guard n >= 4, m >= 4 else { return [] }
        // Dot products of the normalized descriptors: the distance² between them is 2·64 − 2·dot.
        var transposed = [Float](repeating: 0, count: m * length)
        vDSP_mtrans(b.descriptors, 1, &transposed, 1, vDSP_Length(length), vDSP_Length(m))
        var dots = [Float](repeating: 0, count: n * m)
        vDSP_mmul(a.descriptors, 1, transposed, 1, &dots, 1, vDSP_Length(n), vDSP_Length(m), vDSP_Length(length))
        let total = Float(2 * length)
        func distance(_ dot: Float) -> Float { sqrt(max(0, total - 2 * dot)) }

        // Each row's best and second best (vDSP, so it's quick in any build), and each column's best.
        var bestForA = [(index: Int, best: Float, second: Float)]()
        bestForA.reserveCapacity(n)
        dots.withUnsafeMutableBufferPointer { buffer in
            for i in 0..<n {
                let row = buffer.baseAddress! + i * m
                var best: Float = 0, index: vDSP_Length = 0
                vDSP_maxvi(row, 1, &best, &index, vDSP_Length(m))
                let saved = row[Int(index)]
                row[Int(index)] = -.infinity
                var second: Float = 0
                vDSP_maxv(row, 1, &second, vDSP_Length(m))
                row[Int(index)] = saved
                bestForA.append((Int(index), best, second))
            }
        }
        var columns = [Float](repeating: 0, count: m * n)
        vDSP_mtrans(dots, 1, &columns, 1, vDSP_Length(m), vDSP_Length(n))
        var bestForB = [Int](repeating: -1, count: m)
        columns.withUnsafeBufferPointer { buffer in
            for j in 0..<m {
                var best: Float = 0, index: vDSP_Length = 0
                vDSP_maxvi(buffer.baseAddress! + j * n, 1, &best, &index, vDSP_Length(n))
                bestForB[j] = Int(index)
            }
        }
        var result: [Match] = []
        for i in 0..<n {
            let (j, best, second) = bestForA[i]
            guard bestForB[j] == i, distance(best) < 0.75 * distance(second) else { continue }
            result.append(Match(first: a.points[i], second: b.points[j]))
        }
        return result
    }

    // MARK: - Homographies

    /// The homography most matches agree with (RANSAC, then refitted to all that agree), when
    /// enough do for the photos to overlap rather than match by chance (Brown and Lowe's test).
    static func verifiedHomography(_ matches: [Match]) -> (homography: simd_double3x3, inliers: [Match])? {
        guard matches.count >= 12 else { return nil }
        var generator = SplitMix(seed: UInt64(matches.count))
        var bestInliers: [Int] = []
        var iterations = 0, limit = 2000
        while iterations < limit {
            iterations += 1
            var picks = Set<Int>()
            while picks.count < 4 { picks.insert(Int(generator.next() % UInt64(matches.count))) }
            guard let h = homography(Array(picks).map { matches[$0] }) else { continue }
            let inliers = matches.indices.filter { error(h, matches[$0]) < inlierTolerance }
            if inliers.count > bestInliers.count {
                bestInliers = inliers
                // Enough tries to draw four inliers at least once with 99.9% confidence.
                let ratio = Double(inliers.count) / Double(matches.count)
                let needed = log(0.001) / log(max(1e-9, 1 - pow(ratio, 4)))
                limit = min(limit, max(50, Int(needed.rounded(.up))))
            }
        }
        guard bestInliers.count >= 4, var h = homography(bestInliers.map { matches[$0] }) else { return nil }
        var inliers = matches.filter { error(h, $0) < inlierTolerance }
        if let refit = homography(inliers) {
            h = refit
            inliers = matches.filter { error(h, $0) < inlierTolerance }
        }
        guard inliers.count >= 15, Double(inliers.count) > 8 + 0.3 * Double(matches.count) else { return nil }
        return (h, inliers)
    }

    /// Distance (pixels) from where `h` puts the match's first point to its second.
    static func error(_ h: simd_double3x3, _ match: Match) -> Double {
        let p = h * SIMD3(match.first.x, match.first.y, 1)
        guard abs(p.z) > 1e-12 else { return .infinity }
        return simd_distance(SIMD2(p.x, p.y) / p.z, match.second)
    }

    /// The homography taking the matches' first points to their second (least squares over all of
    /// them, with Hartley's normalization), or nil when they don't pin one down.
    static func homography(_ matches: [Match]) -> simd_double3x3? {
        guard matches.count >= 4 else { return nil }
        func normalizer(_ points: [SIMD2<Double>]) -> simd_double3x3 {
            let mean = points.reduce(.zero, +) / Double(points.count)
            let spread = points.reduce(0) { $0 + simd_distance($1, mean) } / Double(points.count)
            let s = spread > 1e-12 ? sqrt(2) / spread : 1
            return simd_double3x3(rows: [SIMD3(s, 0, -s * mean.x), SIMD3(0, s, -s * mean.y), SIMD3(0, 0, 1)])
        }
        let ta = normalizer(matches.map(\.first)), tb = normalizer(matches.map(\.second))
        // Normal equations for h (h₃₃ = 1): two rows per match.
        var ata = [Double](repeating: 0, count: 64), atb = [Double](repeating: 0, count: 8)
        for match in matches {
            let a = ta * SIMD3(match.first.x, match.first.y, 1), b = tb * SIMD3(match.second.x, match.second.y, 1)
            let rows: [([Double], Double)] = [
                ([a.x, a.y, 1, 0, 0, 0, -a.x * b.x, -a.y * b.x], b.x),
                ([0, 0, 0, a.x, a.y, 1, -a.x * b.y, -a.y * b.y], b.y),
            ]
            for (row, value) in rows {
                for i in 0..<8 {
                    atb[i] += row[i] * value
                    for j in 0..<8 { ata[i * 8 + j] += row[i] * row[j] }
                }
            }
        }
        guard let h = solve(ata, atb, size: 8) else { return nil }
        let normalized = simd_double3x3(rows: [SIMD3(h[0], h[1], h[2]), SIMD3(h[3], h[4], h[5]), SIMD3(h[6], h[7], 1)])
        let result = tb.inverse * normalized * ta
        guard abs(result[2, 2]) > 1e-12, result.determinant.isFinite, abs(result.determinant) > 1e-12 else { return nil }
        return result * (1 / result[2, 2])
    }

    // MARK: - Cameras

    /// Groups of photos linked by overlaps; the biggest one, in index order.
    static func largestComponent(count: Int, pairs: [Pair]) -> [Int] {
        var parent = Array(0..<count)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for pair in pairs { parent[root(pair.first)] = root(pair.second) }
        let groups = Dictionary(grouping: 0..<count, by: root)
        return groups.values.max { $0.count < $1.count || ($0.count == $1.count && $0[0] > $1[0]) } ?? []
    }

    /// The photos' focal length in pixels: what they record, or else the median of what the
    /// homographies imply (OpenCV's estimate), or else a normal lens's.
    static func initialFocalLength(images: [PanoramaAlignmentImage], component: [Int], homographies: [Pair: simd_double3x3]) -> [Double] {
        if component.allSatisfy({ images[$0].focalLength != nil }) {
            return images.map { $0.focalLength ?? 0 }
        }
        var estimates: [Double] = []
        for (pair, h) in homographies where component.contains(pair.first) && component.contains(pair.second) {
            if let f = focalLengths(from: h) { estimates.append(f) }
        }
        estimates.sort()
        let fallback = Double(images.map { max($0.width, $0.height) }.max() ?? 1000)
        let estimate = estimates.isEmpty ? fallback : estimates[estimates.count / 2]
        return images.map { $0.focalLength ?? estimate }
    }

    /// The focal length a homography between two photos taken with the same lens implies (from
    /// OpenCV's `focalsFromHomography`), with points measured from the photos' centers.
    static func focalLengths(from homography: simd_double3x3) -> Double? {
        let h = homography.transpose // columns of the transpose are the rows
        func row(_ r: Int) -> SIMD3<Double> { h[r] }
        let r0 = row(0), r1 = row(1), r2 = row(2)
        func candidate(_ d1: Double, _ d2: Double, _ v1: Double, _ v2: Double) -> Double? {
            var (a, b) = (v1, v2)
            if a < b { swap(&a, &b) }
            if a > 0, b > 0 { return sqrt(abs(d1) > abs(d2) ? a : b) }
            if a > 0 { return sqrt(a) }
            return nil
        }
        var d1 = r2.x * r2.y, d2 = (r2.y - r2.x) * (r2.y + r2.x)
        let f1 = candidate(d1, d2, -(r0.x * r0.y + r1.x * r1.y) / d1,
                           (r0.x * r0.x + r1.x * r1.x - r0.y * r0.y - r1.y * r1.y) / d2)
        d1 = r0.x * r1.x + r0.y * r1.y
        d2 = r0.x * r0.x + r0.y * r0.y - r1.x * r1.x - r1.y * r1.y
        let f0 = candidate(d1, d2, -r0.z * r1.z / d1, (r1.z * r1.z - r0.z * r0.z) / d2)
        guard let f0, let f1, f0.isFinite, f1.isFinite else { return nil }
        return sqrt(f0 * f1)
    }

    /// Rotations to start from: the photo with the most overlap fixed, the others reached through
    /// the strongest overlaps (a maximum spanning tree), each turned by the rotation its homography
    /// implies.
    static func initialCameras(
        component: [Int], focal: [Double], matches: [Pair: [Match]], homographies: [Pair: simd_double3x3], count: Int
    ) -> [PanoramaCamera?] {
        var cameras = [PanoramaCamera?](repeating: nil, count: count)
        var strength = [Int](repeating: 0, count: count)
        for (pair, inliers) in matches {
            strength[pair.first] += inliers.count
            strength[pair.second] += inliers.count
        }
        guard let root = component.max(by: { strength[$0] < strength[$1] }) else { return cameras }
        cameras[root] = PanoramaCamera(rotation: matrix_identity_double3x3, focalLength: focal[root])
        var placed: Set<Int> = [root]
        // Prim's algorithm on overlap strength.
        while placed.count < component.count {
            var best: (from: Int, to: Int, count: Int)?
            for (pair, inliers) in matches {
                let (a, b) = (pair.first, pair.second)
                if placed.contains(a) != placed.contains(b), inliers.count > (best?.count ?? 0) {
                    best = placed.contains(a) ? (a, b, inliers.count) : (b, a, inliers.count)
                }
            }
            guard let best, let from = cameras[best.from] else { break }
            let pair = Pair(first: min(best.from, best.to), second: max(best.from, best.to))
            guard var h = homographies[pair] else { break }
            if pair.first != best.from { h = h.inverse }
            let kFrom = intrinsics(focal[best.from]), kTo = intrinsics(focal[best.to])
            let relative = orthonormalized(kTo.inverse * h * kFrom)
            cameras[best.to] = PanoramaCamera(rotation: relative * from.rotation, focalLength: focal[best.to])
            placed.insert(best.to)
        }
        return cameras
    }

    static func intrinsics(_ focal: Double) -> simd_double3x3 {
        simd_double3x3(diagonal: SIMD3(focal, focal, 1))
    }

    /// The rotation nearest `m` (polar decomposition, by Newton's iteration).
    static func orthonormalized(_ m: simd_double3x3) -> simd_double3x3 {
        var r = m * (1 / cbrt(abs(m.determinant)).nonZero)
        if r.determinant < 0 { r = r * -1 }
        for _ in 0..<30 {
            let next = (r + r.inverse.transpose) * 0.5
            if simd_length_squared((next - r).columns.0) + simd_length_squared((next - r).columns.1)
                + simd_length_squared((next - r).columns.2) < 1e-24 { return next }
            r = next
        }
        return r
    }

    // MARK: - Bundle adjustment

    /// Refines every placed camera's rotation (the first placed one stays fixed) and the focal
    /// length (one for all photos when they record the same, else one each) so matched points'
    /// directions agree: Levenberg–Marquardt on the distance between the two rays, in pixels, with
    /// Huber weights so a few bad matches don't pull everything.
    static func refine(_ cameras: inout [PanoramaCamera?], matches: [Pair: [Match]], sharedFocalLength: Bool) {
        let placed = cameras.indices.filter { cameras[$0] != nil }
        guard placed.count >= 2 else { return }
        // At most this many matches per pair, spread over the overlap, keep it quick.
        let pairs = matches.map { pair, inliers -> (Pair, [Match]) in
            let step = max(1, inliers.count / 300)
            return (pair, stride(from: 0, to: inliers.count, by: step).map { inliers[$0] })
        }
        let fixed = placed.first { cameras[$0]?.rotation == matrix_identity_double3x3 } ?? placed[0]
        let rotating = placed.filter { $0 != fixed }
        var rotationIndex: [Int: Int] = [:]
        for (i, camera) in rotating.enumerated() { rotationIndex[camera] = i * 3 }
        let focalBase = rotating.count * 3
        var focalIndex: [Int: Int] = [:]
        for (i, camera) in placed.enumerated() { focalIndex[camera] = focalBase + (sharedFocalLength ? 0 : i) }
        let parameterCount = focalBase + (sharedFocalLength ? 1 : placed.count)

        var base = cameras.map { $0 ?? PanoramaCamera(rotation: matrix_identity_double3x3, focalLength: 1) }
        let meanFocal = placed.reduce(0) { $0 + base[$1].focalLength } / Double(placed.count)

        func camera(_ index: Int, _ parameters: [Double]) -> PanoramaCamera {
            var result = base[index]
            if let r = rotationIndex[index] {
                result.rotation = rotationMatrix(SIMD3(parameters[r], parameters[r + 1], parameters[r + 2])) * result.rotation
            }
            if let f = focalIndex[index] { result.focalLength *= exp(parameters[f]) }
            return result
        }
        func residuals(_ parameters: [Double]) -> [Double] {
            var result: [Double] = []
            result.reserveCapacity(pairs.reduce(0) { $0 + $1.1.count } * 3)
            var cache: [Int: PanoramaCamera] = [:]
            for (pair, inliers) in pairs {
                let a = cache[pair.first] ?? camera(pair.first, parameters)
                let b = cache[pair.second] ?? camera(pair.second, parameters)
                cache[pair.first] = a
                cache[pair.second] = b
                for match in inliers {
                    let difference = (a.ray(match.first) - b.ray(match.second)) * meanFocal
                    result.append(difference.x)
                    result.append(difference.y)
                    result.append(difference.z)
                }
            }
            return result
        }
        func huberWeights(_ r: [Double]) -> [Double] {
            let sigma = 2.0
            return stride(from: 0, to: r.count, by: 3).flatMap { i -> [Double] in
                let norm = sqrt(r[i] * r[i] + r[i + 1] * r[i + 1] + r[i + 2] * r[i + 2])
                let w = norm <= sigma ? 1 : sigma / norm
                return [w, w, w]
            }
        }
        func cost(_ r: [Double]) -> Double {
            let sigma = 2.0
            return stride(from: 0, to: r.count, by: 3).reduce(0) { total, i in
                let norm = sqrt(r[i] * r[i] + r[i + 1] * r[i + 1] + r[i + 2] * r[i + 2])
                return total + (norm <= sigma ? norm * norm / 2 : sigma * (norm - sigma / 2))
            }
        }

        var parameters = [Double](repeating: 0, count: parameterCount)
        var r = residuals(parameters)
        var currentCost = cost(r)
        var lambda = 1e-3
        for _ in 0..<60 {
            let weights = huberWeights(r)
            // Jacobian by forward differences, one parameter at a time.
            var jacobian = [[Double]](repeating: [], count: parameterCount)
            for p in 0..<parameterCount {
                var shifted = parameters
                let step = 1e-6
                shifted[p] += step
                let rs = residuals(shifted)
                jacobian[p] = zip(rs, r).map { ($0 - $1) / step }
            }
            // JᵀWJ and JᵀWr, with the weights' square roots folded into J and r (vDSP).
            let count = r.count
            let roots = weights.map { $0.squareRoot() }
            var weighted = [Double](repeating: 0, count: parameterCount * count)
            for p in 0..<parameterCount {
                for k in 0..<count { weighted[p * count + k] = jacobian[p][k] * roots[k] }
            }
            let weightedResiduals = zip(r, roots).map { $0 * $1 }
            var transposed = [Double](repeating: 0, count: count * parameterCount)
            vDSP_mtransD(weighted, 1, &transposed, 1, vDSP_Length(count), vDSP_Length(parameterCount))
            var jtj = [Double](repeating: 0, count: parameterCount * parameterCount)
            vDSP_mmulD(weighted, 1, transposed, 1, &jtj, 1, vDSP_Length(parameterCount), vDSP_Length(parameterCount), vDSP_Length(count))
            var jtr = [Double](repeating: 0, count: parameterCount)
            vDSP_mmulD(weighted, 1, weightedResiduals, 1, &jtr, 1, vDSP_Length(parameterCount), 1, vDSP_Length(count))
            var improved = false
            for _ in 0..<10 {
                var damped = jtj
                for p in 0..<parameterCount { damped[p * parameterCount + p] *= 1 + lambda; damped[p * parameterCount + p] += 1e-12 }
                guard let delta = solve(damped, jtr.map { -$0 }, size: parameterCount) else { lambda *= 10; continue }
                let candidate = zip(parameters, delta).map(+)
                let rc = residuals(candidate)
                let candidateCost = cost(rc)
                if candidateCost < currentCost {
                    let relative = (currentCost - candidateCost) / max(currentCost, 1e-12)
                    // Fold the step into the cameras so the next one starts from zero again.
                    for index in placed { base[index] = camera(index, candidate) }
                    parameters = [Double](repeating: 0, count: parameterCount)
                    r = rc
                    currentCost = candidateCost
                    lambda = max(lambda / 10, 1e-9)
                    improved = relative > 1e-7
                    break
                }
                lambda *= 10
            }
            if !improved { break }
        }
        for index in placed { cameras[index] = base[index] }
    }

    /// The rotation by `axisAngle` (its direction the axis, its length the angle in radians).
    static func rotationMatrix(_ axisAngle: SIMD3<Double>) -> simd_double3x3 {
        let angle = simd_length(axisAngle)
        guard angle > 1e-15 else { return matrix_identity_double3x3 }
        return simd_double3x3(simd_quatd(angle: angle, axis: axisAngle / angle))
    }

    // MARK: - Levelling

    /// Turns the whole panorama so it's level and centered: "down" is the direction most
    /// perpendicular to every camera's x axis (cameras are held level as they pan, so their x axes lie
    /// in the horizon's plane), "forward" the middle of the photos across the horizon.
    static func level(_ cameras: inout [PanoramaCamera?]) {
        let placed = cameras.compactMap { $0 }
        guard !placed.isEmpty else { return }
        // A camera's axes in world space are the rows of its rotation.
        func axis(_ camera: PanoramaCamera, _ row: Int) -> SIMD3<Double> {
            SIMD3(camera.rotation[0, row], camera.rotation[1, row], camera.rotation[2, row])
        }
        var scatter = simd_double3x3()
        for camera in placed {
            let x = axis(camera, 0)
            scatter += simd_double3x3(columns: (x * x.x, x * x.y, x * x.z))
        }
        var down = smallestEigenvector(scatter)
        let cameraDown = placed.reduce(SIMD3<Double>.zero) { $0 + axis($1, 1) }
        if placed.count < 3 || simd_length(cameraDown) < 1e-9 {
            // Too few photos to say: keep the photos' own sense of down.
            down = simd_normalize(cameraDown == .zero ? SIMD3(0, 1, 0) : cameraDown)
        } else if simd_dot(down, cameraDown) < 0 {
            down = -down
        }
        var forward = placed.reduce(SIMD3<Double>.zero) { $0 + axis($1, 2) }
        forward -= down * simd_dot(forward, down)
        if simd_length(forward) < 1e-9 { forward = axis(placed[0], 2) - down * simd_dot(axis(placed[0], 2), down) }
        forward = simd_normalize(forward)
        let right = simd_normalize(simd_cross(down, forward))
        // New world axes as rows: x_world' = W · x_world, so camera rotations become R · Wᵀ.
        let world = simd_double3x3(rows: [right, down, simd_cross(right, down)])
        for index in cameras.indices {
            guard var camera = cameras[index] else { continue }
            camera.rotation = camera.rotation * world.transpose
            cameras[index] = camera
        }
    }

    /// The unit eigenvector of a symmetric matrix with the smallest eigenvalue (Jacobi's method).
    static func smallestEigenvector(_ m: simd_double3x3) -> SIMD3<Double> {
        var a = [[m[0, 0], m[1, 0], m[2, 0]], [m[0, 1], m[1, 1], m[2, 1]], [m[0, 2], m[1, 2], m[2, 2]]]
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<50 {
            var p = 0, q = 1
            for (i, j) in [(0, 2), (1, 2)] where abs(a[i][j]) > abs(a[p][q]) { p = i; q = j }
            guard abs(a[p][q]) > 1e-15 else { break }
            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let t = (theta >= 0 ? 1 : -1) / (abs(theta) + sqrt(theta * theta + 1))
            let c = 1 / sqrt(t * t + 1), s = t * c
            for k in 0..<3 {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[k][q] = s * akp + c * akq
            }
            for k in 0..<3 {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk - s * aqk
                a[q][k] = s * apk + c * aqk
            }
            for k in 0..<3 {
                let vkp = v[k][p], vkq = v[k][q]
                v[k][p] = c * vkp - s * vkq
                v[k][q] = s * vkp + c * vkq
            }
        }
        let smallest = (0..<3).min { a[$0][$0] < a[$1][$1] } ?? 0
        return simd_normalize(SIMD3(v[0][smallest], v[1][smallest], v[2][smallest]))
    }

    // MARK: - Helpers

    /// Solves `a · x = b` for a symmetric positive definite `a` (Cholesky), `size` × `size`, row major.
    static func solve(_ a: [Double], _ b: [Double], size n: Int) -> [Double]? {
        var l = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var sum = a[i * n + j]
                for k in 0..<j { sum -= l[i * n + k] * l[j * n + k] }
                if i == j {
                    guard sum > 0 else { return gaussianSolve(a, b, size: n) }
                    l[i * n + i] = sqrt(sum)
                } else {
                    l[i * n + j] = sum / l[j * n + j]
                }
            }
        }
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sum = b[i]
            for k in 0..<i { sum -= l[i * n + k] * y[k] }
            y[i] = sum / l[i * n + i]
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var sum = y[i]
            for k in (i + 1)..<n { sum -= l[k * n + i] * x[k] }
            x[i] = sum / l[i * n + i]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    /// Gaussian elimination with partial pivoting, for systems that aren't positive definite.
    static func gaussianSolve(_ a: [Double], _ b: [Double], size n: Int) -> [Double]? {
        var m = a, v = b
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(m[$0 * n + column]) < abs(m[$1 * n + column]) }),
                  abs(m[pivot * n + column]) > 1e-14 else { return nil }
            if pivot != column {
                for k in 0..<n { m.swapAt(pivot * n + k, column * n + k) }
                v.swapAt(pivot, column)
            }
            for row in (column + 1)..<n {
                let factor = m[row * n + column] / m[column * n + column]
                guard factor != 0 else { continue }
                for k in column..<n { m[row * n + k] -= factor * m[column * n + k] }
                v[row] -= factor * v[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = v[row]
            for k in (row + 1)..<n { sum -= m[row * n + k] * x[k] }
            x[row] = sum / m[row * n + row]
        }
        return x.allSatisfy(\.isFinite) ? x : nil
    }

    /// A separable Gaussian blur (edges extended).
    static func gaussianBlur(_ pixels: [Float], width: Int, height: Int, sigma: Float) -> [Float] {
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = (-radius...radius).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        var source = pixels
        var middle = [Float](repeating: 0, count: pixels.count)
        var output = [Float](repeating: 0, count: pixels.count)
        source.withUnsafeMutableBufferPointer { s in
            middle.withUnsafeMutableBufferPointer { m in
                output.withUnsafeMutableBufferPointer { o in
                    var src = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                    var mid = vImage_Buffer(data: m.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                    var dst = vImage_Buffer(data: o.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                    let length = UInt32(kernel.count)
                    vImageConvolve_PlanarF(&src, &mid, nil, 0, 0, kernel, 1, length, 0, vImage_Flags(kvImageEdgeExtend))
                    vImageConvolve_PlanarF(&mid, &dst, nil, 0, 0, kernel, length, 1, 0, vImage_Flags(kvImageEdgeExtend))
                }
            }
        }
        return output
    }

    /// A one-dimensional convolution along rows (`horizontal`) or columns (edges extended).
    static func convolve(_ pixels: [Float], width: Int, height: Int, kernel: [Float], horizontal: Bool) -> [Float] {
        var source = pixels
        var output = [Float](repeating: 0, count: pixels.count)
        source.withUnsafeMutableBufferPointer { s in
            output.withUnsafeMutableBufferPointer { o in
                var src = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                var dst = vImage_Buffer(data: o.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                let length = UInt32(kernel.count)
                vImageConvolve_PlanarF(&src, &dst, nil, 0, 0, kernel, horizontal ? 1 : length, horizontal ? length : 1, 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        return output
    }

    static func bilinear(_ pixels: [Float], width: Int, height: Int, x: Float, y: Float) -> Float {
        let fx = min(max(x, 0), Float(width - 1) - 0.001), fy = min(max(y, 0), Float(height - 1) - 0.001)
        let x0 = Int(fx), y0 = Int(fy), tx = fx - Float(x0), ty = fy - Float(y0)
        let i = y0 * width + x0
        let top = pixels[i] * (1 - tx) + pixels[i + 1] * tx
        let bottom = pixels[i + width] * (1 - tx) + pixels[i + width + 1] * tx
        return top * (1 - ty) + bottom * ty
    }

    /// A small deterministic random number generator, so the same photos always align the same way.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

private extension Double {
    nonisolated var nonZero: Double { self == 0 ? 1 : self }
}
