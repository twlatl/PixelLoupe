import Foundation

/// A tone curve through any number of control points (2 to 16), interpolated with a monotone cubic
/// so it never overshoots or inverts between points.
///
/// The curve is flat left of its first point and right of its last. Catalogs saved when curves had
/// five fixed inputs (0, ¼, ½, ¾, 1) decode as points at those inputs.
nonisolated struct ToneCurve: Codable, Sendable {
    struct Point: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
    }

    static let minimumPoints = 2
    static let maximumPoints = 16
    /// Closest two points may be in x, so the curve stays a function.
    static let minimumGap = 1.0 / 128
    /// The inputs of the original five-point curves.
    static let legacyInputs: [Double] = [0, 0.25, 0.5, 0.75, 1]
    static let identity = ToneCurve(points: [Point(x: 0, y: 0), Point(x: 1, y: 1)])

    /// Control points in increasing x, all within 0…1.
    private(set) var points: [Point]

    /// Normalizes `points`: clamped to 0…1, sorted, no two closer than ``minimumGap``, at most
    /// ``maximumPoints`` and at least two.
    init(points: [Point]) {
        var sorted = points
            .map { Point(x: $0.x.clamped(to: 0...1), y: $0.y.clamped(to: 0...1)) }
            .sorted { $0.x < $1.x }
        var result: [Point] = []
        for point in sorted where result.last.map({ point.x - $0.x >= Self.minimumGap }) ?? true {
            result.append(point)
        }
        sorted = result
        if sorted.count > Self.maximumPoints { sorted = Self.decimated(sorted, to: Self.maximumPoints) }
        while sorted.count < Self.minimumPoints {
            sorted.append(sorted.isEmpty ? Point(x: 0, y: 0) : Point(x: min(1, sorted[0].x + 1), y: sorted[0].y))
            if sorted.count == 2, sorted[1].x - sorted[0].x < Self.minimumGap { sorted[0].x = max(0, sorted[1].x - 0.5) }
        }
        self.points = sorted
    }

    /// Output values at the five legacy inputs.
    init(outputs: [Double]) {
        self.init(points: zip(Self.legacyInputs, outputs).map { Point(x: $0, y: $1) })
    }

    private enum CodingKeys: String, CodingKey { case points, outputs }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let points = try container.decodeIfPresent([Point].self, forKey: .points) {
            self.init(points: points)
        } else if let outputs = try container.decodeIfPresent([Double].self, forKey: .outputs) {
            self.init(outputs: outputs)
        } else {
            self = .identity
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(points, forKey: .points)
    }

    /// Every point on the diagonal: the curve does nothing, however many points it has.
    var isIdentity: Bool { points.allSatisfy { abs($0.y - $0.x) < 1e-9 } }

    // MARK: - Editing

    var canAddPoint: Bool { points.count < Self.maximumPoints }
    var canRemovePoint: Bool { points.count > Self.minimumPoints }

    /// Adds a point and returns its index, or `nil` when the curve is full or another point is too near in x.
    @discardableResult
    mutating func addPoint(x: Double, y: Double) -> Int? {
        let x = x.clamped(to: 0...1)
        guard canAddPoint, !points.contains(where: { abs($0.x - x) < Self.minimumGap }) else { return nil }
        let index = points.firstIndex { $0.x > x } ?? points.count
        points.insert(Point(x: x, y: y.clamped(to: 0...1)), at: index)
        return index
    }

    /// Moves a point, keeping it between its neighbors.
    mutating func movePoint(_ index: Int, toX x: Double, y: Double) {
        guard points.indices.contains(index) else { return }
        let lower = index > 0 ? points[index - 1].x + Self.minimumGap : 0
        let upper = index < points.count - 1 ? points[index + 1].x - Self.minimumGap : 1
        points[index] = Point(x: x.clamped(to: lower...max(lower, upper)), y: y.clamped(to: 0...1))
    }

    /// Removes a point unless only two remain.
    @discardableResult
    mutating func removePoint(_ index: Int) -> Bool {
        guard canRemovePoint, points.indices.contains(index) else { return false }
        points.remove(at: index)
        return true
    }

    /// Evenly spaced picks that keep the first and last point.
    private static func decimated(_ points: [Point], to count: Int) -> [Point] {
        (0..<count).map { points[Int((Double($0) * Double(points.count - 1) / Double(count - 1)).rounded())] }
    }

    // MARK: - Evaluating

    /// Evaluates the curve at `x` (0…1).
    func value(at x: Double) -> Double {
        Evaluator(self).value(at: x)
    }

    /// Samples the curve into a lookup table of `count` entries.
    func table(count: Int) -> [Double] {
        if isIdentity { return (0..<count).map { Double($0) / Double(count - 1) } }
        let evaluator = Evaluator(self)
        return (0..<count).map { evaluator.value(at: Double($0) / Double(count - 1)) }
    }

    /// A curve with its tangents worked out once.
    private struct Evaluator {
        let xs: [Double]
        let ys: [Double]
        let tangents: [Double]

        init(_ curve: ToneCurve) {
            xs = curve.points.map(\.x)
            ys = curve.points.map(\.y)
            tangents = ToneCurve.monotoneTangents(xs: xs, ys: ys)
        }

        func value(at x: Double) -> Double {
            let x = x.clamped(to: 0...1)
            if x <= xs[0] { return ys[0] }
            if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
            // The segment containing x (a binary search; curves are short, but tables call this 1024 times).
            var low = 0, high = xs.count - 1
            while high - low > 1 {
                let mid = (low + high) / 2
                if xs[mid] <= x { low = mid } else { high = mid }
            }
            let h = xs[high] - xs[low]
            let t = (x - xs[low]) / h
            let t2 = t * t, t3 = t2 * t
            let value = (2 * t3 - 3 * t2 + 1) * ys[low]
                + (t3 - 2 * t2 + t) * h * tangents[low]
                + (-2 * t3 + 3 * t2) * ys[high]
                + (t3 - t2) * h * tangents[high]
            return value.clamped(to: 0...1)
        }
    }

    /// Fritsch–Carlson tangents.
    fileprivate static func monotoneTangents(xs: [Double], ys: [Double]) -> [Double] {
        let n = xs.count
        var slopes = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { slopes[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) }
        var tangents = [Double](repeating: 0, count: n)
        tangents[0] = slopes[0]
        tangents[n - 1] = slopes[n - 2]
        for i in 1..<(n - 1) {
            tangents[i] = slopes[i - 1] * slopes[i] <= 0 ? 0 : (slopes[i - 1] + slopes[i]) / 2
        }
        for i in 0..<(n - 1) where slopes[i] == 0 {
            tangents[i] = 0
            tangents[i + 1] = 0
        }
        for i in 0..<(n - 1) where slopes[i] != 0 {
            let a = tangents[i] / slopes[i], b = tangents[i + 1] / slopes[i]
            let s = a * a + b * b
            if s > 9 {
                let tau = 3 / s.squareRoot()
                tangents[i] = tau * a * slopes[i]
                tangents[i + 1] = tau * b * slopes[i]
            }
        }
        return tangents
    }
}

nonisolated extension ToneCurve: Equatable {
    /// Curves are equal when they draw the same: any two identity curves match.
    static func == (lhs: ToneCurve, rhs: ToneCurve) -> Bool {
        (lhs.isIdentity && rhs.isIdentity) || lhs.points == rhs.points
    }
}

/// The curves Lightroom's Point Curve menu puts on the point (RGB) curve, named as in `ToneCurveName2012`.
/// Its points are Lightroom's own (from its Develop templates), in 0…255.
nonisolated enum PointCurvePreset: String, CaseIterable, Sendable {
    case linear = "Linear"
    case mediumContrast = "Medium Contrast"
    case strongContrast = "Strong Contrast"

    var curve: ToneCurve {
        let points: [(Double, Double)] = switch self {
        case .linear: [(0, 0), (255, 255)]
        case .mediumContrast: [(0, 0), (32, 22), (64, 56), (128, 128), (192, 196), (255, 255)]
        case .strongContrast: [(0, 0), (32, 16), (64, 50), (128, 128), (192, 202), (255, 255)]
        }
        return ToneCurve(points: points.map { ToneCurve.Point(x: $0 / 255, y: $1 / 255) })
    }

    /// The preset `curve` draws, if any. Points may be off by rounding (catalogs keep them in 0…255).
    init?(matching curve: ToneCurve) {
        if curve.isIdentity { self = .linear; return }
        guard let preset = Self.allCases.first(where: { preset in
            let points = preset.curve.points
            return points.count == curve.points.count
                && zip(points, curve.points).allSatisfy { abs($0.x - $1.x) < 0.002 && abs($0.y - $1.y) < 0.002 }
        }) else { return nil }
        self = preset
    }
}

/// Lightroom's parametric curve: four region sliders (Shadows, Darks, Lights, Highlights) and the
/// three splits between the regions. It is applied before the point curve.
nonisolated struct ParametricCurve: Codable, Equatable, Sendable {
    /// Region amounts, -1…1.
    var shadows = 0.0
    var darks = 0.0
    var lights = 0.0
    var highlights = 0.0
    /// Where the regions meet, as a fraction of the tonal range.
    var shadowSplit = 0.25
    var midtoneSplit = 0.5
    var highlightSplit = 0.75

    /// How far the splits may come together.
    static let minimumSplitGap = 0.05
    /// The most one region at full strength moves the curve.
    private static let strength = 0.35

    var isIdentity: Bool { shadows == 0 && darks == 0 && lights == 0 && highlights == 0 }

    var amounts: [Double] { [shadows, darks, lights, highlights] }

    /// The regions' names, in the order of ``amounts``.
    static let regionNames = ["Shadows", "Darks", "Lights", "Highlights"]
    /// Where the splits start, and where double-clicking one puts it back.
    static let defaultSplits = [0.25, 0.5, 0.75]

    var splits: [Double] { [shadowSplit, midtoneSplit, highlightSplit] }

    /// The region (an index into ``amounts``) input `x` falls in.
    func region(at x: Double) -> Int {
        splits.firstIndex { x < $0 } ?? 3
    }

    /// A region's amount, by its index in ``amounts``; set values are clamped to -1…1.
    subscript(region region: Int) -> Double {
        get { amounts[region] }
        set {
            let value = newValue.clamped(to: -1...1)
            switch region {
            case 0: shadows = value
            case 1: darks = value
            case 2: lights = value
            default: highlights = value
            }
        }
    }

    /// Output for input `x` (0…1). Each region is a raised-cosine bump over its span, reaching into
    /// its neighbors; the outer regions hold full strength out to the ends. The shift fades to zero
    /// at black and white.
    func value(at x: Double) -> Double {
        let x = x.clamped(to: 0...1)
        guard !isIdentity else { return x }
        let knots = [0, shadowSplit, midtoneSplit, highlightSplit, 1]
        var shift = 0.0
        for (index, amount) in amounts.enumerated() where amount != 0 {
            let low = knots[index], high = knots[index + 1]
            let middle = (low + high) / 2, reach = max(high - low, 0.0001)
            let distance = abs(x - middle)
            var weight = distance >= reach ? 0 : 0.5 * (1 + cos(.pi * distance / reach))
            if (index == 0 && x < middle) || (index == 3 && x > middle) { weight = 1 }
            shift += amount * weight
        }
        return (x + Self.strength * shift * 4 * x * (1 - x)).clamped(to: 0...1)
    }

    /// Moves one split, keeping the three in order and apart.
    mutating func setSplit(_ index: Int, to value: Double) {
        let gap = Self.minimumSplitGap
        switch index {
        case 0: shadowSplit = value.clamped(to: gap...(midtoneSplit - gap))
        case 1: midtoneSplit = value.clamped(to: (shadowSplit + gap)...(highlightSplit - gap))
        default: highlightSplit = value.clamped(to: (midtoneSplit + gap)...(1 - gap))
        }
    }
}
