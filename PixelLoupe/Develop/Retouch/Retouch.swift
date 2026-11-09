import CoreGraphics
import Foundation

nonisolated extension PhotoAdjustments {
    /// A spot removed by copying pixels from elsewhere, or (Remove, RAW-260) by filling it with new ones.
    /// Positions are fractions of the photo's frame before cropping, origin bottom-left (the masks'
    /// coordinates); `radius` is a fraction of its long edge.
    ///
    /// A spot placed with a click is a circle at `center`. One painted in the Remove tool has an `area`
    /// instead; its `center` and `radius` are then the circle around the area, where its pin and Spot
    /// Removal's list show it.
    struct Spot: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var kind = Kind.heal
        var center = UnitPoint(x: 0.5, y: 0.5)
        var source = UnitPoint(x: 0.6, y: 0.5)
        var radius = 0.02
        /// 0…1: how far inward from the edge the spot blends.
        var feather = 0.5
        var opacity = 1.0
        /// What was painted in the Remove tool; `nil` for a circle.
        var area: RemoveArea?
        /// Remove: which of the many possible fills this is. Refresh picks another (see ADR 0004).
        var seed: UInt64 = 0
        /// Remove: filled by the generative model rather than from the photo's own patches.
        var usesGenerativeAI = false
        /// Remove: ⌘-dragged to a source of its own, so it copies from `source` (blending as Heal does)
        /// instead of filling.
        var hasCustomSource = false

        enum Kind: String, Codable, CaseIterable, Sendable {
            /// Copies the source's texture and matches it to the colors around the spot.
            case heal
            /// Copies the source as it is.
            case clone
            /// Fills the area with new pixels made to fit around it (RAW-260).
            case remove

            var title: String { rawValue.capitalized }
        }

        /// Whether it's drawn with a fill (rather than copied from its source).
        var isFilled: Bool { kind == .remove && !hasCustomSource }

        /// Moves the spot (and what was painted) by `dx`, `dy`, keeping its source where it was relative to it.
        mutating func move(by dx: Double, _ dy: Double) {
            center = UnitPoint(x: center.x + dx, y: center.y + dy)
            source = UnitPoint(x: source.x + dx, y: source.y + dy)
            area?.move(by: dx, dy)
        }

        /// Sets `center` and `radius` to the circle around the painted area, on a frame `aspect` wide per unit tall.
        mutating func fitCircleToArea(aspect: Double) {
            guard let box = area?.bounds(aspect: aspect) else { return }
            let offset = (x: source.x - center.x, y: source.y - center.y)
            center = UnitPoint(x: box.midX, y: box.midY)
            source = UnitPoint(x: center.x + offset.x, y: center.y + offset.y)
            // Half the box's longer side, in long-edge units.
            let longEdge = max(aspect, 1)
            radius = max(Double(box.width) * aspect, Double(box.height)) / longEdge / 2
        }
    }

    /// The part of the photo a Remove spot covers: the object Detect Objects found, and brush strokes that
    /// paint more of it or (erasing, the Selected card's Subtract) take some away, in order.
    struct RemoveArea: Codable, Hashable, Sendable {
        var object: ObjectMatte?
        var brush = BrushMask()

        var isEmpty: Bool { object == nil && brush.strokes.allSatisfy(\.isErasing) }

        /// The box (unit coordinates) everything painted lies in, on a frame `aspect` wide per unit tall, so
        /// brush sizes (fractions of the long edge) reach the right distance across and up.
        func bounds(aspect: Double) -> CGRect? {
            var box: CGRect?
            if let object { box = object.box }
            let longEdge = max(aspect, 1)
            for stroke in brush.strokes where !stroke.isErasing {
                let rx = stroke.size * longEdge / max(aspect, 1e-6), ry = stroke.size * longEdge
                for point in stroke.points {
                    let dab = CGRect(x: point.x - rx, y: point.y - ry, width: rx * 2, height: ry * 2)
                    box = box?.union(dab) ?? dab
                }
            }
            return box
        }

        mutating func move(by dx: Double, _ dy: Double) {
            if let box = object?.box { object?.box = box.offsetBy(dx: dx, dy: dy) }
            for index in brush.strokes.indices {
                brush.strokes[index].points = brush.strokes[index].points.map { UnitPoint(x: $0.x + dx, y: $0.y + dy) }
            }
        }
    }

    /// An object Detect Objects found: a gray matte over `box` (unit coordinates of the frame), rows from the
    /// bottom, compressed (LZFSE) so a spot stays a few kilobytes in the catalog.
    struct ObjectMatte: Codable, Hashable, Sendable {
        var box: CGRect
        var width: Int
        var height: Int
        /// LZFSE-compressed 8-bit coverage, `width` × `height`.
        var compressed: Data

        init(box: CGRect, width: Int, height: Int, coverage: [UInt8]) {
            self.box = box
            self.width = width
            self.height = height
            compressed = (try? (Data(coverage) as NSData).compressed(using: .lzfse) as Data) ?? Data(coverage)
        }

        /// The coverage bytes, or `nil` when they can't be read.
        var coverage: [UInt8]? {
            let data = (try? (compressed as NSData).decompressed(using: .lzfse) as Data) ?? compressed
            return data.count == width * height ? [UInt8](data) : nil
        }
    }

    /// A red-eye correction placed on an eye.
    struct RedEyeSpot: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var center = UnitPoint(x: 0.5, y: 0.5)
        /// The pupil's radius as a fraction of the long edge.
        var radius = 0.01
        /// How strongly red is taken out, 0…1.
        var strength = 1.0
        /// How much the pupil is darkened, 0…1.
        var darken = 0.5
    }
}

nonisolated extension PhotoAdjustments.Spot {
    /// Settings saved before a field existed decode with its default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func decode<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        id = try decode(.id, id)
        kind = try decode(.kind, kind)
        center = try decode(.center, center)
        source = try decode(.source, source)
        radius = try decode(.radius, radius)
        feather = try decode(.feather, feather)
        opacity = try decode(.opacity, opacity)
        area = try container.decodeIfPresent(PhotoAdjustments.RemoveArea.self, forKey: .area)
        seed = try decode(.seed, seed)
        usesGenerativeAI = try decode(.usesGenerativeAI, usesGenerativeAI)
        hasCustomSource = try decode(.hasCustomSource, hasCustomSource)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, center, source, radius, feather, opacity, area, seed, usesGenerativeAI, hasCustomSource
    }
}
