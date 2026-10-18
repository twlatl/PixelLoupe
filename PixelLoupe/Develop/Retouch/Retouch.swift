import CoreGraphics
import Foundation

nonisolated extension PhotoAdjustments {
    /// A spot removed by copying pixels from elsewhere. Positions are fractions of the photo's frame
    /// before cropping, origin bottom-left (the masks' coordinates); `radius` is a fraction of its long edge.
    struct Spot: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var kind = Kind.heal
        var center = UnitPoint(x: 0.5, y: 0.5)
        var source = UnitPoint(x: 0.6, y: 0.5)
        var radius = 0.02
        /// 0…1: how far inward from the edge the spot blends.
        var feather = 0.5
        var opacity = 1.0

        enum Kind: String, Codable, CaseIterable, Sendable {
            /// Copies the source's texture and matches it to the colors around the spot.
            case heal
            /// Copies the source as it is.
            case clone

            var title: String { rawValue.capitalized }
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
