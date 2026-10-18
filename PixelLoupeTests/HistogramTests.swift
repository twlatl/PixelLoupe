import AppKit
import CoreImage
import ImageIO
import Testing
@testable import PixelLoupe

@Suite("Histogram")
struct HistogramTests {
    private let p3 = CGColorSpace(name: CGColorSpace.displayP3)!

    /// A solid color given in Display P3 (encoded) values.
    private func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ rect: CGRect) -> CIImage {
        CIImage(color: CIColor(red: red, green: green, blue: blue, colorSpace: p3)!).cropped(to: rect)
    }

    @Test func countsEveryPixelInTheRightBins() throws {
        // Left half black, right half white, 200 × 100.
        let image = solid(1, 1, 1, CGRect(x: 100, y: 0, width: 100, height: 100))
            .composited(over: solid(0, 0, 0, CGRect(x: 0, y: 0, width: 200, height: 100)))
        let histogram = try #require(HistogramCalculator.histogram(of: image))
        #expect(histogram.pixelCount == 20_000)
        for channel in histogram.channels {
            #expect(channel[0] == 10_000)
            #expect(channel[255] == 10_000)
        }
    }

    @Test func measuresDisplayValuesPerChannel() throws {
        // Display P3 (0.5, 0.25, 0.75): each channel lands in its own bin.
        let image = solid(0.5, 0.25, 0.75, CGRect(x: 0, y: 0, width: 64, height: 64))
        let histogram = try #require(HistogramCalculator.histogram(of: image))
        func peak(_ counts: [UInt32]) -> Int { counts.indices.max { counts[$0] < counts[$1] }! }
        #expect(abs(peak(histogram.red) - 128) <= 1)
        #expect(abs(peak(histogram.green) - 64) <= 1)
        #expect(abs(peak(histogram.blue) - 191) <= 1)
    }

    @Test func largePhotosAreReducedFirst() throws {
        let image = solid(0.5, 0.5, 0.5, CGRect(x: 0, y: 0, width: 4000, height: 3000))
        let histogram = try #require(HistogramCalculator.histogram(of: image))
        #expect(histogram.pixelCount == 512 * 384)
    }

    @Test func clippedChannels() {
        var histogram = Histogram(red: .init(repeating: 0, count: 256), green: .init(repeating: 0, count: 256), blue: .init(repeating: 0, count: 256))
        histogram.red[128] = 10_000
        histogram.green[128] = 10_000
        histogram.blue[128] = 10_000
        #expect(histogram.clippedChannels(atBlack: true).isEmpty)
        #expect(histogram.clippedChannels(atBlack: false).isEmpty)
        histogram.red[255] = 50
        histogram.blue[0] = 50
        #expect(histogram.clippedChannels(atBlack: false) == [.red])
        #expect(histogram.clippedChannels(atBlack: true) == [.blue])
        histogram.green[255] = 1
        #expect(histogram.clippedChannels(atBlack: false) == [.red], "a stray pixel or two isn't clipping")
    }
}

@Suite("Clipping overlay")
struct ClippingOverlayTests {
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!])

    private func pixel(_ image: CIImage, at point: CGPoint) -> [Float] {
        var pixel = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
        return pixel
    }

    @Test func paintsClippedShadowsBlueAndHighlightsRed() {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        // Black, mid gray and white thirds.
        let image = CIImage(color: CIColor(red: 1, green: 1, blue: 1, colorSpace: p3)!).cropped(to: CGRect(x: 20, y: 0, width: 10, height: 10))
            .composited(over: CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5, colorSpace: p3)!).cropped(to: CGRect(x: 10, y: 0, width: 10, height: 10)))
            .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, colorSpace: p3)!).cropped(to: CGRect(x: 0, y: 0, width: 30, height: 10)))

        let both = ClippingOverlay.apply(to: image, shadows: true, highlights: true)
        let black = pixel(both, at: CGPoint(x: 5, y: 5)), gray = pixel(both, at: CGPoint(x: 15, y: 5)), white = pixel(both, at: CGPoint(x: 25, y: 5))
        #expect(black[2] > 0.9 && black[0] < 0.3, "clipped shadows are blue")
        #expect(white[0] > 0.9 && white[1] < 0.3, "clipped highlights are red")
        #expect(abs(gray[0] - 0.5) < 0.02 && abs(gray[2] - 0.5) < 0.02, "midtones are untouched")

        let highlightsOnly = ClippingOverlay.apply(to: image, shadows: false, highlights: true)
        #expect(pixel(highlightsOnly, at: CGPoint(x: 5, y: 5))[2] < 0.05, "shadows aren't painted when off")
        #expect(ClippingOverlay.apply(to: image, shadows: false, highlights: false) === image)
    }
}

@Suite("Histogram zones")
struct HistogramZoneTests {
    @Test func zonesSpanTheWidthLikeLightroom() {
        #expect(HistogramZone.at(fraction: 0) == .blacks)
        #expect(HistogramZone.at(fraction: 0.2) == .shadows)
        #expect(HistogramZone.at(fraction: 0.5) == .exposure)
        #expect(HistogramZone.at(fraction: 0.7) == .highlights)
        #expect(HistogramZone.at(fraction: 0.95) == .whites)
        #expect(HistogramZone.at(fraction: 1) == .whites)
    }

    @Test func draggingRightBrightens() {
        let start = PhotoAdjustments()
        let exposure = HistogramZone.exposure.applying(0.5, to: start)
        #expect(exposure.light.exposure == 1.5)
        #expect(HistogramZone.shadows.applying(0.2, to: start).light.shadows == 0.3)
        #expect(HistogramZone.highlights.applying(-0.2, to: start).light.highlights == -0.3)
        // Black Point darkens as it rises, so brightening the blacks lowers it.
        #expect(HistogramZone.blacks.applying(0.2, to: start).light.blackPoint == -0.3)
        // Brightening the whites brings Levels' input white down.
        let whites = HistogramZone.whites.applying(0.2, to: start)
        #expect(whites.levels.inputWhite == 0.9)
        #expect(whites.levels.isEnabled)
    }

    @Test func valuesStayInRange() {
        var start = PhotoAdjustments()
        start.light.isEnabled = false
        let far = HistogramZone.exposure.applying(10, to: start)
        #expect(far.light.exposure == 5)
        #expect(far.light.isEnabled, "dragging turns the section on")
        #expect(HistogramZone.shadows.applying(-10, to: start).light.shadows == -1)
        start.levels.inputBlack = 0.4
        #expect(HistogramZone.whites.applying(10, to: start).levels.inputWhite == 0.45, "input white stays above input black")
    }

    @Test func displayValues() {
        var adjustments = PhotoAdjustments()
        adjustments.light.exposure = 0.35
        #expect(HistogramZone.exposure.displayValue(in: adjustments) == SliderRow.signed(0.35))
        #expect(HistogramZone.whites.displayValue(in: adjustments) == SliderRow.unsigned(1))
    }
}

@Suite("Shooting info")
struct ShootingInfoTests {
    @Test func formatsLikeLightroom() {
        let info = ShootingInfo(properties: [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifISOSpeedRatings: [640],
                kCGImagePropertyExifFocalLength: 12.0,
                kCGImagePropertyExifFNumber: 4.5,
                kCGImagePropertyExifExposureTime: 1.0 / 400,
            ] as [CFString: Any],
        ])
        #expect(info.isoText == "ISO 640")
        #expect(info.focalLengthText == "12 mm")
        #expect(info.apertureText == "ƒ / 4.5")
        #expect(info.exposureTimeText == "1/400 sec")
    }

    @Test func longExposuresAndMissingValues() {
        #expect(ShootingInfo(exposureTime: 2.5).exposureTimeText == "2.5 sec")
        #expect(ShootingInfo(exposureTime: 30).exposureTimeText == "30 sec")
        #expect(ShootingInfo(exposureTime: 1.0 / 3).exposureTimeText == "1/3 sec")
        let empty = ShootingInfo(properties: [:])
        #expect(empty.isoText == nil && empty.focalLengthText == nil && empty.apertureText == nil && empty.exposureTimeText == nil)
    }
}

@Suite("Histogram view")
@MainActor
struct HistogramViewTests {
    @Test func showsTheShootingInfoAndClippingState() throws {
        let view = HistogramView(frame: NSRect(x: 0, y: 0, width: 272, height: 120))
        view.shootingInfo = ShootingInfo(iso: 640, focalLength: 12, aperture: 4.5, exposureTime: 1.0 / 400)
        let labels = view.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(labels.contains("ISO 640") && labels.contains("12 mm") && labels.contains("ƒ / 4.5") && labels.contains("1/400 sec"))

        var shown: (Bool, Bool)?
        view.onClippingDisplayChange = { shown = ($0, $1) }
        view.toggleBothClippingOverlays()
        #expect(shown.map { $0.0 && $0.1 } == true)
        view.toggleBothClippingOverlays()
        #expect(shown.map { !$0.0 && !$0.1 } == true)
        view.showsShadowClipping = true
        view.toggleBothClippingOverlays()
        #expect(view.showsShadowClipping && view.showsHighlightClipping, "J turns both on unless both already are")
    }
}
