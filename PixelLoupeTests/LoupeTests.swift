import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Loupe shape and placement")
struct LoupeShapeTests {
    @Test func hitTestsDesignRegions() {
        #expect(LoupeShape.region(at: LoupeShape.center) == .lens)
        #expect(LoupeShape.region(at: CGPoint(x: 299.5, y: 12)) == .edge, "top of the ring")
        #expect(LoupeShape.region(at: CGPoint(x: 560, y: 480)) == .edge, "the corner tab")
        #expect(LoupeShape.region(at: CGPoint(x: 580, y: 580)) == .edge, "the grip is hit-tested by the placement")
        #expect(LoupeShape.region(at: CGPoint(x: 20, y: 580)) == .none, "outside, lower left")
        #expect(LoupeShape.region(at: CGPoint(x: 5, y: 5)) == .none, "outside, upper left corner")
    }

    @Test func placementMapsArtboardToView() {
        let placement = LoupePlacement(lensCenter: CGPoint(x: 400, y: 300), size: 300)
        #expect(placement.scale == 0.5)
        #expect(placement.viewPoint(LoupeShape.center) == CGPoint(x: 400, y: 300))
        // The tab is at the lower right: larger x, smaller y in (y-up) view coordinates.
        let tab = placement.viewPoint(CGPoint(x: 560, y: 560))
        #expect(tab.x > 400 && tab.y < 300)
        let back = placement.artboardPoint(tab)
        #expect(abs(back.x - 560) < 0.001 && abs(back.y - 560) < 0.001)
        #expect(placement.region(at: CGPoint(x: 400, y: 300)) == .lens)
        #expect(abs(placement.lensRadius - LoupeShape.lensRadius / 2) < 0.001)
    }

    /// The grip keeps its size and line weight as the loupe grows.
    @Test(arguments: [200.0, 320.0, 640.0])
    func gripIsFixedSize(size: Double) {
        let placement = LoupePlacement(lensCenter: CGPoint(x: 400, y: 400), size: size)
        let (start, end) = placement.gripLines[0]
        let reference = LoupePlacement(lensCenter: .zero, size: 320).gripLines[0]
        #expect(abs(hypot(end.x - start.x, end.y - start.y) - hypot(reference.1.x - reference.0.x, reference.1.y - reference.0.y)) < 0.001)
        #expect(placement.region(at: placement.gripCenter) == .grip)
        // The grip sits in the tab's lower-right corner.
        let corner = placement.viewPoint(LoupeShape.gripAnchor)
        #expect(placement.gripCenter.x < corner.x && placement.gripCenter.y > corner.y)
        #expect(placement.coverRadius > placement.lensRadius)
    }

    @Test func offsetLoupeMagnifiesPastTheTab() {
        var placement = LoupePlacement(lensCenter: CGPoint(x: 400, y: 300), size: 300)
        #expect(placement.focusPoint(centered: true) == CGPoint(x: 400, y: 300))
        let target = placement.focusPoint(centered: false)
        #expect(target.x > 400 && target.y < 300)
        #expect(placement.region(at: target) == .none, "the target isn't covered by the loupe")

        placement.focus(on: CGPoint(x: 100, y: 100), centered: false)
        let refocused = placement.focusPoint(centered: false)
        #expect(abs(refocused.x - 100) < 0.001 && abs(refocused.y - 100) < 0.001)
    }
}

@Suite("Loupe settings")
struct LoupeSettingsTests {
    @Test func defaultsAndPersistence() throws {
        let suite = "LoupeSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = LoupeSettings(defaults: defaults)
        #expect(settings.zoom == 1)
        #expect(settings.centered)
        #expect(!settings.focusOnCursor && !settings.showsPixelGrid && !settings.showsColorValue)

        settings.zoom = 8
        settings.size = 10_000
        settings.focusOnCursor = true
        settings.centered = false
        settings.showsColorValue = true

        let reloaded = LoupeSettings(defaults: defaults)
        #expect(reloaded.zoom == 8)
        #expect(reloaded.size == LoupeSettings.sizeRange.upperBound, "size is clamped when loaded")
        #expect(reloaded.focusOnCursor && !reloaded.centered && reloaded.showsColorValue)
    }

    @Test func zoomLevelsSpan50To1600Percent() {
        #expect(LoupeSettings.zoomLevels.map(LoupeSettings.title(forZoom:)) == ["50", "100", "200", "400", "800", "1600"])
    }
}

@Suite("Loupe rendering")
struct LoupeRenderingTests {
    /// A 1000 × 1000 photo, red on the left half and blue on the right, shown at 500 × 500 points
    /// on a 2× display (so one point is two photo pixels, and the preview is at 100%).
    private let geometry = PreviewGeometry(
        imageRect: CGRect(x: 0, y: 0, width: 500, height: 500),
        imageSize: CGSize(width: 1000, height: 1000),
        backingScale: 2
    )
    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    private var photo: CIImage {
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 500, height: 1000))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 500, y: 0, width: 500, height: 1000))
        return red.composited(over: blue)
    }

    private func pixel(_ image: CIImage, at point: CGPoint) -> (r: Float, g: Float, b: Float) {
        var value = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &value, rowBytes: 16, bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
        return (value[0], value[1], value[2])
    }

    private func request(focusX: CGFloat, zoom: Double = 1) -> LoupeRenderRequest {
        LoupeRenderRequest(
            lensCenter: CGPoint(x: 100, y: 400), lensRadius: 50, coverRadius: 52,
            focus: CGPoint(x: focusX, y: 250), zoom: zoom, magnify: true
        )
    }

    @Test func geometryRoundTrips() {
        let point = CGPoint(x: 123, y: 456)
        let back = geometry.viewPoint(forImagePoint: geometry.imagePoint(forViewPoint: point))
        #expect(abs(back.x - point.x) < 0.001 && abs(back.y - point.y) < 0.001)
        #expect(geometry.pointsPerImagePixel(zoom: 1) == 0.5)
        // A 100-point lens at 100% shows 200 photo pixels, which is 100 preview points here.
        #expect(abs(geometry.previewDiameter(ofLens: 100, zoom: 1) - 100) < 0.001)
        #expect(abs(geometry.previewDiameter(ofLens: 100, zoom: 4) - 25) < 0.001)
    }

    @Test(arguments: [0.5, 1.0, 4.0, 16.0])
    func lensShowsTheFocusedArea(zoom: Double) {
        let output = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let lensCenterPixel = CGPoint(x: 200, y: 800)

        let photo = self.photo.transformed(by: CGAffineTransform(
            scaleX: LoupeRenderer.renderScale(forZoom: zoom), y: LoupeRenderer.renderScale(forZoom: zoom)
        ))
        let scale = LoupeRenderer.renderScale(forZoom: zoom)
        let onBlue = LoupeRenderer.composite(request(focusX: 260, zoom: zoom), photo: photo, photoScale: scale, over: output, geometry: geometry, matte: .black)
        #expect(pixel(onBlue, at: lensCenterPixel).b > 0.9)

        let onRed = LoupeRenderer.composite(request(focusX: 240, zoom: zoom), photo: photo, photoScale: scale, over: output, geometry: geometry, matte: .black)
        #expect(pixel(onRed, at: lensCenterPixel).r > 0.9)
        #expect(pixel(onRed, at: CGPoint(x: 600, y: 200)).r < 0.01, "outside the lens is untouched")
    }

    @Test func magnifiesAroundTheFocus() {
        // Focus 5 photo pixels left of the red/blue edge. At 1600% that's 80 display pixels, so a
        // pixel 60 to the right of the lens center is still red and one 100 to the right is blue.
        let output = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let composite = LoupeRenderer.composite(request(focusX: 247.5, zoom: 16), photo: photo, photoScale: 1, over: output, geometry: geometry, matte: .black)
        #expect(pixel(composite, at: CGPoint(x: 260, y: 800)).r > 0.9)
        #expect(pixel(composite, at: CGPoint(x: 290, y: 800)).b > 0.9)
    }

    /// Before the full-resolution decoder is ready, the lens magnifies the lower-resolution preview.
    @Test func magnifiesAReducedScalePhoto() {
        let output = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let preview = photo.transformed(by: CGAffineTransform(scaleX: 0.25, y: 0.25))
        let onBlue = LoupeRenderer.composite(request(focusX: 260, zoom: 4), photo: preview, photoScale: 0.25, over: output, geometry: geometry, matte: .black)
        #expect(pixel(onBlue, at: CGPoint(x: 200, y: 800)).b > 0.9)
        let onRed = LoupeRenderer.composite(request(focusX: 240, zoom: 4), photo: preview, photoScale: 0.25, over: output, geometry: geometry, matte: .black)
        #expect(pixel(onRed, at: CGPoint(x: 200, y: 800)).r > 0.9)
    }

    @Test func colorValueReadsTheFocusedPixel() throws {
        let context = CIContext()
        let red = try #require(LoupeRenderer.colorValue(at: request(focusX: 100), photo: photo, photoScale: 1, geometry: geometry, context: context))
        #expect(red.r == 255 && red.g == 0 && red.b == 0)
        let blue = try #require(LoupeRenderer.colorValue(at: request(focusX: 400), photo: photo, photoScale: 1, geometry: geometry, context: context))
        #expect(blue.b == 255 && blue.r == 0)
        #expect(LoupeRenderer.colorValue(at: request(focusX: 600), photo: photo, photoScale: 1, geometry: geometry, context: context) == nil,
                "no value outside the photo")
    }
}
