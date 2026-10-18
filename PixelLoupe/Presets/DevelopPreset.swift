import Foundation

/// A Develop preset: a Lightroom / Camera Raw preset file (`.xmp`) and the settings it carries.
///
/// A preset holds only some settings (a black-and-white look sets the B&W mix and a few tones, not
/// exposure). Applying it changes just those, through the same mapping the Lightroom catalog import
/// uses (``LightroomDevelopMapper``), and leaves the rest of the photo's settings alone.
nonisolated struct DevelopPreset: Identifiable, Equatable, Sendable {
    /// The file it was read from (its identity in the library).
    let url: URL
    let name: String
    /// The group it's listed under (Lightroom's `crs:Group`, else its folder).
    let group: String
    /// Lightroom's sort key within the group (`crs:SortName`), else the name.
    let sortName: String
    let settings: LuaTable
    /// Settings that follow the photo's ISO (`crs:ISODependent`): points of an ISO and the settings at it.
    var isoPoints: [ISOPoint] = []

    struct ISOPoint: Equatable, Sendable {
        var iso: Double
        var settings: [String: Double]
    }

    var id: URL { url }

    /// Reads a preset. `nil` for files that aren't presets: profiles (`PresetType="Look"`), or files
    /// without settings.
    static func load(_ url: URL, defaultGroup: String) -> DevelopPreset? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data, url: url, defaultGroup: defaultGroup)
    }

    static func parse(_ data: Data, url: URL, defaultGroup: String) -> DevelopPreset? {
        guard var settings = XMPDevelopSettings.parse(data) else { return nil }
        let type = settings["PresetType"]?.string ?? "Normal"
        guard type == "Normal", settings["HasSettings"]?.bool != false else { return nil }
        let text = PresetText.read(data)
        let name = text["Name"].flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        // The text elements aren't settings.
        for key in ["Name", "ShortName", "SortName", "Group", "Description"] { settings.hash[key] = nil }
        settings.hash["ISODependent"] = nil
        return DevelopPreset(
            url: url, name: name,
            group: text["Group"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultGroup,
            sortName: text["SortName"].flatMap { $0.isEmpty ? nil : $0 } ?? name,
            settings: settings,
            isoPoints: ISOPoints.read(data)
        )
    }

    /// The photo a preset is checked against.
    struct Photo: Equatable, Sendable {
        var cameraModel: String?
        /// From a monochrome camera (Leica's Monochrom, Pentax's K-3 III Monochrome): no color to work with.
        var isMonochrome = false

        init(cameraModel: String?, isMonochrome: Bool? = nil) {
            self.cameraModel = cameraModel
            self.isMonochrome = isMonochrome ?? cameraModel.map { $0.localizedCaseInsensitiveContains("monochrom") } ?? false
        }
    }

    /// How well a preset suits a photo, as Lightroom judges it.
    enum Compatibility: Equatable, Sendable {
        case compatible
        /// It applies, but not all of it does (its profile isn't available for this camera).
        case partial(String)
        /// It's for other photos (another camera, monochrome cameras only, HDR only); Lightroom hides it.
        case incompatible(String)

        var reason: String? {
            switch self {
            case .compatible: nil
            case .partial(let reason), .incompatible(let reason): reason
            }
        }
    }

    /// What the preset declares it suits (`crs:CameraModelRestriction`, `SupportsColor`,
    /// `SupportsMonochrome`, `SupportsNormalDynamicRange`) against the photo, and whether the profile
    /// it names is available. PixelLoupe edits in standard dynamic range, so HDR-only presets don't suit.
    func compatibility(with photo: Photo, profiles: AdobeProfileLibrary = .shared) -> Compatibility {
        if let camera = settings["CameraModelRestriction"]?.string, !camera.isEmpty,
           photo.cameraModel.map(AdobeProfile.normalized) != AdobeProfile.normalized(camera) {
            return .incompatible("Only for the \(camera).")
        }
        if photo.isMonochrome, settings["SupportsMonochrome"]?.bool == false { return .incompatible("Not for monochrome cameras.") }
        if !photo.isMonochrome, settings["SupportsColor"]?.bool == false { return .incompatible("Only for monochrome cameras.") }
        if settings["SupportsNormalDynamicRange"]?.bool == false { return .incompatible("Only for HDR editing.") }
        let look = settings["Look"]?.table
        if let name = look?["Name"]?.string ?? settings["CameraProfile"]?.string {
            // Adobe's standard looks have PixelLoupe stand-ins; any other profile has to be imported.
            if LightroomDevelopMapper.profileMapping(for: name) == .unknown,
               profiles.find(id: look?["UUID"]?.string, name: name, cameraModel: photo.cameraModel) == nil {
                return .partial("The profile “\(name)” isn’t available for this camera.")
            }
        }
        return .compatible
    }

    /// Whether the preset can be applied at an amount other than 100% (`crs:SupportsAmount`).
    var supportsAmount: Bool { settings["SupportsAmount"]?.bool ?? false }

    /// The Lightroom setting keys the preset sets (not its bookkeeping).
    var settingKeys: Set<String> { Set(settings.hash.keys).subtracting(Self.metadataKeys) }

    private static let metadataKeys: Set<String> = [
        "PresetType", "Cluster", "UUID", "SupportsAmount", "SupportsColor", "SupportsMonochrome", "SupportsHighDynamicRange",
        "SupportsNormalDynamicRange", "SupportsSceneReferred", "SupportsOutputReferred", "CameraModelRestriction",
        "Copyright", "ContactInfo", "Version", "ProcessVersion", "HasSettings", "Amount", "Baseline", "ISO",
    ]

    /// `adjustments` with the preset's settings applied (and nothing else changed). `isRaw` picks how
    /// white balance is read, as for an import.
    func applied(to adjustments: PhotoAdjustments, isRaw: Bool, cameraModel: String? = nil, iso: Double? = nil,
                 profiles: AdobeProfileLibrary = .shared) -> PhotoAdjustments {
        // ISO-adaptive presets: the settings at the photo's ISO.
        var settings = settings
        for (key, value) in Self.settings(at: iso, of: isoPoints) { settings.hash[key] = .number(value) }
        // Map the preset onto default settings: each setting it holds lands where the import puts it,
        // and a setting at its default (such as Clarity 0) maps to the default.
        var mapped = PhotoAdjustments()
        var input = LightroomDevelopMapper.Input(
            settings: settings, processVersion: settings["ProcessVersion"]?.string, whiteBalance: nil, isRaw: isRaw, seed: 1)
        input.cameraModel = cameraModel
        input.profiles = profiles
        _ = LightroomDevelopMapper.apply(input, to: &mapped)
        var result = Self.baseline(settings["Baseline"]?.string, from: adjustments)
        PresetMerge.copy(Set(settings.hash.keys).subtracting(Self.metadataKeys), from: mapped, to: &result)
        return result
    }

    /// A preset's `crs:Baseline`: "Adobe Default" and "Camera Settings" start from the defaults (the
    /// photo keeps its crop, rotation, spots, red eye and masks, which belong to it). PixelLoupe's
    /// default rendering is already the camera's own look, so Camera Settings also drops any Adobe
    /// profile; Adobe Default keeps the profile choice to the preset.
    static func baseline(_ name: String?, from adjustments: PhotoAdjustments) -> PhotoAdjustments {
        guard let name, ["Adobe Default", "Camera Settings"].contains(name) else { return adjustments }
        var reset = PhotoAdjustments()
        reset.crop = adjustments.crop
        reset.orientation = adjustments.orientation
        reset.spots = adjustments.spots
        reset.redEyes = adjustments.redEyes
        reset.masks = adjustments.masks
        return reset
    }

    /// The ISO-dependent settings at `iso`, interpolated on a log scale between the points around it
    /// (the first or last point beyond them). Empty without an ISO or points.
    static func settings(at iso: Double?, of points: [ISOPoint]) -> [String: Double] {
        guard let iso, iso > 0, !points.isEmpty else { return [:] }
        let sorted = points.filter { $0.iso > 0 }.sorted { $0.iso < $1.iso }
        guard let first = sorted.first, let last = sorted.last else { return [:] }
        if iso <= first.iso { return first.settings }
        if iso >= last.iso { return last.settings }
        guard let upper = sorted.firstIndex(where: { $0.iso >= iso }) else { return last.settings }
        let low = sorted[upper - 1], high = sorted[upper]
        let t = (log2(iso) - log2(low.iso)) / (log2(high.iso) - log2(low.iso))
        var result: [String: Double] = [:]
        for key in Set(low.settings.keys).union(high.settings.keys) {
            let a = low.settings[key] ?? high.settings[key] ?? 0, b = high.settings[key] ?? a
            result[key] = a + (b - a) * t
        }
        return result
    }
}

/// Copies, for each Lightroom setting a preset holds, the PixelLoupe settings it maps to.
nonisolated enum PresetMerge {
    typealias Copy = @Sendable (PhotoAdjustments, inout PhotoAdjustments) -> Void

    static func copy(_ keys: Set<String>, from mapped: PhotoAdjustments, to result: inout PhotoAdjustments) {
        // A setting can share its target with others (all four parametric sliders are one curve):
        // copying the target once is enough.
        var done = Set<String>()
        for key in keys {
            guard let (target, copy) = table[key], !done.contains(target) else { continue }
            done.insert(target)
            copy(mapped, &result)
        }
    }

    /// The settings a preset can change, for tests and the gap report.
    static var supportedKeys: Set<String> { Set(table.keys) }

    private static let table: [String: (target: String, copy: Copy)] = {
        var table: [String: (String, Copy)] = [:]
        func add(_ keys: [String], _ target: String, _ copy: @escaping Copy) { for key in keys { table[key] = (target, copy) } }

        // Light and Presence, slider by slider.
        add(["Exposure2012"], "exposure") { $1.light.exposure = $0.light.exposure }
        add(["Contrast2012"], "contrast") { $1.light.contrast = $0.light.contrast }
        add(["Highlights2012"], "highlights") { $1.light.highlights = $0.light.highlights }
        add(["Shadows2012"], "shadows") { $1.light.shadows = $0.light.shadows }
        add(["Whites2012"], "whites") { $1.light.whites = $0.light.whites }
        add(["Blacks2012"], "blacks") { $1.light.blackPoint = $0.light.blackPoint }
        add(["Texture"], "texture") { $1.presence.texture = $0.presence.texture }
        add(["Clarity2012"], "clarity") { $1.presence.clarity = $0.presence.clarity }
        add(["Dehaze"], "dehaze") { $1.presence.dehaze = $0.presence.dehaze }
        add(["Vibrance"], "vibrance") { $1.presence.vibrance = $0.presence.vibrance }
        add(["Saturation"], "saturation") { $1.presence.saturation = $0.presence.saturation }

        // Color mixer and B&W mix, color by color.
        for range in PhotoAdjustments.SelectiveColorRange.allCases {
            let name = range.title
            add(["HueAdjustment\(name)"], "hue-\(name)") { $1.selectiveColor[range].hue = $0.selectiveColor[range].hue }
            add(["SaturationAdjustment\(name)"], "saturation-\(name)") {
                $1.selectiveColor[range].saturation = $0.selectiveColor[range].saturation
            }
            add(["LuminanceAdjustment\(name)"], "luminance-\(name)") {
                $1.selectiveColor[range].luminance = $0.selectiveColor[range].luminance
            }
            add(["GrayMixer\(name)"], "gray-\(name)") { $1.blackAndWhite[range] = $0.blackAndWhite[range] }
        }
        add(["ConvertToGrayscale"], "grayscale") {
            $1.blackAndWhite.isEnabled = $0.blackAndWhite.isEnabled
            $1.blackAndWhite.intensity = $0.blackAndWhite.intensity
        }

        // Color grading, wheel by wheel (split toning sets the shadow and highlight wheels).
        add(["ColorGradeShadowHue", "ColorGradeShadowSat", "ColorGradeShadowLum", "SplitToningShadowHue", "SplitToningShadowSaturation"],
            "wheel-shadows") { $1.color.shadows = $0.color.shadows }
        add(["ColorGradeMidtoneHue", "ColorGradeMidtoneSat", "ColorGradeMidtoneLum"], "wheel-midtones") { $1.color.midtones = $0.color.midtones }
        add(["ColorGradeHighlightHue", "ColorGradeHighlightSat", "ColorGradeHighlightLum", "SplitToningHighlightHue",
             "SplitToningHighlightSaturation"], "wheel-highlights") { $1.color.highlights = $0.color.highlights }
        add(["ColorGradeGlobalHue", "ColorGradeGlobalSat", "ColorGradeGlobalLum"], "wheel-global") { $1.color.global = $0.color.global }
        add(["ColorGradeBlending"], "blending") { $1.color.blending = $0.color.blending }
        add(["SplitToningBalance"], "balance") { $1.color.balance = $0.color.balance }

        // Curves.
        add(["ToneCurvePV2012"], "curve-rgb") { $1.curves.rgb = $0.curves.rgb }
        add(["ToneCurvePV2012Red"], "curve-red") { $1.curves.red = $0.curves.red }
        add(["ToneCurvePV2012Green"], "curve-green") { $1.curves.green = $0.curves.green }
        add(["ToneCurvePV2012Blue"], "curve-blue") { $1.curves.blue = $0.curves.blue }
        add(["ParametricShadows", "ParametricDarks", "ParametricLights", "ParametricHighlights",
             "ParametricShadowSplit", "ParametricMidtoneSplit", "ParametricHighlightSplit"], "curve-parametric") {
            $1.curves.parametric = $0.curves.parametric
        }

        // Detail. Sharpening is one setting in Lightroom's presets (they hold all four sliders).
        add(["Sharpness", "SharpenRadius", "SharpenDetail", "SharpenEdgeMasking"], "sharpen") { $1.sharpen = $0.sharpen }
        add(["LuminanceSmoothing"], "noise-luminance") { $1.noiseReduction.amount = $0.noiseReduction.amount }
        add(["ColorNoiseReduction"], "noise-color") { $1.noiseReduction.color = $0.noiseReduction.color }
        add(["LuminanceNoiseReductionDetail"], "noise-detail") { $1.noiseReduction.detail = $0.noiseReduction.detail }

        // Effects: the vignette is built from its amount, grain likewise.
        add(["PostCropVignetteAmount", "PostCropVignetteMidpoint", "PostCropVignetteFeather", "PostCropVignetteRoundness",
             "PostCropVignetteStyle", "PostCropVignetteHighlightContrast"], "vignette") { $1.vignette = $0.vignette }
        add(["GrainAmount", "GrainSize", "GrainFrequency"], "grain") {
            $1.effects.grain = $0.effects.grain
            $1.effects.grainSize = $0.effects.grainSize
            $1.effects.grainRoughness = $0.effects.grainRoughness
            if $1.effects.grainSeed == 0 { $1.effects.grainSeed = $0.effects.grainSeed }
        }

        // Sections Lightroom's presets set as a whole.
        add(["WhiteBalance", "Temperature", "Tint", "IncrementalTemperature", "IncrementalTint"], "white-balance") {
            $1.whiteBalance = $0.whiteBalance
        }
        add(["LensProfileEnable", "LensProfileSetup", "LensProfileName", "LensProfileFilename", "LensManualDistortionAmount",
             "LensProfileDistortionScale", "LensProfileVignettingScale", "AutoLateralCA", "DefringePurpleAmount", "DefringeGreenAmount",
             "DefringePurpleHueLo", "DefringePurpleHueHi", "DefringeGreenHueLo", "DefringeGreenHueHi", "VignetteAmount",
             "VignetteMidpoint"], "lens") { $1.lens = $0.lens }
        add(["PerspectiveVertical", "PerspectiveHorizontal", "PerspectiveRotate", "PerspectiveAspect", "PerspectiveScale",
             "PerspectiveX", "PerspectiveY", "PerspectiveUpright"], "transform") { $1.transform = $0.transform }
        add(["CameraProfile", "Look"], "profile") {
            $1.profile = $0.profile
            // Adobe's B&W profiles are how its newer B&W presets turn a photo black and white.
            if $0.blackAndWhite.isEnabled {
                $1.blackAndWhite.isEnabled = true
                $1.blackAndWhite.intensity = $0.blackAndWhite.intensity
            }
        }
        add(["ShadowTint", "RedHue", "RedSaturation", "GreenHue", "GreenSaturation", "BlueHue", "BlueSaturation"], "calibration") {
            $1.calibration = $0.calibration
        }
        return table
    }()
}

/// The text a preset file carries for people: its name, group and sort name (`rdf:Alt` lists).
nonisolated enum PresetText {
    static func read(_ data: Data) -> [String: String] {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.values
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        private static let names: Set<String> = ["crs:Name", "crs:Group", "crs:SortName"]
        private var element: String?
        private var depth = 0
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            depth += 1
            // The preset's own name, not a look's (which nests deeper, inside crs:Look).
            if Self.names.contains(elementName), element == nil, depth <= 4 {
                element = elementName
                text = ""
            } else if elementName == "rdf:li" {
                text = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            depth -= 1
            if elementName == "rdf:li", let element, values[String(element.dropFirst(4))] == nil {
                values[String(element.dropFirst(4))] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if elementName == element { element = nil }
        }
    }
}

/// A preset's `crs:ISODependent` list: each `rdf:li` carries an ISO and the settings at it as attributes.
private nonisolated enum ISOPoints {
    static func read(_ data: Data) -> [DevelopPreset.ISOPoint] {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.points
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var points: [DevelopPreset.ISOPoint] = []
        private var inside = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if elementName == "crs:ISODependent" { inside = true }
            guard inside, elementName == "rdf:li" else { return }
            var settings: [String: Double] = [:]
            var iso: Double?
            for (name, value) in attributes where name.hasPrefix("crs:") {
                let key = String(name.dropFirst(4))
                guard let number = Double(value.hasPrefix("+") ? String(value.dropFirst()) : value) else { continue }
                if key == "ISO" { iso = number } else { settings[key] = number }
            }
            if let iso { points.append(.init(iso: iso, settings: settings)) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if elementName == "crs:ISODependent" { inside = false }
        }
    }
}
