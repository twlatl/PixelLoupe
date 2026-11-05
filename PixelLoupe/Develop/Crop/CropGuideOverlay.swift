import CoreGraphics
import Foundation

/// The composition guide drawn inside the crop, as in Lightroom's Tools ▸ Crop Guide Overlay. O cycles
/// through them in this order while cropping; the Tool Overlay setting decides when the guide shows.
enum CropGuideOverlay: String, CaseIterable {
    case thirds, fifths, diagonal, halves, grid

    static let `default` = CropGuideOverlay.thirds
    /// Grid cells across the crop's long side.
    static let gridCells = 20

    private static let key = "CropGuideOverlay"

    /// The overlay last chosen, kept across launches.
    static var saved: CropGuideOverlay {
        get { Defaults.store.string(forKey: key).flatMap(CropGuideOverlay.init(rawValue:)) ?? .default }
        set { Defaults.store.set(newValue.rawValue, forKey: key) }
    }

    var title: String {
        switch self {
        case .thirds: "Thirds"
        case .fifths: "Fifths"
        case .diagonal: "Diagonal"
        case .halves: "Halves"
        case .grid: "Grid"
        }
    }

    /// The overlay O moves to.
    var next: CropGuideOverlay {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    struct Segment: Equatable {
        var start: CGPoint
        var end: CGPoint
    }

    /// The guide's lines for a crop rectangle.
    func segments(in rect: CGRect) -> [Segment] {
        switch self {
        case .thirds: Self.divisions(rect, count: 3)
        case .fifths: Self.divisions(rect, count: 5)
        case .halves: Self.divisions(rect, count: 2)
        case .diagonal: Self.diagonals(rect)
        case .grid: Self.grid(rect, cells: Self.gridCells)
        }
    }

    /// Lines dividing each side into `count` equal parts.
    private static func divisions(_ rect: CGRect, count: Int) -> [Segment] {
        (1..<count).flatMap { index -> [Segment] in
            let fraction = CGFloat(index) / CGFloat(count)
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
}
