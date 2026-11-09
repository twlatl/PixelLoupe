import AppKit
import Testing
@testable import PixelLoupe

@Suite("Color Grading panel: tabs, units and dots", .serialized)
@MainActor
struct ColorGradingPanelTests {
    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    private func view<T: NSView>(_ identifier: String, in panel: AdjustmentsPanelViewController, as type: T.Type = NSView.self) throws -> T {
        try #require(allViews(panel.view).first { $0.accessibilityIdentifier() == identifier } as? T)
    }

    private func makePanel(scope: AdjustmentsPanelViewController.Scope = .photo) -> AdjustmentsPanelViewController {
        let panel = AdjustmentsPanelViewController(scope: scope)
        _ = panel.view
        panel.isEditingEnabled = true
        return panel
    }

    /// Picks `tab` in the panel's picker as a click would.
    private func pick(_ tab: ColorGradingTab, in panel: AdjustmentsPanelViewController, scope: String = "") throws {
        let picker = try view("\(scope)colorGradingTab", in: panel, as: NSSegmentedControl.self)
        picker.selectedSegment = tab.rawValue
        _ = (picker.target as AnyObject).perform(picker.action, with: picker)
    }

    /// Whether the page holding `identifier` is shown, whether or not its section is collapsed.
    private func isShown(_ identifier: String, in panel: AdjustmentsPanelViewController) throws -> Bool {
        var view: NSView? = try self.view(identifier, in: panel)
        while let current = view, !allViews(panel.view).contains(where: { ($0 as? AdjustmentSectionView)?.contentStack === current }) {
            if current.isHidden { return false }
            view = current.superview
        }
        return true
    }

    // MARK: Model

    @Test("A tab is marked when its wheel tints or shifts luminance; Blending, Balance and All never mark")
    func marking() {
        var color = PhotoAdjustments.ColorGrading()
        #expect(ColorGradingTab.allCases.allSatisfy { !$0.isMarked(in: color) })
        color.blending = 0.2
        color.balance = 0.4
        color.shadows.hue = 0.3 // a hue with no strength does nothing
        #expect(ColorGradingTab.allCases.allSatisfy { !$0.isMarked(in: color) })
        color.shadows.amount = 0.1
        color.global.luminance = -0.2
        #expect(ColorGradingTab.allCases.filter { $0.isMarked(in: color) } == [.shadows, .global])
        color.midtones.amount = 0.5
        color.highlights.luminance = 0.1
        #expect(!ColorGradingTab.all.isMarked(in: color))
    }

    @Test("The picked tab is remembered and announced, starting at All")
    func rememberedTab() {
        let saved = ColorGradingTab.current
        defer { ColorGradingTab.current = saved }
        Defaults.store.removeObject(forKey: ColorGradingTab.defaultsKey)
        #expect(ColorGradingTab.current == .all)
        let posts = Counter()
        let observer = NotificationCenter.default.addObserver(forName: ColorGradingTab.didChangeNotification, object: nil, queue: nil) { _ in
            posts.count += 1
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        ColorGradingTab.current = .highlights
        ColorGradingTab.current = .highlights
        #expect(ColorGradingTab.current == .highlights)
        #expect(posts.count == 1, "picking the same tab again isn't a change")
    }

    // MARK: Units

    @Test("Sliders show and take Lightroom's units")
    func units() {
        typealias Panel = AdjustmentsPanelViewController
        #expect(Panel.degrees(189.0 / 360) == "189")
        #expect(Panel.percent(0.14) == "14")
        #expect(Panel.signedPercent(-0.25) == "-25" && Panel.signedPercent(0.001) == "0")

        let hue = SliderRow(title: "Hue", range: 0...1, format: Panel.degrees)
        #expect(hue.value(forDisplayed: "180") == 0.5)
        #expect(hue.value(forDisplayed: "400") == 1, "clamped to the wheel")
        let saturation = SliderRow(title: "Saturation", range: 0...1, format: Panel.percent)
        #expect(saturation.value(forDisplayed: "30") == 0.3)
        let luminance = SliderRow(title: "Luminance", range: -1...1, format: Panel.signedPercent)
        #expect(luminance.value(forDisplayed: "-40") == -0.4)
        let blending = SliderRow(title: "Blending", range: 0...1, defaultValue: 0.5, format: Panel.percent)
        #expect(blending.displayedValue == "50")
    }

    // MARK: Panel

    @Test("Each tab shows its own controls; Global has no Blending or Balance")
    func tabsShowTheirControls() throws {
        let saved = ColorGradingTab.current
        defer { ColorGradingTab.current = saved }
        let panel = makePanel()
        try pick(.all, in: panel)
        #expect(try isShown("colorWheel.Midtones", in: panel) && isShown("colorWheel.Shadows", in: panel))
        #expect(try !isShown("colorWheel.Shadows.single", in: panel))
        #expect(try isShown("slider.Color Grading.Blending", in: panel))

        try pick(.shadows, in: panel)
        #expect(try isShown("colorWheel.Shadows.single", in: panel) && isShown("slider.Color Grading.Shadows.Hue", in: panel))
        #expect(try !isShown("colorWheel.Midtones", in: panel) && !isShown("colorWheel.Highlights.single", in: panel))
        #expect(try isShown("slider.Color Grading.Balance", in: panel))

        try pick(.global, in: panel)
        #expect(try isShown("colorWheel.Global.single", in: panel) && isShown("slider.Color Grading.Global.Luminance", in: panel))
        #expect(try !isShown("slider.Color Grading.Blending", in: panel) && !isShown("slider.Color Grading.Balance", in: panel))
        #expect(ColorGradingTab.current == .global)
    }

    @Test("A wheel's sliders edit it, the All tab follows, and its dot appears")
    func slidersEditTheWheel() throws {
        let saved = ColorGradingTab.current
        defer { ColorGradingTab.current = saved }
        let panel = makePanel()
        var changes: [(PhotoAdjustments, Bool, String)] = []
        panel.onChange = { changes.append(($0, $1, $2)) }
        panel.display(PhotoAdjustments(), asShotWhiteBalance: (5500, 0))
        try pick(.shadows, in: panel)

        let dots = try #require(allViews(panel.view).compactMap { $0 as? SegmentDotsView }.first)
        #expect(dots.marked == [false, false, false, false, false])

        let saturation = try view("slider.Color Grading.Shadows.Saturation", in: panel, as: SliderRow.self)
        let hue = try view("slider.Color Grading.Shadows.Hue", in: panel, as: SliderRow.self)
        hue.onChange?(0.5, false)
        saturation.onChange?(0.3, true)
        #expect(panel.adjustments.color.shadows == .init(hue: 0.5, amount: 0.3))
        #expect(changes.last?.1 == true && changes.last?.2 == "Adjust Color Grading", "one undoable edit")
        #expect(dots.marked == [false, true, false, false, false])

        let single = try view("colorWheel.Shadows.single", in: panel, as: ColorWheelView.self)
        let inAll = try view("colorWheel.Shadows", in: panel, as: ColorWheelView.self)
        #expect(single.hue == 0.5 && single.amount == 0.3)
        #expect(inAll.hue == 0.5 && inAll.amount == 0.3, "the All tab's wheel follows")

        // Dragging the wheel moves the sliders.
        single.onChange?(0.25, 0.6, true)
        #expect(hue.displayedValue == "90" && saturation.displayedValue == "60")
    }

    @Test("A mask's panel shows the tab picked in the photo's")
    func masksShareTheTab() throws {
        let saved = ColorGradingTab.current
        defer { ColorGradingTab.current = saved }
        let photo = makePanel()
        let mask = makePanel(scope: .mask)
        try pick(.midtones, in: photo)
        let maskPicker = try view("Mask.colorGradingTab", in: mask, as: NSSegmentedControl.self)
        #expect(maskPicker.selectedSegment == ColorGradingTab.midtones.rawValue)
        #expect(try isShown("colorWheel.Mask.Midtones.single", in: mask))
        try pick(.global, in: mask, scope: "Mask.")
        #expect(try isShown("colorWheel.Global.single", in: photo))
    }
}

/// Counts notifications posted on the main thread.
nonisolated private final class Counter: @unchecked Sendable {
    var count = 0
}
