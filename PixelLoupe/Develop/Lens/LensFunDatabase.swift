import Foundation

/// The LensFun lens database (https://github.com/lensfun/lensfun, CC BY-SA 3.0), bundled as its
/// original XML files. Parsed on first use, off the main thread; only the Lens Corrections panel
/// needs it, since each photo stores its resolved profile.
nonisolated final class LensFunDatabase: Sendable {
    struct Camera: Sendable, Equatable {
        var maker: String
        /// The EXIF model name first, then localized names.
        var models: [String]
        var mount: String
        var cropFactor: Double
    }

    struct Lens: Sendable, Equatable {
        var maker: String
        /// The primary name first, then localized names.
        var models: [String]
        var mounts: [String]
        /// The crop factor and aspect ratio of the camera the lens was calibrated on.
        var cropFactor: Double
        var aspectRatio: Double
        var distortion: [Distortion] = []
        var tca: [TCA] = []
        var vignetting: [Vignetting] = []

        var model: String { models.first ?? "" }
        var hasCorrections: Bool { !distortion.isEmpty || !tca.isEmpty || !vignetting.isEmpty }

        /// How the panel's Profile menu names this calibration.
        var variantTitle: String {
            let crop = cropFactor.formatted(.number.precision(.fractionLength(0...2)))
            return "LensFun (crop factor \(crop))"
        }
    }

    struct Distortion: Sendable, Equatable {
        var focal: Double
        /// (a, b, c, d, e) of rd = ru · (e·ru⁴ + a·ru³ + b·ru² + c·ru + d).
        var coefficients: [Double]
    }

    struct TCA: Sendable, Equatable {
        var focal: Double
        /// (b, c, v) for red and blue of rd = ru · (b·ru² + c·ru + v).
        var red: [Double]
        var blue: [Double]
    }

    struct Vignetting: Sendable, Equatable {
        var focal: Double
        var aperture: Double
        var distance: Double
        var k: [Double]
    }

    let cameras: [Camera]
    let lenses: [Lens]
    /// Mounts whose lenses also fit each mount (adapters), by mount name.
    let compatibleMounts: [String: [String]]

    init(cameras: [Camera], lenses: [Lens], compatibleMounts: [String: [String]]) {
        self.cameras = cameras
        self.lenses = lenses
        self.compatibleMounts = compatibleMounts
    }

    /// The bundled database. The first use parses about 5 MB of XML, so call it off the main thread.
    static let shared: LensFunDatabase = {
        let bundle = Bundle(for: BundleToken.self)
        let urls = (bundle.urls(forResourcesWithExtension: "xml", subdirectory: nil) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return load(urls.compactMap { try? Data(contentsOf: $0) })
    }()

    private final class BundleToken {}

    static func load(_ files: [Data]) -> LensFunDatabase {
        var cameras: [Camera] = [], lenses: [Lens] = [], mounts: [String: [String]] = [:]
        for data in files {
            let parser = Parser()
            let xml = XMLParser(data: data)
            xml.delegate = parser
            guard xml.parse(), parser.isLensDatabase else { continue }
            cameras += parser.cameras
            lenses += parser.lenses
            mounts.merge(parser.mounts) { $0 + $1 }
        }
        return LensFunDatabase(cameras: cameras, lenses: lenses, compatibleMounts: mounts)
    }

    // MARK: - Matching

    /// The camera with this EXIF make and model.
    func camera(make: String?, model: String?) -> Camera? {
        guard let make, let model else { return nil }
        let maker = Self.normalizedMaker(make), name = Self.normalized(model)
        return cameras.first { Self.normalizedMaker($0.maker) == maker && $0.models.contains { Self.normalized($0) == name } }
            ?? cameras.first { Self.sameMaker($0.maker, make) && $0.models.contains { Self.normalized($0) == name } }
    }

    /// Lenses that fit the camera (all of them when the camera isn't known).
    func lenses(for camera: Camera?) -> [Lens] {
        guard let camera else { return lenses.filter(\.hasCorrections) }
        let mounts = Set([camera.mount] + (compatibleMounts[camera.mount] ?? []))
        return lenses.filter { $0.hasCorrections && !mounts.isDisjoint(with: $0.mounts) }
    }

    /// The profile matching the photo's camera and lens (the best calibration of the best-named
    /// lens), or nil when nothing matches well enough.
    func match(make: String?, model: String?, lens lensModel: String?) -> Lens? {
        let camera = camera(make: make, model: model)
        let candidates = lenses(for: camera)
        if let lensModel, !lensModel.isEmpty {
            let wanted = Self.tokens(lensModel)
            var best: (lens: Lens, score: Double)?
            for lens in candidates {
                let score = lens.models.map { Self.similarity(Self.tokens($0), wanted) }.max() ?? 0
                // Prefer the lens maker named on the camera, then the calibration closest to the camera.
                let bonus = (Self.sameMaker(lens.maker, make ?? "") ? 0.02 : 0)
                    - abs((camera?.cropFactor ?? lens.cropFactor) - lens.cropFactor) * 0.001
                    - ((camera?.cropFactor ?? lens.cropFactor) < lens.cropFactor ? 0.005 : 0)
                if score >= 0.75, score + bonus > (best?.score ?? 0) { best = (lens, score + bonus) }
            }
            if let best { return best.lens }
        }
        // Fixed-lens cameras: the one lens made for the camera's own mount.
        if let camera {
            let own = candidates.filter { $0.mounts.contains(camera.mount) }
            if Set(own.map(\.model)).count == 1 { return own.first }
        }
        return nil
    }

    /// Lowercased words of a name, with "f/2.8", "F2.8" and "2.80" all becoming "2.8".
    static func tokens(_ name: String) -> [String] {
        var text = name.lowercased().replacingOccurrences(of: "f/", with: " ")
        // "24-70mm" → "24-70 mm"
        text = text.replacingOccurrences(of: #"(\d)mm"#, with: "$1 mm", options: .regularExpression)
        let words = text.split { !($0.isLetter || $0.isNumber || $0 == ".") }.map(String.init)
        return words.compactMap { word -> String? in
            var word = word.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            // "f2.8" → "2.8"
            if word.first == "f", word.dropFirst().first?.isNumber == true { word.removeFirst() }
            if let number = Double(word) {
                // "2.80" → "2.8", "50.0" → "50"
                var formatted = String(format: "%.2f", number)
                while formatted.hasSuffix("0") { formatted.removeLast() }
                if formatted.hasSuffix(".") { formatted.removeLast() }
                return formatted
            }
            return word.isEmpty ? nil : word
        }
    }

    /// Words that tell versions of a lens apart ("FE 70-200mm F2.8 GM OSS" and "… OSS II" are
    /// different lenses).
    static let versionWords: Set<String> = ["ii", "iii", "iv", "v", "vi", "mk", "mkii", "mkiii", "mkiv", "mk2", "mk3", "mk4"]

    /// How alike two names are (0…1), by shared words. Numbers (focal lengths, apertures) and
    /// version words must agree.
    static func similarity(_ a: [String], _ b: [String]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let numbersA = Set(a.filter { Double($0) != nil }), numbersB = Set(b.filter { Double($0) != nil })
        guard numbersA == numbersB || (numbersA.isSubset(of: numbersB) && !numbersA.isEmpty) else { return 0 }
        guard Set(a).intersection(versionWords) == Set(b).intersection(versionWords) else { return 0 }
        let shared = Set(a).intersection(b).count
        return 2 * Double(shared) / Double(Set(a).count + Set(b).count)
    }

    static func normalized(_ name: String) -> String {
        name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Maker names as cameras write them ("NIKON CORPORATION", "OLYMPUS IMAGING CORP.") reduced
    /// to their brand.
    static func normalizedMaker(_ maker: String) -> String {
        let noise: Set<String> = ["corporation", "corp", "co", "ltd", "inc", "imaging", "optical", "company", "camera", "electric", "industrial", "gmbh", "ag", "the"]
        let words = maker.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { !noise.contains($0) }
        return words.joined(separator: " ")
    }

    static func sameMaker(_ a: String, _ b: String) -> Bool {
        let a = normalizedMaker(a), b = normalizedMaker(b)
        return a == b || a.split(separator: " ").first == b.split(separator: " ").first
    }

    // MARK: - Resolving

    /// The lens's corrections for one photo: interpolated at its focal length, aperture and focus
    /// distance, in the photo's coordinates (`cropFactor` of the camera that took it).
    static func profile(for lens: Lens, cropFactor: Double?, focalLength: Double?, aperture: Double?, distance: Double?) -> PhotoAdjustments.LensProfile {
        let crop = cropFactor ?? lens.cropFactor
        let focal = focalLength ?? lens.distortion.first?.focal ?? lens.vignetting.first?.focal ?? 50
        var profile = PhotoAdjustments.LensProfile(maker: lens.maker, model: lens.model, variant: lens.variantTitle)
        // LensFun's distortion and TCA models measure the radius in half the short side of the
        // calibration camera's frame; vignetting in half its diagonal.
        profile.distortionUnit = crop / (lens.cropFactor * (1 + lens.aspectRatio * lens.aspectRatio).squareRoot())
        profile.vignettingUnit = crop / lens.cropFactor

        if !lens.distortion.isEmpty {
            profile.distortion = interpolate(lens.distortion.map { ($0.focal, $0.coefficients) }, at: focal)
        }
        if !lens.tca.isEmpty {
            let values = interpolate(lens.tca.map { ($0.focal, $0.red + $0.blue) }, at: focal)
            profile.tcaRed = Array(values[0..<3])
            profile.tcaBlue = Array(values[3..<6])
        }
        if !lens.vignetting.isEmpty {
            profile.vignetting = vignetting(lens.vignetting, focal: focal, aperture: aperture, distance: distance)
        }
        return profile
    }

    /// Linear interpolation of coefficient lists between the nearest calibrated focal lengths
    /// (the nearest one outside the calibrated range).
    static func interpolate(_ entries: [(focal: Double, values: [Double])], at focal: Double) -> [Double] {
        let sorted = entries.sorted { $0.focal < $1.focal }
        guard let first = sorted.first, let last = sorted.last else { return [] }
        if focal <= first.focal { return first.values }
        if focal >= last.focal { return last.values }
        let upper = sorted.firstIndex { $0.focal >= focal }!
        let a = sorted[upper - 1], b = sorted[upper]
        let t = b.focal == a.focal ? 0 : (focal - a.focal) / (b.focal - a.focal)
        return zip(a.values, b.values).map { $0 + ($1 - $0) * t }
    }

    /// Vignetting at the focus distance nearest the photo's (the farthest when unknown), then
    /// interpolated across aperture (in stops) and focal length.
    static func vignetting(_ entries: [Vignetting], focal: Double, aperture: Double?, distance: Double?) -> [Double] {
        let distances = Set(entries.map(\.distance))
        let chosenDistance = distance.flatMap { d in distances.min { abs(log($0 / d)) < abs(log($1 / d)) } } ?? distances.max() ?? 0
        let atDistance = entries.filter { $0.distance == chosenDistance }
        let focals = Array(Set(atDistance.map(\.focal))).sorted()
        func atFocal(_ f: Double) -> [Double] {
            let rows = atDistance.filter { $0.focal == f }
            let stops = rows.map { (focal: log2($0.aperture), values: $0.k) }
            let wanted = aperture.map(log2) ?? stops.map(\.focal).min() ?? 0
            return interpolate(stops, at: wanted)
        }
        return interpolate(focals.map { ($0, atFocal($0)) }, at: focal)
    }

    // MARK: - XML

    private final class Parser: NSObject, XMLParserDelegate {
        var cameras: [Camera] = []
        var lenses: [Lens] = []
        var mounts: [String: [String]] = [:]
        var isLensDatabase = false

        private var text = ""
        private var language: String?
        private var camera: Camera?
        private var lens: Lens?
        private var mountName: String?
        private var mountCompat: [String] = []

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            language = attributes["lang"]
            switch element {
            case "lensdatabase": isLensDatabase = true
            case "camera": camera = Camera(maker: "", models: [], mount: "", cropFactor: 1)
            case "lens": lens = Lens(maker: "", models: [], mounts: [], cropFactor: 1, aspectRatio: 1.5)
            case "mount" where camera == nil && lens == nil: mountName = nil; mountCompat = []
            case "distortion": addDistortion(attributes)
            case "tca": addTCA(attributes)
            case "vignetting": addVignetting(attributes)
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { text = "" }
            if camera != nil {
                switch element {
                case "maker" where language == nil: camera?.maker = value
                case "model" where language == nil: camera?.models.insert(value, at: 0)
                case "model": camera?.models.append(value)
                case "mount": camera?.mount = value
                case "cropfactor": camera?.cropFactor = Double(value) ?? 1
                case "camera":
                    if let camera, !camera.models.isEmpty { cameras.append(camera) }
                    camera = nil
                default: break
                }
            } else if lens != nil {
                switch element {
                case "maker" where language == nil: lens?.maker = value
                case "model" where language == nil: lens?.models.insert(value, at: 0)
                case "model": lens?.models.append(value)
                case "mount": lens?.mounts.append(value)
                case "cropfactor": lens?.cropFactor = Double(value) ?? 1
                case "aspect-ratio": lens?.aspectRatio = Self.ratio(value) ?? 1.5
                case "lens":
                    if let lens, !lens.models.isEmpty { lenses.append(lens) }
                    lens = nil
                default: break
                }
            } else {
                switch element {
                case "name": mountName = value
                case "compat": mountCompat.append(value)
                case "mount":
                    if let mountName { mounts[mountName, default: []] += mountCompat }
                    mountName = nil
                default: break
                }
            }
        }

        /// "1.5", or "3:2".
        static func ratio(_ value: String) -> Double? {
            let parts = value.split(separator: ":").compactMap { Double($0) }
            if parts.count == 2, parts[1] > 0 { return parts[0] / parts[1] }
            return Double(value)
        }

        private func number(_ attributes: [String: String], _ key: String, _ fallback: Double) -> Double {
            attributes[key].flatMap(Double.init) ?? fallback
        }

        private func addDistortion(_ attributes: [String: String]) {
            guard let focal = attributes["focal"].flatMap(Double.init) else { return }
            let coefficients: [Double]
            switch attributes["model"] {
            case "ptlens":
                let a = number(attributes, "a", 0), b = number(attributes, "b", 0), c = number(attributes, "c", 0)
                coefficients = [a, b, c, 1 - a - b - c, 0]
            case "poly3":
                let k1 = number(attributes, "k1", 0)
                coefficients = [0, k1, 0, 1 - k1, 0]
            case "poly5":
                coefficients = [0, number(attributes, "k1", 0), 0, 1, number(attributes, "k2", 0)]
            default:
                return
            }
            lens?.distortion.append(Distortion(focal: focal, coefficients: coefficients))
        }

        private func addTCA(_ attributes: [String: String]) {
            guard let focal = attributes["focal"].flatMap(Double.init) else { return }
            switch attributes["model"] {
            case "linear":
                lens?.tca.append(TCA(focal: focal, red: [0, 0, number(attributes, "kr", 1)], blue: [0, 0, number(attributes, "kb", 1)]))
            case "poly3":
                lens?.tca.append(TCA(
                    focal: focal,
                    red: [number(attributes, "br", 0), number(attributes, "cr", 0), number(attributes, "vr", 1)],
                    blue: [number(attributes, "bb", 0), number(attributes, "cb", 0), number(attributes, "vb", 1)]
                ))
            default:
                break
            }
        }

        private func addVignetting(_ attributes: [String: String]) {
            guard attributes["model"] == "pa", let focal = attributes["focal"].flatMap(Double.init),
                  let aperture = attributes["aperture"].flatMap(Double.init) else { return }
            lens?.vignetting.append(Vignetting(
                focal: focal, aperture: aperture, distance: number(attributes, "distance", 1000),
                k: [number(attributes, "k1", 0), number(attributes, "k2", 0), number(attributes, "k3", 0)]
            ))
        }
    }
}
