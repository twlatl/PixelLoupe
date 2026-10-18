import CoreGraphics
import Foundation

nonisolated extension PhotoAdjustments {
    /// An adjustment applied through a mask: a name, mask components that add, subtract or intersect,
    /// and the sliders applied where the mask is.
    ///
    /// Coordinates are fractions of the photo's frame, before cropping and straightening, with the
    /// origin at the bottom-left (like the crop), so a mask stays on its subject when the crop changes.
    struct LocalAdjustment: Codable, Equatable, Identifiable, Sendable {
        var id = UUID()
        var name = "Mask"
        var isEnabled = true
        /// How strongly the adjustment shows, 0…1.
        var amount = 1.0
        var components: [MaskComponent] = []
        var settings = LocalSettings()

        var isActive: Bool { isEnabled && amount > 0 && !components.isEmpty && settings.isActive }
    }

    /// One shape of a mask, and how it combines with the shapes before it.
    struct MaskComponent: Codable, Equatable, Sendable {
        var shape: MaskShape
        var mode = Mode.add
        /// Selects everything but the shape.
        var isInverted = false

        enum Mode: String, Codable, CaseIterable, Sendable {
            case add, subtract, intersect
        }
    }

    enum MaskShape: Codable, Equatable, Sendable {
        case linear(LinearGradient)
        case radial(RadialGradient)

        var title: String {
            switch self {
            case .linear: "Linear Gradient"
            case .radial: "Radial Gradient"
            }
        }
    }

    /// The effect is nothing at `zero` and full at `full`, ramping between along the line joining them.
    struct LinearGradient: Codable, Equatable, Sendable {
        var zero: UnitPoint
        var full: UnitPoint
    }

    /// An ellipse: full effect inside, fading to nothing over `feather` of its radius at the edge.
    struct RadialGradient: Codable, Equatable, Sendable {
        var center: UnitPoint
        /// Half the ellipse's width and height before it is turned, as fractions of the frame.
        var radiusX: Double
        var radiusY: Double
        /// Degrees, counterclockwise.
        var angle = 0.0
        /// 0…1: how far inward from the edge the fade reaches.
        var feather = 0.5
    }

    struct UnitPoint: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
    }

    /// The sliders a mask applies (a subset of the global ones), -1…1 except exposure in stops.
    struct LocalSettings: Codable, Equatable, Sendable {
        /// Stops, -5…5.
        var exposure = 0.0
        var contrast = 0.0
        var highlights = 0.0
        var shadows = 0.0
        var whites = 0.0
        var blacks = 0.0
        var temperature = 0.0
        var tint = 0.0
        var saturation = 0.0
        var clarity = 0.0
        var texture = 0.0
        var dehaze = 0.0

        var isActive: Bool { self != LocalSettings() }
    }
}

nonisolated extension PhotoAdjustments.LocalAdjustment {
    private enum CodingKeys: String, CodingKey { case id, name, isEnabled, amount, components, settings }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? id
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? name
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        amount = try container.decodeIfPresent(Double.self, forKey: .amount) ?? amount
        components = try container.decodeIfPresent([PhotoAdjustments.MaskComponent].self, forKey: .components) ?? components
        settings = try container.decodeIfPresent(PhotoAdjustments.LocalSettings.self, forKey: .settings) ?? settings
    }
}

nonisolated extension PhotoAdjustments.LocalSettings {
    private enum CodingKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, whites, blacks, temperature, tint, saturation, clarity, texture, dehaze
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? exposure
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? contrast
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? highlights
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? shadows
        whites = try container.decodeIfPresent(Double.self, forKey: .whites) ?? whites
        blacks = try container.decodeIfPresent(Double.self, forKey: .blacks) ?? blacks
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? temperature
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? tint
        saturation = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? saturation
        clarity = try container.decodeIfPresent(Double.self, forKey: .clarity) ?? clarity
        texture = try container.decodeIfPresent(Double.self, forKey: .texture) ?? texture
        dehaze = try container.decodeIfPresent(Double.self, forKey: .dehaze) ?? dehaze
    }
}
