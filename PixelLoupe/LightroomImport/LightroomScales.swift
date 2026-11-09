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

    /// Slider values that run −100…+100 in Lightroom and −1…+1 here: contrast, whites, texture, dehaze,
    /// vibrance and saturation (vibrance measured linear in RAW-229), and Shadows under its per-pixel
    /// process (RAW-230). Linear until tuned.
    static func percent(_ lightroom: Double) -> Double {
        round3(lightroom.clamped(to: -100...100) / 100)
    }

    /// Lightroom value → PixelLoupe value, measured from Lightroom's exports of slider sweeps (RAW-229):
    /// each point is the PixelLoupe value whose render matched Lightroom's best, linear in between.
    typealias Table = [(lightroom: Double, pixelLoupe: Double)]

    /// Shadows under its original process (Core Image's highlight and shadow filter), which lifts harder
    /// than Lightroom's: +50 matches 0.4. Lowering them is linear. Imports use the per-pixel process,
    /// so this only converts photos still on the original one.
    static let filterShadowsTable: Table = [(-100, -1), (0, 0), (50, 0.395), (100, 0.802)]
    /// Pulling highlights down is stronger here (−50 matches −0.3); raising them is linear.
    static let highlightsTable: Table = [(-100, -0.729), (-50, -0.302), (0, 0), (100, 1)]
    /// Positive Clarity is stronger here (+100 matches 0.69); negative is linear.
    static let clarityTable: Table = [(-100, -1), (0, 0), (50, 0.41), (100, 0.692)]

    /// `Shadows2012` as the per-pixel process's amount: one to one (RAW-230).
    static func shadows(_ lightroom: Double) -> Double { percent(lightroom) }
    static func highlights(_ lightroom: Double) -> Double { round3(evaluate(highlightsTable, lightroom.clamped(to: -100...100))) }
    static func clarity(_ lightroom: Double) -> Double { round3(evaluate(clarityTable, lightroom.clamped(to: -100...100))) }

    /// Lightroom's parametric curve regions are gentler than PixelLoupe's at the same number: fitted
    /// against Lightroom's export of a preset that sets all four (RAW-229).
    static let parametricStrength = 0.6

    static func parametric(_ lightroom: Double) -> Double {
        round3(lightroom.clamped(to: -100...100) / 100 * parametricStrength)
    }

    /// The other way, for presets PixelLoupe writes: the Lightroom value for a PixelLoupe one (values
    /// past the table's ends, which Lightroom can't reach, become its end).
    static func lightroom(fromShadows value: Double, process: PhotoAdjustments.Light.ShadowsProcess) -> Double {
        switch process {
        case .perPixelGain: (value * 100).clamped(to: -100...100)
        case .highlightShadowFilter: evaluate(filterShadowsTable.map { ($1, $0) }, value)
        }
    }

    /// The original process's Shadows for a Lightroom value.
    static func filterShadows(_ lightroom: Double) -> Double { round3(evaluate(filterShadowsTable, lightroom.clamped(to: -100...100))) }
    static func lightroom(fromHighlights value: Double) -> Double { evaluate(highlightsTable.map { ($1, $0) }, value) }
    static func lightroom(fromClarity value: Double) -> Double { evaluate(clarityTable.map { ($1, $0) }, value) }
    static func lightroom(fromParametric value: Double) -> Double { (value / parametricStrength * 100).clamped(to: -100...100) }

    /// The table's value at `x`, interpolated linearly, held at the ends.
    private static func evaluate(_ table: Table, _ x: Double) -> Double {
        guard let first = table.first, let last = table.last else { return x }
        if x <= first.lightroom { return first.pixelLoupe }
        if x >= last.lightroom { return last.pixelLoupe }
        for (a, b) in zip(table, table.dropFirst()) where x <= b.lightroom {
            return a.pixelLoupe + (b.pixelLoupe - a.pixelLoupe) * (x - a.lightroom) / (b.lightroom - a.lightroom)
        }
        return last.pixelLoupe
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
