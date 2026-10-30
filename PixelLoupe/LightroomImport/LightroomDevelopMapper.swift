import CoreGraphics
import Foundation

/// Turns the settings Lightroom keeps for a photo (`Adobe_imageDevelopSettings.text`) into
/// ``PhotoAdjustments``.
///
/// Each Develop import ticket adds a `map…` step for its panel. A setting PixelLoupe can't carry over
/// exactly is returned as a ``Difference``, which the import report groups and the photo remembers.
/// Settings at their defaults produce nothing. Every key is listed in ``LightroomDevelopCoverage``.
nonisolated enum LightroomDevelopMapper {
    struct Input {
        var settings: LuaTable
        /// `Adobe_imageDevelopSettings.processVersion`, e.g. `11.0`.
        var processVersion: String?
        /// The settings' `WhiteBalance` column (the table also repeats it).
        var whiteBalance: String?
        /// RAW files (and DNG) are developed with temperature and tint; other files with increments.
        var isRaw: Bool
        /// Makes the grain pattern the photo's own; 0 for none.
        var seed = 0
        /// The photo's size in pixels as shown (after orientation), for the crop; `.zero` when unknown.
        var imageSize: CGSize = .zero
        /// The LensFun profile found for the Lightroom lens profile, when the phase looked one up.
        var lensProfile: PhotoAdjustments.LensProfile?
        /// The photo's camera, for camera-matching profiles.
        var cameraModel: String?
        /// Where imported Adobe profiles are found.
        var profiles: AdobeProfileLibrary = .shared
    }

    /// A reason the photo isn't exactly as in Lightroom.
    struct Difference: Equatable, Sendable {
        var key: String
        var title: String
        /// Counted in the report's notes but not tagged on the photo (for what nearly every photo has).
        var reportOnly = false
    }

    static let autoWhiteBalance = Difference(key: "white-balance-auto", title: "Auto white balance imported as As Shot")
    static let whiteBalanceRange = Difference(key: "white-balance-range", title: "White balance outside PixelLoupe’s range was limited")
    static let olderProcess = Difference(key: "older-process-version", title: "Older process version — approximated")
    static let curvePoints = Difference(key: "curve-points", title: "Tone curve with more than 16 points was simplified")
    static let sharpeningOff = Difference(key: "sharpening-default", title: "Sharpening turned off in Lightroom: PixelLoupe keeps its default RAW sharpening")
    static let cropApproximated = Difference(key: "crop-approximated", title: "Crop imported without the photo’s size, so a straightened crop may be off")
    static let lensProfileUnmatched = Difference(key: "lens-profile-unmatched", title: "Lens profile not found in LensFun: the camera’s own correction is used where it has one")
    static let uprightNotApplied = Difference(key: "upright", title: "Upright not applied: Lightroom’s stored transform isn’t used yet; manual sliders are")
    static let unknownSettings = Difference(key: "unknown-settings", title: "Settings from a newer version of Lightroom not imported")

    /// Maps `input` into `adjustments` (which keeps what earlier steps set, such as orientation).
    static func apply(_ input: Input, to adjustments: inout PhotoAdjustments) -> [Difference] {
        var differences: [Difference] = []
        if isCurrentProcess(input.processVersion ?? input.settings["ProcessVersion"]?.string) {
            mapLight(input, to: &adjustments)
        } else {
            // Photos last edited with Lightroom's older tone controls: Lightroom still renders them
            // with those, so their sliders are converted. Everything else (white balance, color, detail,
            // crop, lens…) is the same in every process version.
            mapLegacyTone(input, to: &adjustments)
            differences.append(olderProcess)
        }
        differences += mapWhiteBalance(input, to: &adjustments)
        differences += mapCurves(input, to: &adjustments)
        mapColor(input, to: &adjustments)
        differences += mapDetail(input, to: &adjustments)
        mapEffects(input, to: &adjustments)
        differences += mapCrop(input, to: &adjustments)
        differences += mapLens(input, to: &adjustments)
        differences += mapTransform(input, to: &adjustments)
        differences += mapProfile(input, to: &adjustments)
        differences += mapMasks(input, to: &adjustments)
        differences += mapRetouch(input, to: &adjustments)
        differences += unsupported(input.settings)
        return differences
    }

    // MARK: - Process version

    /// Process versions 6.7 (2012), 10.0, 11.0 and 15.4 share the 2012 sliders; older ones (5.0 and
    /// below) are different tone controls.
    static func isCurrentProcess(_ version: String?) -> Bool {
        guard let version, let number = Double(version) else { return true }
        return number >= 6.7
    }

    // MARK: - Older process versions

    /// What Lightroom's older processes start a photo at: Brightness 50, Contrast 25, Blacks (`Shadows`) 5.
    static let legacyDefaults = (brightness: 50.0, contrast: 25.0, blacks: 5.0)

    /// Converts the tone controls of process versions 2003 and 2010 (approximately; these never map to
    /// the 2012 sliders one to one). Exposure is the same in stops; Fill Light lifts shadows and
    /// Recovery pulls highlights down; Blacks, Brightness and Contrast are measured from their defaults;
    /// the tone curve is the stored one (the default Medium Contrast curve included, since Lightroom
    /// renders with it).
    private static func mapLegacyTone(_ input: Input, to adjustments: inout PhotoAdjustments) {
        let settings = input.settings
        func value(_ key: String) -> Double? { settings[key].flatMap(number) }
        if let exposure = value("Exposure"), exposure != 0 { adjustments.light.exposure = LightroomScales.exposure(exposure) }
        if let fill = value("FillLight"), fill != 0 { adjustments.light.shadows = round3(fill / 100 * 0.8).clamped(to: -1...1) }
        if let recovery = value("HighlightRecovery"), recovery != 0 { adjustments.light.highlights = round3(-recovery / 100 * 0.8).clamped(to: -1...1) }
        if let blacks = value("Shadows") {
            // More blacks darkens: PixelLoupe's Black Point is levels-style, where positive crushes.
            let shift = (blacks - legacyDefaults.blacks) / 100
            if shift != 0 { adjustments.light.blackPoint = round3(shift).clamped(to: -1...1) }
        }
        if let brightness = value("Brightness") {
            let shift = (brightness - legacyDefaults.brightness) / 100
            if shift != 0 { adjustments.light.brightness = round3(shift).clamped(to: -1...1) }
        }
        if let contrast = value("Contrast") {
            let shift = (contrast - legacyDefaults.contrast) / 100
            if shift != 0 { adjustments.light.contrast = round3(shift).clamped(to: -1...1) }
        }
        if let clarity = value("Clarity"), clarity != 0 { adjustments.presence.clarity = LightroomScales.percent(clarity) }
        if let vibrance = value("Vibrance"), vibrance != 0 { adjustments.presence.vibrance = LightroomScales.percent(vibrance) }
        if let saturation = value("Saturation"), saturation != 0 { adjustments.presence.saturation = LightroomScales.percent(saturation) }
        // The curves: the point curve for RGB, then red, green and blue.
        for (key, keyPath) in [("ToneCurve", \PhotoAdjustments.Curves.rgb), ("ToneCurveRed", \.red), ("ToneCurveGreen", \.green), ("ToneCurveBlue", \.blue)] {
            guard let values = settings[key]?.table?.array.compactMap(number), values.count >= 4, values.count % 2 == 0 else { continue }
            let points = stride(from: 0, to: values.count, by: 2).map {
                ToneCurve.Point(x: LightroomScales.curveCoordinate(values[$0]), y: LightroomScales.curveCoordinate(values[$0 + 1]))
            }
            let curve = ToneCurve(points: points)
            if !curve.isIdentity { adjustments.curves[keyPath: keyPath] = curve }
        }
    }

    private static func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }

    // MARK: - Light

    private static func mapLight(_ input: Input, to adjustments: inout PhotoAdjustments) {
        let settings = input.settings
        func value(_ key: String) -> Double? { settings[key].flatMap(number).flatMap { $0 != 0 ? $0 : nil } }
        if let exposure = value("Exposure2012") { adjustments.light.exposure = LightroomScales.exposure(exposure) }
        if let contrast = value("Contrast2012") { adjustments.light.contrast = LightroomScales.percent(contrast) }
        if let highlights = value("Highlights2012") { adjustments.light.highlights = LightroomScales.highlights(highlights) }
        if let shadows = value("Shadows2012") { adjustments.light.shadows = LightroomScales.shadows(shadows) }
        if let whites = value("Whites2012") { adjustments.light.whites = LightroomScales.percent(whites) }
        if let blacks = value("Blacks2012") { adjustments.light.blackPoint = LightroomScales.blackPoint(fromBlacks: blacks) }
        if let texture = value("Texture") { adjustments.presence.texture = LightroomScales.percent(texture) }
        if let clarity = value("Clarity2012") { adjustments.presence.clarity = LightroomScales.clarity(clarity) }
        if let dehaze = value("Dehaze") { adjustments.presence.dehaze = LightroomScales.percent(dehaze) }
        if let vibrance = value("Vibrance") { adjustments.presence.vibrance = LightroomScales.percent(vibrance) }
        if let saturation = value("Saturation") { adjustments.presence.saturation = LightroomScales.percent(saturation) }
    }

    // MARK: - Color mixer, color grading, black & white

    private static func mapColor(_ input: Input, to adjustments: inout PhotoAdjustments) {
        let settings = input.settings
        func value(_ key: String) -> Double? { settings[key].flatMap(number) }

        for range in PhotoAdjustments.SelectiveColorRange.allCases {
            let name = range.title
            if let hue = value("HueAdjustment\(name)"), hue != 0 { adjustments.selectiveColor[range].hue = LightroomScales.percent(hue) }
            if let saturation = value("SaturationAdjustment\(name)"), saturation != 0 {
                adjustments.selectiveColor[range].saturation = LightroomScales.percent(saturation)
            }
            if let luminance = value("LuminanceAdjustment\(name)"), luminance != 0 {
                adjustments.selectiveColor[range].luminance = LightroomScales.percent(luminance)
            }
            if let mix = value("GrayMixer\(name)"), mix != 0 { adjustments.blackAndWhite[range] = LightroomScales.percent(mix) }
        }
        if settings["ConvertToGrayscale"]?.bool == true {
            adjustments.blackAndWhite.isEnabled = true
            adjustments.blackAndWhite.intensity = 1
        }

        func wheel(_ part: String) -> PhotoAdjustments.ColorWheel? {
            let hue = value("ColorGrade\(part)Hue") ?? 0, saturation = value("ColorGrade\(part)Sat") ?? 0
            let luminance = value("ColorGrade\(part)Lum") ?? 0
            guard hue != 0 || saturation != 0 || luminance != 0 else { return nil }
            return .init(hue: LightroomScales.hue(hue), amount: LightroomScales.saturation(saturation), luminance: LightroomScales.percent(luminance))
        }
        if let shadows = wheel("Shadow") { adjustments.color.shadows = shadows }
        if let midtones = wheel("Midtone") { adjustments.color.midtones = midtones }
        if let highlights = wheel("Highlight") { adjustments.color.highlights = highlights }
        if let global = wheel("Global") { adjustments.color.global = global }
        if let blending = value("ColorGradeBlending") { adjustments.color.blending = LightroomScales.saturation(blending) }
        if let balance = value("SplitToningBalance"), balance != 0 { adjustments.color.balance = LightroomScales.percent(balance) }
        // Split toning from before color grading: its shadow and highlight tints are the wheels.
        if adjustments.color.shadows == .init(), let amount = value("SplitToningShadowSaturation"), amount > 0 {
            adjustments.color.shadows = .init(hue: LightroomScales.hue(value("SplitToningShadowHue") ?? 0), amount: LightroomScales.saturation(amount))
        }
        if adjustments.color.highlights == .init(), let amount = value("SplitToningHighlightSaturation"), amount > 0 {
            adjustments.color.highlights = .init(hue: LightroomScales.hue(value("SplitToningHighlightHue") ?? 0), amount: LightroomScales.saturation(amount))
        }
    }

    // MARK: - Detail

    private static func mapDetail(_ input: Input, to adjustments: inout PhotoAdjustments) -> [Difference] {
        let settings = input.settings
        func value(_ key: String) -> Double? { settings[key].flatMap(number) }
        var differences: [Difference] = []

        // Lightroom writes its default RAW sharpening (40, radius 1, detail 25, masking 0) into every
        // RAW photo. PixelLoupe's engine applies its own default, so that is not an edit.
        let radius = value("SharpenRadius") ?? 1, detail = value("SharpenDetail") ?? 25, masking = value("SharpenEdgeMasking") ?? 0
        if let sharpness = value("Sharpness") {
            let isDefault = input.isRaw && (sharpness == 25 || sharpness == 40) && radius == 1 && detail == 25 && masking == 0
            if input.isRaw, sharpness == 0 {
                differences.append(sharpeningOff)
            } else if sharpness > 0, !isDefault {
                adjustments.sharpen = .init(
                    intensity: LightroomScales.sharpness(sharpness), radius: LightroomScales.sharpenRadius(radius),
                    detail: LightroomScales.percent(detail).clamped(to: 0...1), masking: LightroomScales.percent(masking).clamped(to: 0...1))
            }
        }

        if let smoothing = value("LuminanceSmoothing"), smoothing > 0 {
            adjustments.noiseReduction.amount = LightroomScales.percent(smoothing).clamped(to: 0...1)
        }
        // The same default for RAW color noise reduction (25) is the engine's.
        if let color = value("ColorNoiseReduction"), color > 0, !(input.isRaw && color == 25) {
            adjustments.noiseReduction.color = LightroomScales.percent(color).clamped(to: 0...1)
        }
        if let luminanceDetail = value("LuminanceNoiseReductionDetail"), luminanceDetail != 50 {
            adjustments.noiseReduction.detail = LightroomScales.percent(luminanceDetail).clamped(to: 0...1)
        }
        return differences
    }

    // MARK: - Lens corrections

    /// Whether the settings turn Lightroom's profile corrections on, so the phase should look up a profile.
    static func usesLensProfile(_ settings: LuaTable) -> Bool {
        settings["LensProfileEnable"].flatMap(number).map { $0 != 0 } ?? false
    }

    private static func mapLens(_ input: Input, to adjustments: inout PhotoAdjustments) -> [Difference] {
        let settings = input.settings
        func value(_ key: String) -> Double? { settings[key].flatMap(number) }
        var lens = PhotoAdjustments.LensCorrections()
        var differences: [Difference] = []

        if usesLensProfile(settings) {
            lens.enableProfileCorrections = true
            lens.setup = settings["LensProfileSetup"]?.string == "Custom" ? .custom : .auto
            lens.profile = input.lensProfile
            if input.lensProfile == nil { differences.append(lensProfileUnmatched) }
            if let distortion = value("LensProfileDistortionScale") { lens.distortionAmount = (distortion / 100).clamped(to: 0...2) }
            if let vignetting = value("LensProfileVignettingScale") { lens.vignettingAmount = (vignetting / 100).clamped(to: 0...2) }
        }
        if let aberration = value("AutoLateralCA"), aberration != 0 { lens.removeChromaticAberration = true }
        if let distortion = value("LensManualDistortionAmount"), distortion != 0 { lens.manualDistortion = LightroomScales.percent(distortion) }
        if let purple = value("DefringePurpleAmount"), purple > 0 {
            lens.purpleAmount = (purple / 20).clamped(to: 0...1)
            lens.purpleHue = .init(lower: (value("DefringePurpleHueLo") ?? 30) / 100, upper: (value("DefringePurpleHueHi") ?? 70) / 100)
        }
        if let green = value("DefringeGreenAmount"), green > 0 {
            lens.greenAmount = (green / 20).clamped(to: 0...1)
            lens.greenHue = .init(lower: (value("DefringeGreenHueLo") ?? 40) / 100, upper: (value("DefringeGreenHueHi") ?? 60) / 100)
        }
        if let vignetting = value("VignetteAmount"), vignetting != 0 {
            lens.manualVignetting = LightroomScales.percent(vignetting)
            lens.vignettingMidpoint = ((value("VignetteMidpoint") ?? 50) / 100).clamped(to: 0...1)
        }
        if let constrain = value("CropConstrainToWarp"), constrain != 0 { lens.constrainCrop = true }

        // Constrain Crop alone, with no correction to constrain, is not an edit.
        if lens.hasManualCorrections || lens.enableProfileCorrections || lens.removeChromaticAberration {
            adjustments.lens = lens
        }
        return differences
    }

    // MARK: - Masks

    static let brushMasks = Difference(key: "masks-brush", title: "Brush masks not imported")
    static let aiMasks = Difference(key: "masks-ai", title: "AI masks (subject, sky, background, people…) not imported")
    static let rangeMasks = Difference(key: "masks-range", title: "Range masks not imported")
    static let otherMasks = Difference(key: "masks-other", title: "Masks of an unknown type not imported")
    static let localSettings = Difference(key: "masks-local-settings", title: "Local sharpening, noise, moiré, defringe and toning not imported")

    /// The local sliders a mask carries that PixelLoupe has nothing for.
    private static let unsupportedLocalKeys = [
        "LocalSharpness", "LocalLuminanceNoise", "LocalMoire", "LocalDefringe", "LocalToningHue", "LocalToningSaturation",
        "LocalCurveRefineSaturation", "LocalBrightness", "LocalContrast", "LocalClarity", "LocalExposure", "LocalHue",
    ]

    private static func mapMasks(_ input: Input, to adjustments: inout PhotoAdjustments) -> [Difference] {
        let settings = input.settings
        var differences: [Difference] = []
        var found: [PhotoAdjustments.LocalAdjustment] = []
        func note(_ difference: Difference) { if !differences.contains(difference) { differences.append(difference) } }

        if let brush = settings["PaintBasedCorrections"]?.table, !brush.array.isEmpty { note(brushMasks) }
        for (key, isLegacy) in [("MaskGroupBasedCorrections", false), ("GradientBasedCorrections", true), ("CircularGradientBasedCorrections", true)] {
            guard let corrections = settings[key]?.table?.array else { continue }
            for correction in corrections {
                guard let table = correction.table else { continue }
                if let adjustment = localAdjustment(from: table, isLegacy: isLegacy, note: note) { found.append(adjustment) }
            }
        }
        if !found.isEmpty { adjustments.masks = found }
        return differences
    }

    /// One correction as a local adjustment, or `nil` when it has a mask or settings PixelLoupe can't carry.
    private static func localAdjustment(
        from table: LuaTable, isLegacy: Bool, note: (Difference) -> Void
    ) -> PhotoAdjustments.LocalAdjustment? {
        func value(_ key: String) -> Double? { table[key].flatMap(number) }
        let masks = table["CorrectionMasks"]?.table?.array.compactMap(\.table) ?? [table]
        var components: [PhotoAdjustments.MaskComponent] = []
        var supported = true
        for mask in masks {
            switch mask["What"]?.string ?? "" {
            case "Mask/Gradient":
                guard let component = linearComponent(mask) else { supported = false; note(otherMasks); continue }
                components.append(component)
            case "Mask/CircularGradient":
                guard let component = radialComponent(mask, isLegacy: isLegacy) else { supported = false; note(otherMasks); continue }
                components.append(component)
            case "Mask/Paint": supported = false; note(brushMasks)
            case "Mask/Image": supported = false; note(aiMasks)
            case let what where what.contains("Range"): supported = false; note(rangeMasks)
            default: supported = false; note(otherMasks)
            }
        }
        guard supported, !components.isEmpty else { return nil }

        var local = PhotoAdjustments.LocalSettings()
        local.exposure = LightroomScales.exposure(value("LocalExposure2012") ?? 0)
        local.contrast = LightroomScales.percent(value("LocalContrast2012") ?? 0)
        local.highlights = LightroomScales.percent(value("LocalHighlights2012") ?? 0)
        local.shadows = LightroomScales.percent(value("LocalShadows2012") ?? 0)
        local.whites = LightroomScales.percent(value("LocalWhites2012") ?? 0)
        local.blacks = LightroomScales.percent(value("LocalBlacks2012") ?? 0)
        local.clarity = LightroomScales.percent(value("LocalClarity2012") ?? 0)
        local.texture = LightroomScales.percent(value("LocalTexture") ?? 0)
        local.dehaze = LightroomScales.percent(value("LocalDehaze") ?? 0)
        local.saturation = LightroomScales.percent(value("LocalSaturation") ?? 0)
        local.temperature = LightroomScales.percent(value("LocalTemperature") ?? 0)
        local.tint = LightroomScales.percent(value("LocalTint") ?? 0)
        if unsupportedLocalKeys.contains(where: { (value($0) ?? 0) != 0 }) { note(localSettings) }
        guard local.isActive else { return nil }

        var adjustment = PhotoAdjustments.LocalAdjustment()
        adjustment.name = table["CorrectionName"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? components[0].shape.title
        adjustment.isEnabled = table["CorrectionActive"]?.bool ?? true
        adjustment.amount = (value("CorrectionAmount") ?? 1).clamped(to: 0...1)
        adjustment.components = components
        adjustment.settings = local
        return adjustment
    }

    /// Lightroom's coordinates are fractions of the photo with the origin at the top-left.
    private static func point(x: Double, y: Double) -> PhotoAdjustments.UnitPoint { .init(x: x, y: 1 - y) }

    private static func blend(_ mask: LuaTable) -> (PhotoAdjustments.MaskComponent.Mode, Bool) {
        let mode: PhotoAdjustments.MaskComponent.Mode = switch Int(mask["MaskBlendMode"].flatMap(number) ?? 0) {
        case 1: .subtract
        case 2: .intersect
        default: .add
        }
        return (mode, mask["MaskInverted"]?.bool ?? false)
    }

    private static func linearComponent(_ mask: LuaTable) -> PhotoAdjustments.MaskComponent? {
        guard let zx = mask["ZeroX"].flatMap(number), let zy = mask["ZeroY"].flatMap(number),
              let fx = mask["FullX"].flatMap(number), let fy = mask["FullY"].flatMap(number) else { return nil }
        let (mode, inverted) = blend(mask)
        return .init(shape: .linear(.init(zero: point(x: zx, y: zy), full: point(x: fx, y: fy))), mode: mode, isInverted: inverted)
    }

    private static func radialComponent(_ mask: LuaTable, isLegacy: Bool) -> PhotoAdjustments.MaskComponent? {
        guard let top = mask["Top"].flatMap(number), let left = mask["Left"].flatMap(number),
              let bottom = mask["Bottom"].flatMap(number), let right = mask["Right"].flatMap(number) else { return nil }
        let (mode, inverted) = blend(mask)
        let center = point(x: (left + right) / 2, y: (top + bottom) / 2)
        // Lightroom turns clockwise; PixelLoupe counterclockwise.
        let angle = -(mask["Angle"].flatMap(number) ?? 0)
        let feather = ((mask["Feather"].flatMap(number) ?? 50) / 100).clamped(to: 0...1)
        // The older radial filter applied outside its ellipse unless Flipped.
        let outside = isLegacy && !(mask["Flipped"]?.bool ?? false)
        return .init(
            shape: .radial(.init(center: center, radiusX: abs(right - left) / 2, radiusY: abs(bottom - top) / 2, angle: angle, feather: feather)),
            mode: mode, isInverted: inverted != outside)
    }

    // MARK: - Spot removal and red eye

    static let aiRemove = Difference(key: "retouch-ai", title: "Generative or AI removal, and spot types PixelLoupe doesn’t know, not imported")

    /// A spot's source when Lightroom picked it itself: beside the spot, on the side with room.
    static func automaticSource(for center: PhotoAdjustments.UnitPoint, radius: Double, imageSize: CGSize) -> PhotoAdjustments.UnitPoint {
        let longEdge = Double(max(imageSize.width, imageSize.height, 1))
        let offset = 2.6 * radius * longEdge / Double(max(imageSize.width, 1))
        return .init(x: center.x + offset < 0.97 ? center.x + offset : center.x - offset, y: center.y)
    }

    private static func mapRetouch(_ input: Input, to adjustments: inout PhotoAdjustments) -> [Difference] {
        let settings = input.settings
        let size = input.imageSize.width > 0 && input.imageSize.height > 0 ? input.imageSize : CGSize(width: 3, height: 2)
        let longEdge = Double(max(size.width, size.height))
        var differences: [Difference] = []
        var spots: [PhotoAdjustments.Spot] = []

        func kind(_ text: String?) -> PhotoAdjustments.Spot.Kind? {
            switch text?.lowercased() {
            case "heal", "contentaware", "content-aware", "gaussian", nil: .heal
            case "clone": .clone
            default: nil
            }
        }

        // Spots from older versions: radius, centers and sources in lower case.
        for entry in settings["RetouchInfo"]?.table?.array.compactMap(\.table) ?? [] {
            func value(_ key: String) -> Double? { entry[key].flatMap(number) }
            guard let x = value("centerX"), let y = value("centerY"), let radius = value("radius") else { continue }
            guard let kind = kind(entry["spotType"]?.string) else { differences.append(aiRemove); continue }
            var spot = PhotoAdjustments.Spot()
            spot.kind = kind
            spot.center = .init(x: x, y: 1 - y)
            spot.radius = radius.clamped(to: 0.001...0.5)
            spot.opacity = (value("opacity") ?? 1).clamped(to: 0...1)
            if let sx = value("sourceX"), let sy = value("sourceY") {
                spot.source = .init(x: sx, y: 1 - sy)
            } else {
                spot.source = automaticSource(for: spot.center, radius: spot.radius, imageSize: size)
            }
            spots.append(spot)
        }
        // Newer: a circle mask with per-axis sizes.
        for entry in settings["RetouchAreas"]?.table?.array.compactMap(\.table) ?? [] {
            func value(_ key: String) -> Double? { entry[key].flatMap(number) }
            guard let mask = entry["Masks"]?.table?.array.first?.table,
                  let x = mask["X"].flatMap(number), let y = mask["Y"].flatMap(number) else { continue }
            guard let kind = kind(entry["SpotType"]?.string ?? entry["spotType"]?.string) else { differences.append(aiRemove); continue }
            var spot = PhotoAdjustments.Spot()
            spot.kind = kind
            spot.center = .init(x: x, y: 1 - y)
            let sizeX = mask["SizeX"].flatMap(number) ?? 0.02, sizeY = mask["SizeY"].flatMap(number) ?? sizeX
            spot.radius = (max(sizeX * Double(size.width), sizeY * Double(size.height)) / longEdge).clamped(to: 0.001...0.5)
            spot.feather = ((value("Feather") ?? 50) / 100).clamped(to: 0...1)
            spot.opacity = (value("Opacity") ?? 1).clamped(to: 0...1)
            if let sx = value("SourceX") ?? value("sourceX"), let sy = value("SourceY") ?? value("sourceY") {
                spot.source = .init(x: sx, y: 1 - sy)
            } else {
                spot.source = automaticSource(for: spot.center, radius: spot.radius, imageSize: size)
            }
            spots.append(spot)
        }
        if !spots.isEmpty { adjustments.spots = spots }

        // Red eyes: an ellipse on the pupil.
        var eyes: [PhotoAdjustments.RedEyeSpot] = []
        for entry in settings["RedEyeInfo"]?.table?.array.compactMap(\.table) ?? [] {
            guard let ellipse = entry["pupil"]?["ellipse"]?.table,
                  let x = ellipse["centerX"].flatMap(number), let y = ellipse["centerY"].flatMap(number) else { continue }
            var eye = PhotoAdjustments.RedEyeSpot()
            eye.center = .init(x: x, y: 1 - y)
            let sizeX = ellipse["sizeX"].flatMap(number) ?? 0.01, sizeY = ellipse["sizeY"].flatMap(number) ?? sizeX
            eye.radius = (max(sizeX * Double(size.width), sizeY * Double(size.height)) / longEdge).clamped(to: 0.001...0.2)
            eye.strength = (entry["pupil"]?["strength"].flatMap(number) ?? 1).clamped(to: 0...1)
            eye.darken = (entry["pupilDarkenAmount"].flatMap(number) ?? 0.5).clamped(to: 0...1)
            eyes.append(eye)
        }
        if !eyes.isEmpty { adjustments.redEyes = eyes }
        return differences.isEmpty ? [] : [aiRemove]
    }

    // MARK: - Profile and calibration

    /// Imported as Default: Adobe's standard-rendering profiles, which nearly every photo has.
    static let defaultProfileNote = Difference(
        key: "profile-default", title: "photos use an Adobe Color or Standard profile: imported as PixelLoupe’s Default, which is close but not identical",
        reportOnly: true)

    /// What PixelLoupe makes of a Lightroom profile name.
    enum ProfileMapping: Equatable {
        case none
        case defaultLook
        case look(PhotoAdjustments.Profile.Kind)
        /// One of Adobe's B&W profiles ("B&W 01" … "B&W 17"): the photo becomes black and white, with
        /// PixelLoupe's conversion (the settings' B&W mix then applies, as in Lightroom).
        case blackAndWhite
        case unknown
    }

    static func profileMapping(for name: String) -> ProfileMapping {
        var text = name.lowercased().trimmingCharacters(in: .whitespaces)
        // "Camera Vivid v2": the version isn't a different look.
        if let range = text.range(of: #" v\d+$"#, options: .regularExpression) { text.removeSubrange(range) }
        switch text {
        case "embedded", "": return .none
        // "Default Color" and the like are Lightroom's presets saying "the camera's default profile".
        case "adobe color", "adobe standard", "camera standard", "camera faithful", "adobe default", "default color", "default monochrome",
             "default profile": return .defaultLook
        case "adobe vivid", "camera vivid": return .look(.vivid)
        case "adobe landscape", "camera landscape": return .look(.landscape)
        case "adobe portrait", "camera portrait": return .look(.portrait)
        case "adobe monochrome", "camera monochrome": return .look(.monochrome)
        case "adobe neutral", "camera neutral": return .look(.neutral)
        case _ where text.range(of: #"^b&w \d+$"#, options: .regularExpression) != nil: return .blackAndWhite
        default: return .unknown
        }
    }

    /// `profile-` and the name as lowercase letters, digits and hyphens.
    static func profileKey(for name: String) -> String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let squeezed = slug.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return "profile-" + String(squeezed.prefix(40))
    }

    private static func mapProfile(_ input: Input, to adjustments: inout PhotoAdjustments) -> [Difference] {
        let settings = input.settings
        func value(_ key: String) -> Double? { settings[key].flatMap(number) }

        // Calibration.
        var calibration = PhotoAdjustments.Calibration()
        calibration.shadowTint = LightroomScales.percent(value("ShadowTint") ?? 0)
        calibration.redHue = LightroomScales.percent(value("RedHue") ?? 0)
        calibration.redSaturation = LightroomScales.percent(value("RedSaturation") ?? 0)
        calibration.greenHue = LightroomScales.percent(value("GreenHue") ?? 0)
        calibration.greenSaturation = LightroomScales.percent(value("GreenSaturation") ?? 0)
        calibration.blueHue = LightroomScales.percent(value("BlueHue") ?? 0)
        calibration.blueSaturation = LightroomScales.percent(value("BlueSaturation") ?? 0)
        if calibration.isActive { adjustments.calibration = calibration }

        // The look (newer catalogs) names the profile; otherwise the camera profile does. A preset's
        // empty look (`<crs:Look crs:Name=""/>`) names none.
        let look = settings["Look"]?.table.flatMap { $0["Name"]?.string?.isEmpty == false ? $0 : nil }
        guard let name = look?["Name"]?.string ?? settings["CameraProfile"]?.string else { return [] }
        let amount = look?["Amount"]?.number ?? 1
        let mapping = profileMapping(for: name)
        // The real profile, when it's been imported (Adobe's defaults stay PixelLoupe's own rendering).
        if mapping != .none, mapping != .defaultLook,
           let entry = input.profiles.find(id: look?["UUID"]?.string, name: name, cameraModel: input.cameraModel) {
            adjustments.profile = .init(kind: .standard, amount: amount.clamped(to: 0...2), importedName: name, adobeID: entry.id)
            if entry.isMonochrome {
                adjustments.blackAndWhite.isEnabled = true
                adjustments.blackAndWhite.intensity = 1
            }
            return []
        }
        switch mapping {
        case .none:
            return []
        case .defaultLook:
            return [defaultProfileNote]
        case .look(let kind):
            adjustments.profile = .init(kind: kind, amount: amount.clamped(to: 0...2), importedName: name)
            return [Difference(key: "profile-approximated", title: "Lightroom profile replaced by PixelLoupe’s own look")]
        case .blackAndWhite:
            adjustments.blackAndWhite.isEnabled = true
            adjustments.blackAndWhite.intensity = 1
            adjustments.profile = .init(kind: .standard, amount: amount.clamped(to: 0...2), importedName: name)
            return [Difference(key: "profile-black-and-white", title: "Lightroom B&W profile replaced by PixelLoupe’s black and white")]
        case .unknown:
            // The look's name for one of the lens-profile style entries is no profile either.
            return [Difference(key: profileKey(for: name), title: "Profile “\(name)” isn’t available: imported as Default")]
        }
    }

    // MARK: - Transform

    private static func mapTransform(_ input: Input, to adjustments: inout PhotoAdjustments) -> [Difference] {
        let settings = input.settings
        func value(_ key: String) -> Double? { settings[key].flatMap(number) }
        var transform = PhotoAdjustments.Transform()
        if let vertical = value("PerspectiveVertical") { transform.vertical = LightroomScales.percent(vertical) }
        if let horizontal = value("PerspectiveHorizontal") { transform.horizontal = LightroomScales.percent(horizontal) }
        if let rotate = value("PerspectiveRotate") { transform.rotate = rotate.clamped(to: -10...10) }
        if let aspect = value("PerspectiveAspect") { transform.aspect = LightroomScales.percent(aspect) }
        if let scale = value("PerspectiveScale"), scale > 0 { transform.scale = (scale / 100).clamped(to: 0.5...1.5) }
        if let x = value("PerspectiveX") { transform.offsetX = LightroomScales.percent(x) }
        if let y = value("PerspectiveY") { transform.offsetY = LightroomScales.percent(y) }

        var differences: [Difference] = []
        let mode = Int(value("PerspectiveUpright") ?? 0)
        if mode != 0 {
            transform.upright = PhotoAdjustments.Transform.Upright.allCases.indices.contains(mode)
                ? PhotoAdjustments.Transform.Upright.allCases[mode] : .off
            // The stored matrix for the active mode: nine numbers, row by row.
            if let text = settings["UprightTransform_\(mode)"]?.string {
                let numbers = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if numbers.count == 9 { transform.uprightMatrix = numbers }
            }
            differences.append(uprightNotApplied)
        }
        if transform.hasManualTransform || transform.upright != .off {
            adjustments.transform = transform
        }
        return differences
    }

    // MARK: - Crop

    private static func mapCrop(_ input: Input, to adjustments: inout PhotoAdjustments) -> [Difference] {
        let settings = input.settings
        func value(_ key: String) -> Double? { settings[key].flatMap(number) }
        let crop = LightroomCropConverter.Crop(
            left: value("CropLeft") ?? 0, top: value("CropTop") ?? 0, right: value("CropRight") ?? 1, bottom: value("CropBottom") ?? 1,
            angle: value("CropAngle") ?? 0, constrainAspectRatio: settings["CropConstrainAspectRatio"]?.bool ?? false)
        guard crop.isActive else { return [] }
        var size = input.imageSize
        var approximated = false
        if size.width <= 0 || size.height <= 0 {
            // Without the size only an unrotated crop is exact; assume a 3:2 photo otherwise.
            size = CGSize(width: 3, height: 2)
            approximated = crop.angle != 0
        }
        guard let converted = LightroomCropConverter.convert(crop, size: size) else { return [] }
        adjustments.crop = converted
        return approximated ? [cropApproximated] : []
    }

    // MARK: - Effects

    private static func mapEffects(_ input: Input, to adjustments: inout PhotoAdjustments) {
        let settings = input.settings
        func value(_ key: String) -> Double? { settings[key].flatMap(number) }

        if let amount = value("PostCropVignetteAmount"), amount != 0 {
            var vignette = PhotoAdjustments.Vignette()
            // Lightroom's negative amounts darken; PixelLoupe's positive strength does.
            vignette.strength = -LightroomScales.percent(amount)
            vignette.radius = LightroomScales.percent(value("PostCropVignetteMidpoint") ?? 50).clamped(to: 0...1)
            vignette.softness = LightroomScales.percent(value("PostCropVignetteFeather") ?? 50).clamped(to: 0...1)
            vignette.roundness = LightroomScales.percent(value("PostCropVignetteRoundness") ?? 0)
            vignette.highlightContrast = LightroomScales.percent(value("PostCropVignetteHighlightContrast") ?? 0).clamped(to: 0...1)
            switch Int(value("PostCropVignetteStyle") ?? 1) {
            case 2: vignette.style = .colorPriority
            case 3: vignette.style = .paintOverlay
            default: vignette.style = .highlightPriority
            }
            adjustments.vignette = vignette
        }
        if let amount = value("GrainAmount"), amount > 0 {
            adjustments.effects.grain = LightroomScales.percent(amount).clamped(to: 0...1)
            adjustments.effects.grainSize = LightroomScales.percent(value("GrainSize") ?? 25).clamped(to: 0...1)
            adjustments.effects.grainRoughness = LightroomScales.percent(value("GrainFrequency") ?? 50).clamped(to: 0...1)
            adjustments.effects.grainSeed = max(1, input.seed)
        }
    }

    // MARK: - Curves

    private static func mapCurves(_ input: Input, to adjustments: inout PhotoAdjustments) -> [Difference] {
        let settings = input.settings
        var simplified = false
        func curve(_ key: String) -> ToneCurve? {
            guard let values = settings[key]?.table?.array.compactMap(number), values.count >= 4, values.count % 2 == 0 else { return nil }
            let points = stride(from: 0, to: values.count, by: 2).map {
                ToneCurve.Point(x: LightroomScales.curveCoordinate(values[$0]), y: LightroomScales.curveCoordinate(values[$0 + 1]))
            }
            if points.count > ToneCurve.maximumPoints { simplified = true }
            let curve = ToneCurve(points: points)
            return curve.isIdentity ? nil : curve
        }
        if let rgb = curve("ToneCurvePV2012") { adjustments.curves.rgb = rgb }
        if let red = curve("ToneCurvePV2012Red") { adjustments.curves.red = red }
        if let green = curve("ToneCurvePV2012Green") { adjustments.curves.green = green }
        if let blue = curve("ToneCurvePV2012Blue") { adjustments.curves.blue = blue }

        func amount(_ key: String) -> Double? { settings[key].flatMap(number).flatMap { $0 != 0 ? LightroomScales.parametric($0) : nil } }
        var parametric = ParametricCurve()
        parametric.shadows = amount("ParametricShadows") ?? 0
        parametric.darks = amount("ParametricDarks") ?? 0
        parametric.lights = amount("ParametricLights") ?? 0
        parametric.highlights = amount("ParametricHighlights") ?? 0
        if !parametric.isIdentity {
            if let split = settings["ParametricShadowSplit"].flatMap(number) { parametric.shadowSplit = LightroomScales.split(split) }
            if let split = settings["ParametricMidtoneSplit"].flatMap(number) { parametric.midtoneSplit = LightroomScales.split(split) }
            if let split = settings["ParametricHighlightSplit"].flatMap(number) { parametric.highlightSplit = LightroomScales.split(split) }
            adjustments.curves.parametric = parametric
        }
        return simplified ? [curvePoints] : []
    }

    // MARK: - White balance

    private static func mapWhiteBalance(_ input: Input, to adjustments: inout PhotoAdjustments) -> [Difference] {
        let settings = input.settings
        let name = settings["WhiteBalance"]?.string ?? input.whiteBalance
        if name == "Auto" {
            return [autoWhiteBalance]
        }
        if input.isRaw {
            // "As Shot" keeps the camera's values, even when the settings repeat them as numbers.
            guard let name, name != "As Shot" else { return [] }
            let temperature = settings["Temperature"].flatMap(number)
            let tint = settings["Tint"].flatMap(number)
            guard temperature != nil || tint != nil else { return [] }
            var result = PhotoAdjustments.WhiteBalance()
            var clamped = false
            if let temperature {
                result.temperature = LightroomScales.rawTemperature(temperature)
                clamped = !LightroomScales.temperatureRange.contains(temperature)
            }
            result.tint = tint.map(LightroomScales.rawTint)
            if PhotoAdjustments.WhiteBalance.presets.contains(where: { $0.name == name }) { result.preset = name }
            adjustments.whiteBalance = result
            return clamped ? [whiteBalanceRange] : []
        }
        let temperature = settings["IncrementalTemperature"].flatMap(number) ?? 0
        let tint = settings["IncrementalTint"].flatMap(number) ?? 0
        guard temperature != 0 || tint != 0 else { return [] }
        var result = PhotoAdjustments.WhiteBalance()
        if temperature != 0 { result.temperature = LightroomScales.incrementalTemperature(temperature) }
        if tint != 0 { result.tint = LightroomScales.incrementalTint(tint) }
        adjustments.whiteBalance = result
        return []
    }

    // MARK: - Settings not imported yet

    /// One difference per group that has a non-neutral setting, plus unknown keys.
    private static func unsupported(_ settings: LuaTable) -> [Difference] {
        var groups: [String: Difference] = [:]
        var order: [String] = []
        var unknown = false
        for (key, value) in settings.hash.sorted(by: { $0.key < $1.key }) {
            switch LightroomDevelopCoverage.status(of: key) {
            case nil:
                unknown = true
            case .unsupported(let group)?:
                guard !LightroomDevelopCoverage.isNeutral(key, value), groups[group.key] == nil else { continue }
                groups[group.key] = Difference(key: group.key, title: group.title)
                order.append(group.key)
            default:
                break
            }
        }
        var result = order.compactMap { groups[$0] }
        if unknown { result.append(unknownSettings) }
        return result
    }

    private static func number(_ value: LuaValue) -> Double? {
        switch value {
        case .number(let number): number
        case .string(let text): Double(text)
        default: nil
        }
    }
}
