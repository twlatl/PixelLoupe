import AppKit
import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Brush masks (RAW-191)")
struct BrushMaskTests {
    private typealias Stroke = PhotoAdjustments.BrushStroke
    private typealias Brush = PhotoAdjustments.BrushMask

    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let extent = CGRect(x: 0, y: 0, width: 200, height: 100)

    private func stroke(_ points: [(Double, Double)], size: Double = 0.1, feather: Double = 0, flow: Double = 1, density: Double = 1,
                        erasing: Bool = false) -> Stroke {
        .init(points: points.map { .init(x: $0.0, y: $0.1) }, size: size, feather: feather, flow: flow, density: density, isErasing: erasing)
    }

    /// Coverage at a pixel of a 200 × 100 frame (rows from the bottom).
    private func coverage(_ brush: Brush, _ x: Int, _ y: Int) -> Float {
        BrushRasterizer.matte(for: brush, width: 200, height: 100)[y * 200 + x]
    }

    private func maskValue(_ mask: PhotoAdjustments.LocalAdjustment, _ x: Int, _ y: Int) -> Float {
        var data = [Float](repeating: 0, count: 4)
        let image = LocalAdjustmentRenderer.mask(for: mask, extent: extent)!
        context.render(image, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return data[0]
    }

    private func brushMask(_ strokes: [Stroke], inverted: Bool = false) -> PhotoAdjustments.LocalAdjustment {
        var mask = PhotoAdjustments.LocalAdjustment()
        mask.name = "Brush 1"
        mask.components = [.init(shape: .brush(.init(strokes: strokes)), isInverted: inverted)]
        mask.settings.exposure = 1
        return mask
    }

    // MARK: Painting

    @Test("A dab is solid inside its radius (the long edge's fraction) and nothing outside")
    func hardDab() {
        // Radius 0.1 of the 200 px long edge: 20 px around (100, 50).
        let brush = Brush(strokes: [stroke([(0.5, 0.5)])])
        #expect(coverage(brush, 100, 50) == 1)
        #expect(coverage(brush, 100 + 18, 50) == 1)
        #expect(coverage(brush, 100 + 22, 50) == 0)
        #expect(coverage(brush, 100, 50 + 22) == 0, "round, not stretched by the frame's shape")
    }

    @Test("Feather softens the edge from where it starts")
    func feather() {
        let brush = Brush(strokes: [stroke([(0.5, 0.5)], feather: 0.5)])
        #expect(coverage(brush, 100 + 8, 50) == 1, "inside the hard core (10 px)")
        let fading = coverage(brush, 100 + 15, 50)
        #expect(fading > 0.1 && fading < 0.9, "\(fading)")
        #expect(coverage(brush, 100 + 21, 50) == 0)
    }

    @Test("Flow builds up over the stroke's dabs; density caps the stroke however often it passes")
    func flowAndDensity() {
        let single = Brush(strokes: [stroke([(0.5, 0.5)], flow: 0.3)])
        #expect(abs(coverage(single, 100, 50) - 0.3) < 0.001)
        let scrubbed = Brush(strokes: [stroke([(0.45, 0.5), (0.55, 0.5), (0.45, 0.5), (0.55, 0.5)], flow: 0.3)])
        #expect(coverage(scrubbed, 100, 50) > 0.9)

        let capped = Brush(strokes: [stroke([(0.45, 0.5), (0.55, 0.5), (0.45, 0.5)], flow: 0.5, density: 0.4)])
        #expect(abs(coverage(capped, 100, 50) - 0.4) < 0.001)
        // A lighter stroke over a stronger one leaves it alone; a second strong one builds on a weaker one up to its density.
        let over = Brush(strokes: [stroke([(0.5, 0.5)], density: 0.8), stroke([(0.5, 0.5)], density: 0.4)])
        #expect(abs(coverage(over, 100, 50) - 0.8) < 0.001)
        let builds = Brush(strokes: [stroke([(0.5, 0.5)], flow: 0.3), stroke([(0.5, 0.5)], flow: 0.3)])
        #expect(abs(coverage(builds, 100, 50) - 0.51) < 0.001)
    }

    @Test("An erasing stroke takes away what was painted before it, by its flow and density")
    func erase() {
        let painted = stroke([(0.3, 0.5), (0.7, 0.5)])
        let erased = Brush(strokes: [painted, stroke([(0.5, 0.5)], erasing: true)])
        #expect(coverage(erased, 100, 50) == 0)
        #expect(coverage(erased, 70, 50) == 1, "the rest of the stroke stays")
        let half = Brush(strokes: [painted, stroke([(0.5, 0.5)], density: 0.5, erasing: true)])
        #expect(abs(coverage(half, 100, 50) - 0.5) < 0.001)
        // Painting again after erasing paints.
        let again = Brush(strokes: [painted, stroke([(0.5, 0.5)], erasing: true), stroke([(0.5, 0.5)])])
        #expect(coverage(again, 100, 50) == 1)
    }

    @Test("Dabs are spaced evenly along the stroke, carrying the spacing across its points")
    func dabSpacing() {
        let centers = BrushRasterizer.dabCenters([CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 0), CGPoint(x: 10, y: 0)], spacing: 2)
        #expect(centers.count == 6)
        #expect(zip(centers.map(\.x), [0.0, 2, 4, 6, 8, 10]).allSatisfy { abs($0 - $1) < 1e-9 }, "\(centers)")
        #expect(BrushRasterizer.dabCenters([CGPoint(x: 5, y: 5)], spacing: 2) == [CGPoint(x: 5, y: 5)])
    }

    @Test("Painting the next stroke on the cached matte matches painting every stroke from scratch")
    func cachedMatchesScratch() {
        let first = stroke([(0.2, 0.3), (0.8, 0.6)], feather: 0.4, flow: 0.6)
        let second = stroke([(0.5, 0.1), (0.5, 0.9)], size: 0.05, feather: 0.8, flow: 0.5, density: 0.7, erasing: true)
        let width = 173, height = 91
        _ = BrushRasterizer.matte(for: Brush(strokes: [first]), width: width, height: height)
        let incremental = BrushRasterizer.matte(for: Brush(strokes: [first, second]), width: width, height: height)
        var scratch = [Float](repeating: 0, count: width * height)
        for each in [first, second] { BrushRasterizer.paint(each, into: &scratch, width: width, height: height) }
        #expect(incremental == scratch)
    }

    @Test("The brush renders the right way up through the mask, and an unpainted inverted brush selects everything")
    func renderedMask() {
        // Painted near the bottom-left of the frame.
        let mask = brushMask([stroke([(0.1, 0.2)])])
        #expect(maskValue(mask, 20, 20) > 0.99)
        #expect(maskValue(mask, 20, 80) < 0.01)
        #expect(maskValue(mask, 180, 20) < 0.01)

        let empty = brushMask([])
        #expect(maskValue(empty, 100, 50) < 0.01)
        #expect(maskValue(brushMask([], inverted: true), 100, 50) > 0.99)

        // The adjustment applies where painted.
        let gray = CIImage(color: CIColor(red: 0.25, green: 0.25, blue: 0.25)).cropped(to: extent)
        let out = LocalAdjustmentRenderer.apply([mask], to: gray)
        var data = [Float](repeating: 0, count: 4)
        context.render(out, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: 20, y: 20, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        #expect(data[0] > 0.45)
        context.render(out, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: 150, y: 70, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        #expect(abs(data[0] - 0.25) < 0.01)
    }

    // MARK: Model

    @Test("Strokes survive saving, and an unpainted brush is an empty mask")
    func codingAndEmpty() throws {
        let mask = brushMask([stroke([(0.1, 0.2), (0.3, 0.4)], size: 0.05, feather: 0.3, flow: 0.7, density: 0.9, erasing: true)])
        var adjustments = PhotoAdjustments()
        adjustments.masks = [mask, brushMask([])]
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: JSONEncoder().encode(adjustments))
        #expect(decoded.masks == adjustments.masks)

        #expect(!mask.isEmpty && brushMask([]).isEmpty)
        #expect(adjustments.hasEmptyMasks)
        adjustments.deleteEmptyMasks()
        #expect(adjustments.masks.map(\.id) == [mask.id])
    }

    @Test("[ ] step the brush size and ⇧[ ⇧] its feather, within their ranges")
    func settingsSteps() {
        var brush = MaskGeometry.BrushSettings()
        brush.stepSize(1)
        #expect(abs(brush.size - 0.048) < 1e-9)
        brush.stepSize(-100)
        #expect(brush.size == MaskGeometry.BrushSettings.sizeRange.lowerBound)
        brush.stepFeather(2)
        #expect(brush.feather == 0.7)
        brush.stepFeather(10)
        #expect(brush.feather == 1)
    }

    // MARK: Painting on the photo

    @MainActor
    @Test("Dragging over a brush mask paints one stroke with the brush's settings; ⌥ erases")
    func overlayPaints() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 220), styleMask: [.borderless], backing: .buffered, defer: false)
        let overlay = MaskOverlayView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
        window.contentView?.addSubview(overlay)
        overlay.frameRect = CGRect(x: 10, y: 10, width: 400, height: 200)
        overlay.adjustment = brushMask([])
        overlay.brush.size = 0.02
        overlay.brush.flow = 0.6
        var steps: [(PhotoAdjustments.LocalAdjustment, Bool, String)] = []
        overlay.onChange = { steps.append(($0, $1, $2)) }
        func event(_ type: NSEvent.EventType, _ x: Double, _ y: Double, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func strokes() throws -> [Stroke] {
            guard case .brush(let brush)? = steps.last?.0.components.first?.shape else { throw CancellationError() }
            return brush.strokes
        }

        overlay.mouseDown(with: event(.leftMouseDown, 110, 110))
        overlay.mouseDragged(with: event(.leftMouseDragged, 111, 110))   // too close to add a point
        overlay.mouseDragged(with: event(.leftMouseDragged, 150, 110))
        overlay.mouseUp(with: event(.leftMouseUp, 210, 110))
        var painted = try strokes()
        #expect(painted.count == 1)
        #expect(painted[0].points == [.init(x: 0.25, y: 0.5), .init(x: 0.35, y: 0.5), .init(x: 0.5, y: 0.5)])
        #expect(painted[0].size == 0.02 && painted[0].flow == 0.6 && !painted[0].isErasing)
        #expect(steps.first?.1 == false && steps.last?.1 == true)
        #expect(steps.allSatisfy { $0.2 == "Brush Stroke" })

        steps.removeAll()
        overlay.mouseDown(with: event(.leftMouseDown, 110, 110, .option))
        overlay.mouseUp(with: event(.leftMouseUp, 110, 110, .option))
        painted = try strokes()
        #expect(painted.count == 2 && painted[1].isErasing)
        #expect(steps.last?.1 == true && steps.last?.2 == "Erase")
    }

    // MARK: Panel and keys

    @MainActor
    @Test("The Brush button adds a brush; its sliders show only for a brush mask and set the next stroke")
    func panelBrushControls() throws {
        let panel = MaskPanelViewController()
        var added: [MaskPanelViewController.MaskKind] = []
        panel.onAdd = { added.append($0) }
        var reported: MaskGeometry.BrushSettings?
        panel.onBrushChange = { reported = $0 }
        let brush = brushMask([])
        var radial = PhotoAdjustments.LocalAdjustment()
        radial.components = [.init(shape: .radial(MaskGeometry.defaultRadial()))]
        panel.display(masks: [radial, brush], selecting: radial.id)

        try #require(subview("addBrushMask", of: NSButton.self, in: panel.view)).performClick(nil)
        #expect(added == [.brush])

        let controls = try #require(subview("brushControls", of: NSStackView.self, in: panel.view))
        #expect(controls.isHidden)
        panel.select(brush.id)
        #expect(!controls.isHidden)
        #expect(try #require(subview("maskKind", of: NSTextField.self, in: panel.view)).stringValue == "Brush")

        var sent = false
        panel.onChange = { _, _, _ in sent = true }
        let flow = try #require(subview("slider.Brush.Flow", of: SliderRow.self, in: panel.view))
        flow.onChange?(0.25, true)
        #expect(panel.brush.flow == 0.25 && reported?.flow == 0.25)
        #expect(!sent, "the brush's settings aren't an edit of the photo")

        // The keys step the same settings, and the sliders follow.
        panel.brush.stepSize(1)
        let size = try #require(subview("slider.Brush.Size", of: SliderRow.self, in: panel.view))
        #expect(size.value == panel.brush.size)
    }

    @Test("K adds a brush; ⇧[ and ⇧] are its feather; [ and ] stay the rating keys outside a brush")
    func keys() {
        func command(_ characters: String, ignoring: String, shift: Bool = false) -> KeyCommand? {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: 0)
            return event.flatMap(KeyCommand.init(event:))
        }
        #expect(command("k", ignoring: "k") == .brushMask)
        #expect(command("{", ignoring: "{", shift: true) == .brushFeather(-1))
        #expect(command("}", ignoring: "}", shift: true) == .brushFeather(1))
        #expect(command("[", ignoring: "[") == .adjustRating(-1))
    }

    private func subview<View: NSView>(_ identifier: String, of type: View.Type, in view: NSView) -> View? {
        if let view = view as? View, view.accessibilityIdentifier() == identifier { return view }
        return view.subviews.lazy.compactMap { self.subview(identifier, of: type, in: $0) }.first
    }
}
