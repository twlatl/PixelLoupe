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

        /// Nothing in it: no shapes, or only brushes that haven't been painted (Delete All Empty Masks).
        var isEmpty: Bool { components.allSatisfy(\.shape.isEmpty) }

        /// Whether it needs the photo's subject found (a Subject or Background shape).
        var usesSubject: Bool { components.contains(where: \.shape.usesSubject) }
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
        case brush(BrushMask)
        /// What Vision finds as the photo's subject (every subject it finds).
        case subject(SubjectSelection)
        /// Everything but the subject.
        case background(SubjectSelection)

        var title: String {
            switch self {
            case .linear: "Linear Gradient"
            case .radial: "Radial Gradient"
            case .brush: "Brush"
            case .subject: "Subject"
            case .background: "Background"
            }
        }

        var isEmpty: Bool {
            if case .brush(let brush) = self { brush.strokes.isEmpty } else { false }
        }

        var isBrush: Bool {
            if case .brush = self { true } else { false }
        }

        var usesSubject: Bool {
            switch self {
            case .subject, .background: true
            case .linear, .radial, .brush: false
            }
        }

        /// A Subject or Background shape's edge settings.
        var subjectSelection: SubjectSelection? {
            switch self {
            case .subject(let selection), .background(let selection): selection
            case .linear, .radial, .brush: nil
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

    /// How a Subject or Background mask's edge follows what Vision found.
    struct SubjectSelection: Codable, Hashable, Sendable {
        /// 0…1: how soft the edge is.
        var feather = 0.25
        /// -1…1: shrinks (negative) or grows the selection before it is feathered.
        var edge = 0.0
    }

    /// Painted strokes, in order; an erasing stroke takes away what the strokes before it painted.
    struct BrushMask: Codable, Hashable, Sendable {
        var strokes: [BrushStroke] = []
    }

    /// One drag of the brush: the dabs follow `points`, each a soft disc with this stroke's settings.
    struct BrushStroke: Codable, Hashable, Sendable {
        var points: [UnitPoint]
        /// The brush's radius as a fraction of the frame's long edge, so it covers the same part of the
        /// photo at any size.
        var size: Double
        /// 0…1: how far in from the edge the softening reaches.
        var feather: Double
        /// 0…1: how much each dab adds, so going back over a spot builds it up.
        var flow: Double
        /// 0…1: the most the stroke reaches, however often it goes over a spot.
        var density: Double
        var isErasing = false
    }

    struct UnitPoint: Codable, Hashable, Sendable {
        var x: Double
        var y: Double
    }

    /// What a mask applies: the Develop panel's own sections (RAW-193), less the ones that only make sense for
    /// the whole photo (Profile, Calibration, Lens, Transform, Vignette, Crop), and a white balance shift
    /// relative to the photo's.
    struct LocalSettings: Codable, Equatable, Sendable {
        /// Warmer (positive) or cooler, -1…1.
        var temperature = 0.0
        /// Magenta (positive) or green, -1…1.
        var tint = 0.0
        /// The White Balance section's switch: off leaves the shift set but unused.
        var isWhiteBalanceEnabled = true
        var light = Light()
        var presence = Presence()
        var color = ColorGrading()
        var blackAndWhite = BlackAndWhite()
        var curves = Curves()
        var levels = Levels()
        var definition = Definition()
        var selectiveColor = SelectiveColor()
        var noiseReduction = NoiseReduction()
        var sharpen = Sharpen()
        var effects = Effects()

        var isActive: Bool { self != LocalSettings() }

        // Lightroom's local correction sliders (and masks saved before RAW-193), by name.

        /// Stops, -5…5.
        var exposure: Double {
            get { light.exposure }
            set { light.exposure = newValue }
        }
        var contrast: Double {
            get { light.contrast }
            set { light.contrast = newValue }
        }
        var highlights: Double {
            get { light.highlights }
            set { light.highlights = newValue }
        }
        var shadows: Double {
            get { light.shadows }
            set { light.shadows = newValue }
        }
        var whites: Double {
            get { light.whites }
            set { light.whites = newValue }
        }
        /// Positive lifts the blacks: the Black Point slider the other way round.
        var blacks: Double {
            get { -light.blackPoint }
            set { light.blackPoint = -newValue }
        }
        var saturation: Double {
            get { presence.saturation }
            set { presence.saturation = newValue }
        }
        var clarity: Double {
            get { presence.clarity }
            set { presence.clarity = newValue }
        }
        var texture: Double {
            get { presence.texture }
            set { presence.texture = newValue }
        }
        var dehaze: Double {
            get { presence.dehaze }
            set { presence.dehaze = newValue }
        }

        /// The sections as photo settings, for the Develop panel's controls and the pipeline's renderers.
        /// The white balance shift travels in `whiteBalance.temperature` and `tint`, as -1…1, not kelvin.
        var adjustments: PhotoAdjustments {
            var adjustments = PhotoAdjustments()
            adjustments.whiteBalance.isEnabled = isWhiteBalanceEnabled
            adjustments.whiteBalance.temperature = temperature == 0 ? nil : temperature
            adjustments.whiteBalance.tint = tint == 0 ? nil : tint
            adjustments.light = light
            adjustments.presence = presence
            adjustments.color = color
            adjustments.blackAndWhite = blackAndWhite
            adjustments.curves = curves
            adjustments.levels = levels
            adjustments.definition = definition
            adjustments.selectiveColor = selectiveColor
            adjustments.noiseReduction = noiseReduction
            adjustments.sharpen = sharpen
            adjustments.effects = effects
            return adjustments
        }

        init() {}

        /// The mask's sections from settings edited in the Develop panel's controls (see `adjustments`).
        init(_ adjustments: PhotoAdjustments) {
            let whiteBalance = adjustments.whiteBalance
            isWhiteBalanceEnabled = whiteBalance.isEnabled
            temperature = whiteBalance.temperature ?? 0
            tint = whiteBalance.tint ?? 0
            light = adjustments.light
            presence = adjustments.presence
            color = adjustments.color
            blackAndWhite = adjustments.blackAndWhite
            curves = adjustments.curves
            levels = adjustments.levels
            definition = adjustments.definition
            selectiveColor = adjustments.selectiveColor
            noiseReduction = adjustments.noiseReduction
            sharpen = adjustments.sharpen
            effects = adjustments.effects
        }
    }
}

nonisolated extension PhotoAdjustments.LocalAdjustment {
    // MARK: Refining a Subject or Background mask

    /// Whether the component at `index` refines the mask rather than shaping it: on a Subject or Background
    /// mask, the brush only adds to or takes away from what was found.
    func isRefinement(_ index: Int) -> Bool {
        usesSubject && components[index].shape.isBrush
    }

    /// Starts a brush stroke refining a Subject or Background mask: painting adds to the selection, erasing
    /// (`stroke.isErasing`) takes away. The stroke goes into an adding brush and, erasing, into a subtracting
    /// one (or the other way round), so wherever strokes cross, the latest wins.
    mutating func beginRefinement(_ stroke: PhotoAdjustments.BrushStroke) {
        let adding = refinementIndex(.add), subtracting = refinementIndex(.subtract)
        var paint = stroke, erase = stroke
        paint.isErasing = false
        erase.isErasing = true
        append(stroke.isErasing ? erase : paint, to: adding)
        append(stroke.isErasing ? paint : erase, to: subtracting)
    }

    /// Continues the refining stroke begun last.
    mutating func extendRefinement(to point: PhotoAdjustments.UnitPoint) {
        for index in components.indices where isRefinement(index) {
            guard case .brush(var brush) = components[index].shape, !brush.strokes.isEmpty else { continue }
            brush.strokes[brush.strokes.count - 1].points.append(point)
            components[index].shape = .brush(brush)
        }
    }

    /// Inverts the mask's shapes (Invert). A Subject or Background mask's refining brush isn't inverted: it
    /// still adds to and takes away from the inverted selection.
    mutating func setInverted(_ isInverted: Bool) {
        for index in components.indices where !isRefinement(index) { components[index].isInverted = isInverted }
    }

    /// The refining brush that adds (or subtracts), made the first time it's needed.
    private mutating func refinementIndex(_ mode: PhotoAdjustments.MaskComponent.Mode) -> Int {
        if let index = components.indices.first(where: { isRefinement($0) && components[$0].mode == mode }) { return index }
        components.append(.init(shape: .brush(.init()), mode: mode))
        return components.count - 1
    }

    private mutating func append(_ stroke: PhotoAdjustments.BrushStroke, to index: Int) {
        guard case .brush(var brush) = components[index].shape else { return }
        brush.strokes.append(stroke)
        components[index].shape = .brush(brush)
    }

    // MARK: Decoding


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
        case temperature, tint, isWhiteBalanceEnabled = "whiteBalanceEnabled", light, presence, color, blackAndWhite, curves, levels, definition, selectiveColor, noiseReduction, sharpen, effects
    }

    /// The flat sliders masks had before RAW-193.
    private enum LegacyKeys: String, CodingKey {
        case exposure, contrast, highlights, shadows, whites, blacks, saturation, clarity, texture, dehaze
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? temperature
        tint = try container.decodeIfPresent(Double.self, forKey: .tint) ?? tint
        isWhiteBalanceEnabled = try container.decodeIfPresent(Bool.self, forKey: .isWhiteBalanceEnabled) ?? isWhiteBalanceEnabled
        light = try container.decodeIfPresent(PhotoAdjustments.Light.self, forKey: .light) ?? light
        presence = try container.decodeIfPresent(PhotoAdjustments.Presence.self, forKey: .presence) ?? presence
        color = try container.decodeIfPresent(PhotoAdjustments.ColorGrading.self, forKey: .color) ?? color
        blackAndWhite = try container.decodeIfPresent(PhotoAdjustments.BlackAndWhite.self, forKey: .blackAndWhite) ?? blackAndWhite
        curves = try container.decodeIfPresent(PhotoAdjustments.Curves.self, forKey: .curves) ?? curves
        levels = try container.decodeIfPresent(PhotoAdjustments.Levels.self, forKey: .levels) ?? levels
        definition = try container.decodeIfPresent(PhotoAdjustments.Definition.self, forKey: .definition) ?? definition
        selectiveColor = try container.decodeIfPresent(PhotoAdjustments.SelectiveColor.self, forKey: .selectiveColor) ?? selectiveColor
        noiseReduction = try container.decodeIfPresent(PhotoAdjustments.NoiseReduction.self, forKey: .noiseReduction) ?? noiseReduction
        sharpen = try container.decodeIfPresent(PhotoAdjustments.Sharpen.self, forKey: .sharpen) ?? sharpen
        effects = try container.decodeIfPresent(PhotoAdjustments.Effects.self, forKey: .effects) ?? effects

        // A mask saved before RAW-193: its sliders, into the sections they now belong to.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let paths: [(LegacyKeys, WritableKeyPath<Self, Double>)] = [
            (.exposure, \.exposure), (.contrast, \.contrast), (.highlights, \.highlights), (.shadows, \.shadows), (.whites, \.whites),
            (.blacks, \.blacks), (.saturation, \.saturation), (.clarity, \.clarity), (.texture, \.texture), (.dehaze, \.dehaze),
        ]
        for (key, path) in paths {
            if let value = try legacy.decodeIfPresent(Double.self, forKey: key) { self[keyPath: path] = value }
        }
    }

    /// Only what differs from the defaults, so an untouched section adds nothing to the catalog.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        func encode<Value: Encodable & Equatable>(_ path: KeyPath<Self, Value>, _ key: CodingKeys) throws {
            if self[keyPath: path] != defaults[keyPath: path] { try container.encode(self[keyPath: path], forKey: key) }
        }
        try encode(\.temperature, .temperature)
        try encode(\.tint, .tint)
        try encode(\.isWhiteBalanceEnabled, .isWhiteBalanceEnabled)
        try encode(\.light, .light)
        try encode(\.presence, .presence)
        try encode(\.color, .color)
        try encode(\.blackAndWhite, .blackAndWhite)
        try encode(\.curves, .curves)
        try encode(\.levels, .levels)
        try encode(\.definition, .definition)
        try encode(\.selectiveColor, .selectiveColor)
        try encode(\.noiseReduction, .noiseReduction)
        try encode(\.sharpen, .sharpen)
        try encode(\.effects, .effects)
    }
}
