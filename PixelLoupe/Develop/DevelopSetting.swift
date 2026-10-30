import Foundation

/// One setting Copy Settings and Sync Settings can carry from one photo to others, as listed (with
/// a checkbox each) in Lightroom's Copy Settings dialog.
nonisolated enum DevelopSetting: String, CaseIterable, Codable, Sendable {
    case whiteBalance
    case exposure, contrast, highlights, shadows, whites, blacks, brilliance, brightness
    case texture, clarity, dehaze, vibrance, saturation
    case toneCurve, levels, definition
    case colorMixer, colorGrading
    case blackAndWhite
    case sharpening, noiseReduction
    case lensCorrections, transform
    case vignette, grain
    case portraitLighting, rimLight
    case profile, calibration
    case redEye, spotRemoval, masking, crop

    var title: String {
        switch self {
        case .whiteBalance: "White Balance"
        case .exposure: "Exposure"
        case .contrast: "Contrast"
        case .highlights: "Highlights"
        case .shadows: "Shadows"
        case .whites: "Whites"
        case .blacks: "Blacks"
        case .brilliance: "Brilliance"
        case .brightness: "Brightness"
        case .texture: "Texture"
        case .clarity: "Clarity"
        case .dehaze: "Dehaze"
        case .vibrance: "Vibrance"
        case .saturation: "Saturation"
        case .toneCurve: "Tone Curve"
        case .levels: "Levels"
        case .definition: "Definition"
        case .colorMixer: "Color Mixer"
        case .colorGrading: "Color Grading"
        case .blackAndWhite: "Black & White"
        case .sharpening: "Sharpening"
        case .noiseReduction: "Noise Reduction"
        case .lensCorrections: "Lens Corrections"
        case .transform: "Transform"
        case .vignette: "Vignette"
        case .grain: "Grain"
        case .portraitLighting: "Portrait Lighting"
        case .rimLight: "Rim Light"
        case .profile: "Profile"
        case .calibration: "Calibration"
        case .redEye: "Red Eye"
        case .spotRemoval: "Spot Removal"
        case .masking: "Masking"
        case .crop: "Crop & Straighten"
        }
    }

    /// The dialog's groups. A group of one is a single checkbox; larger groups have a checkbox for the
    /// group and one for each setting in it.
    struct Group: Identifiable, Sendable {
        var title: String
        var settings: [DevelopSetting]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "White Balance", settings: [.whiteBalance]),
        Group(title: "Basic Tone", settings: [.exposure, .contrast, .highlights, .shadows, .whites, .blacks, .brilliance, .brightness]),
        Group(title: "Presence", settings: [.texture, .clarity, .dehaze, .vibrance, .saturation]),
        Group(title: "Tone", settings: [.toneCurve, .levels, .definition]),
        Group(title: "Color", settings: [.colorMixer, .colorGrading]),
        Group(title: "Black & White", settings: [.blackAndWhite]),
        Group(title: "Detail", settings: [.sharpening, .noiseReduction]),
        Group(title: "Lens Corrections", settings: [.lensCorrections]),
        Group(title: "Transform", settings: [.transform]),
        Group(title: "Effects", settings: [.vignette, .grain]),
        Group(title: "Portrait Lighting", settings: [.portraitLighting]),
        Group(title: "Rim Light", settings: [.rimLight]),
        Group(title: "Profile", settings: [.profile]),
        Group(title: "Calibration", settings: [.calibration]),
        Group(title: "Red Eye", settings: [.redEye]),
        Group(title: "Spot Removal", settings: [.spotRemoval]),
        Group(title: "Masking", settings: [.masking]),
        Group(title: "Crop & Straighten", settings: [.crop]),
    ]

    /// Checked when the dialog opens: everything but what's placed on one photo (red eye, spots,
    /// masks and the crop), as in Lightroom.
    static let defaultSelection: Set<DevelopSetting> = Set(allCases).subtracting([.redEye, .spotRemoval, .masking, .crop])

    /// `target` with the `settings` taken from `source`. A section's on/off switch comes along with
    /// any of its settings.
    static func apply(_ settings: Set<DevelopSetting>, from source: PhotoAdjustments, to target: PhotoAdjustments) -> PhotoAdjustments {
        var result = target
        func copy<Value>(_ keyPath: WritableKeyPath<PhotoAdjustments, Value>) {
            result[keyPath: keyPath] = source[keyPath: keyPath]
        }
        for setting in settings {
            switch setting {
            case .whiteBalance: copy(\.whiteBalance)
            case .exposure: copy(\.light.exposure)
            case .contrast: copy(\.light.contrast)
            case .highlights: copy(\.light.highlights)
            case .shadows: copy(\.light.shadows); copy(\.light.shadowsProcess)
            case .whites: copy(\.light.whites)
            case .blacks: copy(\.light.blackPoint)
            case .brilliance: copy(\.light.brilliance)
            case .brightness: copy(\.light.brightness)
            case .texture: copy(\.presence.texture)
            case .clarity: copy(\.presence.clarity)
            case .dehaze: copy(\.presence.dehaze)
            case .vibrance: copy(\.presence.vibrance)
            case .saturation: copy(\.presence.saturation)
            case .toneCurve: copy(\.curves)
            case .levels: copy(\.levels)
            case .definition: copy(\.definition)
            case .colorMixer: copy(\.selectiveColor)
            case .colorGrading: copy(\.color)
            case .blackAndWhite: copy(\.blackAndWhite)
            case .sharpening: copy(\.sharpen)
            case .noiseReduction: copy(\.noiseReduction)
            case .lensCorrections: copy(\.lens)
            case .transform: copy(\.transform)
            case .vignette: copy(\.vignette)
            case .grain: copy(\.effects)
            case .portraitLighting: copy(\.portraitLighting)
            case .rimLight: copy(\.rimLight)
            case .profile: copy(\.profile)
            case .calibration: copy(\.calibration)
            case .redEye:
                copy(\.redEye)
                copy(\.redEyes)
            case .spotRemoval: copy(\.spots)
            case .masking: copy(\.masks)
            case .crop:
                copy(\.crop)
                copy(\.orientation)
            }
        }
        if !settings.isDisjoint(with: groups[1].settings) { copy(\.light.isEnabled) }
        if !settings.isDisjoint(with: groups[2].settings) { copy(\.presence.isEnabled) }
        return result
    }
}

nonisolated extension PhotoAdjustments {
    /// Lightroom's Delete All Empty Masks: masks with nothing in them (every component removed, or a
    /// brush never painted).
    var hasEmptyMasks: Bool { masks.contains(where: \.isEmpty) }

    mutating func deleteEmptyMasks() {
        masks.removeAll(where: \.isEmpty)
    }

    /// Convert to Black & White: the Black & White section's Auto, as in the panel.
    static let autoBlackAndWhite = BlackAndWhite(isEnabled: true, tone: 0.2)
}
