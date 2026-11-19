import CoreGraphics
import Foundation

/// Rendering a DNG camera profile on Apple's RAW engine (RAW-126).
///
/// The DNG specification renders a profile from the camera's own colors: its matrices take them to linear ProPhoto
/// RGB, then come the hue/saturation map for the photo's light, the look table and the tone curve. Apple's engine
/// takes no matrix, so PixelLoupe starts from the engine's own linear colors and applies the profile's look: its look
/// table and tone curve, baked into one color cube that the engine runs in its linear stage
/// (`CIRAWFilter.linearSpaceFilter`). The matrices are ignored, and so is the hue/saturation map that refines them
/// (``AdobeProfileLibrary/appliesHueSaturationMaps``), so the match to Lightroom is approximate.
nonisolated extension DNGCameraProfile {
    /// What the library, the catalog and a photo's settings know the profile by: its camera and name, so importing a
    /// newer copy of a profile replaces it.
    var id: String { Self.id(name: name, cameraModel: cameraModel) }

    static let idPrefix = "dcp:"

    static func id(name: String, cameraModel: String) -> String {
        idPrefix + AdobeProfile.normalized(cameraModel) + ":" + name.lowercased()
    }

    /// Whether the profile was made for this camera. Adobe names a camera with its maker ("Sony ILCE-7CM2",
    /// "Nikon Z 8"); EXIF has the maker apart from the model for some ("SONY", "ILCE-7CM2") and in it for others
    /// ("NIKON CORPORATION", "NIKON Z 8").
    func isFor(cameraMake make: String?, model: String?) -> Bool {
        guard let model, !model.isEmpty else { return false }
        if AdobeProfile.isCamera(cameraModel, model) { return true }
        let firstWord = make?.split(separator: " ").first.map(String.init) ?? ""
        return AdobeProfile.normalized(cameraModel) == AdobeProfile.normalized(firstWord) + AdobeProfile.normalized(model)
    }

    /// Whether the profile has its own tone curve. One without leaves the tone to the RAW engine.
    var hasToneCurve: Bool { toneCurve != nil }

    // MARK: - Light

    /// The color temperature of an EXIF `LightSource`, as the DNG SDK takes them; 0 for the ones without.
    static func temperature(ofIlluminant illuminant: Int) -> Double {
        switch illuminant {
        case 3, 17: 2850            // tungsten, Standard Light A
        case 24: 3200               // ISO studio tungsten
        case 23: 5000               // D50
        case 1, 4, 9, 18, 20: 5500  // daylight, flash, fine weather, Standard Light B, D55
        case 10, 19, 21: 6500       // cloudy, Standard Light C, D65
        case 11, 22: 7500           // shade, D75
        case 12: 6400               // daylight fluorescent
        case 13: 5050               // day white fluorescent
        case 2, 14: 4150            // fluorescent, cool white fluorescent
        case 15: 3525               // white fluorescent
        case 16: 2925               // warm white fluorescent
        default: 0
        }
    }

    /// How much of the first calibration a photo lit at `temperature` (kelvins) takes, 0…1: all of the nearer one
    /// outside the two lights, and between them by the inverse of the temperature, as the specification says.
    func firstCalibrationWeight(temperature: Double) -> Double {
        guard calibrations.count == 2 else { return 1 }
        let first = Self.temperature(ofIlluminant: calibrations[0].illuminant)
        let second = Self.temperature(ofIlluminant: calibrations[1].illuminant)
        guard first > 0, second > 0, first != second, temperature > 0 else { return 1 }
        let weight = (1 / temperature - 1 / second) / (1 / first - 1 / second)
        return weight.clamped(to: 0...1)
    }

    /// The hue/saturation map for a photo that takes `weight` of the first calibration.
    func hueSaturationMap(firstCalibrationWeight weight: Double) -> AdobeProfile.LookTable? {
        guard let first = calibrations.first?.hueSaturationMap else { return calibrations.last?.hueSaturationMap }
        guard calibrations.count == 2, let second = calibrations[1].hueSaturationMap, second.entries.count == first.entries.count,
              weight < 1 else { return first }
        if weight <= 0 { return second }
        let w = Float(weight)
        return AdobeProfile.LookTable(
            hueDivisions: first.hueDivisions, saturationDivisions: first.saturationDivisions, valueDivisions: first.valueDivisions,
            valueIsSRGB: first.valueIsSRGB, entries: zip(first.entries, second.entries).map { $0 * w + $1 * (1 - w) }
        )
    }

    // MARK: - The cube

    /// Samples per side of the cube. More than a look table alone gets, since the tone curve is in it too and is
    /// steep in the shadows.
    static let cubeDimension = 64

    /// The profile baked into a cube over ROMM (ProPhoto) RGB, gamma 1.8, for the RAW engine's linear stage: the
    /// hue/saturation map (when `usesCalibration`: it corrects the one camera the profile is for), the look table at
    /// `amount` (1 is 100%), then the tone curve.
    ///
    /// `firstCalibrationWeight` picks the hue/saturation map; see ``firstCalibrationWeight(temperature:)``.
    func cube(amount: Double, firstCalibrationWeight weight: Double = 1, usesCalibration: Bool = true,
              dimension n: Int = DNGCameraProfile.cubeDimension) -> AdobeProfile.Cube {
        let map = usesCalibration ? hueSaturationMap(firstCalibrationWeight: weight) : nil
        let look = amount != 0 ? lookTable : nil
        let curve = toneCurve.map(ToneCurve.init)
        let k = Float(amount)
        // The cube's axis: ROMM's encoding, to linear and back.
        let linear = (0..<n).map { pow(Float($0) / Float(n - 1), 1.8) }
        var values = [Float](repeating: 1, count: n * n * n * 4)
        values.withUnsafeMutableBufferPointer { buffer in
            // Each worker writes its own slice of the cube.
            nonisolated(unsafe) let buffer = buffer
            DispatchQueue.concurrentPerform(iterations: n) { blue in
                for green in 0..<n {
                    for red in 0..<n {
                        var color = SIMD3(linear[red], linear[green], linear[blue])
                        if let map { color = map.apply(color, amount: 1) }
                        if let look { color = look.apply(color, amount: k) }
                        if let curve { color = curve.apply(color) }
                        let target = ((blue * n + green) * n + red) * 4
                        buffer[target] = pow(max(color.x, 0), 1 / 1.8)
                        buffer[target + 1] = pow(max(color.y, 0), 1 / 1.8)
                        buffer[target + 2] = pow(max(color.z, 0), 1 / 1.8)
                    }
                }
            }
        }
        return .init(dimension: n, data: values.withUnsafeBufferPointer { Data(buffer: $0) }, colorSpaceName: CGColorSpace.rommrgb as String)
    }

    // MARK: - Tone

    /// A tone curve through a profile's points: the smooth curve the DNG SDK draws through them (a cubic spline with
    /// no curvature at its ends), applied to a color so its hue stays (the SDK's `RefBaselineRGBTone`).
    struct ToneCurve: Sendable {
        private let x: [Double], y: [Double]
        /// The curve's slope at each point.
        private let slopes: [Double]

        init(_ points: [TonePoint]) {
            let x = points.map { Double($0.input) }, y = points.map { Double($0.output) }
            self.x = x
            self.y = y
            let count = x.count
            guard count >= 2 else { slopes = [Double](repeating: 1, count: count); return }
            // First the slope at each point as the average of the slopes either side, weighted by the other side's
            // length, with the ends carried on from their neighbors.
            var s = [Double](repeating: 0, count: count)
            var a = x[1] - x[0], b = (y[1] - y[0]) / a
            s[0] = b
            for j in 2..<max(count, 2) {
                let c = x[j] - x[j - 1], d = (y[j] - y[j - 1]) / c
                s[j - 1] = (b * c + d * a) / (a + c)
                a = c
                b = d
            }
            s[count - 1] = 2 * b - s[count - 2]
            s[0] = 2 * s[0] - s[1]
            // Then the slopes that also make the curvature continuous: a tridiagonal system, solved in place.
            if count > 2 {
                var e = [Double](repeating: 0, count: count), f = e, g = e
                f[0] = 0.5
                e[count - 1] = 0.5
                g[0] = 0.75 * (s[0] + s[1])
                g[count - 1] = 0.75 * (s[count - 2] + s[count - 1])
                for j in 1..<(count - 1) {
                    let span = (x[j + 1] - x[j - 1]) * 2
                    e[j] = (x[j + 1] - x[j]) / span
                    f[j] = (x[j] - x[j - 1]) / span
                    g[j] = 1.5 * s[j]
                }
                for j in 1..<count {
                    let pivot = 1 - f[j - 1] * e[j]
                    if j != count - 1 { f[j] /= pivot }
                    g[j] = (g[j] - g[j - 1] * e[j]) / pivot
                }
                for j in stride(from: count - 2, through: 0, by: -1) { g[j] -= f[j] * g[j + 1] }
                s = g
            }
            slopes = s
        }

        /// The curve at `input`, 0…1.
        func value(at input: Double) -> Double {
            guard x.count >= 2 else { return input }
            if input <= x[0] { return y[0] }
            if input >= x[x.count - 1] { return y[y.count - 1] }
            // The first point past the input.
            var low = 1, high = x.count - 1
            while low < high {
                let middle = (low + high) / 2
                if x[middle] < input { low = middle + 1 } else { high = middle }
            }
            let j = low
            let width = x[j] - x[j - 1]
            let b = (input - x[j - 1]) / width, c = (x[j] - input) / width
            return (y[j - 1] * (2 - c + b) + slopes[j - 1] * width * b) * (c * c)
                + (y[j] * (2 - b + c) - slopes[j] * width * c) * (b * b)
        }

        /// The curve applied to a linear color: its largest and smallest channels go through the curve and the one
        /// between keeps its place between them, which keeps the hue.
        func apply(_ color: SIMD3<Float>) -> SIMD3<Float> {
            let red = Double(min(max(color.x, 0), 1)), green = Double(min(max(color.y, 0), 1)), blue = Double(min(max(color.z, 0), 1))
            let high = max(red, green, blue), low = min(red, green, blue)
            let newHigh = value(at: high), newLow = value(at: low)
            guard high > low else { return SIMD3(repeating: Float(newHigh)) }
            let scale = (newHigh - newLow) / (high - low)
            return SIMD3(Float(newLow + (red - low) * scale), Float(newLow + (green - low) * scale), Float(newLow + (blue - low) * scale))
        }
    }
}
