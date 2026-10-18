import Foundation

/// Every key Lightroom writes in a photo's develop settings, and what PixelLoupe does with it.
///
/// A key is **mapped** (turned into a ``PhotoAdjustments`` value), **bookkeeping** (versions, digests
/// and the like: no look of its own), **legacy** (only meaningful in processes older than 2012), or
/// **unsupported** (not imported; the photo is reported as imported with differences when the
/// setting isn't at its neutral value). Each Develop import ticket moves keys from unsupported to
/// mapped. A test fails when settings from the fixture catalogs use a key that isn't listed.
nonisolated enum LightroomDevelopCoverage {
    enum Status: Equatable, Sendable {
        case mapped
        case bookkeeping
        case legacy
        case unsupported(Group)
    }

    /// Unsupported settings are reported together: one line per group in the import report.
    struct Group: Equatable, Sendable {
        /// The difference key stored on photos, e.g. `tone-controls`.
        var key: String
        var title: String
    }

    // MARK: - Groups

    static let detail = Group(key: "noise-reduction-detail", title: "Noise reduction contrast, color detail and smoothness not imported")
    static let lens = Group(key: "lens-corrections", title: "Lens corrections not imported")
    static let profile = Group(key: "preset", title: "Presets and AI looks not imported")
    static let masks = Group(key: "point-color-blur", title: "Point color, lens blur and depth maps not imported")
    static let hdr = Group(key: "hdr", title: "HDR and glow not imported")

    // MARK: - The table

    private static let colors = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]

    static let table: [String: Status] = {
        var table: [String: Status] = [:]
        func add(_ status: Status, _ keys: [String]) { for key in keys { table[key] = status } }

        add(.mapped, [
            "Exposure2012", "WhiteBalance", "Temperature", "Tint", "IncrementalTemperature", "IncrementalTint",
            "Contrast2012", "Highlights2012", "Shadows2012", "Whites2012", "Blacks2012",
            "Texture", "Clarity2012", "Dehaze", "Vibrance", "Saturation",
            "ToneCurvePV2012", "ToneCurvePV2012Red", "ToneCurvePV2012Green", "ToneCurvePV2012Blue",
            "ParametricShadows", "ParametricDarks", "ParametricLights", "ParametricHighlights",
            "ParametricShadowSplit", "ParametricMidtoneSplit", "ParametricHighlightSplit",
            "ConvertToGrayscale", "ColorGradeBlending", "SplitToningBalance",
            "ColorGradeGlobalHue", "ColorGradeGlobalSat", "ColorGradeGlobalLum", "ColorGradeShadowHue", "ColorGradeShadowSat",
            "ColorGradeShadowLum", "ColorGradeMidtoneHue", "ColorGradeMidtoneSat", "ColorGradeMidtoneLum",
            "ColorGradeHighlightHue", "ColorGradeHighlightSat", "ColorGradeHighlightLum",
            "SplitToningShadowHue", "SplitToningShadowSaturation", "SplitToningHighlightHue", "SplitToningHighlightSaturation",
            "Sharpness", "SharpenRadius", "SharpenDetail", "SharpenEdgeMasking", "LuminanceSmoothing",
            "LuminanceNoiseReductionDetail", "ColorNoiseReduction",
            "PostCropVignetteAmount", "PostCropVignetteMidpoint", "PostCropVignetteFeather", "PostCropVignetteRoundness",
            "PostCropVignetteStyle", "PostCropVignetteHighlightContrast", "GrainAmount", "GrainSize", "GrainFrequency",
            "CropLeft", "CropRight", "CropTop", "CropBottom", "CropAngle", "CropConstrainAspectRatio",
            "LensProfileEnable", "LensProfileSetup", "LensManualDistortionAmount", "LensProfileDistortionScale",
            "LensProfileVignettingScale", "AutoLateralCA", "DefringePurpleAmount", "DefringeGreenAmount",
            "DefringePurpleHueLo", "DefringePurpleHueHi", "DefringeGreenHueLo", "DefringeGreenHueHi",
            "VignetteAmount", "VignetteMidpoint", "CropConstrainToWarp",
            "LensProfileName", "LensProfileFilename",
            "PerspectiveVertical", "PerspectiveHorizontal", "PerspectiveRotate", "PerspectiveAspect", "PerspectiveScale",
            "PerspectiveX", "PerspectiveY", "PerspectiveUpright",
            "CameraProfile", "Look", "ShadowTint", "RedHue", "RedSaturation", "GreenHue", "GreenSaturation",
            "BlueHue", "BlueSaturation",
            "MaskGroupBasedCorrections", "GradientBasedCorrections", "CircularGradientBasedCorrections", "PaintBasedCorrections",
            "RetouchInfo", "RetouchAreas", "RedEyeInfo",
        ] + colors.flatMap { ["HueAdjustment\($0)", "SaturationAdjustment\($0)", "LuminanceAdjustment\($0)", "GrayMixer\($0)"] })
        add(.bookkeeping, [
            "Version", "ProcessVersion", "CompatibleVersion", "HasCrop", "HasSettings", "AlreadyApplied", "RawFileName", "CameraProfileDigest", "ToggleStyleAmount", "ToggleStyleDigest",
            "OverrideLookVignette", "EnableDistractionRemoval", "AutoTone", "AutoGrayscaleMix", "HDRMaxValue",
            "LensProfileDigest", "LensProfileIsEmbedded",
            "CustomLensProfileFilename", "CustomLensProfileName", "CustomLensProfileDigest", "CustomLensProfileIsEmbedded",
            "UprightVersion", "UprightPreview", "UprightCenterMode", "UprightCenterNormX", "UprightCenterNormY",
            "UprightFocalMode", "UprightFocalLength35mm", "UprightTransformCount", "UprightFourSegmentsCount",
            "UprightDependentDigest", "UprightGuidedDependentDigest",
            "ToneCurveName2012",
            "CropAspectRatioW", "CropAspectRatioH", "CropUnit", "CropWidth", "CropHeight",
        ])
        for index in 0..<8 { add(.bookkeeping, ["UprightTransform_\(index)"]) }
        for index in 0..<8 { add(.bookkeeping, ["UprightFourSegments_\(index)"]) }
        add(.legacy, [
            "Exposure", "Contrast", "Brightness", "Shadows", "FillLight", "HighlightRecovery", "Clarity",
            "ToneCurve", "ToneCurveRed", "ToneCurveGreen", "ToneCurveBlue", "ToneCurveName",
        ])
        add(.unsupported(detail), ["LuminanceNoiseReductionContrast", "ColorNoiseReductionDetail", "ColorNoiseReductionSmoothness"])
        add(.unsupported(lens), [
            "LensProfileChromaticAberrationScale", "CustomLensProfileDistortionScale", "CustomLensProfileVignettingScale",
            "CustomLensProfileChromaticAberrationScale",
        ])
        add(.unsupported(profile), ["Preset", "AILook", "SupportsAmount"])
        add(.unsupported(masks), ["PointColors", "LensBlur", "DepthMapInfo", "FilterList"])
        add(.unsupported(hdr), [
            "HDREditMode", "SDRBlend", "SDRBrightness", "SDRClarity", "SDRContrast", "SDRHighlights", "SDRShadows",
            "SDRWhites", "Glow", "GlowRange", "GlowSpread", "GlowStyle", "GlowWarmth", "CurveRefineSaturation",
        ])
        return table
    }()

    static func status(of key: String) -> Status? { table[key] }

    // MARK: - Neutral values

    /// Values that mean "not adjusted", for the keys whose neutral isn't 0, false, empty or "".
    private static let neutralNumbers: [String: [Double]] = [
        "Sharpness": [0, 25, 40], "SharpenRadius": [1], "ParametricShadowSplit": [25], "ParametricMidtoneSplit": [50],
        "ParametricHighlightSplit": [75], "SharpenDetail": [25], "ColorNoiseReduction": [0, 25],
        "ColorNoiseReductionDetail": [50], "ColorNoiseReductionSmoothness": [50], "ColorGradeBlending": [50],
        "GrainSize": [25], "GrainFrequency": [50], 
        "LensProfileDistortionScale": [100], "LensProfileVignettingScale": [100], "LensProfileChromaticAberrationScale": [100],
        "CustomLensProfileDistortionScale": [100], "CustomLensProfileVignettingScale": [100],
        "CustomLensProfileChromaticAberrationScale": [100], "CropRight": [1], "CropBottom": [1],
        "GlowRange": [50], "GlowSpread": [50], "CurveRefineSaturation": [100], "VignetteMidpoint": [50],
    ]
    private static let neutralStrings: [String: Set<String>] = [
        "LensProfileSetup": ["LensDefaults"], "ToneCurveName2012": ["Linear", ""], "ToneCurveName": ["Linear", "", "Custom"],
    ]
    /// Profiles and looks that Lightroom applies on import: not an edit.
    private static let defaultProfiles: Set<String> = ["Embedded", "Adobe Standard", "Adobe Standard v2", "Adobe Color", "Adobe Default"]

    /// Whether `value` for `key` is the setting's neutral value, so the photo has nothing to report.
    static func isNeutral(_ key: String, _ value: LuaValue) -> Bool {
        switch key {
        case "ToneCurve", "ToneCurveRed", "ToneCurveGreen", "ToneCurveBlue":
            return isLinearCurve(value)
        case "CameraProfile":
            return value.string.map { defaultProfiles.contains($0) || $0.hasPrefix("Adobe ") } ?? true
        case "Look", "AILook", "Preset":
            guard let table = value.table, !table.isEmpty else { return true }
            guard let name = table["Name"]?.string, key == "Look" else { return false }
            return defaultProfiles.contains(name)
        case "SupportsAmount":
            return true
        default:
            break
        }
        switch value {
        case .number(let number):
            return (neutralNumbers[key] ?? [0]).contains { abs($0 - number) < 0.0005 }
        case .bool(let flag):
            return !flag
        case .string(let text):
            return neutralStrings[key]?.contains(text) ?? text.isEmpty
        case .table(let table):
            return table.isEmpty
        }
    }

    private static func isLinearCurve(_ value: LuaValue) -> Bool {
        guard let table = value.table else { return true }
        return table.isEmpty || table.array.compactMap(\.number) == [0, 0, 255, 255]
    }
}
