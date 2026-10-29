import CoreGraphics
import Foundation

/// Non-destructive Develop settings for one photo. Stored as JSON in `Photo.adjustmentsData`;
/// originals are never modified.
///
/// Every section has an `isEnabled` switch (the circle in the panel header). A section affects the
/// image only when it is enabled and differs from its defaults.
nonisolated struct PhotoAdjustments: Codable, Equatable, Sendable {
    var light = Light()
    var color = ColorGrading()
    var blackAndWhite = BlackAndWhite()
    var redEye = RedEye()
    var whiteBalance = WhiteBalance()
    var curves = Curves()
    var levels = Levels()
    var definition = Definition()
    var selectiveColor = SelectiveColor()
    var noiseReduction = NoiseReduction()
    var sharpen = Sharpen()
    var vignette = Vignette()
    var crop = Crop()
    var orientation = Orientation()
    var lens = LensCorrections()
    var presence = Presence()
    var effects = Effects()
    var transform = Transform()
    var profile = Profile()
    var calibration = Calibration()
    var portraitLighting = PortraitLighting()
    var rimLight = RimLight()
    /// Local adjustments, in the order they are applied.
    var masks: [LocalAdjustment] = []
    /// Spot removal, applied first (to the photo as decoded).
    var spots: [Spot] = []
    /// Positioned red-eye corrections (the automatic ``redEye`` toggle is separate).
    var redEyes: [RedEyeSpot] = []

    static let `default` = PhotoAdjustments()

    var isDefault: Bool { self == .default }

    // MARK: - Sections

    struct Light: Codable, Equatable, Sendable {
        var isEnabled = true
        /// Stops, -5…5.
        var exposure = 0.0
        /// Lifts shadows and protects highlights together, -1…1.
        var brilliance = 0.0
        var highlights = 0.0
        var shadows = 0.0
        /// Moves the white point: positive brightens the lightest tones, negative pulls them down, -1…1.
        var whites = 0.0
        var brightness = 0.0
        var contrast = 0.0
        var blackPoint = 0.0

        var isActive: Bool { isEnabled && self != Light(isEnabled: true) }
    }

    /// Lightroom's Presence sliders: local contrast at two scales, haze, and color strength.
    struct Presence: Codable, Equatable, Sendable {
        var isEnabled = true
        /// Fine-to-mid detail, -1…1 (negative smooths).
        var texture = 0.0
        /// Larger-scale local contrast, -1…1 (negative softens).
        var clarity = 0.0
        /// Removes (positive) or adds (negative) haze, -1…1.
        var dehaze = 0.0
        /// Saturation weighted toward muted colors and away from skin tones, -1…1.
        var vibrance = 0.0
        /// Saturation of every color, -1…1 (-1 is monochrome).
        var saturation = 0.0

        var isActive: Bool { isEnabled && self != Presence(isEnabled: true) }
        /// The sliders that need neighboring pixels, rendered apart from the color table.
        var hasSpatialEffect: Bool { isEnabled && (texture != 0 || clarity != 0 || dehaze != 0) }
        /// The sliders folded into the color table.
        var hasColorEffect: Bool { isEnabled && (vibrance != 0 || saturation != 0) }
    }

    /// Hue, strength and luminance for one tonal range of the color grading wheels.
    struct ColorWheel: Codable, Equatable, Sendable {
        /// 0…1 around the wheel (0 = red).
        var hue = 0.0
        /// 0…1, distance from the center of the wheel.
        var amount = 0.0
        /// -1…1.
        var luminance = 0.0
    }

    struct ColorGrading: Codable, Equatable, Sendable {
        var isEnabled = true
        var shadows = ColorWheel()
        var midtones = ColorWheel()
        var highlights = ColorWheel()
        /// Tints the whole photo, whatever the tone.
        var global = ColorWheel()
        /// Shifts the split between shadows and highlights, -1…1.
        var balance = 0.0
        /// How far the shadow, midtone and highlight wheels reach into each other, 0…1 (0.5 is the
        /// default look; 0 splits the tones sharply).
        var blending = 0.5

        var isActive: Bool { isEnabled && self != ColorGrading(isEnabled: true) }
    }

    struct BlackAndWhite: Codable, Equatable, Sendable {
        /// Off by default: turning Black & White on is itself the adjustment.
        var isEnabled = false
        /// 0…1 blend between color and monochrome.
        var intensity = 1.0
        /// Warm (positive) or cool (negative) toning, -1…1.
        var neutrals = 0.0
        /// Contrast of the monochrome conversion, -1…1.
        var tone = 0.0
        /// How bright each color range comes out in the monochrome result, -1…1 (Lightroom's B&W mix).
        var mix = Array(repeating: 0.0, count: SelectiveColorRange.allCases.count)

        subscript(range: SelectiveColorRange) -> Double {
            get { mix[range.rawValue] }
            set { mix[range.rawValue] = newValue }
        }

        var isActive: Bool { isEnabled }
    }

    /// The base look a photo starts from, before any slider (Lightroom's Profile menu). Each is
    /// PixelLoupe's own approximation, not Adobe's.
    struct Profile: Codable, Equatable, Sendable {
        var isEnabled = true
        var kind = Kind.standard
        /// How strongly the profile applies, 0…2 (1 is as designed).
        var amount = 1.0
        /// The Lightroom profile this stands in for, when it came from an import.
        var importedName: String?
        /// An imported Adobe profile (its `crs:UUID`), rendered from its own tables; `kind` is then
        /// `.standard`. See ``AdobeProfileLibrary``.
        var adobeID: String?

        enum Kind: String, Codable, CaseIterable, Sendable {
            /// PixelLoupe's standard rendering: no extra look.
            case standard
            case neutral, vivid, landscape, portrait, monochrome

            var title: String {
                switch self {
                case .standard: "Default"
                default: rawValue.capitalized
                }
            }
        }

        var isActive: Bool { isEnabled && (kind != .standard || adobeID != nil) && amount != 0 }
    }

    /// Camera calibration: how the red, green and blue primaries are rotated and strengthened, and a
    /// green/magenta tint in the shadows. All -1…1 (Lightroom's -100…100).
    struct Calibration: Codable, Equatable, Sendable {
        var isEnabled = true
        var shadowTint = 0.0
        var redHue = 0.0
        var redSaturation = 0.0
        var greenHue = 0.0
        var greenSaturation = 0.0
        var blueHue = 0.0
        var blueSaturation = 0.0

        var isActive: Bool { isEnabled && self != Calibration(isEnabled: true) }
    }

    /// Perspective correction (Lightroom's Transform panel): keystone, rotation, aspect, scale and
    /// offset sliders, with the Upright mode Lightroom had chosen.
    struct Transform: Codable, Equatable, Sendable {
        var isEnabled = true
        /// -1…1: tilts the photo's top away from (negative) or toward (positive) the viewer.
        var vertical = 0.0
        /// -1…1: turns the photo about its vertical axis.
        var horizontal = 0.0
        /// Degrees, -10…10 (positive turns clockwise).
        var rotate = 0.0
        /// -1…1: stretches the photo's width against its height.
        var aspect = 0.0
        /// 0.5…1.5 (1 is the photo's size).
        var scale = 1.0
        /// -1…1: moves the photo sideways, as a fraction of a quarter of its width.
        var offsetX = 0.0
        /// -1…1: moves the photo up (positive) or down, as a fraction of a quarter of its height.
        var offsetY = 0.0
        /// Zooms in so no empty corner shows after the transform.
        var constrainCrop = false
        var upright = Upright.off
        /// Lightroom's stored Upright matrix (row-major 3×3, as written in `UprightTransform_n`) for
        /// the mode it was in. Kept for a later release; nothing renders it yet.
        var uprightMatrix: [Double]?

        enum Upright: String, Codable, CaseIterable, Sendable {
            case off, auto, level, vertical, full, guided

            var title: String { rawValue.capitalized }
        }

        /// Whether the sliders change the photo.
        var hasManualTransform: Bool {
            vertical != 0 || horizontal != 0 || rotate != 0 || aspect != 0 || scale != 1 || offsetX != 0 || offsetY != 0
        }

        var isActive: Bool { isEnabled && hasManualTransform }
    }

    /// Finishing effects (Lightroom's Effects panel). Grain lives here, so color photos can have it too.
    struct Effects: Codable, Equatable, Sendable {
        var isEnabled = true
        /// Film grain amount, 0…1.
        var grain = 0.0
        /// Grain size, 0…1 (0.25 is Lightroom's default).
        var grainSize = 0.25
        /// How crisp the grain is, 0…1: low is soft and blotchy, high is sharp (0.5 is the default).
        var grainRoughness = 0.5
        /// Makes this photo's grain pattern its own; a photo keeps the same grain every time it renders.
        var grainSeed = 0

        var isActive: Bool { isEnabled && grain != 0 }
    }

    /// Rim Light (RAW-203, from Pixegen's Filter ▸ Rim Light): up to three colored lights behind the subject that
    /// catch its edges, and how much of their light glows in the air around it. Off on a new photo; turning it on
    /// with no lights adds one.
    struct RimLight: Codable, Equatable, Sendable {
        static let maximumLights = 3
        var isEnabled = false
        var lights: [Light] = []
        /// How much of the lights' light glows around the subject, 0…1.
        var glow = 0.1

        var isActive: Bool { isEnabled && lights.contains { $0.strength > 0 } }

        /// One light: where it comes from, its color, how strong it is, how far it wraps in from the edges, and how
        /// hard its inner edge is rather than feathered.
        struct Light: Codable, Equatable, Identifiable, Sendable {
            var id = UUID()
            /// Degrees counterclockwise from the right, −180…180: 90 is from above.
            var angle = 135.0
            /// The light's color, sRGB 0…1. Warm by default.
            var red = 1.0
            var green = 0.86
            var blue = 0.7
            /// 0…1.
            var strength = 0.5
            /// How far in from the edge it reaches, 0…1.
            var width = 0.3
            /// 0 tails off softly from the edge; 1 holds it bright and ends it crisply at Width.
            var choke = 0.0
        }

        /// What the next added light starts as: from across the last one, in a color that sets it off (cool, then
        /// white), as wide and choked as the last.
        var nextLight: Light {
            guard let last = lights.last else { return Light() }
            let colors: [(Double, Double, Double)] = [(0.7, 0.84, 1), (1, 1, 1)]
            let color = colors[min(max(lights.count - 1, 0), 1)]
            return Light(angle: last.angle > 0 ? last.angle - 180 : last.angle + 180, red: color.0, green: color.1, blue: color.2,
                         strength: 0.5, width: last.width, choke: last.choke)
        }
    }

    /// Portrait Lighting (RAW-211): studio-style lighting on the people in the photo. Off on a new photo; turning it
    /// off keeps the effect and Intensity for turning it back on.
    struct PortraitLighting: Codable, Equatable, Sendable {
        enum Effect: String, Codable, CaseIterable, Sendable {
            /// A soft key light on each face, from above the camera.
            case studio
            /// A key light from one side of each face and a shadow on the other.
            case contour
            /// The people on black.
            case stage
            /// The people in black and white on black.
            case stageMono

            var title: String {
                switch self {
                case .studio: "Studio"
                case .contour: "Contour"
                case .stage: "Stage"
                case .stageMono: "Stage Mono"
                }
            }

            /// Whether the effect needs the faces as well as the people (RAW-215).
            var usesFaces: Bool { self == .studio || self == .contour }
        }

        var isEnabled = false
        var effect = Effect.studio
        /// How strong the effect is, 0…1; for Stage, how dark the background goes.
        var intensity = 1.0

        /// Stage Mono still turns the people black and white at Intensity 0.
        var isActive: Bool { isEnabled && (intensity > 0 || effect == .stageMono) }
    }

    struct RedEye: Codable, Equatable, Sendable {
        var isEnabled = false
        var isActive: Bool { isEnabled }
    }

    struct WhiteBalance: Codable, Equatable, Sendable {
        var isEnabled = true
        /// Kelvin. `nil` keeps the white balance the camera recorded ("As Shot").
        var temperature: Double?
        /// -150…150. `nil` means As Shot.
        var tint: Double?
        /// The preset the values came from (see ``presets``), shown in the pop-up; `nil` is Custom
        /// when the values are set. Editing a value by hand clears it.
        var preset: String?

        var isActive: Bool { isEnabled && (temperature != nil || tint != nil) }

        /// A named white balance. The values are typical of the lighting; Lightroom's presets vary by camera.
        struct Preset: Equatable, Sendable {
            var name: String
            var temperature: Double
            var tint: Double
        }

        /// The light-source presets, as in Lightroom's White Balance pop-up.
        static let presets: [Preset] = [
            .init(name: "Daylight", temperature: 5500, tint: 10),
            .init(name: "Cloudy", temperature: 6500, tint: 10),
            .init(name: "Shade", temperature: 7500, tint: 10),
            .init(name: "Tungsten", temperature: 2850, tint: 0),
            .init(name: "Fluorescent", temperature: 3800, tint: 21),
            .init(name: "Flash", temperature: 5500, tint: 0),
        ]
        /// Pop-up items that aren't light sources.
        static let asShotName = "As Shot", autoName = "Auto", customName = "Custom"

        /// The name the pop-up shows.
        var displayName: String {
            guard isActive else { return Self.asShotName }
            return preset ?? Self.customName
        }
    }

    enum CurveChannel: String, Codable, CaseIterable, Sendable {
        case rgb, red, green, blue

        var title: String {
            switch self {
            case .rgb: "RGB"
            case .red: "Red"
            case .green: "Green"
            case .blue: "Blue"
            }
        }
    }

    struct Curves: Codable, Equatable, Sendable {
        var isEnabled = true
        var rgb = ToneCurve.identity
        var red = ToneCurve.identity
        var green = ToneCurve.identity
        var blue = ToneCurve.identity
        var parametric = ParametricCurve()

        subscript(channel: CurveChannel) -> ToneCurve {
            get {
                switch channel {
                case .rgb: rgb
                case .red: red
                case .green: green
                case .blue: blue
                }
            }
            set {
                switch channel {
                case .rgb: rgb = newValue
                case .red: red = newValue
                case .green: green = newValue
                case .blue: blue = newValue
                }
            }
        }

        var isActive: Bool { isEnabled && self != Curves(isEnabled: true) }
    }

    struct Levels: Codable, Equatable, Sendable {
        var isEnabled = true
        var inputBlack = 0.0
        var inputWhite = 1.0
        /// Midtone gamma, 0.1…10 (1 = unchanged).
        var gamma = 1.0
        var outputBlack = 0.0
        var outputWhite = 1.0

        var isActive: Bool { isEnabled && self != Levels(isEnabled: true) }
    }

    struct Definition: Codable, Equatable, Sendable {
        var isEnabled = true
        /// Local contrast, 0…1.
        var intensity = 0.0

        var isActive: Bool { isEnabled && intensity != 0 }
    }

    enum SelectiveColorRange: Int, Codable, CaseIterable, Sendable {
        case red, orange, yellow, green, aqua, blue, purple, magenta

        var title: String {
            switch self {
            case .red: "Red"
            case .orange: "Orange"
            case .yellow: "Yellow"
            case .green: "Green"
            case .aqua: "Aqua"
            case .blue: "Blue"
            case .purple: "Purple"
            case .magenta: "Magenta"
            }
        }

        /// Center hue in degrees.
        var hue: Double {
            switch self {
            case .red: 0
            case .orange: 30
            case .yellow: 60
            case .green: 120
            case .aqua: 180
            case .blue: 225
            case .purple: 275
            case .magenta: 315
            }
        }
    }

    struct SelectiveColorAdjustment: Codable, Equatable, Sendable {
        /// -1…1 (±30°).
        var hue = 0.0
        /// -1…1.
        var saturation = 0.0
        /// -1…1.
        var luminance = 0.0

        var isIdentity: Bool { self == SelectiveColorAdjustment() }
    }

    struct SelectiveColor: Codable, Equatable, Sendable {
        var isEnabled = true
        var ranges = Array(repeating: SelectiveColorAdjustment(), count: SelectiveColorRange.allCases.count)

        subscript(range: SelectiveColorRange) -> SelectiveColorAdjustment {
            get { ranges[range.rawValue] }
            set { ranges[range.rawValue] = newValue }
        }

        var isActive: Bool { isEnabled && ranges.contains { !$0.isIdentity } }
    }

    struct NoiseReduction: Codable, Equatable, Sendable {
        var isEnabled = true
        /// Luminance noise, 0…1.
        var amount = 0.0
        /// Color noise, 0…1.
        var color = 0.0
        /// How much fine detail luminance smoothing keeps, 0…1 (0.5 is Core Image's default). Applies to
        /// non-RAW files; the RAW engine has no such control.
        var detail = 0.5

        var isActive: Bool { isEnabled && (amount != 0 || color != 0) }
    }

    struct Sharpen: Codable, Equatable, Sendable {
        var isEnabled = true
        /// Amount, 0…1 (Lightroom's Sharpness 0…150).
        var intensity = 0.0
        /// Radius in pixels of the full-size photo, 0.5…3.
        var radius = 1.0
        /// Emphasis on fine detail over broad edges, 0…1 (0.25 is neutral).
        var detail = 0.25
        /// How much of the photo is left alone: 0 sharpens everything, 1 only the strongest edges.
        var masking = 0.0

        static let radiusRange = 0.5...3.0

        var isActive: Bool { isEnabled && intensity != 0 }
    }

    /// Rotation and flipping applied on top of the camera's orientation (Photo ▸ Rotate/Flip).
    /// The photo is mirrored horizontally first (if `isMirrored`), then turned counterclockwise by
    /// `quarterTurns` × 90°.
    struct Orientation: Codable, Equatable, Sendable {
        var quarterTurns = 0
        var isMirrored = false

        var isIdentity: Bool { quarterTurns == 0 && !isMirrored }
        /// Whether width and height swap relative to the camera's orientation.
        var swapsDimensions: Bool { quarterTurns % 2 != 0 }
    }

    enum OrientationChange: CaseIterable, Sendable {
        case rotateLeft, rotateRight, flipHorizontal, flipVertical
    }

    /// Applies a rotate or flip, carrying the crop and straightening along with the photo.
    mutating func apply(_ change: OrientationChange) {
        let k = orientation.quarterTurns
        var rect = crop.rect
        switch change {
        case .rotateLeft:
            orientation.quarterTurns = (k + 1) % 4
            rect = CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        case .rotateRight:
            orientation.quarterTurns = (k + 3) % 4
            rect = CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
        case .flipHorizontal:
            // H · R^k · M = R^-k · H · M
            orientation.quarterTurns = (4 - k) % 4
            orientation.isMirrored.toggle()
            rect.origin.x = 1 - rect.maxX
            crop.angle = -crop.angle
        case .flipVertical:
            // V = R^2 · H, so V · R^k · M = R^(2-k) · H · M
            orientation.quarterTurns = (6 - k) % 4
            orientation.isMirrored.toggle()
            rect.origin.y = 1 - rect.maxY
            crop.angle = -crop.angle
        }
        crop.rect = rect
    }

    /// Returns to the camera's orientation, carrying the crop back with the photo.
    mutating func resetOrientation() {
        while orientation.quarterTurns != 0 { apply(.rotateRight) }
        if orientation.isMirrored { apply(.flipHorizontal) }
    }

    /// Crop & Straighten. The crop is a rectangle in the photo's frame after straightening.
    struct Crop: Codable, Equatable, Sendable {
        /// Straightening angle in degrees, −45…45. Positive rotates counterclockwise.
        var angle = 0.0
        /// Crop rectangle in unit coordinates of the photo's frame (origin bottom-left).
        var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        var aspect = CropAspect.original
        var isAspectLocked = true
        /// Keep the crop inside the photo (no empty corners).
        var constrainToImage = true

        var isActive: Bool { angle != 0 || rect != CGRect(x: 0, y: 0, width: 1, height: 1) }
    }

    struct Vignette: Codable, Equatable, Sendable {
        var isEnabled = true
        /// Darkens (positive) or lightens (negative) the edges, -1…1.
        var strength = 0.0
        /// Midpoint: how far from the center the effect begins, 0…1.
        var radius = 0.5
        /// Feather: how gradually it builds, 0…1.
        var softness = 0.5
        /// -1 squarer … 1 rounder; 0 follows the crop's shape.
        var roundness = 0.0
        var style = Style.highlightPriority
        /// With highlight priority, how much bright areas keep their brightness, 0…1.
        var highlightContrast = 0.0

        enum Style: String, Codable, CaseIterable, Sendable {
            /// Darkens or lightens while protecting highlights.
            case highlightPriority
            /// Darkens or lightens every tone the same.
            case colorPriority
            /// Paints black or white over the edges.
            case paintOverlay

            var title: String {
                switch self {
                case .highlightPriority: "Highlight Priority"
                case .colorPriority: "Color Priority"
                case .paintOverlay: "Paint Overlay"
                }
            }
        }

        var isActive: Bool { isEnabled && strength != 0 }
    }
}

nonisolated extension PhotoAdjustments {
    private enum LegacyBlackAndWhiteKeys: String, CodingKey { case grain }

    private enum CodingKeys: String, CodingKey {
        case light, color, blackAndWhite, redEye, whiteBalance, curves, levels, definition
        case selectiveColor, noiseReduction, sharpen, vignette, crop, orientation, lens, presence, effects, transform, profile, calibration, portraitLighting, rimLight
        case masks, spots, redEyes
    }

    /// Sections missing from older saved settings decode as their defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func decode<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        self.init()
        light = try decode(.light, light)
        color = try decode(.color, color)
        blackAndWhite = try decode(.blackAndWhite, blackAndWhite)
        redEye = try decode(.redEye, redEye)
        whiteBalance = try decode(.whiteBalance, whiteBalance)
        curves = try decode(.curves, curves)
        levels = try decode(.levels, levels)
        definition = try decode(.definition, definition)
        selectiveColor = try decode(.selectiveColor, selectiveColor)
        noiseReduction = try decode(.noiseReduction, noiseReduction)
        sharpen = try decode(.sharpen, sharpen)
        vignette = try decode(.vignette, vignette)
        crop = try decode(.crop, crop)
        orientation = try decode(.orientation, orientation)
        lens = try decode(.lens, lens)
        presence = try decode(.presence, presence)
        effects = try decode(.effects, effects)
        transform = try decode(.transform, transform)
        profile = try decode(.profile, profile)
        calibration = try decode(.calibration, calibration)
        portraitLighting = try decode(.portraitLighting, portraitLighting)
        rimLight = try decode(.rimLight, rimLight)
        masks = try decode(.masks, masks)
        spots = try decode(.spots, spots)
        redEyes = try decode(.redEyes, redEyes)
        // Grain used to belong to Black & White.
        if !container.contains(.effects), let legacy = try? container.nestedContainer(keyedBy: LegacyBlackAndWhiteKeys.self, forKey: .blackAndWhite),
           let grain = try? legacy.decodeIfPresent(Double.self, forKey: .grain), grain > 0 {
            effects.grain = grain
        }
    }

    init(data: Data?) {
        guard let data, let decoded = try? JSONDecoder().decode(PhotoAdjustments.self, from: data) else {
            self = .default
            return
        }
        self = decoded
    }

    /// `nil` when everything is at its default, so unedited photos store nothing.
    var encoded: Data? {
        guard !isDefault else { return nil }
        let encoder = JSONEncoder()
        // Stable output, so unchanged settings compare equal and don't dirty the photo.
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(self)
    }
}

/// Portrait Lighting's fields missing from saved settings, or an effect this version doesn't know, decode as defaults.
nonisolated extension PhotoAdjustments.PortraitLighting {
    private enum CodingKeys: String, CodingKey { case isEnabled, effect, intensity }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        effect = (try? container.decodeIfPresent(String.self, forKey: .effect)).flatMap { $0.flatMap(Effect.init(rawValue:)) } ?? effect
        intensity = try container.decodeIfPresent(Double.self, forKey: .intensity) ?? intensity
    }
}

/// Rim Light's fields missing from saved settings decode as their defaults, so it can grow.
nonisolated extension PhotoAdjustments.RimLight {
    private enum CodingKeys: String, CodingKey { case isEnabled, lights, glow }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        lights = Array((try container.decodeIfPresent([Light].self, forKey: .lights) ?? lights).prefix(Self.maximumLights))
        glow = try container.decodeIfPresent(Double.self, forKey: .glow) ?? glow
    }
}

nonisolated extension PhotoAdjustments.RimLight.Light {
    private enum CodingKeys: String, CodingKey { case id, angle, red, green, blue, strength, width, choke }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? id
        angle = try container.decodeIfPresent(Double.self, forKey: .angle) ?? angle
        red = try container.decodeIfPresent(Double.self, forKey: .red) ?? red
        green = try container.decodeIfPresent(Double.self, forKey: .green) ?? green
        blue = try container.decodeIfPresent(Double.self, forKey: .blue) ?? blue
        strength = try container.decodeIfPresent(Double.self, forKey: .strength) ?? strength
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? width
        choke = try container.decodeIfPresent(Double.self, forKey: .choke) ?? choke
    }
}

/// Saved settings from before `whites` existed still decode: missing fields keep their defaults.
nonisolated extension PhotoAdjustments.Light {
    private enum CodingKeys: String, CodingKey {
        case isEnabled, exposure, brilliance, highlights, shadows, whites, brightness, contrast, blackPoint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        exposure = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? exposure
        brilliance = try container.decodeIfPresent(Double.self, forKey: .brilliance) ?? brilliance
        highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? highlights
        shadows = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? shadows
        whites = try container.decodeIfPresent(Double.self, forKey: .whites) ?? whites
        brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? brightness
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? contrast
        blackPoint = try container.decodeIfPresent(Double.self, forKey: .blackPoint) ?? blackPoint
    }
}

/// Curves saved before the parametric curve decode with it at its defaults.
nonisolated extension PhotoAdjustments.Curves {
    private enum CodingKeys: String, CodingKey { case isEnabled, rgb, red, green, blue, parametric }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        rgb = try container.decodeIfPresent(ToneCurve.self, forKey: .rgb) ?? rgb
        red = try container.decodeIfPresent(ToneCurve.self, forKey: .red) ?? red
        green = try container.decodeIfPresent(ToneCurve.self, forKey: .green) ?? green
        blue = try container.decodeIfPresent(ToneCurve.self, forKey: .blue) ?? blue
        parametric = try container.decodeIfPresent(ParametricCurve.self, forKey: .parametric) ?? parametric
    }
}

/// Color grading saved before the Global wheel and Blending decode with them at their defaults.
nonisolated extension PhotoAdjustments.ColorGrading {
    private enum CodingKeys: String, CodingKey { case isEnabled, shadows, midtones, highlights, global, balance, blending }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        shadows = try container.decodeIfPresent(PhotoAdjustments.ColorWheel.self, forKey: .shadows) ?? shadows
        midtones = try container.decodeIfPresent(PhotoAdjustments.ColorWheel.self, forKey: .midtones) ?? midtones
        highlights = try container.decodeIfPresent(PhotoAdjustments.ColorWheel.self, forKey: .highlights) ?? highlights
        global = try container.decodeIfPresent(PhotoAdjustments.ColorWheel.self, forKey: .global) ?? global
        balance = try container.decodeIfPresent(Double.self, forKey: .balance) ?? balance
        blending = try container.decodeIfPresent(Double.self, forKey: .blending) ?? blending
    }
}

/// Black & White settings from before the color mix decode with it at zero; their grain moved to Effects.
nonisolated extension PhotoAdjustments.BlackAndWhite {
    private enum CodingKeys: String, CodingKey { case isEnabled, intensity, neutrals, tone, mix }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        intensity = try container.decodeIfPresent(Double.self, forKey: .intensity) ?? intensity
        neutrals = try container.decodeIfPresent(Double.self, forKey: .neutrals) ?? neutrals
        tone = try container.decodeIfPresent(Double.self, forKey: .tone) ?? tone
        if let stored = try container.decodeIfPresent([Double].self, forKey: .mix), stored.count == mix.count { mix = stored }
    }
}

/// Sharpening saved before Radius, Detail and Masking decode: `edges` (0…1) was the radius.
nonisolated extension PhotoAdjustments.Sharpen {
    private enum CodingKeys: String, CodingKey { case isEnabled, intensity, radius, detail, masking, edges }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        intensity = try container.decodeIfPresent(Double.self, forKey: .intensity) ?? intensity
        if let radius = try container.decodeIfPresent(Double.self, forKey: .radius) {
            self.radius = radius
        } else if let edges = try container.decodeIfPresent(Double.self, forKey: .edges) {
            radius = 0.5 + edges * 2.5
        }
        detail = try container.decodeIfPresent(Double.self, forKey: .detail) ?? detail
        masking = try container.decodeIfPresent(Double.self, forKey: .masking) ?? masking
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(intensity, forKey: .intensity)
        try container.encode(radius, forKey: .radius)
        try container.encode(detail, forKey: .detail)
        try container.encode(masking, forKey: .masking)
    }
}

nonisolated extension PhotoAdjustments.NoiseReduction {
    private enum CodingKeys: String, CodingKey { case isEnabled, amount, color, detail }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        amount = try container.decodeIfPresent(Double.self, forKey: .amount) ?? amount
        color = try container.decodeIfPresent(Double.self, forKey: .color) ?? color
        detail = try container.decodeIfPresent(Double.self, forKey: .detail) ?? detail
    }
}

nonisolated extension PhotoAdjustments.Vignette {
    private enum CodingKeys: String, CodingKey { case isEnabled, strength, radius, softness, roundness, style, highlightContrast }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        strength = try container.decodeIfPresent(Double.self, forKey: .strength) ?? strength
        radius = try container.decodeIfPresent(Double.self, forKey: .radius) ?? radius
        softness = try container.decodeIfPresent(Double.self, forKey: .softness) ?? softness
        roundness = try container.decodeIfPresent(Double.self, forKey: .roundness) ?? roundness
        style = try container.decodeIfPresent(Style.self, forKey: .style) ?? style
        highlightContrast = try container.decodeIfPresent(Double.self, forKey: .highlightContrast) ?? highlightContrast
    }
}

nonisolated extension PhotoAdjustments.Effects {
    private enum CodingKeys: String, CodingKey { case isEnabled, grain, grainSize, grainRoughness, grainSeed }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        grain = try container.decodeIfPresent(Double.self, forKey: .grain) ?? grain
        grainSize = try container.decodeIfPresent(Double.self, forKey: .grainSize) ?? grainSize
        grainRoughness = try container.decodeIfPresent(Double.self, forKey: .grainRoughness) ?? grainRoughness
        grainSeed = try container.decodeIfPresent(Int.self, forKey: .grainSeed) ?? grainSeed
    }
}

/// Transform settings are new; the Upright fields can be missing from earlier saves of newer builds.
nonisolated extension PhotoAdjustments.Transform {
    private enum CodingKeys: String, CodingKey {
        case isEnabled, vertical, horizontal, rotate, aspect, scale, offsetX, offsetY, constrainCrop, upright, uprightMatrix
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        vertical = try container.decodeIfPresent(Double.self, forKey: .vertical) ?? vertical
        horizontal = try container.decodeIfPresent(Double.self, forKey: .horizontal) ?? horizontal
        rotate = try container.decodeIfPresent(Double.self, forKey: .rotate) ?? rotate
        aspect = try container.decodeIfPresent(Double.self, forKey: .aspect) ?? aspect
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? scale
        offsetX = try container.decodeIfPresent(Double.self, forKey: .offsetX) ?? offsetX
        offsetY = try container.decodeIfPresent(Double.self, forKey: .offsetY) ?? offsetY
        constrainCrop = try container.decodeIfPresent(Bool.self, forKey: .constrainCrop) ?? constrainCrop
        upright = try container.decodeIfPresent(Upright.self, forKey: .upright) ?? upright
        uprightMatrix = try container.decodeIfPresent([Double].self, forKey: .uprightMatrix)
    }
}

nonisolated extension PhotoAdjustments.Profile {
    private enum CodingKeys: String, CodingKey { case isEnabled, kind, amount, importedName, adobeID }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? kind
        amount = try container.decodeIfPresent(Double.self, forKey: .amount) ?? amount
        importedName = try container.decodeIfPresent(String.self, forKey: .importedName)
        adobeID = try container.decodeIfPresent(String.self, forKey: .adobeID)
    }
}

nonisolated extension PhotoAdjustments.Calibration {
    private enum CodingKeys: String, CodingKey {
        case isEnabled, shadowTint, redHue, redSaturation, greenHue, greenSaturation, blueHue, blueSaturation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        shadowTint = try container.decodeIfPresent(Double.self, forKey: .shadowTint) ?? shadowTint
        redHue = try container.decodeIfPresent(Double.self, forKey: .redHue) ?? redHue
        redSaturation = try container.decodeIfPresent(Double.self, forKey: .redSaturation) ?? redSaturation
        greenHue = try container.decodeIfPresent(Double.self, forKey: .greenHue) ?? greenHue
        greenSaturation = try container.decodeIfPresent(Double.self, forKey: .greenSaturation) ?? greenSaturation
        blueHue = try container.decodeIfPresent(Double.self, forKey: .blueHue) ?? blueHue
        blueSaturation = try container.decodeIfPresent(Double.self, forKey: .blueSaturation) ?? blueSaturation
    }
}
