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

    @Test("Point Curve presets: Lightroom's points, recognized from the curves (rounding allowed), and written back")
    func pointCurvePresets() {
        #expect(PointCurvePreset.mediumContrast.curve.points.map { ($0.x * 255).rounded() } == [0, 32, 64, 128, 192, 255])
        #expect(PointCurvePreset.strongContrast.curve.points.map { ($0.y * 255).rounded() } == [0, 16, 50, 128, 202, 255])

        var curves = PhotoAdjustments.Curves()
        #expect(curves.pointCurvePreset == .linear)
        curves.apply(.strongContrast)
        #expect(curves.pointCurvePreset == .strongContrast && curves.pointCurveName == "Strong Contrast")
        // A catalog's 0…255 points, as imported.
        curves.rgb = ToneCurve(points: [(0, 0), (32, 22), (64, 56), (128, 128), (192, 196), (255, 255)].map { .init(x: $0 / 255, y: $1 / 255) })
        #expect(curves.pointCurvePreset == .mediumContrast)
        curves.blue = ToneCurve(points: [.init(x: 0, y: 0.1), .init(x: 1, y: 1)])
        #expect(curves.pointCurvePreset == nil && curves.pointCurveName == "Custom", "an edited channel makes it Custom")
        curves.apply(.linear)
        #expect(curves.blue.isIdentity && curves.rgb.isIdentity && curves.pointCurveName == "Linear")

        var photo = PhotoAdjustments()
        photo.curves.apply(.mediumContrast)
        #expect(PresetWriter.settings(for: photo, sections: [.toneCurve])["ToneCurveName2012"] == .text("Medium Contrast"))
    }

    @Test("Choosing a Point Curve preset replaces the point curve and resets the channels, as one edit")
    func pointCurveMenu() throws {
        let (panel, changes) = makePanel()
        let popUp = try #require(subview("pointCurvePopUp", of: NSPopUpButton.self, in: panel.view))
        #expect(popUp.titleOfSelectedItem == "Linear")
        #expect(popUp.itemTitles == ["Linear", "Medium Contrast", "Strong Contrast", "", "Custom"])

        let editor = try #require(subview("curveEditor", of: CurveEditorView.self, in: panel.view))
        try #require(subview("curveMode.Green Channel", of: NSButton.self, in: panel.view)).performClick(nil)
        editor.onChange?(ToneCurve(points: [.init(x: 0, y: 0.1), .init(x: 1, y: 1)]), true)
        #expect(popUp.titleOfSelectedItem == "Custom")

        changes.list.removeAll()
        popUp.selectItem(withTitle: "Strong Contrast")
        _ = popUp.target?.perform(popUp.action, with: popUp)
        #expect(panel.adjustments.curves.pointCurvePreset == .strongContrast)
        #expect(panel.adjustments.curves.green.isIdentity && editor.curve.isIdentity, "the green curve shown is reset")
        #expect(changes.list.count == 1 && changes.list.first?.isFinal == true && changes.list.first?.action == "Adjust Tone Curve")
        #expect(popUp.titleOfSelectedItem == "Strong Contrast", "the same whichever channel is selected")

        // Custom changes nothing.
        popUp.selectItem(withTitle: "Custom")
        _ = popUp.target?.perform(popUp.action, with: popUp)
        #expect(changes.list.count == 1 && popUp.titleOfSelectedItem == "Strong Contrast")

        try #require(subview("curveMode.Parametric Curve", of: NSButton.self, in: panel.view)).performClick(nil)
        #expect(popUp.superview?.isHidden == true, "not shown with the parametric curve")
    }

    @Test("Input and Output show the selected point in 0…255, and typing moves it")
    func inputOutput() throws {
        let (panel, changes) = makePanel()
        let window = NSWindow(contentRect: panel.view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = panel.view
        panel.view.layoutSubtreeIfNeeded()
        let editor = try #require(subview("curveEditor", of: CurveEditorView.self, in: panel.view))
        let input = try #require(subview("curveInput", of: NSTextField.self, in: panel.view))
        let output = try #require(subview("curveOutput", of: NSTextField.self, in: panel.view))
        #expect(!input.isEnabled && input.stringValue.isEmpty && !output.isEnabled, "nothing selected")

        // Click the graph at (64, 96).
        let plot = editor.bounds.insetBy(dx: 6, dy: 6)
        let location = editor.convert(NSPoint(x: plot.minX + plot.width * 64 / 255, y: plot.minY + plot.height * 96 / 255), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            type == .leftMouseDown ? editor.mouseDown(with: event) : editor.mouseUp(with: event)
        }
        #expect(input.isEnabled && abs(input.integerValue - 64) <= 1 && abs(output.integerValue - 96) <= 1)

        changes.list.removeAll()
        output.stringValue = "150"
        _ = output.target?.perform(output.action, with: output)
        #expect(output.integerValue == 150 && editor.selectedPoint.map(CurveEditorView.levels)?.output == 150)
        #expect(panel.adjustments.curves.rgb == editor.curve)
        #expect(changes.list.count == 1 && changes.list.first?.isFinal == true && changes.list.first?.action == "Adjust Tone Curve")

        try #require(subview("curveMode.Parametric Curve", of: NSButton.self, in: panel.view)).performClick(nil)
        #expect(input.superview?.isHidden == true, "not shown with the parametric curve")
    }

    @Test("Parametric mode: the split bar shows, and the region under the pointer bolds its slider's title")
    func parametricPanel() throws {
        let (panel, changes) = makePanel()
        let bar = try #require(subview("parametricSplits", of: ParametricSplitBar.self, in: panel.view))
        let editor = try #require(subview("curveEditor", of: CurveEditorView.self, in: panel.view))
        #expect(bar.isHidden, "not with the point curve")
        try #require(subview("curveMode.Parametric Curve", of: NSButton.self, in: panel.view)).performClick(nil)
        #expect(!bar.isHidden)

        editor.onHighlightRegion?(1)
        let darks = try #require(subview("slider.Tone Curve.Darks", of: SliderRow.self, in: panel.view))
        let lights = try #require(subview("slider.Tone Curve.Lights", of: SliderRow.self, in: panel.view))
        #expect(darks.isEmphasized && !lights.isEmphasized)
        editor.onHighlightRegion?(nil)
        #expect(!darks.isEmphasized)

        var moved = panel.adjustments.curves.parametric
        moved.setSplit(2, to: 0.8)
        bar.onChange?(moved, true)
        #expect(panel.adjustments.curves.parametric.highlightSplit == 0.8)
        #expect(changes.list.last?.action == "Adjust Tone Curve" && changes.list.last?.isFinal == true)
        #expect(editor.parametric.highlightSplit == 0.8, "the graph follows")
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
