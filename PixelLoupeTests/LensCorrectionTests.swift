import AppKit
import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Lens correction rendering")
struct LensCorrectionRenderingTests {
    private let context = CIContext(options: [.workingColorSpace: NSNull()])
    private let size = CGRect(x: 0, y: 0, width: 400, height: 300)

    private func pixel(_ image: CIImage, _ x: CGFloat, _ y: CGFloat) -> [Float] {
        var pixel = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
        return pixel
    }

    /// The center of a channel's (0 red, 2 blue) bright pixels in a region.
    private func centroid(_ image: CIImage, channel: Int, in rect: CGRect) -> CGPoint {
        var bitmap = [Float](repeating: 0, count: Int(rect.width * rect.height) * 4)
        context.render(image, toBitmap: &bitmap, rowBytes: Int(rect.width) * 16, bounds: rect, format: .RGBAf, colorSpace: nil)
        var sum = (weight: 0.0, x: 0.0, y: 0.0)
        for y in 0..<Int(rect.height) {
            for x in 0..<Int(rect.width) {
                let v = Double(bitmap[(y * Int(rect.width) + x) * 4 + channel])
                guard v > 0.05 else { continue }
                // Bitmap rows run top to bottom.
                sum = (sum.weight + v, sum.x + v * (Double(rect.minX) + Double(x) + 0.5), sum.y + v * (Double(rect.maxY) - Double(y) - 0.5))
            }
        }
        return CGPoint(x: sum.x / sum.weight, y: sum.y / sum.weight)
    }

    private var gray: CIImage {
        CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: size)
    }

    @Test func manualVignettingBrightensCornersOnly() {
        var lens = PhotoAdjustments.LensCorrections()
        lens.manualVignetting = 1
        let result = LensCorrector.apply(lens, to: gray)
        #expect(abs(pixel(result, 200, 150)[1] - 0.5) < 0.01, "the center is untouched")
        #expect(pixel(result, 1, 1)[1] > 0.9, "corners are brighter")
        lens.manualVignetting = -1
        #expect(pixel(LensCorrector.apply(lens, to: gray), 1, 298)[1] < 0.3, "or darker")
    }

    @Test func chromaticAberrationScalesRedAndBlueAboutTheCenter() {
        // A red and blue dot up and to the right of the center, and green everywhere.
        let dot = CGRect(x: 300, y: 230, width: 4, height: 4)
        let image = CIImage(color: CIColor(red: 1, green: 0, blue: 1)).cropped(to: dot)
            .composited(over: CIImage(color: CIColor(red: 0, green: 0.5, blue: 0)).cropped(to: size))
        var lens = PhotoAdjustments.LensCorrections()
        lens.removeChromaticAberration = true
        // Red is 2% too large: corrected red at p comes from p × 1.02, so the dot moves in.
        lens.chromaticAberration = .init(red: 1.02, blue: 1)
        let result = LensCorrector.apply(lens, to: image)
        let search = CGRect(x: 250, y: 190, width: 80, height: 60)
        let red = centroid(result, channel: 0, in: search), blue = centroid(result, channel: 2, in: search)
        let center = CGPoint(x: 200, y: 150)
        let expected = CGPoint(x: center.x + (302 - center.x) / 1.02, y: center.y + (232 - center.y) / 1.02)
        #expect(abs(red.x - expected.x) < 0.3 && abs(red.y - expected.y) < 0.3, "red moved to \(red), expected \(expected)")
        #expect(abs(blue.x - 302) < 0.1 && abs(blue.y - 232) < 0.1, "blue stayed at \(blue)")
    }

    @Test func manualDistortionMovesEdgesAndConstrainCropFillsTheFrame() {
        var lens = PhotoAdjustments.LensCorrections()
        lens.manualDistortion = -1  // corrects pincushion: corrected pixels come from further out
        let geometry = LensCorrector.Geometry(lens: lens, profile: nil, halfDiagonal: 250)
        let edge = geometry.sourceOffsets(for: CGPoint(x: 200, y: 0), scale: 1)[0]
        #expect(edge.x > 200, "the edge samples from outside the photo")
        let result = LensCorrector.apply(lens, to: gray)
        #expect(pixel(result, 1, 150)[3] < 0.5, "so it shows empty space")

        lens.constrainCrop = true
        let scale = geometry.constrainingScale(in: size)
        #expect(scale < 1 && scale > 0.7)
        let constrained = LensCorrector.apply(lens, to: gray)
        for (x, y) in [(0.5, 0.5), (399.5, 0.5), (0.5, 299.5), (399.5, 299.5), (200, 0.5), (0.5, 150)] {
            #expect(pixel(constrained, x, y)[3] > 0.99, "covered at \(x), \(y)")
        }
    }

    @Test func defringeRemovesPurpleOnEdgesButNotFlatColor() {
        // A purple stripe along a dark/bright edge, and a large flat purple area.
        let purple = CIColor(red: 0.5, green: 0.1, blue: 0.7)
        let image = CIImage(color: purple).cropped(to: CGRect(x: 198, y: 0, width: 3, height: 150))
            .composited(over: CIImage(color: CIColor(red: 0.9, green: 0.9, blue: 0.9)).cropped(to: CGRect(x: 200, y: 0, width: 200, height: 150)))
            .composited(over: CIImage(color: CIColor(red: 0.02, green: 0.02, blue: 0.02)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 150)))
            .composited(over: CIImage(color: purple).cropped(to: size))
        var lens = PhotoAdjustments.LensCorrections()
        lens.purpleAmount = 1
        let result = LensCorrector.apply(lens, to: image)
        let fringe = pixel(result, 199, 75)
        #expect(abs(fringe[0] - fringe[2]) < 0.05, "the fringe is neutral: \(fringe)")
        let flat = pixel(result, 100, 250)
        #expect(abs(flat[2] - 0.7) < 0.01 && abs(flat[0] - 0.5) < 0.01, "flat purple keeps its color: \(flat)")
        lens.purpleHue = .init(lower: 0, upper: 0.2)
        let outOfRange = pixel(LensCorrector.apply(lens, to: image), 199, 75)
        #expect(outOfRange[2] - outOfRange[0] > 0.1, "hues outside the range are kept: \(outOfRange)")
    }

    /// Regression: Core Image repeats a processor kernel's edge pixels beyond its output, which
    /// smeared the corrected photo across whatever was drawn beside it (the preview's matte).
    @Test func nothingLeaksPastThePhoto() throws {
        let context = CIContext()
        let noise = try #require(CIFilter(name: "CIRandomGenerator")?.outputImage).cropped(to: CGRect(x: 0, y: 0, width: 1400, height: 934))
        let photo = CIImage(cgImage: try #require(context.createCGImage(noise, from: noise.extent)))
        var lens = PhotoAdjustments.LensCorrections()
        lens.manualDistortion = 0.3
        lens.manualVignetting = 0.2
        lens.purpleAmount = 0.5
        let corrected = LensCorrector.apply(lens, to: photo)
        let matte = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: -600, y: 0, width: 3410, height: 934))
        let composite = corrected.transformed(by: CGAffineTransform(translationX: 1410, y: 0)).composited(over: matte)
        // Rendered whole, as a window or export would.
        let rendered = CIImage(cgImage: try #require(context.createCGImage(composite, from: composite.extent)))
        for x in [100.0, 700, 1300, 1405] {
            let value = pixel(rendered, x + 600, 400)
            #expect(value[0] < 0.01 && value[1] > 0.99 && value[2] < 0.01, "matte at \(x): \(value)")
        }
    }

    @Test func defaultsChangeNothing() {
        let image = gray
        #expect(LensCorrector.apply(PhotoAdjustments.LensCorrections(), to: image) === image)
    }
}
