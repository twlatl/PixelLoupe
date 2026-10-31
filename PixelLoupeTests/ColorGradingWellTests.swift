import AppKit
import Testing
@testable import PixelLoupe

@Suite("Color Grading wells: photo colors and the eyedropper", .serialized)
@MainActor
struct ColorGradingWellTests {
    typealias RGB = ColorGradingSwatches.RGB

    private func isClose(_ a: Double, _ b: Double, _ tolerance: Double = 0.02) -> Bool { abs(a - b) <= tolerance }
    private func isClose(_ a: RGB, _ b: RGB, _ tolerance: Double = 0.05) -> Bool {
        let d = a - b
        return max(abs(d.x), abs(d.y), abs(d.z)) <= tolerance
    }

    @Test("A color sets its hue and its chroma as the saturation; grays give nothing")
    func colorToWheel() throws {
        let red = try #require(ColorGradingSwatches.wheel(for: RGB(1, 0, 0)))
        #expect(red.hue == 0 && red.amount == 1, "pure red is past 100 chroma, so full strength")

        let orange = try #require(ColorGradingSwatches.wheel(for: RGB(0.8, 0.5, 0.3)))
        #expect(isClose(orange.hue, 24.0 / 360, 0.001))
        #expect(orange.amount > 0.25 && orange.amount < 0.55, "a muted orange is a moderate grade")
        #expect(orange.amount == (orange.amount * 100).rounded() / 100, "in whole Saturation steps")

        #expect(ColorGradingSwatches.wheel(for: RGB(0.5, 0.5, 0.5)) == nil)
        #expect(ColorGradingSwatches.wheel(for: RGB(0.52, 0.5, 0.5)) == nil, "near gray has no hue worth giving")
    }

    @Test("Swatches are the photo's main colors, busiest first, without grays")
    func swatches() {
        let red = RGB(0.8, 0.2, 0.2), blue = RGB(0.2, 0.3, 0.8), gray = RGB(0.5, 0.5, 0.5)
        let pixels = Array(repeating: red, count: 500) + Array(repeating: blue, count: 250) + Array(repeating: gray, count: 300)
        let found = ColorGradingSwatches.swatches(from: pixels, for: .global, in: .init())
        #expect(found.count == 2)
        #expect(found.count == 2 && isClose(found[0], red) && isClose(found[1], blue))
    }

    @Test("Shadows, Midtones and Highlights wells offer only colors in their tonal range")
    func tonalRange() {
        let darkBlue = RGB(0.1, 0.1, 0.35), paleYellow = RGB(0.95, 0.9, 0.4)
        let pixels = Array(repeating: darkBlue, count: 400) + Array(repeating: paleYellow, count: 400)
        let shadows = ColorGradingSwatches.swatches(from: pixels, for: .shadows, in: .init())
        let highlights = ColorGradingSwatches.swatches(from: pixels, for: .highlights, in: .init())
        #expect(shadows.count == 1 && shadows.first.map { isClose($0, darkBlue) } == true)
        #expect(highlights.count == 1 && highlights.first.map { isClose($0, paleYellow) } == true)
        #expect(ColorGradingSwatches.swatches(from: pixels, for: .global, in: .init()).count == 2)
        #expect(ColorGradingSwatches.swatches(from: [], for: .global, in: .init()).isEmpty)
    }

    private func makePanel() -> (AdjustmentsPanelViewController, Changes) {
        let panel = AdjustmentsPanelViewController()
        _ = panel.view
        panel.isEditingEnabled = true
        let changes = Changes()
        panel.onChange = { _, isFinal, action in changes.list.append((isFinal, action)) }
        var adjustments = PhotoAdjustments()
        adjustments.color.midtones = .init(hue: 0.5, amount: 0.1, luminance: 0.3)
        panel.display(adjustments, asShotWhiteBalance: (5500, 0))
        return (panel, changes)
    }

    @Test("Applying a color sets hue and saturation only, as one edit")
    func apply() {
        let (panel, changes) = makePanel()
        #expect(panel.applyGradingColor(RGB(1, 0, 0), to: .midtones))
        #expect(panel.adjustments.color.midtones == .init(hue: 0, amount: 1, luminance: 0.3), "luminance kept")
        #expect(changes.list.count == 1 && changes.list.first?.0 == true && changes.list.first?.1 == "Adjust Color Grading")

        #expect(!panel.applyGradingColor(RGB(0.5, 0.5, 0.5), to: .midtones), "a gray changes nothing")
        #expect(changes.list.count == 1)
        #expect(!panel.applyGradingColor(RGB(1, 0, 0), to: .all), "All has no wheel of its own")
    }

    @Test("Each single wheel has a well; All doesn't")
    func wells() {
        let (panel, _) = makePanel()
        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        let wells = allViews(panel.view).compactMap { $0 as? ColorGradingWellButton }.map { $0.accessibilityIdentifier() }
        #expect(Set(wells) == ["colorGradingWell.Shadows", "colorGradingWell.Midtones", "colorGradingWell.Highlights", "colorGradingWell.Global"])
        let midtones = allViews(panel.view).compactMap { $0 as? ColorGradingWellButton }.first { $0.accessibilityIdentifier() == "colorGradingWell.Midtones" }
        let tint = midtones?.color.usingColorSpace(.sRGB)
        #expect(tint.map { $0.greenComponent > $0.redComponent && abs($0.greenComponent - 0.5) < 0.1 } == true, "a faint cyan")
    }

    @Test("The popover offers the photo's colors; a swatch applies, the eyedropper asks to pick")
    func popover() async throws {
        let (panel, changes) = makePanel()
        let teal = RGB(0.1, 0.55, 0.5)
        panel.ungradedPixels = { Array(repeating: teal, count: 200) + Array(repeating: RGB(0.9, 0.2, 0.6), count: 50) }
        var picking: ColorGradingTab?
        panel.onPickGradingColor = { picking = $0 }

        panel.showColorWell(.global, from: nil)
        let content = try #require(panel.colorWellPopover)
        for _ in 0..<200 where content.swatches == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(content.swatches?.count == 2)
        #expect(content.swatchButtons.count == 2)

        let first = try #require(content.swatchButtons.first)
        _ = (first.target as AnyObject).perform(first.action, with: first)
        let expected = try #require(ColorGradingSwatches.wheel(for: teal))
        #expect(isClose(panel.adjustments.color.global.hue, expected.hue, 0.01) && isClose(panel.adjustments.color.global.amount, expected.amount))
        #expect(changes.list.count == 1)

        #expect(content.current == ColorGradingWellButton.tint(panel.adjustments.color.global), "the popover shows the picked color")

        let eyedropper = content.eyedropperButton
        _ = (eyedropper.target as AnyObject).perform(eyedropper.action, with: eyedropper)
        #expect(picking == .global)
    }

    @Test("Dragging the eyedropper out of the popover and letting go asks to pick the photo there")
    func eyedropperDrag() throws {
        let (panel, _) = makePanel()
        var dropped: (ColorGradingTab, NSPoint)?
        panel.onDropGradingColor = { dropped = ($0, $1) }
        panel.showColorWell(.highlights, from: nil)
        let content = try #require(panel.colorWellPopover)
        content.eyedropperButton.onDrop?(NSPoint(x: 120, y: 340))
        #expect(dropped?.0 == .highlights && dropped?.1 == NSPoint(x: 120, y: 340))
    }
}

private final class Changes {
    var list: [(Bool, String)] = []
}
