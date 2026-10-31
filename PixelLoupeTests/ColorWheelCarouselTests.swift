import AppKit
import Testing
@testable import PixelLoupe

@Suite("Color Grading carousel: peeking tonal wheels", .serialized)
@MainActor
struct ColorWheelCarouselTests {
    @Test("Shadows peeks at Midtones, Midtones at both, Highlights at Midtones; All and Global don't peek")
    func neighbours() {
        #expect(ColorGradingTab.shadows.neighbours == [.midtones])
        #expect(ColorGradingTab.midtones.neighbours == [.shadows, .highlights])
        #expect(ColorGradingTab.highlights.neighbours == [.midtones])
        #expect(ColorGradingTab.global.neighbours.isEmpty && ColorGradingTab.all.neighbours.isEmpty)
        #expect(ColorGradingTab.carousel.map(\.carouselIndex) == [0, 1, 2] && ColorGradingTab.global.carouselIndex == nil)
    }

    @Test("The shown wheel is centered and each neighbour shows a sliver at the edge")
    func frames() {
        let bounds = CGRect(x: 0, y: 0, width: 274, height: 170)
        let peek = ColorWheelCarouselView.peekWidth
        func visible(_ frame: CGRect) -> CGFloat { max(0, frame.intersection(bounds).width) }

        let shadows = ColorWheelCarouselView.wheelFrames(count: 3, position: 0, in: bounds)
        #expect(shadows[0].midX == bounds.midX && shadows[0].height == 170)
        #expect(abs(visible(shadows[1]) - peek) < 0.001, "Midtones peeks in at the right")
        #expect(visible(shadows[2]) == 0, "Highlights is two wheels away, out of sight")

        let midtones = ColorWheelCarouselView.wheelFrames(count: 3, position: 1, in: bounds)
        #expect(midtones[1].midX == bounds.midX)
        #expect(abs(visible(midtones[0]) - peek) < 0.001 && abs(visible(midtones[2]) - peek) < 0.001)

        // Halfway through a slide the two wheels share the strip.
        let sliding = ColorWheelCarouselView.wheelFrames(count: 3, position: 0.5, in: bounds)
        #expect(abs((sliding[0].midX + sliding[1].midX) / 2 - bounds.midX) < 0.001)
    }

    @Test("Peeks show their wheel's setting, and clicking one shows its tab without editing")
    func peeks() throws {
        let saved = ColorGradingTab.current
        defer { ColorGradingTab.current = saved }
        let panel = AdjustmentsPanelViewController()
        _ = panel.view
        panel.isEditingEnabled = true
        var changes = 0
        panel.onChange = { _, _, _ in changes += 1 }
        var adjustments = PhotoAdjustments()
        adjustments.color.shadows = .init(hue: 0.47, amount: 0.79)
        panel.display(adjustments, asShotWhiteBalance: (5500, 0))
        ColorGradingTab.current = .midtones

        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        func wheel(_ identifier: String) throws -> ColorWheelView {
            try #require(allViews(panel.view).first { $0.accessibilityIdentifier() == identifier } as? ColorWheelView)
        }
        let shadowsPeek = try wheel("colorWheelPeek.Midtones.Shadows")
        #expect(shadowsPeek.hue == 0.47 && shadowsPeek.amount == 0.79, "drawn with Shadows' own setting")
        #expect(shadowsPeek.accessibilityRole() == .button)
        #expect(try wheel("colorWheel.Midtones.single").accessibilityRole() == .colorWell, "the tab's own wheel edits")
        #expect(allViews(panel.view).filter { $0.accessibilityIdentifier().hasPrefix("colorWheelPeek.Global") }.isEmpty)

        shadowsPeek.mouseDown(with: try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)))
        #expect(ColorGradingTab.current == .shadows)
        #expect(panel.adjustments.color.shadows == .init(hue: 0.47, amount: 0.79) && changes == 0, "a click on a peek isn't an edit")
        let picker = try #require(allViews(panel.view).first { $0.accessibilityIdentifier() == "colorGradingTab" } as? NSSegmentedControl)
        #expect(picker.selectedSegment == ColorGradingTab.shadows.rawValue)

        // VoiceOver presses a peek the same way.
        #expect(try wheel("colorWheelPeek.Shadows.Midtones").accessibilityPerformPress())
        #expect(ColorGradingTab.current == .midtones)
    }
}
