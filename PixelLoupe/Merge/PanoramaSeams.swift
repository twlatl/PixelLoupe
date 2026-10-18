import Foundation
import simd

/// Where each photo shows in a panorama, and how bright: worked out on a small version of the
/// panorama (see ``PanoramaMerger``) and stretched to whatever size it's merged at.
///
/// - **Gains** even out what the photos' exposures don't explain (vignetting, metering): Brown and
///   Lowe's gain compensation, which balances the photos' average brightness where they overlap
///   while keeping each gain near 1.
/// - **Seams** (which photo each pixel comes from) start with the photo whose middle is nearest, then
///   each overlapping pair's seam is moved where the two photos look most alike (a graph cut), so it
///   avoids things that moved between them, like water and leaves.
nonisolated enum PanoramaSeams {
    /// One photo warped onto the small panorama, within its footprint (`x`, `y`, `width`, `height`
    /// in pixels from the panorama's top left).
    struct Photo: Sendable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
        /// Linear RGB, exposure-matched, row by row.
        var color: [SIMD3<Float>]
        var covered: [Bool]
        /// How far each pixel is from the photo's edge, as a fraction of its size (0…0.5).
        var centrality: [Float]

        func contains(_ px: Int, _ py: Int) -> Bool {
            px >= x && py >= y && px < x + width && py < y + height
        }

        func index(_ px: Int, _ py: Int) -> Int { (py - y) * width + (px - x) }

        func covers(_ px: Int, _ py: Int) -> Bool { contains(px, py) && covered[index(px, py)] }
    }

    // MARK: - Gains

    /// Each photo's brightness correction (Brown and Lowe; OpenCV's `GainCompensator`): photos
    /// overlapping by more pixels count more, and gains are kept near 1 (σ 0.1) against the overlap
    /// brightness noise (σ 10 levels in 255).
    static func gains(_ photos: [Photo]) -> [Float] {
        let n = photos.count
        guard n >= 2 else { return Array(repeating: 1, count: n) }
        var count = [Double](repeating: 0, count: n * n)
        var mean = [Double](repeating: 0, count: n * n) // mean[i * n + j]: photo i's brightness where it overlaps j
        for i in 0..<n {
            for j in (i + 1)..<n {
                let a = photos[i], b = photos[j]
                let x0 = max(a.x, b.x), x1 = min(a.x + a.width, b.x + b.width)
                let y0 = max(a.y, b.y), y1 = min(a.y + a.height, b.y + b.height)
                guard x0 < x1, y0 < y1 else { continue }
                var total = 0.0, sumA = 0.0, sumB = 0.0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let ia = a.index(x, y), ib = b.index(x, y)
                        guard a.covered[ia], b.covered[ib] else { continue }
                        sumA += Double(luminance(a.color[ia]))
                        sumB += Double(luminance(b.color[ib]))
                        total += 1
                    }
                }
                guard total > 0 else { continue }
                count[i * n + j] = total
                count[j * n + i] = total
                mean[i * n + j] = sumA / total * 255
                mean[j * n + i] = sumB / total * 255
            }
        }
        let alpha = 1.0 / (10 * 10), beta = 1.0 / (0.1 * 0.1)
        var a = [Double](repeating: 0, count: n * n), b = [Double](repeating: 0, count: n)
        for i in 0..<n {
            for j in 0..<n where j != i && count[i * n + j] > 0 {
                let c = count[i * n + j]
                b[i] += beta * c
                a[i * n + i] += beta * c + 2 * alpha * mean[i * n + j] * mean[i * n + j] * c
                a[i * n + j] -= 2 * alpha * mean[i * n + j] * mean[j * n + i] * c
            }
            // A photo overlapping nothing keeps its exposure.
            if a[i * n + i] == 0 { a[i * n + i] = 1; b[i] = 1 }
        }
        guard let solved = PanoramaAligner.gaussianSolve(a, b, size: n) else { return Array(repeating: 1, count: n) }
        return solved.map { Float(min(max($0, 0.25), 4)) }
    }

    static func luminance(_ rgb: SIMD3<Float>) -> Float {
        0.2627 * rgb.x + 0.6780 * rgb.y + 0.0593 * rgb.z
    }

    // MARK: - Seams

    /// The photo (index into `photos`) each pixel of a `width` × `height` panorama comes from, or −1
    /// where none covers it. `gains` scale the photos' colors before they're compared.
    static func labels(_ photos: [Photo], gains: [Float], width: Int, height: Int) -> [Int16] {
        var labels = [Int16](repeating: -1, count: width * height)
        var best = [Float](repeating: -1, count: width * height)
        for (index, photo) in photos.enumerated() {
            let covered = photo.covered, centrality = photo.centrality
            for y in photo.y..<(photo.y + photo.height) {
                for x in photo.x..<(photo.x + photo.width) {
                    let i = (y - photo.y) * photo.width + (x - photo.x)
                    guard covered[i], centrality[i] > best[y * width + x] else { continue }
                    best[y * width + x] = centrality[i]
                    labels[y * width + x] = Int16(index)
                }
            }
        }
        // Only photos whose areas touch share a seam.
        var touching = Set<Int>()
        for y in 0..<height {
            for x in 0..<width {
                let here = labels[y * width + x]
                guard here >= 0 else { continue }
                for (nx, ny) in [(x + 1, y), (x, y + 1)] where nx < width && ny < height {
                    let there = labels[ny * width + nx]
                    if there >= 0, there != here { touching.insert(Int(min(here, there)) * photos.count + Int(max(here, there))) }
                }
            }
        }
        for pair in touching.sorted() {
            cutSeam(between: pair / photos.count, and: pair % photos.count, photos: photos, gains: gains, labels: &labels, width: width, height: height)
        }
        return labels
    }

    /// How different two photos look at a pixel: gamma-encoded, clipped at white, so the seam finds
    /// it cheap to cross where they agree (or are both blown out).
    static func difference(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        func encoded(_ c: SIMD3<Float>) -> SIMD3<Float> {
            let clipped = simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
            return SIMD3(pow(clipped.x, 1 / 2.2), pow(clipped.y, 1 / 2.2), pow(clipped.z, 1 / 2.2))
        }
        let d = simd_abs(encoded(a) - encoded(b))
        return d.x + d.y + d.z
    }

    /// How far (pixels on the small panorama) a seam may move from where it starts: about 400
    /// pixels at full resolution.
    static let seamReach = 24

    /// Moves the seam between photos `a` and `b` to the cheapest cut near where it is: a minimum cut
    /// in the grid of pixels within ``seamReach`` of it that both photos cover, each link costing how
    /// different the photos look at its two ends. Pixels bordering that band on `a`'s side must stay
    /// `a`, on `b`'s side `b`.
    static func cutSeam(between a: Int, and b: Int, photos: [Photo], gains: [Float], labels: inout [Int16], width: Int, height: Int) {
        let pa = photos[a], pb = photos[b]
        let x0 = max(pa.x, pb.x), x1 = min(pa.x + pa.width, pb.x + pb.width)
        let y0 = max(pa.y, pb.y), y1 = min(pa.y + pa.height, pb.y + pb.height)
        guard x0 < x1, y0 < y1 else { return }
        let la = Int16(a), lb = Int16(b)
        let regionWidth = x1 - x0, regionHeight = y1 - y0
        // Where both photos cover the overlap and it's labeled one of them, row by row (no closures
        // over the photos, which an unoptimized build would copy on every call).
        var inPair = [Bool](repeating: false, count: regionWidth * regionHeight)
        for y in y0..<y1 {
            let rowA = (y - pa.y) * pa.width - pa.x, rowB = (y - pb.y) * pb.width - pb.x
            for x in x0..<x1 {
                let label = labels[y * width + x]
                if (label == la || label == lb), pa.covered[rowA + x], pb.covered[rowB + x] {
                    inPair[(y - y0) * regionWidth + (x - x0)] = true
                }
            }
        }
        let steps = [(1, 0), (0, 1), (-1, 0), (0, -1)]

        // The band: distance (in steps) from the seam, outward from the pixels on it.
        var distance = [Int32](repeating: -1, count: regionWidth * regionHeight)
        var queue: [Int] = [] // region indices
        for ry in 0..<regionHeight {
            for rx in 0..<regionWidth where inPair[ry * regionWidth + rx] {
                let x = x0 + rx, y = y0 + ry
                let other = labels[y * width + x] == la ? lb : la
                for (dx, dy) in steps {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, ny >= 0, nx < width, ny < height, labels[ny * width + nx] == other {
                        distance[ry * regionWidth + rx] = 0
                        queue.append(ry * regionWidth + rx)
                        break
                    }
                }
            }
        }
        guard !queue.isEmpty else { return }
        var read = 0
        while read < queue.count {
            let i = queue[read]; read += 1
            let d = distance[i]
            guard d < Int32(seamReach) else { continue }
            let rx = i % regionWidth, ry = i / regionWidth
            for (dx, dy) in steps {
                let nx = rx + dx, ny = ry + dy
                guard nx >= 0, ny >= 0, nx < regionWidth, ny < regionHeight else { continue }
                let j = ny * regionWidth + nx
                guard inPair[j], distance[j] < 0 else { continue }
                distance[j] = d + 1
                queue.append(j)
            }
        }

        var node = [Int32](repeating: -1, count: regionWidth * regionHeight)
        var costs = [Float](repeating: 0, count: queue.count)
        let gainA = gains[a], gainB = gains[b]
        for (n, i) in queue.enumerated() {
            node[i] = Int32(n)
            let x = x0 + i % regionWidth, y = y0 + i / regionWidth
            costs[n] = difference(pa.color[(y - pa.y) * pa.width + x - pa.x] * gainA, pb.color[(y - pb.y) * pb.width + x - pb.x] * gainB)
        }
        guard queue.count >= 16 else { return }
        let source = Int32(queue.count), sink = source + 1
        var graph = FlowGraph(nodeCount: queue.count + 2)
        var touchesSource = false, touchesSink = false
        for (n, i) in queue.enumerated() {
            let here = Int32(n)
            let rx = i % regionWidth, ry = i / regionWidth
            for (dx, dy) in steps {
                let nx = x0 + rx + dx, ny = y0 + ry + dy
                guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                let inRegion = nx >= x0 && ny >= y0 && nx < x1 && ny < y1
                let neighbor = inRegion ? node[(ny - y0) * regionWidth + (nx - x0)] : -1
                if neighbor >= 0 {
                    // Each link once, from the pixel to its right and below neighbors.
                    if dx + dy > 0 {
                        let capacity = costs[n] + costs[Int(neighbor)] + 1e-3
                        graph.addEdge(here, neighbor, capacity, capacity)
                    }
                } else {
                    let label = labels[ny * width + nx]
                    if label == la {
                        graph.addEdge(source, here, .infinity, 0)
                        touchesSource = true
                    } else if label == lb {
                        graph.addEdge(here, sink, .infinity, 0)
                        touchesSink = true
                    }
                }
            }
        }
        guard touchesSource, touchesSink else { return }
        let sourceSide = graph.minimumCut(source: source, sink: sink)
        for (n, i) in queue.enumerated() {
            labels[(y0 + i / regionWidth) * width + x0 + i % regionWidth] = sourceSide[n] ? la : lb
        }
    }

    /// A flow network for the seam's minimum cut (Dinic's algorithm, iterative so long paths can't
    /// overflow the stack).
    struct FlowGraph {
        private var head: [Int32]
        private var to: [Int32] = []
        private var next: [Int32] = []
        private var capacity: [Float] = []

        init(nodeCount: Int) {
            head = Array(repeating: -1, count: nodeCount)
        }

        mutating func addEdge(_ u: Int32, _ v: Int32, _ forward: Float, _ backward: Float) {
            let cap = forward.isInfinite ? 1e12 : forward
            to.append(v); capacity.append(cap); next.append(head[Int(u)]); head[Int(u)] = Int32(to.count - 1)
            to.append(u); capacity.append(backward); next.append(head[Int(v)]); head[Int(v)] = Int32(to.count - 1)
        }

        /// Pushes as much flow as fits from `source` to `sink`, then says which nodes are still
        /// reachable from the source: that side of the minimum cut. (Raw pointers keep it quick even
        /// in an unoptimized build.)
        mutating func minimumCut(source: Int32, sink: Int32) -> [Bool] {
            let n = head.count
            var levelStorage = [Int32](repeating: -1, count: n)
            var queueStorage = [Int32](repeating: 0, count: n)
            var currentStorage = head
            var pathStorage = [Int32](repeating: 0, count: n + 1)
            let epsilon: Float = 1e-6
            let s = Int(source), t = Int(sink)
            head.withUnsafeBufferPointer { headBuffer in
            to.withUnsafeBufferPointer { toBuffer in
            next.withUnsafeBufferPointer { nextBuffer in
            capacity.withUnsafeMutableBufferPointer { capacityBuffer in
            levelStorage.withUnsafeMutableBufferPointer { levelBuffer in
            queueStorage.withUnsafeMutableBufferPointer { queueBuffer in
            currentStorage.withUnsafeMutableBufferPointer { currentBuffer in
            pathStorage.withUnsafeMutableBufferPointer { pathBuffer in
                let head = headBuffer.baseAddress!, to = toBuffer.baseAddress!, next = nextBuffer.baseAddress!
                let capacity = capacityBuffer.baseAddress!, level = levelBuffer.baseAddress!
                let queue = queueBuffer.baseAddress!, current = currentBuffer.baseAddress!, path = pathBuffer.baseAddress!

                func buildLevels() -> Bool {
                    for i in 0..<n { level[i] = -1 }
                    level[s] = 0
                    var read = 0, write = 1
                    queue[0] = source
                    while read < write {
                        let u = Int(queue[read]); read += 1
                        // Nothing past the sink's level is on a shortest path.
                        if level[t] >= 0, level[u] >= level[t] { break }
                        var e = Int(head[u])
                        while e >= 0 {
                            let v = Int(to[e])
                            if capacity[e] > epsilon, level[v] < 0 {
                                level[v] = level[u] + 1
                                queue[write] = Int32(v); write += 1
                            }
                            e = Int(next[e])
                        }
                    }
                    return level[t] >= 0
                }

                while buildLevels() {
                    for i in 0..<n { current[i] = head[i] }
                    while true {
                        // One augmenting path along the level graph, found without recursion.
                        var length = 0
                        var u = s
                        var found = false
                        while true {
                            if u == t { found = true; break }
                            var e = Int(current[u])
                            while e >= 0 {
                                let v = Int(to[e])
                                if capacity[e] > epsilon, level[v] == level[u] + 1 { break }
                                e = Int(next[e])
                            }
                            current[u] = Int32(e)
                            if e >= 0 {
                                path[length] = Int32(e); length += 1
                                u = Int(to[e])
                            } else {
                                // A dead end: never come back here this phase.
                                level[u] = -1
                                guard length > 0 else { break }
                                length -= 1
                                let last = Int(path[length])
                                u = Int(to[last ^ 1])
                                current[u] = next[Int(current[u])]
                            }
                        }
                        guard found else { break }
                        var flow = Float.infinity
                        for i in 0..<length { flow = min(flow, capacity[Int(path[i])]) }
                        for i in 0..<length {
                            let e = Int(path[i])
                            capacity[e] -= flow
                            capacity[e ^ 1] += flow
                        }
                    }
                }
            }}}}}}}}
            let level = levelStorage
            // After the last phase, `level` marks what the source still reaches.
            return level.map { $0 >= 0 }
        }
    }
}
