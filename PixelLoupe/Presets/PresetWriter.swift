import Foundation

/// The parts of the settings a preset can hold, as Lightroom's New Develop Preset dialog lists them.
nonisolated enum PresetSection: String, CaseIterable, Codable, Sendable {
    case whiteBalance, basicTone, presence, toneCurve, colorMixer, colorGrading, blackAndWhite, detail, effects, lens, transform,
         calibration, profile, portraitLighting, rimLight

    var title: String {
        switch self {
        case .whiteBalance: "White Balance"
        case .basicTone: "Basic Tone"
        case .presence: "Presence"
        case .toneCurve: "Tone Curve"
        case .colorMixer: "Color Mixer"
        case .colorGrading: "Color Grading"
        case .blackAndWhite: "Black & White"
        case .detail: "Detail (Sharpening and Noise Reduction)"
        case .effects: "Effects (Vignette and Grain)"
        case .lens: "Lens Corrections"
        case .transform: "Transform"
        case .calibration: "Calibration"
        case .profile: "Profile"
        case .portraitLighting: "Portrait Lighting"
        case .rimLight: "Rim Light"
        }
    }

    /// The Lightroom settings each section writes, so an existing preset's sections can be told from its keys.
    static func sections(of keys: Set<String>) -> Set<PresetSection> {
        Set(allCases.filter { section in
            let sample = PresetWriter.settings(for: PhotoAdjustments(), sections: [section]).keys
            return !keys.isDisjoint(with: sample)
        })
    }
}

/// Rim Light in a preset. Lightroom has nothing like it, so it's PixelLoupe's own setting, written as one attribute
/// holding its settings as JSON. Lightroom ignores it; PixelLoupe reads it back (``DevelopPreset/applied(to:isRaw:cameraModel:iso:profiles:)``).
nonisolated enum RimLightPreset {
    static let key = "PixelLoupeRimLight"

    static func text(_ rimLight: PhotoAdjustments.RimLight) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(rimLight)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func rimLight(_ text: String?) -> PhotoAdjustments.RimLight? {
        text.flatMap { try? JSONDecoder().decode(PhotoAdjustments.RimLight.self, from: Data($0.utf8)) }
    }
}

/// Portrait Lighting in a preset (RAW-214): PixelLoupe's own setting, written as JSON like ``RimLightPreset``.
nonisolated enum PortraitLightingPreset {
    static let key = "PixelLoupePortraitLighting"

    static func text(_ portraitLighting: PhotoAdjustments.PortraitLighting) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(portraitLighting)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func portraitLighting(_ text: String?) -> PhotoAdjustments.PortraitLighting? {
        text.flatMap { try? JSONDecoder().decode(PhotoAdjustments.PortraitLighting.self, from: Data($0.utf8)) }
    }
}

/// Writes PixelLoupe settings as a Lightroom / Camera Raw preset (`.xmp`): the inverse of the import's
/// mapping (``LightroomDevelopMapper`` with ``LightroomScales``), so a preset made here applies the same
/// in PixelLoupe and opens in Lightroom. Settings Lightroom has no equivalent for (Brilliance,
/// Brightness, Levels, Definition…) aren't written.
nonisolated enum PresetWriter {
    /// A Lightroom setting value: a number, text, a curve (points in 0…255), or a profile reference.
    enum Value: Equatable {
        case number(Double)
        case text(String)
        case curve([(Double, Double)])
        case look(name: String, amount: Double, uuid: String?)

        static func == (a: Value, b: Value) -> Bool {
            switch (a, b) {
            case let (.number(x), .number(y)): x == y
            case let (.text(x), .text(y)): x == y
            case let (.curve(x), .curve(y)): x.count == y.count && zip(x, y).allSatisfy { $0 == $1 }
            case let (.look(n1, a1, u1), .look(n2, a2, u2)): n1 == n2 && a1 == a2 && u1 == u2
            default: false
            }
        }
    }

    // MARK: - Settings

    /// The Lightroom settings for `sections` of `adjustments`. Every key of a section is written, at its
    /// default when PixelLoupe's is, so applying the preset resets what it covers (as Lightroom's do).
    static func settings(for adjustments: PhotoAdjustments, sections: Set<PresetSection>, profiles: AdobeProfileLibrary = .shared)
        -> [String: Value] {
        var out: [String: Value] = [:]
        func number(_ key: String, _ value: Double, places: Double = 0) {
            let scale = pow(10, places)
            out[key] = .number((value * scale).rounded() / scale)
        }
        let a = adjustments

        if sections.contains(.whiteBalance) {
            let wb = a.whiteBalance
            if wb.isActive {
                out["WhiteBalance"] = .text(wb.preset ?? "Custom")
                if let temperature = wb.temperature { number("Temperature", temperature) }
                if let tint = wb.tint { number("Tint", tint) }
            } else {
                out["WhiteBalance"] = .text("As Shot")
            }
        }
        if sections.contains(.basicTone) {
            number("Exposure2012", a.light.exposure, places: 2)
            number("Contrast2012", a.light.contrast * 100)
            number("Highlights2012", LightroomScales.lightroom(fromHighlights: a.light.highlights))
            number("Shadows2012", LightroomScales.lightroom(fromShadows: a.light.shadows, process: a.light.shadowsProcess))
            number("Whites2012", a.light.whites * 100)
            number("Blacks2012", -a.light.blackPoint * 100)
        }
        if sections.contains(.presence) {
            number("Texture", a.presence.texture * 100)
            number("Clarity2012", LightroomScales.lightroom(fromClarity: a.presence.clarity))
            number("Dehaze", a.presence.dehaze * 100)
            number("Vibrance", a.presence.vibrance * 100)
            number("Saturation", a.presence.saturation * 100)
        }
        if sections.contains(.toneCurve) {
            func curve(_ curve: ToneCurve) -> Value { .curve(curve.points.map { (($0.x * 255).rounded(), ($0.y * 255).rounded()) }) }
            out["ToneCurveName2012"] = .text(a.curves.pointCurveName)
            out["ToneCurvePV2012"] = curve(a.curves.rgb)
            out["ToneCurvePV2012Red"] = curve(a.curves.red)
            out["ToneCurvePV2012Green"] = curve(a.curves.green)
            out["ToneCurvePV2012Blue"] = curve(a.curves.blue)
            let parametric = a.curves.parametric
            number("ParametricShadows", LightroomScales.lightroom(fromParametric: parametric.shadows))
            number("ParametricDarks", LightroomScales.lightroom(fromParametric: parametric.darks))
            number("ParametricLights", LightroomScales.lightroom(fromParametric: parametric.lights))
            number("ParametricHighlights", LightroomScales.lightroom(fromParametric: parametric.highlights))
            number("ParametricShadowSplit", parametric.shadowSplit * 100)
            number("ParametricMidtoneSplit", parametric.midtoneSplit * 100)
            number("ParametricHighlightSplit", parametric.highlightSplit * 100)
        }
        if sections.contains(.colorMixer) {
            for range in PhotoAdjustments.SelectiveColorRange.allCases {
                number("HueAdjustment\(range.title)", a.selectiveColor[range].hue * 100)
                number("SaturationAdjustment\(range.title)", a.selectiveColor[range].saturation * 100)
                number("LuminanceAdjustment\(range.title)", a.selectiveColor[range].luminance * 100)
            }
        }
        if sections.contains(.colorGrading) {
            // Lightroom reads the Shadows and Highlights wheels' hue and saturation only under their Split Toning names.
            for (name, wheel) in [("Shadow", a.color.shadows), ("Midtone", a.color.midtones), ("Highlight", a.color.highlights), ("Global", a.color.global)] {
                let splitToning = name == "Shadow" || name == "Highlight"
                number(splitToning ? "SplitToning\(name)Hue" : "ColorGrade\(name)Hue", wheel.hue * 360)
                number(splitToning ? "SplitToning\(name)Saturation" : "ColorGrade\(name)Sat", wheel.amount * 100)
                number("ColorGrade\(name)Lum", wheel.luminance * 100)
            }
            number("ColorGradeBlending", a.color.blending * 100)
            number("SplitToningBalance", a.color.balance * 100)
        }
        if sections.contains(.blackAndWhite) {
            out["ConvertToGrayscale"] = .text(a.blackAndWhite.isEnabled ? "True" : "False")
            for range in PhotoAdjustments.SelectiveColorRange.allCases { number("GrayMixer\(range.title)", a.blackAndWhite[range] * 100) }
        }
        if sections.contains(.detail) {
            number("Sharpness", a.sharpen.intensity * 150)
            number("SharpenRadius", a.sharpen.radius, places: 1)
            number("SharpenDetail", a.sharpen.detail * 100)
            number("SharpenEdgeMasking", a.sharpen.masking * 100)
            number("LuminanceSmoothing", a.noiseReduction.amount * 100)
            number("ColorNoiseReduction", a.noiseReduction.color * 100)
            number("LuminanceNoiseReductionDetail", a.noiseReduction.detail * 100)
        }
        if sections.contains(.effects) {
            let vignette = a.vignette
            number("PostCropVignetteAmount", -vignette.strength * 100)
            number("PostCropVignetteMidpoint", vignette.radius * 100)
            number("PostCropVignetteFeather", vignette.softness * 100)
            number("PostCropVignetteRoundness", vignette.roundness * 100)
            number("PostCropVignetteHighlightContrast", vignette.highlightContrast * 100)
            let style: Double = switch vignette.style {
            case .highlightPriority: 1
            case .colorPriority: 2
            case .paintOverlay: 3
            }
            number("PostCropVignetteStyle", style)
            number("GrainAmount", a.effects.grain * 100)
            number("GrainSize", a.effects.grainSize * 100)
            number("GrainFrequency", a.effects.grainRoughness * 100)
        }
        if sections.contains(.lens) {
            let lens = a.lens
            number("LensProfileEnable", lens.enableProfileCorrections ? 1 : 0)
            out["LensProfileSetup"] = .text(lens.setup == .custom ? "Custom" : "LensDefaults")
            number("LensProfileDistortionScale", lens.distortionAmount * 100)
            number("LensProfileVignettingScale", lens.vignettingAmount * 100)
            number("AutoLateralCA", lens.removeChromaticAberration ? 1 : 0)
            number("LensManualDistortionAmount", lens.manualDistortion * 100)
            number("DefringePurpleAmount", lens.purpleAmount * 20)
            number("DefringePurpleHueLo", lens.purpleHue.lower * 100)
            number("DefringePurpleHueHi", lens.purpleHue.upper * 100)
            number("DefringeGreenAmount", lens.greenAmount * 20)
            number("DefringeGreenHueLo", lens.greenHue.lower * 100)
            number("DefringeGreenHueHi", lens.greenHue.upper * 100)
            number("VignetteAmount", lens.manualVignetting * 100)
            number("VignetteMidpoint", lens.vignettingMidpoint * 100)
        }
        if sections.contains(.transform) {
            let transform = a.transform
            number("PerspectiveVertical", transform.vertical * 100)
            number("PerspectiveHorizontal", transform.horizontal * 100)
            number("PerspectiveRotate", transform.rotate, places: 1)
            number("PerspectiveAspect", transform.aspect * 100)
            number("PerspectiveScale", transform.scale * 100)
            number("PerspectiveX", transform.offsetX * 100, places: 1)
            number("PerspectiveY", transform.offsetY * 100, places: 1)
        }
        if sections.contains(.calibration) {
            let c = a.calibration
            for (key, value) in [("ShadowTint", c.shadowTint), ("RedHue", c.redHue), ("RedSaturation", c.redSaturation), ("GreenHue", c.greenHue),
                                 ("GreenSaturation", c.greenSaturation), ("BlueHue", c.blueHue), ("BlueSaturation", c.blueSaturation)] {
                number(key, value * 100)
            }
        }
        if sections.contains(.profile) {
            let profile = a.profile
            if let id = profile.adobeID {
                out["Look"] = .look(name: profiles.entry(id: id)?.name ?? profile.importedName ?? "Adobe Color", amount: profile.amount, uuid: id)
            } else {
                let name = switch profile.kind {
                case .standard: "Adobe Color"
                case .neutral: "Adobe Neutral"
                case .vivid: "Adobe Vivid"
                case .landscape: "Adobe Landscape"
                case .portrait: "Adobe Portrait"
                case .monochrome: "Adobe Monochrome"
                }
                out["Look"] = .look(name: name, amount: profile.amount, uuid: nil)
            }
        }
        if sections.contains(.portraitLighting), let text = PortraitLightingPreset.text(a.portraitLighting) {
            out[PortraitLightingPreset.key] = .text(text)
        }
        if sections.contains(.rimLight), let text = RimLightPreset.text(a.rimLight) {
            out[RimLightPreset.key] = .text(text)
        }
        return out
    }

    // MARK: - XMP

    /// Settings that are never negative, which Lightroom writes without a sign.
    static func unsigned(_ key: String) -> Bool {
        let exact: Set<String> = [
            "ColorGradeBlending", "Sharpness", "SharpenRadius", "SharpenDetail", "SharpenEdgeMasking", "LuminanceSmoothing",
            "ColorNoiseReduction", "LuminanceNoiseReductionDetail", "PostCropVignetteMidpoint", "PostCropVignetteFeather",
            "PostCropVignetteStyle", "GrainAmount", "GrainSize", "GrainFrequency", "Temperature", "LensProfileEnable",
            "LensProfileDistortionScale", "LensProfileVignettingScale", "AutoLateralCA", "VignetteMidpoint", "PerspectiveScale",
            "ParametricShadowSplit", "ParametricMidtoneSplit", "ParametricHighlightSplit",
        ]
        return exact.contains(key) || key.hasPrefix("Defringe") || (key.hasPrefix("ColorGrade") && (key.hasSuffix("Hue") || key.hasSuffix("Sat")))
            || (key.hasPrefix("SplitToning") && (key.hasSuffix("Hue") || key.hasSuffix("Saturation")))
    }

    /// A complete preset file.
    static func xmp(name: String, group: String, settings: [String: Value], uuid: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")) -> Data {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        /// Lightroom signs only the settings whose sliders go below zero ("+20" contrast, "25" grain).
        func format(_ key: String, _ value: Double) -> String {
            let text = value == value.rounded() ? String(Int(value)) : String(value)
            return value > 0 && !unsigned(key) ? "+" + text : text
        }
        var attributes: [(String, String)] = [
            ("PresetType", "Normal"), ("Cluster", ""), ("UUID", uuid), ("SupportsAmount", "True"), ("SupportsColor", "True"),
            ("SupportsMonochrome", "True"), ("SupportsHighDynamicRange", "True"), ("SupportsNormalDynamicRange", "True"),
            ("SupportsSceneReferred", "True"), ("SupportsOutputReferred", "True"), ("CameraModelRestriction", ""), ("Copyright", ""),
            ("ContactInfo", ""), ("Version", "15.0"), ("ProcessVersion", "11.0"),
        ]
        // A setting given (a converted preset's process version) replaces the default.
        attributes.removeAll { settings[$0.0] != nil }
        var elements: [String] = []
        for key in settings.keys.sorted() {
            switch settings[key]! {
            case .number(let value): attributes.append((key, format(key, value)))
            case .text(let value): attributes.append((key, value))
            case .curve(let points):
                let items = points.map { "     <rdf:li>\(Int($0.0)), \(Int($0.1))</rdf:li>" }.joined(separator: "\n")
                elements.append("   <crs:\(key)>\n    <rdf:Seq>\n\(items)\n    </rdf:Seq>\n   </crs:\(key)>")
            case .look(let lookName, let amount, let id):
                let uuid = id.map { " crs:UUID=\"\(escaped($0))\"" } ?? ""
                elements.append("   <crs:Look>\n    <rdf:Description crs:Name=\"\(escaped(lookName))\" crs:Amount=\"\(amount)\"\(uuid)/>\n   </crs:Look>")
            }
        }
        attributes.append(("HasSettings", "True"))
        func alt(_ element: String, _ text: String) -> String {
            text.isEmpty
                ? "   <crs:\(element)>\n    <rdf:Alt>\n     <rdf:li xml:lang=\"x-default\"/>\n    </rdf:Alt>\n   </crs:\(element)>"
                : "   <crs:\(element)>\n    <rdf:Alt>\n     <rdf:li xml:lang=\"x-default\">\(escaped(text))</rdf:li>\n    </rdf:Alt>\n   </crs:\(element)>"
        }
        let text = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="PixelLoupe">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
        \(attributes.map { "   crs:\($0.0)=\"\(escaped($0.1))\"" }.joined(separator: "\n"))>
        \(alt("Name", name))
        \(alt("ShortName", ""))
        \(alt("SortName", ""))
        \(alt("Group", group))
        \(alt("Description", ""))
        \(elements.joined(separator: "\n"))
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>

        """
        return Data(text.utf8)
    }
}
