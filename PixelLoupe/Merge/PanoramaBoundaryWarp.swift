import Accelerate
import Foundation
import simd

/// Boundary Warp: bends the panorama so its ragged edge fits the rectangle around it, keeping the
/// content's shapes as much as it can (after He, Chang and Sun's "Rectangling Panoramic Images via
/// Warping", without their line constraints). Worked out on the small panorama the seams use.
///
/// A mesh is laid over the photos' coverage by stretching each row, then each column, of the covered
/// area to the full rectangle; that mesh is then solved again (least squares) so every cell keeps its
/// shape, as nearly as a similarity transform allows, while the outer vertices stay on the
/// rectangle's edges. Boundary Warp's amount moves the mesh from where the content is (0) to that
/// solution (100).
nonisolated struct PanoramaBoundaryWarp: Sendable {
    let width: Int
    let height: Int
    let columns: Int
    let rows: Int
    /// Mesh vertices on the unwarped panorama (pixels at the small size), row by row.
    let source: [SIMD2<Double>]
    /// The same vertices with the warp in full.
    let target: [SIMD2<Double>]

    init?(coverage: [Bool], width: Int, height: Int) {
        guard width >= 8, height >= 8, coverage.contains(true) else { return nil }
        self.width = width
        self.height = height
        // Cells about square, 40 across the long side.
        let long = 40.0
        columns = max(4, Int((long * Double(width) / Double(max(width, height))).rounded()))
        rows = max(4, Int((long * Double(height) / Double(max(width, height))).rounded()))

        let stretch = Stretch(coverage: coverage, width: width, height: height)
        var source: [SIMD2<Double>] = []
        var grid: [SIMD2<Double>] = []
        for row in 0...rows {
            for column in 0...columns {
                let point = SIMD2(Double(column) * Double(width) / Double(columns), Double(row) * Double(height) / Double(rows))
                grid.append(point)
                source.append(stretch.source(of: point))
            }
        }
        self.source = source
        target = Self.solve(source: source, start: grid, columns: columns, rows: rows, width: Double(width), height: Double(height))
    }

    // MARK: - Mapping

    /// The warp's map, sampled every `step` pixels of the small panorama: for each sample (row by
    /// row), the point of the unwarped panorama it shows, as fractions of its width and height from
    /// the top left (which may be outside it). `amount` is 0…1.
    func map(amount: Double, step: Int = 2) -> (width: Int, height: Int, points: [SIMD2<Float>?]) {
        let mapWidth = max(1, width / step), mapHeight = max(1, height / step)
        let sx = Double(width) / Double(mapWidth), sy = Double(height) / Double(mapHeight)
        var result = [SIMD2<Float>?](repeating: nil, count: mapWidth * mapHeight)
        let warped = zip(source, target).map { $0 + ($1 - $0) * amount }
        func vertex(_ row: Int, _ column: Int) -> Int { row * (columns + 1) + column }
        for row in 0..<rows {
            for column in 0..<columns {
                let corners = [vertex(row, column), vertex(row, column + 1), vertex(row + 1, column + 1), vertex(row + 1, column)]
                let to = corners.map { warped[$0] }, from = corners.map { source[$0] }
                let low = to.reduce(SIMD2(repeating: Double.infinity)) { simd_min($0, $1) }
                let high = to.reduce(SIMD2(repeating: -Double.infinity)) { simd_max($0, $1) }
                let x0 = max(0, Int((low.x / sx).rounded(.down))), x1 = min(mapWidth - 1, Int((high.x / sx).rounded(.up)))
                let y0 = max(0, Int((low.y / sy).rounded(.down))), y1 = min(mapHeight - 1, Int((high.y / sy).rounded(.up)))
                guard x0 <= x1, y0 <= y1 else { continue }
                for y in y0...y1 {
                    for x in x0...x1 where result[y * mapWidth + x] == nil {
                        let p = SIMD2((Double(x) + 0.5) * sx, (Double(y) + 0.5) * sy)
                        guard let uv = Self.unitCoordinates(of: p, in: to) else { continue }
                        let s = Self.bilinear(from, uv)
                        result[y * mapWidth + x] = SIMD2(Float(s.x / Double(width)), Float(s.y / Double(height)))
                    }
                }
            }
        }
        // Beyond the mesh (it follows the photos' edges only roughly), each sample moves as the
        // nearest outer vertex does, so nothing near the edges is lost and no warp is no change.
        var outer: [(at: SIMD2<Double>, shift: SIMD2<Double>)] = []
        for row in 0...rows {
            for column in 0...columns where row == 0 || row == rows || column == 0 || column == columns {
                let v = vertex(row, column)
                outer.append((warped[v], warped[v] - source[v]))
            }
        }
        for y in 0..<mapHeight {
            for x in 0..<mapWidth where result[y * mapWidth + x] == nil {
                let p = SIMD2((Double(x) + 0.5) * sx, (Double(y) + 0.5) * sy)
                guard let nearest = outer.min(by: { simd_distance_squared($0.at, p) < simd_distance_squared($1.at, p) }) else { continue }
                let s = p - nearest.shift
                result[y * mapWidth + x] = SIMD2(Float(s.x / Double(width)), Float(s.y / Double(height)))
            }
        }
        return (mapWidth, mapHeight, result)
    }

    /// Where `p` sits in the quad `q` (corners clockwise from the top left) as (u, v) in 0…1, by
    /// Newton's method on the bilinear map, or nil when it's outside.
    static func unitCoordinates(of p: SIMD2<Double>, in q: [SIMD2<Double>]) -> SIMD2<Double>? {
        var uv = SIMD2<Double>(0.5, 0.5)
        for _ in 0..<8 {
            let f = bilinear(q, uv) - p
            let du = (q[1] - q[0]) * (1 - uv.y) + (q[2] - q[3]) * uv.y
            let dv = (q[3] - q[0]) * (1 - uv.x) + (q[2] - q[1]) * uv.x
            let det = du.x * dv.y - du.y * dv.x
            guard abs(det) > 1e-12 else { return nil }
            uv -= SIMD2((f.x * dv.y - f.y * dv.x) / det, (du.x * f.y - du.y * f.x) / det)
        }
        let tolerance = 1e-6
        guard uv.x >= -tolerance, uv.y >= -tolerance, uv.x <= 1 + tolerance, uv.y <= 1 + tolerance,
              simd_length(bilinear(q, uv) - p) < 1e-3 else { return nil }
        return uv
    }

    static func bilinear(_ q: [SIMD2<Double>], _ uv: SIMD2<Double>) -> SIMD2<Double> {
        let top = q[0] + (q[1] - q[0]) * uv.x, bottom = q[3] + (q[2] - q[3]) * uv.x
        return top + (bottom - top) * uv.y
    }

    // MARK: - Solving

    /// The vertex positions that keep each cell's shape (as a similarity transform of its `source`
    /// shape) with the outer vertices on the rectangle's edges: linear least squares. `start` is the
    /// answer when it can't be solved.
    static func solve(source: [SIMD2<Double>], start: [SIMD2<Double>], columns: Int, rows: Int, width: Double, height: Double) -> [SIMD2<Double>] {
        // Each energy term: a weighted linear combination of unknowns (x and y of each vertex) minus a constant.
        struct Term { var indices: [Int]; var coefficients: [Double]; var constant: Double }
        var terms: [Term] = []
        func vertex(_ row: Int, _ column: Int) -> Int { row * (columns + 1) + column }
        let shapeWeight = 1.0
        for row in 0..<rows {
            for column in 0..<columns {
                let corners = [vertex(row, column), vertex(row, column + 1), vertex(row + 1, column + 1), vertex(row + 1, column)]
                // The similarity fit's residual: (A (AᵀA)⁻¹ Aᵀ − I) t, A's rows from the source corners.
                var a = [[Double]]()
                for c in corners {
                    let s = source[c]
                    a.append([s.x, -s.y, 1, 0])
                    a.append([s.y, s.x, 0, 1])
                }
                var ata = [Double](repeating: 0, count: 16)
                for r in a { for i in 0..<4 { for j in 0..<4 { ata[i * 4 + j] += r[i] * r[j] } } }
                guard let inverse = invert4(ata) else { continue }
                var projection = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 8)
                for i in 0..<8 {
                    for j in 0..<8 {
                        var sum = 0.0
                        for k in 0..<4 { for l in 0..<4 { sum += a[i][k] * inverse[k * 4 + l] * a[j][l] } }
                        projection[i][j] = sum - (i == j ? 1 : 0)
                    }
                }
                let unknowns = corners.flatMap { [$0 * 2, $0 * 2 + 1] }
                for i in 0..<8 {
                    terms.append(Term(indices: unknowns, coefficients: projection[i].map { $0 * shapeWeight }, constant: 0))
                }
            }
        }
        // The outer vertices pinned (heavily) to the rectangle.
        let boundaryWeight = 50.0
        for row in 0...rows {
            for column in 0...columns {
                let v = vertex(row, column)
                if column == 0 { terms.append(Term(indices: [v * 2], coefficients: [boundaryWeight], constant: 0)) }
                if column == columns { terms.append(Term(indices: [v * 2], coefficients: [boundaryWeight], constant: boundaryWeight * width)) }
                if row == 0 { terms.append(Term(indices: [v * 2 + 1], coefficients: [boundaryWeight], constant: 0)) }
                if row == rows { terms.append(Term(indices: [v * 2 + 1], coefficients: [boundaryWeight], constant: boundaryWeight * height)) }
            }
        }

        // The normal equations MᵀM x = Mᵀc, solved by sparse Cholesky (Accelerate).
        let n = start.count * 2
        var entries: [Int: Double] = [:]
        var rhs = [Double](repeating: 0, count: n)
        for term in terms {
            for (i, ci) in zip(term.indices, term.coefficients) {
                rhs[i] += ci * term.constant
                for (j, cj) in zip(term.indices, term.coefficients) where j <= i {
                    entries[i * n + j, default: 0] += ci * cj
                }
            }
        }
        for i in 0..<n { entries[i * n + i, default: 0] += 1e-9 }
        var rowIndices: [Int32] = [], columnIndices: [Int32] = [], values: [Double] = []
        for (key, value) in entries {
            rowIndices.append(Int32(key / n))
            columnIndices.append(Int32(key % n))
            values.append(value)
        }
        var attributes = SparseAttributes_t()
        attributes.kind = SparseSymmetric
        attributes.triangle = SparseLowerTriangle
        let matrix = SparseConvertFromCoordinate(Int32(n), Int32(n), values.count, 1, attributes, rowIndices, columnIndices, values)
        defer { SparseCleanup(matrix) }
        let factorization = SparseFactor(SparseFactorizationCholesky, matrix)
        defer { SparseCleanup(factorization) }
        guard factorization.status == SparseStatusOK else { return start }
        var x = [Double](repeating: 0, count: n)
        rhs.withUnsafeMutableBufferPointer { b in
            x.withUnsafeMutableBufferPointer { result in
                SparseSolve(factorization, DenseVector_Double(count: Int32(n), data: b.baseAddress!),
                            DenseVector_Double(count: Int32(n), data: result.baseAddress!))
            }
        }
        guard x.allSatisfy(\.isFinite) else { return start }
        return stride(from: 0, to: n, by: 2).map { SIMD2(x[$0], x[$0 + 1]) }
    }

    static func invert4(_ m: [Double]) -> [Double]? {
        var a = m, inverse = (0..<16).map { $0 % 5 == 0 ? 1.0 : 0.0 }
        for column in 0..<4 {
            guard let pivot = (column..<4).max(by: { abs(a[$0 * 4 + column]) < abs(a[$1 * 4 + column]) }),
                  abs(a[pivot * 4 + column]) > 1e-12 else { return nil }
            for k in 0..<4 { a.swapAt(pivot * 4 + k, column * 4 + k); inverse.swapAt(pivot * 4 + k, column * 4 + k) }
            let d = a[column * 4 + column]
            for k in 0..<4 { a[column * 4 + k] /= d; inverse[column * 4 + k] /= d }
            for row in 0..<4 where row != column {
                let f = a[row * 4 + column]
                guard f != 0 else { continue }
                for k in 0..<4 { a[row * 4 + k] -= f * a[column * 4 + k]; inverse[row * 4 + k] -= f * inverse[column * 4 + k] }
            }
        }
        return inverse
    }

    // MARK: - The starting mesh

    /// Stretching each row of the covered area to the full width, then each column of that to the
    /// full height: where a point of the rectangle comes from on the unwarped panorama.
    struct Stretch {
        let width: Int
        let height: Int
        /// Each row's covered span, then (after the rows are stretched) each column's.
        let left: [Double], right: [Double], top: [Double], bottom: [Double]

        init(coverage: [Bool], width: Int, height: Int) {
            self.width = width
            self.height = height
            var left = [Double?](repeating: nil, count: height), right = left
            for y in 0..<height {
                let row = y * width
                if let first = (0..<width).first(where: { coverage[row + $0] }),
                   let last = (0..<width).last(where: { coverage[row + $0] }) {
                    left[y] = Double(first)
                    right[y] = Double(last + 1)
                }
            }
            let smoothing = max(1, height / 60)
            let l = Self.smoothed(Self.filled(left, fallback: 0), radius: smoothing)
            let r = Self.smoothed(Self.filled(right, fallback: Double(width)), radius: smoothing)
            var top = [Double?](repeating: nil, count: width), bottom = top
            for x in 0..<width {
                var first: Int?, last: Int?
                for y in 0..<height {
                    let sx = Int((l[y] + (Double(x) + 0.5) / Double(width) * (r[y] - l[y])).rounded(.down))
                    guard sx >= 0, sx < width, coverage[y * width + sx] else { continue }
                    if first == nil { first = y }
                    last = y
                }
                if let first, let last {
                    top[x] = Double(first)
                    bottom[x] = Double(last + 1)
                }
            }
            let columnSmoothing = max(1, width / 60)
            self.left = l
            self.right = r
            self.top = Self.smoothed(Self.filled(top, fallback: 0), radius: columnSmoothing)
            self.bottom = Self.smoothed(Self.filled(bottom, fallback: Double(height)), radius: columnSmoothing)
        }

        func source(of point: SIMD2<Double>) -> SIMD2<Double> {
            let t = Self.sample(top, at: point.x), b = Self.sample(bottom, at: point.x)
            let y = t + point.y / Double(height) * (b - t)
            let l = Self.sample(left, at: y), r = Self.sample(right, at: y)
            return SIMD2(l + point.x / Double(width) * (r - l), y)
        }

        static func sample(_ values: [Double], at position: Double) -> Double {
            let p = min(max(position - 0.5, 0), Double(values.count - 1))
            let i = Int(p.rounded(.down)), t = p - Double(i)
            return i + 1 < values.count ? values[i] * (1 - t) + values[i + 1] * t : values[i]
        }

        /// Gaps filled from the nearest known value.
        static func filled(_ values: [Double?], fallback: Double) -> [Double] {
            guard let firstKnown = values.firstIndex(where: { $0 != nil }) else { return values.map { _ in fallback } }
            var result = [Double](repeating: 0, count: values.count)
            var last = values[firstKnown]!
            for i in values.indices {
                if let value = values[i] { last = value }
                result[i] = last
            }
            return result
        }

        static func smoothed(_ values: [Double], radius: Int) -> [Double] {
            values.indices.map { i in
                let range = max(0, i - radius)...min(values.count - 1, i + radius)
                return range.reduce(0) { $0 + values[$1] } / Double(range.count)
            }
        }
    }
}

/// Auto Crop: the largest rectangle the photos cover entirely.
nonisolated enum PanoramaCrop {
    /// The biggest all-covered rectangle in a `width` × `height` mask (pixels from the top left), by
    /// the largest-rectangle-in-a-histogram method, row by row.
    static func largestRectangle(_ covered: [Bool], width: Int, height: Int) -> (x: Int, y: Int, width: Int, height: Int)? {
        var heights = [Int](repeating: 0, count: width)
        var best: (x: Int, y: Int, width: Int, height: Int, area: Int)?
        for y in 0..<height {
            for x in 0..<width { heights[x] = covered[y * width + x] ? heights[x] + 1 : 0 }
            var stack: [Int] = []
            for x in 0...width {
                let h = x < width ? heights[x] : 0
                while let top = stack.last, heights[top] > h {
                    stack.removeLast()
                    let barHeight = heights[top]
                    let left = (stack.last ?? -1) + 1
                    let area = barHeight * (x - left)
                    if area > (best?.area ?? 0) { best = (left, y - barHeight + 1, x - left, barHeight, area) }
                }
                stack.append(x)
            }
        }
        return best.map { ($0.x, $0.y, $0.width, $0.height) }
    }
}
