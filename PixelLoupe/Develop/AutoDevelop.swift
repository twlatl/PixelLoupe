import CoreImage
import Foundation

/// The Library's Develop Settings ▸ Auto White Balance and Auto Settings: worked out from a small
/// render of the photo with its current settings, off the main thread, without opening Develop.
nonisolated enum AutoDevelop {
    /// The long edge of the render the estimates look at.
    static let samplePixels: CGFloat = 512

    /// Auto White Balance: the temperature and tint that make the photo average to gray (as
    /// Develop's Auto does), or `nil` when the file can't be read or the photo says nothing about
    /// the light (too dark, too bright or too colorful).
    @concurrent
    static func whiteBalance(for url: URL, adjustments: PhotoAdjustments) async -> PhotoAdjustments.WhiteBalance? {
        guard let source = DevelopSource(url: url) else { return nil }
        let image = source.image(with: adjustments, scale: source.scale(toFit: samplePixels, adjustments: adjustments))
        guard let color = averageColor(of: image) else { return nil }
        let asShot = source.asShotWhiteBalance
        let current = (adjustments.whiteBalance.temperature ?? asShot.temperature, adjustments.whiteBalance.tint ?? asShot.tint)
        guard let estimate = WhiteBalanceEstimator.neutralizing(color, current: current) else { return nil }
        return .init(isEnabled: true, temperature: estimate.temperature, tint: estimate.tint,
                     preset: PhotoAdjustments.WhiteBalance.autoName)
    }

    /// Auto Settings: Exposure and Shadows (Develop's Auto for Light), then Whites and Blacks to put
    /// the brightest and darkest tones near the ends of the range, and Vibrance and Saturation for a
    /// muted photo. `nil` when the file can't be read.
    @concurrent
    static func settings(for url: URL, adjustments: PhotoAdjustments) async -> PhotoAdjustments? {
        guard let source = DevelopSource(url: url) else { return nil }
        var result = adjustments
        let auto = AdjustmentPipeline.autoLight(for: source, current: adjustments, context: PhotoRenderer.context)
        result.light.isEnabled = true
        result.light.exposure = auto.exposure
        result.light.shadows = auto.shadows
        result.light.whites = 0
        result.light.blackPoint = 0
        result.presence.vibrance = 0
        result.presence.saturation = 0

        let image = source.image(with: result, scale: source.scale(toFit: samplePixels, adjustments: result))
        guard let statistics = toneStatistics(of: image) else { return result }
        let tones = autoTones(statistics)
        result.light.whites = tones.whites
        result.light.blackPoint = tones.blackPoint
        result.presence.isEnabled = true
        result.presence.vibrance = tones.vibrance
        result.presence.saturation = tones.saturation
        return result
    }

    /// What Auto Settings looks at: the brightest and darkest tones (0.5% in from each end) and how
    /// colorful the midtones are on average (0…1).
    struct ToneStatistics: Equatable, Sendable {
        var darkest: Double
        var brightest: Double
        var saturation: Double
    }

    /// Whites, Blacks (as `blackPoint`: positive deepens), Vibrance and Saturation for `statistics`,
    /// rounded as the sliders show them.
    static func autoTones(_ statistics: ToneStatistics) -> (whites: Double, blackPoint: Double, vibrance: Double, saturation: Double) {
        func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
        // Bright tones well short of white are pushed up; clipped ones are pulled back.
        let whites = rounded(((0.96 - statistics.brightest) * 2.5).clamped(to: -1...1))
        // A washed-out darkest tone is deepened; crushed shadows are lifted.
        let blackPoint = rounded(((statistics.darkest - 0.03) * 2.5).clamped(to: -1...1))
        // Muted photos get color; colorful ones are left alone.
        let muted = 0.3 - statistics.saturation
        let vibrance = rounded(muted.clamped(to: 0...0.4))
        let saturation = rounded((muted * 0.3).clamped(to: -0.1...0.1))
        return (whites, blackPoint, vibrance, saturation)
    }

    /// The image's average color (display RGB, 0…1).
    static func averageColor(of image: CIImage) -> [Double]? {
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent),
        ]), let average = filter.outputImage else { return nil }
        var pixel = [Float](repeating: 0, count: 4)
        PhotoRenderer.context.render(average, toBitmap: &pixel, rowBytes: 16, bounds: average.extent, format: .RGBAf,
                                     colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
        return pixel.prefix(3).map(Double.init)
    }

    static func toneStatistics(of image: CIImage) -> ToneStatistics? {
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0, width * height <= 1_000_000 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        PhotoRenderer.context.render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
        return toneStatistics(rgba: pixels)
    }

    /// The statistics of RGBA8 pixels.
    static func toneStatistics(rgba pixels: [UInt8]) -> ToneStatistics? {
        let count = pixels.count / 4
        guard count > 0 else { return nil }
        var histogram = [Int](repeating: 0, count: 256)
        var saturationSum = 0.0, saturationCount = 0
        for index in 0..<count {
            let red = Double(pixels[index * 4]) / 255, green = Double(pixels[index * 4 + 1]) / 255
            let blue = Double(pixels[index * 4 + 2]) / 255
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            histogram[min(255, Int(luminance * 255))] += 1
            // Midtones only: near black or white, saturation means little.
            guard luminance > 0.1, luminance < 0.9 else { continue }
            let high = max(red, green, blue), low = min(red, green, blue)
            saturationSum += high > 0 ? (high - low) / high : 0
            saturationCount += 1
        }
        func percentile(_ fraction: Double) -> Double {
            let target = Int(Double(count) * fraction)
            var seen = 0
            for (bin, value) in histogram.enumerated() {
                seen += value
                if seen > target { return Double(bin) / 255 }
            }
            return 1
        }
        return ToneStatistics(darkest: percentile(0.005), brightest: percentile(0.995),
                              saturation: saturationCount > 0 ? saturationSum / Double(saturationCount) : 0)
    }
}
