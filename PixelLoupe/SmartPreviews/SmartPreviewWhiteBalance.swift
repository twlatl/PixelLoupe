import CoreImage
import Foundation

/// The exposure that keeps a camera RAW file's Smart Preview as bright as its original when Temperature and Tint move
/// away from As Shot (RAW-121).
///
/// On a Smart Preview the RAW engine works white balance out with one Rec. 2020 matrix, where the original has the
/// camera's own; the difference is mostly brightness (a daylight photo set to 3000 K comes out about 1 EV too bright).
/// The table holds the Smart Preview's brightness error, in stops, at 8 temperatures × 3 tints; the correction at
/// (T, tint) is the error there less the error at As Shot, added to `CIRAWFilter.exposure`. The error depends on the
/// camera more than on the photo, so one table, measured on the first Smart Preview of a camera model, serves the
/// model (see the RAW-85 white-balance spike).
nonisolated struct SmartPreviewWhiteBalance: Codable, Sendable, Equatable {
    static let temperatures: [Double] = [2500, 3000, 3500, 4000, 5000, 6500, 8500, 12000]
    static let tints: [Double] = [-30, 0, 30]

    /// Stops, by temperature, then by tint.
    var errors: [[Double]]

    /// The exposure to add at `temperature` and `tint` on a photo shot at `asShot`.
    ///
    /// Cooler than As Shot the Smart Preview stays close to right for a while, and the table overshoots there, so the
    /// temperature's part fades in between 40 and 90 mired cooler. On five Sony frames that made 7500 K cost ΔE00
    /// 0.03–0.14 against no correction (the whole correction cost 0.3–0.9) and kept nearly all of the gain at 10000 K.
    func exposureCorrection(temperature: Double, tint: Double, asShot: (temperature: Double, tint: Double)) -> Double {
        let temperaturePart = error(temperature: temperature, tint: tint) - error(temperature: asShot.temperature, tint: tint)
        let tintPart = error(temperature: asShot.temperature, tint: tint) - error(temperature: asShot.temperature, tint: asShot.tint)
        let cooler = 1e6 / max(asShot.temperature, 1) - 1e6 / max(temperature, 1)
        let weight = cooler <= 0 ? 1 : min(max((cooler - 40) / 50, 0), 1)
        return temperaturePart * weight + tintPart
    }

    /// Bilinear in mired (which white balance is close to even in) and tint, clamped to the table.
    func error(temperature: Double, tint: Double) -> Double {
        let mireds = Self.temperatures.map { 1e6 / $0 }   // decreasing
        let x = min(max(1e6 / max(temperature, 1), mireds.last!), mireds.first!)
        var i = 0
        while i < mireds.count - 2 && x < mireds[i + 1] { i += 1 }
        let fx = (mireds[i] - x) / (mireds[i] - mireds[i + 1])
        let tints = Self.tints
        let y = min(max(tint, tints.first!), tints.last!)
        var j = 0
        while j < tints.count - 2 && y > tints[j + 1] { j += 1 }
        let fy = (y - tints[j]) / (tints[j + 1] - tints[j])
        let a = errors[i][j] * (1 - fy) + errors[i][j + 1] * fy
        let b = errors[i + 1][j] * (1 - fy) + errors[i + 1][j + 1] * fy
        return a * (1 - fx) + b * fx
    }

    // MARK: - Measuring

    enum MeasureError: Error {
        case unreadable
    }

    /// The scale both files are decoded at: about 500 px for a 61 MP original, plenty for an average.
    static let measuringScale: Float = 0.05

    /// Measures the table from `original` and its Smart Preview `smartPreview`, written at `smartPreviewScale`. Takes a
    /// few seconds (the RAW engine decodes the original again for each white balance): call it off the main thread.
    ///
    /// At each point, the original's change from D65 is fitted as a 3 × 3 matrix and applied to the Smart Preview's
    /// own pixels at D65; the error is the luminance gain from what the engine makes of the Smart Preview at that
    /// white balance to that.
    static func measure(original: URL, smartPreview: URL, smartPreviewScale: Double) throws -> SmartPreviewWhiteBalance {
        guard let calibration = CIRAWFilter(imageURL: original), let proxy = CIRAWFilter(imageURL: smartPreview)
        else { throw MeasureError.unreadable }
        for filter in [calibration, proxy] {
            // The engine's linear output, without its look.
            filter.exposure = 0
            filter.baselineExposure = 0
            filter.boostAmount = 0
            filter.shadowBias = 0
            filter.localToneMapAmount = 0
            filter.isGamutMappingEnabled = false
            if filter.isSharpnessSupported { filter.sharpnessAmount = 0 }
            if filter.isDetailSupported { filter.detailAmount = 0 }
        }
        calibration.scaleFactor = measuringScale
        proxy.scaleFactor = min(1, measuringScale / Float(max(smartPreviewScale, 0.001)))

        let d65 = CGPoint(x: 0.3127, y: 0.3290)
        calibration.neutralChromaticity = d65
        proxy.neutralChromaticity = d65
        guard let originalAtD65 = render(calibration), let proxyAtD65 = render(proxy) else { throw MeasureError.unreadable }
        var errors: [[Double]] = []
        for temperature in temperatures {
            var row: [Double] = []
            for tint in tints {
                calibration.neutralTemperature = Float(temperature)
                calibration.neutralTint = Float(tint)
                proxy.neutralTemperature = Float(temperature)
                proxy.neutralTint = Float(tint)
                guard let originalHere = render(calibration), let proxyHere = render(proxy),
                      let change = fit(originalAtD65, originalHere) else { throw MeasureError.unreadable }
                let gain = luminanceGain(from: proxyHere, to: proxyAtD65.applying(change))
                row.append(gain > 0 ? log2(gain) : 0)
            }
            errors.append(row)
        }
        return SmartPreviewWhiteBalance(errors: errors)
    }

    private static let linearRec2020 = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    private static let context = CIContext(options: [.workingColorSpace: linearRec2020, .cacheIntermediates: false])

    /// Pixels as linear Rec. 2020 RGB.
    private struct Pixels {
        var values: [SIMD3<Double>]

        func applying(_ matrix: [SIMD3<Double>]) -> Pixels {
            Pixels(values: values.map { SIMD3(($0 * matrix[0]).sum(), ($0 * matrix[1]).sum(), ($0 * matrix[2]).sum()) })
        }
    }

    private static func render(_ filter: CIRAWFilter) -> Pixels? {
        guard let image = filter.outputImage else { return nil }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }
        var rgba = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &rgba, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: linearRec2020)
        return Pixels(values: stride(from: 0, to: rgba.count, by: 4).map {
            SIMD3(Double(rgba[$0]), Double(rgba[$0 + 1]), Double(rgba[$0 + 2]))
        })
    }

    /// The least-squares 3 × 3 matrix (rows) taking `x` to `y`, over pixels that aren't near black or clipped.
    private static func fit(_ x: Pixels, _ y: Pixels) -> [SIMD3<Double>]? {
        guard x.values.count == y.values.count else { return nil }
        let brightest = x.values.reduce(0) { max($0, $1.max()) }
        // XᵀX and XᵀY, accumulated by rows.
        var xx = [SIMD3<Double>](repeating: .zero, count: 3), xy = [SIMD3<Double>](repeating: .zero, count: 3)
        for (a, b) in zip(x.values, y.values) where a.max() <= brightest * 0.8 && a.min() > 1e-5 && b.min() > 1e-5 {
            for r in 0..<3 {
                xx[r] += a * a[r]
                xy[r] += b * a[r]
            }
        }
        guard let inverse = invert(xx) else { return nil }
        // M = (XᵀX)⁻¹ XᵀY, so that y ≈ Mᵀ x; return Mᵀ's rows.
        let m = (0..<3).map { r in inverse[r][0] * xy[0] + inverse[r][1] * xy[1] + inverse[r][2] * xy[2] }
        return (0..<3).map { c in SIMD3(m[0][c], m[1][c], m[2][c]) }
    }

    private static func invert(_ m: [SIMD3<Double>]) -> [SIMD3<Double>]? {
        let (a, b, c) = (m[0][0], m[0][1], m[0][2]), (d, e, f) = (m[1][0], m[1][1], m[1][2]), (g, h, i) = (m[2][0], m[2][1], m[2][2])
        let determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard abs(determinant) > 1e-12 else { return nil }
        return [
            SIMD3(e * i - f * h, c * h - b * i, b * f - c * e) / determinant,
            SIMD3(f * g - d * i, a * i - c * g, c * d - a * f) / determinant,
            SIMD3(d * h - e * g, b * g - a * h, a * e - b * d) / determinant,
        ]
    }

    /// The least-squares gain on luminance taking `x` to `y`.
    private static func luminanceGain(from x: Pixels, to y: Pixels) -> Double {
        let weights = SIMD3<Double>(0.2627, 0.6780, 0.0593)
        var products = 0.0, squares = 0.0
        for (a, b) in zip(x.values, y.values) {
            let p = (a * weights).sum(), q = (b * weights).sum()
            guard p > 1e-5, q > 1e-5 else { continue }
            products += p * q
            squares += p * p
        }
        return squares > 0 ? products / squares : 1
    }

    // MARK: - Per camera model

    /// The camera model a table is kept under, for originals that get one: camera RAW files (not DNGs that are
    /// already linear, such as PixelLoupe's own merges, whose Smart Previews match them without it).
    static func cameraModel(of original: URL) -> String? {
        guard SmartPreviewWriter.recipe(for: original) == .linearDNG else { return nil }
        if let file = TIFFFile(contentsOf: original), let main = file.mainImage, let photometric = main[262],
           file.integers(photometric).first == 34892 { return nil }
        guard let metadata = ImageMetadata.read(from: original) else { return nil }
        return [metadata.cameraMake, metadata.cameraModel].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ").nonEmpty
    }

    /// Where the tables are kept: a folder in the catalog's Smart Previews.
    static func directory(in smartPreviews: URL) -> URL {
        smartPreviews.appending(path: "White Balance", directoryHint: .isDirectory)
    }

    private static func url(for cameraModel: String, in directory: URL) -> URL {
        let name = cameraModel.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return directory.appending(path: "\(name).json")
    }

    static func load(cameraModel: String, in directory: URL) -> SmartPreviewWhiteBalance? {
        guard let data = try? Data(contentsOf: url(for: cameraModel, in: directory)),
              let table = try? JSONDecoder().decode(SmartPreviewWhiteBalance.self, from: data),
              table.errors.count == temperatures.count, table.errors.allSatisfy({ $0.count == tints.count }) else { return nil }
        return table
    }

    func save(cameraModel: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url(for: cameraModel, in: directory), options: .atomic)
    }
}
