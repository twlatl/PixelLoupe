import AppKit
import Testing
@testable import PixelLoupe

/// A single click on a slider's value makes it editable (RAW-290), including Crop's Angle (RAW-291).
@MainActor
struct EditableValueLabelTests {
    private func window(with view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        return window
    }

    private func type(_ text: String, in window: NSWindow, ending command: Selector) throws {
        let editor = try #require(window.fieldEditor(false, for: nil) as? NSTextView)
        editor.string = text
        editor.doCommand(by: command)
    }

    @Test func aSingleClickStartsEditing() throws {
        let label = EditableValueLabel()
        let clicks = label.gestureRecognizers.compactMap { $0 as? NSClickGestureRecognizer }
        #expect(clicks.count == 1)
        #expect(clicks.first?.numberOfClicksRequired == 1)
        #expect(label.toolTip == "Click to enter a value")

        let row = SliderRow(title: "Exposure", range: -5...5)
        let rowLabel = try #require(row.subviews.compactMap { $0 as? EditableValueLabel }.first)
        #expect(rowLabel.gestureRecognizers.compactMap { ($0 as? NSClickGestureRecognizer)?.numberOfClicksRequired } == [1])
    }

    @Test func clicksWhileEditingDoNotRestartTheEdit() throws {
        let label = EditableValueLabel()
        label.frame = NSRect(x: 0, y: 0, width: 60, height: 20)
        let window = window(with: label)
        var ended: [String?] = []
        label.onEndEditing = { ended.append($0) }
        label.stringValue = "1.00"

        label.beginEditingValue()
        let click = try #require(label.gestureRecognizers.first)
        #expect(!click.isEnabled, "clicks in the field place the insertion point")
        try type("2", in: window, ending: #selector(NSResponder.insertNewline(_:)))
        #expect(click.isEnabled)
        #expect(ended == ["2"])

        label.beginEditingValue()
        try type("3", in: window, ending: #selector(NSResponder.cancelOperation(_:)))
        #expect(ended == ["2", nil], "Escape cancels")
    }

    @Test func typedAnglesAreClampedAndRounded() {
        #expect(CropPanelViewController.angle(forTyped: "12.345") == 12.35)
        #expect(CropPanelViewController.angle(forTyped: "\u{2212}3.5") == -3.5)
        #expect(CropPanelViewController.angle(forTyped: "90") == 45)
        #expect(CropPanelViewController.angle(forTyped: "-60") == -45)
        #expect(CropPanelViewController.angle(forTyped: "abc") == nil)
        #expect(CropPanelViewController.angle(forTyped: "") == nil)
    }

    @Test func returnEntersTheAngleAndEscapeKeepsTheOldOne() throws {
        let panel = CropPanelViewController()
        panel.view.frame = NSRect(x: 0, y: 0, width: 280, height: 360)
        let window = window(with: panel.view)
        panel.view.layoutSubtreeIfNeeded()
        var changes: [(Double, Bool)] = []
        panel.onChange = { crop, isFinal in changes.append((crop.angle, isFinal)) }
        let field = try #require(panel.view.firstDescendant(identifier: "cropAngleValue") as? EditableValueLabel)
        let slider = try #require(panel.view.firstDescendant(identifier: "cropAngle"))
        let sliderBefore = slider.frame

        panel.beginEditingAngle()
        #expect(panel.isEditingAngle)
        panel.view.layoutSubtreeIfNeeded()
        // Compared by the slider, not the field's frame: a label's frame overhangs its layout rect by 2pt a side and a
        // bezeled field's doesn't, though both are laid out at the same width. (The bezel is a little taller, so the
        // row may grow while the angle is typed; only the slider's length and position along the row matter here.)
        #expect(slider.frame.minX == sliderBefore.minX && slider.frame.width == sliderBefore.width,
                "the slider doesn't move or shrink when the value is edited")
        try type("-7.5", in: window, ending: #selector(NSResponder.insertNewline(_:)))
        #expect(!panel.isEditingAngle)
        #expect(panel.crop.angle == -7.5)
        #expect(field.stringValue == "-7.50")
        #expect(changes.count == 1 && changes[0].0 == -7.5 && changes[0].1, "a typed angle is final, for undo")

        panel.beginEditingAngle()
        try type("20", in: window, ending: #selector(NSResponder.cancelOperation(_:)))
        #expect(!panel.isEditingAngle)
        #expect(panel.crop.angle == -7.5)
        #expect(field.stringValue == "-7.50")
        #expect(changes.count == 1)

        panel.beginEditingAngle()
        try type("nope", in: window, ending: #selector(NSResponder.insertNewline(_:)))
        #expect(panel.crop.angle == -7.5)
        #expect(field.stringValue == "-7.50")
        #expect(changes.count == 1)
    }
}

private extension NSView {
    func firstDescendant(identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier { return self }
        for subview in subviews {
            if let found = subview.firstDescendant(identifier: identifier) { return found }
        }
        return nil
    }
}
