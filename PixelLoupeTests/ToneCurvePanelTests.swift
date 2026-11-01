import AppKit
import Testing
@testable import PixelLoupe

/// The Adjust panel's Tone Curve section (RAW-246).
@MainActor
struct ToneCurvePanelTests {
    @MainActor
    final class Changes {
        var list: [(isFinal: Bool, action: String)] = []
    }

    private func makePanel() -> (AdjustmentsPanelViewController, Changes) {
        let panel = AdjustmentsPanelViewController()
        panel.view.frame = NSRect(x: 0, y: 0, width: 300, height: 4000)
        panel.isEditingEnabled = true
        let changes = Changes()
        panel.onChange = { _, isFinal, action in changes.list.append((isFinal, action)) }
        panel.display(PhotoAdjustments(), asShotWhiteBalance: (5500, 0))
        panel.view.layoutSubtreeIfNeeded()
        return (panel, changes)
    }

    private func subview<View: NSView>(_ identifier: String, of type: View.Type, in view: NSView) -> View? {
        if let view = view as? View, view.accessibilityIdentifier() == identifier { return view }
        return view.subviews.lazy.compactMap { self.subview(identifier, of: type, in: $0) }.first
    }

    @Test("The section is called Tone Curve, as in Lightroom, and its edits are named for it")
    func renamed() throws {
        let (panel, changes) = makePanel()
        #expect(subview("adjustSection.Tone Curve", of: AdjustmentSectionView.self, in: panel.view) != nil)
        #expect(subview("adjustSection.Curves", of: AdjustmentSectionView.self, in: panel.view) == nil)
        #expect(subview("slider.Tone Curve.Darks", of: NSView.self, in: panel.view) != nil)

        let editor = try #require(subview("curveEditor", of: CurveEditorView.self, in: panel.view))
        editor.onChange?(ToneCurve(points: [.init(x: 0, y: 0.1), .init(x: 1, y: 1)]), true)
        #expect(changes.list.last?.action == "Adjust Tone Curve")
    }

    @Test("The curve graph is square")
    func square() throws {
        Defaults.store.set(true, forKey: "AdjustSectionExpanded.Tone Curve")
        defer { Defaults.store.removeObject(forKey: "AdjustSectionExpanded.Tone Curve") }
        let (panel, _) = makePanel()
        let editor = try #require(subview("curveEditor", of: CurveEditorView.self, in: panel.view))
        #expect(editor.bounds.width > 100)
        #expect(abs(editor.bounds.width - editor.bounds.height) < 0.5)
    }

    @Test("The Adjust buttons pick the curve, and a dot marks each changed curve")
    func modeButtons() throws {
        let (panel, _) = makePanel()
        let picker = try #require(subview("curveChannel", of: CurveModePicker.self, in: panel.view))
        let editor = try #require(subview("curveEditor", of: CurveEditorView.self, in: panel.view))
        #expect(picker.selectedIndex == 1 && editor.channel == .rgb && !editor.isParametric, "Point curve to start")
        #expect(picker.edited == [false, false, false, false, false])

        try #require(subview("curveMode.Red Channel", of: NSButton.self, in: panel.view)).performClick(nil)
        #expect(picker.selectedIndex == 2 && editor.channel == .red)
        editor.onChange?(ToneCurve(points: [.init(x: 0, y: 0.1), .init(x: 1, y: 1)]), true)
        #expect(picker.edited == [false, false, true, false, false])
        #expect(try #require(subview("curveMode.Red Channel", of: NSButton.self, in: panel.view)).accessibilityValue() as? String == "selected, edited")

        try #require(subview("curveMode.Parametric Curve", of: NSButton.self, in: panel.view)).performClick(nil)
        #expect(picker.selectedIndex == 0 && editor.isParametric)
        var parametric = ParametricCurve()
        parametric.darks = 0.4
        editor.onParametricChange?(parametric, true)
        #expect(picker.edited == [true, false, true, false, false])
    }

    @Test("The graph shows the photo's histogram: the channel's in R, G or B, all three added together otherwise")
    func histogram() throws {
        // Wide peaks: the scaling goes by the 5th-tallest bin, so a single-bin spike would run off the top.
        var red = [UInt32](repeating: 10, count: Histogram.binCount), green = red, blue = red
        for bin in 30...50 { red[bin] = 100 }
        for bin in 190...210 { green[bin] = 100; blue[bin] = 100 }
        let histogram = Histogram(red: red, green: green, blue: blue)

        let redHeights = CurveEditorView.histogramHeights(histogram, channel: .red)
        #expect(redHeights[40] > 0.9 && redHeights[200] < 0.2)
        let gray = CurveEditorView.histogramHeights(histogram, channel: .rgb)
        #expect(gray[40] > 0 && gray[200] > gray[40], "green and blue add up at 200")
        #expect(CurveEditorView.histogramHeights(histogram, channel: nil) == gray, "parametric shows the gray one")

        let (panel, _) = makePanel()
        let editor = try #require(subview("curveEditor", of: CurveEditorView.self, in: panel.view))
        panel.histogram = histogram
        #expect(editor.histogram == histogram)
        panel.histogram = nil
        #expect(editor.histogram == nil)
    }

    @Test("A section renamed keeps whether it was open")
    func renamedSectionKeepsExpansion() {
        let keys = ["AdjustSectionExpanded.Test.Old Name", "AdjustSectionExpanded.Test.New Name"]
        defer { for key in keys { Defaults.store.removeObject(forKey: key) } }
        for key in keys { Defaults.store.removeObject(forKey: key) }
        Defaults.store.set(true, forKey: keys[0])

        let section = AdjustmentSectionView(title: "New Name", symbolName: "circle", scope: "Test.", formerTitle: "Old Name")
        #expect(section.isExpanded)
        // Once the new name has its own setting, the old one no longer matters.
        Defaults.store.set(false, forKey: keys[0])
        Defaults.store.set(false, forKey: keys[1])
        #expect(!AdjustmentSectionView(title: "New Name", symbolName: "circle", scope: "Test.", formerTitle: "Old Name").isExpanded)
    }
}
