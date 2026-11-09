import AppKit
import Testing
@testable import PixelLoupe

@Suite("Color wheel: hue dot, modifiers, readout and eyes", .serialized)
@MainActor
struct ColorWheelInteractionTests {
    /// A 100 × 100 wheel: its rim is 43 pt from the center (50, 50), leaving room for the hue dot.
    private let geometry = ColorWheelGeometry(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))

    private func isClose(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.001 }

    // MARK: Geometry

    @Test("The puck follows the pointer; the hue dot turns only the hue; Shift changes only the strength")
    func modes() {
        let top = CGPoint(x: 50, y: 50 + 43 / 2.0)
        let free = geometry.value(at: CGPoint(x: 93, y: 50), mode: .free, current: (0.4, 0.2))
        #expect(isClose(free.hue, 0) && isClose(free.amount, 1))
        let hueOnly = geometry.value(at: top, mode: .hueOnly, current: (0.2, 0.5))
        #expect(isClose(hueOnly.hue, 0.25) && hueOnly.amount == 0.5)
        let strengthOnly = geometry.value(at: top, mode: .strengthOnly, current: (0.2, 0.9))
        #expect(strengthOnly.hue == 0.2 && isClose(strengthOnly.amount, 0.5))
        // At the center a hue has no meaning, so it's kept.
        let center = geometry.value(at: CGPoint(x: 50, y: 50), mode: .free, current: (0.7, 0.3))
        #expect(center.hue == 0.7 && center.amount == 0)
        // The hue can be set before any strength, as in Lightroom.
        let unset = geometry.value(at: top, mode: .hueOnly, current: (0, 0))
        #expect(isClose(unset.hue, 0.25) && unset.amount == 0)
    }

    @Test("Command moves the grabbed point by a quarter of the pointer's move")
    func fineDrag() {
        let target = geometry.fineTarget(moving: CGPoint(x: 50, y: 50), from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 30))
        #expect(target == CGPoint(x: 60, y: 55))
    }

    @Test("The hue dot sits outside the rim at the hue, and clicks near it grab it")
    func hueDot() {
        let dot = geometry.hueDotCenter(hue: 0.25)
        #expect(isClose(dot.x, 50) && dot.y > 93)
        #expect(geometry.isOnHueDot(dot, hue: 0.25))
        #expect(!geometry.isOnHueDot(CGPoint(x: 50, y: 50), hue: 0.25))
        #expect(!geometry.isOnHueDot(dot, hue: 0.75), "the dot moves with the hue")
        #expect(!geometry.isOnHueDot(CGPoint(x: 50, y: 92), hue: 0.25), "a click on the wheel's edge moves the puck")
    }

    // MARK: Dragging

    private func event(_ type: NSEvent.EventType, _ point: CGPoint, _ flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    private func makeWheel() -> (ColorWheelView, changes: () -> [(Double, Double, Bool)]) {
        let wheel = ColorWheelView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var changes: [(Double, Double, Bool)] = []
        wheel.onChange = { changes.append(($0, $1, $2)) }
        return (wheel, { changes })
    }

    @Test("Dragging the hue dot keeps the strength; grabbing it alone changes nothing")
    func dragHueDot() {
        let (wheel, changes) = makeWheel()
        wheel.hue = 0
        wheel.amount = 0.3
        wheel.mouseDown(with: event(.leftMouseDown, geometry.hueDotCenter(hue: 0)))
        #expect(changes().isEmpty)
        wheel.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 50, y: 95)))
        wheel.mouseUp(with: event(.leftMouseUp, CGPoint(x: 50, y: 95)))
        #expect(isClose(wheel.hue, 0.25) && wheel.amount == 0.3)
        #expect(changes().last?.2 == true, "mouse up is the final, undoable change")
    }

    @Test("Shift-drag keeps the hue; Command-drag moves the puck finely")
    func modifierDrags() {
        let (wheel, _) = makeWheel()
        wheel.mouseDown(with: event(.leftMouseDown, CGPoint(x: 93, y: 50)))
        #expect(isClose(wheel.hue, 0) && isClose(wheel.amount, 1))
        wheel.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 50, y: 71.5), .shift))
        #expect(isClose(wheel.hue, 0) && isClose(wheel.amount, 0.5))
        wheel.mouseUp(with: event(.leftMouseUp, CGPoint(x: 50, y: 71.5), .shift))

        // The puck is at (71.5, 50). Command: a 43 pt move of the pointer moves it 10.75 pt, a quarter of the radius.
        wheel.mouseDown(with: event(.leftMouseDown, CGPoint(x: 71.5, y: 50)))
        wheel.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 71.5 + 43, y: 50), .command))
        #expect(isClose(wheel.hue, 0) && isClose(wheel.amount, 0.75))
        wheel.mouseUp(with: event(.leftMouseUp, CGPoint(x: 71.5 + 43, y: 50), .command))
    }

    @Test("A drag highlights the wheel until mouse up")
    func dragHighlights() {
        let (wheel, _) = makeWheel()
        var highlights: [Bool] = []
        wheel.onHighlight = { highlights.append($0) }
        #expect(!wheel.isHighlighted)
        wheel.mouseDown(with: event(.leftMouseDown, CGPoint(x: 60, y: 50)))
        #expect(wheel.isHighlighted)
        wheel.mouseUp(with: event(.leftMouseUp, CGPoint(x: 60, y: 50)))
        #expect(!wheel.isHighlighted && highlights == [true, false])
    }

    // MARK: Readout and muting

    @Test("The All tab's readout uses Lightroom's units")
    func readout() {
        #expect(ColorGradingTab.readout(.init(hue: 189.0 / 360, amount: 0.14, luminance: -0.05)) == "H:189 S:14 L:-5")
        #expect(ColorGradingTab.readout(.init()) == "H:0 S:0 L:0")
        #expect(ColorGradingTab.readout(.init(hue: 0.9999, amount: 0, luminance: -0.001)) == "H:0 S:0 L:0", "no 360 or −0")
    }

    @Test("Muting leaves out just the hidden wheels, in the photo and in one mask")
    func muting() {
        var adjustments = PhotoAdjustments()
        adjustments.color.shadows = .init(hue: 0.1, amount: 0.4)
        adjustments.color.highlights = .init(hue: 0.6, amount: 0.2)
        adjustments.color.global = .init(hue: 0.5, amount: 0.1, luminance: 0.2)
        adjustments.color.blending = 0.3
        var mask = PhotoAdjustments.LocalAdjustment()
        mask.settings.color.midtones = .init(hue: 0.3, amount: 0.5)
        var other = mask
        other.id = UUID()
        adjustments.masks = [mask, other]

        let photo = DevelopViewController.muting(adjustments, wheels: [.shadows, .global], maskWheels: nil)
        #expect(photo.color.shadows == .init() && photo.color.global == .init())
        #expect(photo.color.highlights == adjustments.color.highlights && photo.color.blending == 0.3)
        #expect(photo.masks == adjustments.masks)

        let masked = DevelopViewController.muting(adjustments, wheels: [], maskWheels: (mask.id, [.midtones]))
        #expect(masked.masks[0].settings.color.midtones == .init())
        #expect(masked.masks[1] == other && masked.color == adjustments.color)
        #expect(DevelopViewController.muting(adjustments, wheels: [], maskWheels: nil) == adjustments)
    }

    @Test("An eye hides its wheel from the preview without editing anything")
    func eyeButtons() throws {
        let saved = ColorGradingTab.current
        defer { ColorGradingTab.current = saved }
        let panel = AdjustmentsPanelViewController()
        _ = panel.view
        panel.isEditingEnabled = true
        var changes = 0
        panel.onChange = { _, _, _ in changes += 1 }
        var muted: [Set<ColorGradingTab>] = []
        panel.onMuteWheels = { muted.append($0) }

        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        let eyes = allViews(panel.view).compactMap { $0 as? NSButton }.filter { $0.accessibilityIdentifier() == "colorGradingEye.Shadows" }
        #expect(eyes.count == 2, "one on the All tab, one on Shadows' own")
        let eye = try #require(eyes.first)
        eye.state = .on
        _ = (eye.target as AnyObject).perform(eye.action, with: eye)
        #expect(muted == [[.shadows]] && panel.mutedWheels == [.shadows])
        #expect(eyes.allSatisfy { $0.state == .on }, "both Shadows eyes show it hidden")
        #expect(changes == 0, "not an edit")

        panel.clearMutedWheels()
        #expect(panel.mutedWheels.isEmpty && eyes.allSatisfy { $0.state == .off })
        #expect(muted.count == 1, "clearing is the owner's doing, so it isn't reported back")
    }
}
