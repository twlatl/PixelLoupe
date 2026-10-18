import Foundation

/// How Lightroom's slider values become PixelLoupe's, in one place.
///
/// Each curve starts linear. They are tuned against Lightroom renders (RAW-47 onward), so a change
/// to a mapping is a change to this file and nothing else.
nonisolated enum LightroomScales {
    /// `Exposure2012`, −5…+5 EV, is PixelLoupe's exposure in stops.
    static func exposure(_ lightroom: Double) -> Double {
        round2(lightroom.clamped(to: -5...5))
    }

    /// Slider values that run −100…+100 in Lightroom and −1…+1 here: contrast, highlights, shadows,
    /// whites, texture, clarity, dehaze, vibrance and saturation. Linear until tuned.
    static func percent(_ lightroom: Double) -> Double {
        round3(lightroom.clamped(to: -100...100) / 100)
    }

    /// `Blacks2012`: positive lightens the blacks in Lightroom; PixelLoupe's Black Point is a levels
    /// control where positive crushes them.
    static func blackPoint(fromBlacks lightroom: Double) -> Double {
        round3(-lightroom.clamped(to: -100...100) / 100)
    }

    /// A hue angle in degrees (0…359) as a fraction of the wheel.
    static func hue(_ degrees: Double) -> Double { round3(degrees.truncatingRemainder(dividingBy: 360) / 360 + (degrees < 0 ? 1 : 0)) }

    /// A 0…100 strength as 0…1 (color grading saturation and blending).
    static func saturation(_ lightroom: Double) -> Double { round3(lightroom.clamped(to: 0...100) / 100) }

    /// `Sharpness` runs 0…150.
    static func sharpness(_ lightroom: Double) -> Double { round3(lightroom.clamped(to: 0...150) / 150) }
    static func sharpenRadius(_ lightroom: Double) -> Double { lightroom.clamped(to: PhotoAdjustments.Sharpen.radiusRange) }

    /// Curve points are 0…255 in Lightroom, 0…1 here: exact.
    static func curveCoordinate(_ lightroom: Double) -> Double { (lightroom / 255).clamped(to: 0...1) }

    /// Parametric split positions are percentages (default 25/50/75).
    static func split(_ lightroom: Double) -> Double { lightroom / 100 }

    /// Kelvin for a RAW file's `Temperature`. PixelLoupe's slider covers 2000–50000 K, as Lightroom's does.
    static let temperatureRange: ClosedRange<Double> = 2000...50000
    static func rawTemperature(_ lightroom: Double) -> Double {
        lightroom.clamped(to: temperatureRange).rounded()
    }

    /// `Tint` (−150…+150) is PixelLoupe's tint; positive is magenta in both.
    static func rawTint(_ lightroom: Double) -> Double {
        lightroom.clamped(to: -150...150).rounded()
    }

    /// Mireds (1,000,000 / K) that one unit of a non-RAW file's `IncrementalTemperature` moves the
    /// illuminant from neutral (6500 K). Positive is warmer, as in Lightroom.
    static let miredsPerIncrementalTemperature = 0.8
    static let neutralTemperature = 6500.0

    static func incrementalTemperature(_ lightroom: Double) -> Double {
        let mireds = 1_000_000 / neutralTemperature - lightroom.clamped(to: -100...100) * miredsPerIncrementalTemperature
        return (1_000_000 / mireds).clamped(to: temperatureRange).rounded()
    }

    /// `IncrementalTint` (−100…+100) spans PixelLoupe's tint (−150…+150).
    static func incrementalTint(_ lightroom: Double) -> Double {
        (lightroom.clamped(to: -100...100) * 1.5).rounded()
    }

    private static func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
    private static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
