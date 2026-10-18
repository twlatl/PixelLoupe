import Foundation

/// Finds the white balance that makes a color neutral: the White Balance eyedropper picks a patch
/// that should be gray, and Auto uses the whole photo's average.
///
/// A white balance change scales the red, green and blue of the photo, so the change that
/// neutralizes a color follows from its channel ratios: red against blue is the temperature (in
/// mireds, where equal steps look alike) and green against red and blue is the tint. Both
/// constants are the typical rates for daylight-range light.
nonisolated enum WhiteBalanceEstimator {
    /// Change in ln(red/blue) per mired.
    static let logRatioPerMired = 0.0078
    /// Change in ln(green/√(red·blue)) per tint unit.
    static let logRatioPerTint = 0.004

    static let temperatureRange = LightroomScales.temperatureRange
    static let tintRange = -150.0...150.0

    /// The temperature (K) and tint that turn `color` (display RGB, 0…1, as rendered with the
    /// `current` white balance) neutral, or `nil` for a color too dark, too bright or too saturated
    /// to say anything about the light.
    static func neutralizing(_ color: [Double], current: (temperature: Double, tint: Double)) -> (temperature: Double, tint: Double)? {
        guard color.count >= 3 else { return nil }
        let linear = color.prefix(3).map(Self.linear)
        let (red, green, blue) = (linear[0], linear[1], linear[2])
        guard linear.min()! > 0.003, linear.max()! < 0.97 else { return nil }
        // A saturated color isn't a neutral under tinted light.
        guard linear.max()! / linear.min()! < 4 else { return nil }

        let warm = log(red / blue)
        let greenCast = log(green / (red * blue).squareRoot())
        // Too warm (red over blue): the light is assumed too orange, so move toward the cooler
        // illuminant (more mireds, fewer kelvin). Too green: add magenta.
        let mireds = 1_000_000 / current.temperature + warm / logRatioPerMired
        guard mireds > 0 else { return nil }
        let temperature = (1_000_000 / mireds).clamped(to: temperatureRange).rounded()
        let tint = (current.tint + greenCast / logRatioPerTint).clamped(to: tintRange).rounded()
        return (temperature, tint)
    }

    /// sRGB / Display P3 transfer function.
    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
