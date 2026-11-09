import CoreGraphics
import Foundation

/// The composition guide drawn inside the crop, as in Lightroom's Tools ▸ Crop Guide Overlay. O cycles
/// through them in this order while cropping, and ⇧O turns the asymmetric ones; the Tool Overlay setting
/// decides when the guide shows.
enum CropGuideOverlay: String, CaseIterable {
    case thirds, fifths, diagonal, halves, triangle, goldenRatio, goldenSpiral, aspectRatios, grid

    static let `default` = CropGuideOverlay.thirds
    /// Grid cells across the crop's long side: 20 unless changed with ⌥-scroll.
    static let defaultGridCells = 20
    static let gridCellRange = 4...40
    static let phi: CGFloat = (1 + sqrt(5)) / 2

    private static let key = "CropGuideOverlay"
    private static let orientationsKey = "CropGuideOrientations"
    private static let cycleKey = "CropGuideCycle"
    private static let aspectsKey = "CropGuideAspectRatios"
    private static let gridCellsKey = "CropGuideGridCells"

    /// The Grid guide's density last set with ⌥-scroll, kept across launches.
    static var gridCells: Int {
        get {
            let saved = Defaults.store.integer(forKey: gridCellsKey)
            return saved == 0 ? defaultGridCells : saved.clamped(to: gridCellRange)
        }
        set { Defaults.store.set(newValue.clamped(to: gridCellRange), forKey: gridCellsKey) }
    }

    /// The guides O visits (Choose Overlays to Cycle…); never empty.
    static var cycle: Set<CropGuideOverlay> {
        get {
            guard let saved = Defaults.store.stringArray(forKey: cycleKey) else { return Set(allCases) }
            let cycle = Set(saved.compactMap(CropGuideOverlay.init(rawValue:)))
            return cycle.isEmpty ? Set(allCases) : cycle
        }
        set {
            guard !newValue.isEmpty else { return }
            Defaults.store.set(allCases.filter(newValue.contains).map(\.rawValue), forKey: cycleKey)
        }
    }

    /// The ratios the Aspect Ratios guide shows (Choose Overlays to Cycle…).
    static var shownAspectRatios: Set<AspectRatio> {
        get {
            guard let saved = Defaults.store.stringArray(forKey: aspectsKey) else { return Set(AspectRatio.allCases) }
            return Set(saved.compactMap(AspectRatio.init(rawValue:)))
        }
        set { Defaults.store.set(AspectRatio.allCases.filter(newValue.contains).map(\.rawValue), forKey: aspectsKey) }
    }

    /// The overlay last chosen, kept across launches.
    static var saved: CropGuideOverlay {
        get { Defaults.store.string(forKey: key).flatMap(CropGuideOverlay.init(rawValue:)) ?? .default }
        set { Defaults.store.set(newValue.rawValue, forKey: key) }
    }

    /// This guide's orientation last chosen with ⇧O, kept across launches.
    var savedOrientation: Int {
        get {
            let saved = (Defaults.store.dictionary(forKey: Self.orientationsKey)?[rawValue] as? Int) ?? 0
            return (0..<orientationCount).contains(saved) ? saved : 0
        }
        nonmutating set {
            var all = Defaults.store.dictionary(forKey: Self.orientationsKey) ?? [:]
            all[rawValue] = newValue
            Defaults.store.set(all, forKey: Self.orientationsKey)
        }
    }

    var title: String {
        switch self {
        case .thirds: "Thirds"
        case .fifths: "Fifths"
        case .diagonal: "Diagonal"
        case .halves: "Halves"
        case .triangle: "Triangle"
        case .goldenRatio: "Golden Ratio"
        case .goldenSpiral: "Golden Spiral"
        case .aspectRatios: "Aspect Ratios"
        case .grid: "Grid"
        }
    }

    /// How many ways ⇧O can turn the guide: Triangle's two diagonals; the Golden Spiral's eye in each
    /// quarter, winding either way. The rest are symmetric.
    var orientationCount: Int {
        switch self {
        case .triangle: 2
        case .goldenSpiral: 8
        default: 1
        }
    }

    /// The overlay O moves to: the next one in the cycle, skipping guides left out of it.
    var next: CropGuideOverlay { next(in: Self.cycle) }

    func next(in cycle: Set<CropGuideOverlay>) -> CropGuideOverlay {
        let all = Self.allCases
        let index = all.firstIndex(of: self)!
        return (1...all.count).lazy.map { all[(index + $0) % all.count] }.first(where: cycle.contains) ?? self
    }

    struct Segment: Equatable {
        var start: CGPoint
        var end: CGPoint
    }

    /// The guide's straight lines for a crop rectangle.
    func segments(in rect: CGRect, orientation: Int = 0, gridCells: Int = Self.defaultGridCells) -> [Segment] {
        switch self {
        case .thirds: Self.divisions(rect, at: [1.0 / 3, 2.0 / 3])
        case .fifths: Self.divisions(rect, at: [0.2, 0.4, 0.6, 0.8])
        case .halves: Self.divisions(rect, at: [0.5])
        case .goldenRatio: Self.divisions(rect, at: [1 - 1 / Self.phi, 1 / Self.phi])
        case .diagonal: Self.diagonals(rect)
        case .triangle: Self.triangle(rect, mirrored: orientation % 2 == 1)
        case .goldenSpiral, .aspectRatios: []
        case .grid: Self.grid(rect, cells: gridCells)
        }
    }

    /// The guide's curves for a crop rectangle, as finely sampled polylines.
    func curves(in rect: CGRect, orientation: Int = 0) -> [[CGPoint]] {
        guard self == .goldenSpiral else { return [] }
        return [Self.spiral(rect, orientation: orientation)]
    }

    /// The print and screen shapes the Aspect Ratios guide outlines, as in Lightroom.
    enum AspectRatio: String, CaseIterable {
        case square, fourByFive, letter, fiveBySeven, twoByThree, sixteenByNine

        var title: String {
            switch self {
            case .square: "1 x 1"
            case .fourByFive: "4 x 5"
            case .letter: "8.5 x 11"
            case .fiveBySeven: "5 x 7"
            case .twoByThree: "2 x 3"
            case .sixteenByNine: "16 x 9"
            }
        }

        /// Long side over short side.
        var ratio: CGFloat {
            switch self {
            case .square: 1
            case .fourByFive: 5.0 / 4
            case .letter: 11 / 8.5
            case .fiveBySeven: 7.0 / 5
            case .twoByThree: 3.0 / 2
            case .sixteenByNine: 16.0 / 9
            }
        }
    }

    struct AspectBox: Equatable {
        var aspect: AspectRatio
        var rect: CGRect
    }

    /// Each ratio's largest box that fits the crop, centred and turned the crop's way. A ratio within 1%
    /// of the crop's own is left out, since its box would be the crop.
    static func aspectBoxes(in rect: CGRect, showing aspects: Set<AspectRatio>) -> [AspectBox] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        let portrait = rect.height > rect.width
        let cropRatio = max(rect.width, rect.height) / min(rect.width, rect.height)
        return AspectRatio.allCases.filter(aspects.contains).compactMap { aspect in
            guard abs(aspect.ratio / cropRatio - 1) > 0.01 else { return nil }
            let shape = portrait ? 1 / aspect.ratio : aspect.ratio // width over height
            let size = rect.width / rect.height > shape
                ? CGSize(width: rect.height * shape, height: rect.height)
                : CGSize(width: rect.width, height: rect.width / shape)
            return AspectBox(aspect: aspect, rect: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                                          width: size.width, height: size.height))
        }
    }

    /// Lines across the crop at fractions of each side.
    private static func divisions(_ rect: CGRect, at fractions: [CGFloat]) -> [Segment] {
        fractions.flatMap { fraction -> [Segment] in
            let x = rect.minX + rect.width * fraction
            let y = rect.minY + rect.height * fraction
            return [Segment(start: CGPoint(x: x, y: rect.minY), end: CGPoint(x: x, y: rect.maxY)),
                    Segment(start: CGPoint(x: rect.minX, y: y), end: CGPoint(x: rect.maxX, y: y))]
        }
    }

    /// 45° lines from each corner to the opposite long side, crossing in a diamond in the middle.
    private static func diagonals(_ rect: CGRect) -> [Segment] {
        let side = min(rect.width, rect.height)
        return [(rect.minX, rect.minY, 1.0, 1.0), (rect.maxX, rect.minY, -1, 1),
                (rect.minX, rect.maxY, 1, -1), (rect.maxX, rect.maxY, -1, -1)].map { x, y, dx, dy in
            Segment(start: CGPoint(x: x, y: y), end: CGPoint(x: x + dx * side, y: y + dy * side))
        }
    }

    /// A corner-to-corner diagonal (top left to bottom right, or mirrored), and a line from each other
    /// corner meeting it at a right angle.
    private static func triangle(_ rect: CGRect, mirrored: Bool) -> [Segment] {
        let a = CGPoint(x: mirrored ? rect.maxX : rect.minX, y: rect.maxY)
        let b = CGPoint(x: mirrored ? rect.minX : rect.maxX, y: rect.minY)
        let others = [CGPoint(x: a.x, y: b.y), CGPoint(x: b.x, y: a.y)]
        let direction = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let lengthSquared = direction.x * direction.x + direction.y * direction.y
        guard lengthSquared > 0 else { return [] }
        return [Segment(start: a, end: b)] + others.map { corner in
            let t = ((corner.x - a.x) * direction.x + (corner.y - a.y) * direction.y) / lengthSquared
            return Segment(start: corner, end: CGPoint(x: a.x + t * direction.x, y: a.y + t * direction.y))
        }
    }

    /// Square cells, `cells` across the long side, centred so the leftover is shared by both edges.
    private static func grid(_ rect: CGRect, cells: Int) -> [Segment] {
        guard cells > 0, rect.width > 0, rect.height > 0 else { return [] }
        let spacing = max(rect.width, rect.height) / CGFloat(cells)
        func positions(from minimum: CGFloat, length: CGFloat) -> [CGFloat] {
            let count = Int((length / spacing).rounded(.down))
            let inset = (length - CGFloat(count) * spacing) / 2
            return (0...count).map { minimum + inset + CGFloat($0) * spacing }
                .filter { $0 > minimum + 0.5 && $0 < minimum + length - 0.5 }
        }
        let vertical = positions(from: rect.minX, length: rect.width).map {
            Segment(start: CGPoint(x: $0, y: rect.minY), end: CGPoint(x: $0, y: rect.maxY))
        }
        let horizontal = positions(from: rect.minY, length: rect.height).map {
            Segment(start: CGPoint(x: rect.minX, y: $0), end: CGPoint(x: rect.maxX, y: $0))
        }
        return vertical + horizontal
    }

    /// The golden spiral in a unit square: quarter circles through the squares cut from a golden
    /// rectangle, starting at the bottom-left corner and winding clockwise, squeezed to fit.
    private static let unitSpiral: [CGPoint] = {
        var rect = CGRect(x: 0, y: 0, width: phi, height: 1)
        var points: [CGPoint] = []
        // Squares come off the left, top, right and bottom in turn. Each arc turns a quarter clockwise
        // around the square's corner that the next square touches.
        for step in 0..<14 {
            let side = min(rect.width, rect.height)
            let square: CGRect
            let center: CGPoint
            switch step % 4 {
            case 0:
                square = CGRect(x: rect.minX, y: rect.minY, width: side, height: side)
                center = CGPoint(x: square.maxX, y: square.minY)
                rect = CGRect(x: rect.minX + side, y: rect.minY, width: rect.width - side, height: rect.height)
            case 1:
                square = CGRect(x: rect.minX, y: rect.maxY - side, width: side, height: side)
                center = CGPoint(x: square.minX, y: square.minY)
                rect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - side)
            case 2:
                square = CGRect(x: rect.maxX - side, y: rect.minY, width: side, height: side)
                center = CGPoint(x: square.minX, y: square.maxY)
                rect = CGRect(x: rect.minX, y: rect.minY, width: rect.width - side, height: rect.height)
            default:
                square = CGRect(x: rect.minX, y: rect.minY, width: side, height: side)
                center = CGPoint(x: square.maxX, y: square.maxY)
                rect = CGRect(x: rect.minX, y: rect.minY + side, width: rect.width, height: rect.height - side)
            }
            let start = Double.pi - Double(step % 4) * .pi / 2
            let samples = 48
            for sample in (step == 0 ? 0 : 1)...samples {
                let angle = start - .pi / 2 * Double(sample) / Double(samples)
                points.append(CGPoint(x: center.x + side * cos(angle), y: center.y + side * sin(angle)))
            }
        }
        return points.map { CGPoint(x: $0.x / phi, y: $0.y) }
    }()

    /// Orientation bits: 1 mirrors left–right, 2 top–bottom, 4 turns the spiral a quarter (so its first
    /// arc spans the short side). Together they put the eye in each quarter, winding either way.
    private static func spiral(_ rect: CGRect, orientation: Int) -> [CGPoint] {
        unitSpiral.map { point in
            var p = orientation & 4 != 0 ? CGPoint(x: point.y, y: point.x) : point
            if orientation & 1 != 0 { p.x = 1 - p.x }
            if orientation & 2 != 0 { p.y = 1 - p.y }
            return CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
        }
    }
}
