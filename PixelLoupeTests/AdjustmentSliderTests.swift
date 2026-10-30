import AppKit
import SwiftUI
import Testing
@testable import PixelLoupe

/// Double-clicking a side-panel slider's knob resets it (RAW-77), and Option-dragging any slider snaps to its tick marks,
/// which mark every tenth of the range (RAW-201).
@MainActor
struct AdjustmentSliderTests {
    @Test func optionDragSnapsToTicksAtEveryTenthOfTheRange() {
        let exposure = AdjustmentSlider(value: 0, minValue: -5, maxValue: 5)
        #expect(exposure.numberOfTickMarks == 11)
        #expect(exposure.snapped(0.4) == 0)
        #expect(exposure.snapped(0.6) == 1)
        #expect(exposure.snapped(-2.7) == -3)
        #expect(exposure.snapped(4.9) == 5)

        // One-sided ranges count from their low end, not from the default.
        let amount = AdjustmentSlider(value: 100, minValue: 0, maxValue: 200)
        #expect(amount.snapped(131) == 140)
        let opacity = AdjustmentSlider(value: 1, minValue: 0, maxValue: 1)
        #expect(abs(opacity.snapped(0.33) - 0.3) < 1e-9)

        // A logarithmic row's ticks are tenths of the track, not of the kelvin range.
        let temperature = SliderRow(title: "Temp", range: 2000...50000, defaultValue: 5500, scale: .logarithmic(2000...50000))
        #expect(abs(temperature.slider.snapped(0.27) - 0.3) < 1e-9)
    }

    @Test func navigationSlidersHaveNoTicksAndDoNotSnap() throws {
        let zoom = MonochromeSlider(value: 0.37, minValue: 0, maxValue: 1, target: nil, action: nil)
        zoom.numberOfTickMarks = 0
        #expect(zoom.snapped(0.37) == 0.37)
        let cell = try #require(zoom.cell as? MonochromeSliderCell)
        let withTicks = try #require(MonochromeSlider(frame: .zero).cell as? MonochromeSliderCell)
        #expect(cell.cellSize.height < withTicks.cellSize.height, "no room kept for ticks")
    }

    @Test func theMiddleTickIsLongerOnlyWhenItIsZero() throws {
        let tint = AdjustmentSlider(value: 0, minValue: -1, maxValue: 1)
        tint.frame = NSRect(x: 0, y: 0, width: 200, height: 22)
        let bipolar = try #require(tint.cell as? MonochromeSliderCell)
        #expect(bipolar.isBipolar)
        #expect(bipolar.rectOfTickMark(at: 5).height > bipolar.rectOfTickMark(at: 4).height)
        #expect(bipolar.rectOfTickMark(at: 0).height == bipolar.rectOfTickMark(at: 10).height)

        for (low, high) in [(0.0, 1.0), (0, 2), (-1, 3)] {
            let slider = AdjustmentSlider(value: low, minValue: low, maxValue: high)
            #expect((slider.cell as? MonochromeSliderCell)?.isBipolar == false)
        }
    }

    @Test func ticksLineUpWithTheKnobAtTheirValues() throws {
        let slider = AdjustmentSlider(value: 0, minValue: -5, maxValue: 5)
        slider.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        let cell = try #require(slider.cell as? MonochromeSliderCell)
        for index in [0, 3, 5, 10] {
            slider.doubleValue = slider.tickMarkValue(at: index)
            let knob = cell.knobRect(flipped: slider.isFlipped)
            #expect(abs(knob.midX - cell.rectOfTickMark(at: index).midX) <= 0.5)
            #expect(knob.minX >= 0 && knob.maxX <= 240, "the knob stays inside the slider")
            #expect(cell.rectOfTickMark(at: index).minY >= knob.maxY || cell.rectOfTickMark(at: index).maxY <= knob.minY,
                    "ticks sit under the knob, not across the track")
        }
    }

    @Test func draggingPutsTheKnobUnderThePointer() throws {
        let slider = AdjustmentSlider(value: 0, minValue: -5, maxValue: 5)
        slider.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        let cell = try #require(slider.cell as? MonochromeSliderCell)
        let knob = cell.knobRect(flipped: slider.isFlipped)
        let start = NSPoint(x: knob.midX, y: knob.midY)
        for (index, value) in [(8, 3.0), (0, -5), (10, 5)] {
            slider.doubleValue = 0
            let end = NSPoint(x: cell.rectOfTickMark(at: index).midX, y: knob.midY)
            #expect(cell.startTracking(at: start, in: slider))
            _ = cell.continueTracking(last: start, current: end, in: slider)
            cell.stopTracking(last: end, current: end, in: slider, mouseIsUp: true)
            #expect(abs(slider.doubleValue - value) < 0.1, "the knob follows the pointer to the \(value) tick: \(slider.doubleValue)")
        }
    }

    @Test func swiftUISlidersTickAtTheirStepsWhenThereAreFewEnough() {
        var value = 0.0
        let binding = Binding(get: { value }, set: { value = $0 })
        let columns = MonochromeSliderView(value: binding, range: 1...10, step: 1, label: "Image Size")
        #expect(columns.tickCount == 10)
        let quality = MonochromeSliderView(value: binding, range: 10...100, step: 5, label: "JPEG Quality")
        #expect(quality.tickCount == 11)
        #expect(quality.stepped(37) == 35 && quality.stepped(99) == 100)
        let matte = MonochromeSliderView(value: binding, range: 0...1, label: "Matte")
        #expect(matte.tickCount == 11 && matte.stepped(0.37) == 0.37)
        let zoom = MonochromeSliderView(value: binding, range: 0...1, showsTicks: false, label: "Zoom")
        #expect(zoom.tickCount == 0)
    }

    @Test func doubleClickingTheKnobResetsTheRow() throws {
        let row = SliderRow(title: "Exposure", range: -5...5)
        row.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        let window = NSWindow(contentRect: row.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = row
        row.layoutSubtreeIfNeeded()
        row.value = 2.5
        var changes: [(Double, Bool)] = []
        row.onChange = { changes.append(($0, $1)) }

        let slider = row.slider
        let cell = try #require(slider.cell as? NSSliderCell)
        let knob = cell.knobRect(flipped: slider.isFlipped)
        let point = slider.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        slider.mouseDown(with: event)

        #expect(row.value == 0)
        #expect(changes.count == 1 && changes[0].0 == 0 && changes[0].1, "one final change, saved and undoable")
    }

    @Test func aChangedValueIsShownBrightAndADefaultOneDimmed() {
        let row = SliderRow(title: "Exposure", range: -5...5)
        let label = { (row.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == row.displayedValue })?.textColor }
        #expect(!row.isModified && label() == .secondaryLabelColor)
        row.value = 0.35
        #expect(row.isModified && label() == .labelColor)
        row.value = 0.001
        #expect(!row.isModified && label() == .secondaryLabelColor, "a value that shows as the default is the default")

        let temperature = SliderRow(title: "Temp", range: 2000...50000, defaultValue: 5500, format: { "\(Int($0.rounded()))" }, scale: .logarithmic(2000...50000))
        #expect(!temperature.isModified, "the logarithmic round trip doesn't count as a change")
        temperature.value = 6500
        #expect(temperature.isModified)
        temperature.defaultValue = 6500
        #expect(!temperature.isModified, "a new default counts too")
    }

    @Test func optionDraggingSnapsTheValueItSends() throws {
        let slider = AdjustmentSlider(value: 0, minValue: -5, maxValue: 5)
        var values: [Double] = []
        let target = ActionTarget { values.append(($0 as! NSSlider).doubleValue) }
        slider.target = target
        slider.action = #selector(ActionTarget.fire(_:))

        /// Makes a drag (with or without Option) the event being handled, as it is while the knob is dragged.
        func drag(option: Bool) throws {
            let event = try #require(NSEvent.mouseEvent(
                with: .leftMouseDragged, location: .zero, modifierFlags: option ? [.option] : [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.postEvent(event, atStart: true)
            // Never waits long: a test running alongside could take the event first.
            let current = NSApp.nextEvent(matching: .leftMouseDragged, until: Date(timeIntervalSinceNow: 1), inMode: .default, dequeue: true)
            try #require(current?.modifierFlags.contains(.option) == option)
        }

        try drag(option: true)
        slider.doubleValue = 1.4
        _ = slider.sendAction(slider.action, to: slider.target)
        try drag(option: false)
        slider.doubleValue = 1.4
        _ = slider.sendAction(slider.action, to: slider.target)
        #expect(values == [1, 1.4], "snapped to a tick only while Option is held")
    }

    @Test func aDoubleClickIsAFinalChange() throws {
        // The second click's mouse-down is when the knob is reset; a plain mouse-down is the start of a drag.
        let double = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        let single = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(isFinalControlEvent(double))
        #expect(!isFinalControlEvent(single))
    }
}

/// Double-clicking a slider row's value lets you type one (RAW-232).
@MainActor
struct SliderValueEntryTests {
    @Test func typedNumbersAreInTheUnitsTheLabelShows() throws {
        let exposure = SliderRow(title: "Exposure", range: -5...5)
        #expect(try #require(exposure.value(forDisplayed: "+1.50")) == 1.5)
        #expect(try #require(exposure.value(forDisplayed: "-2")) == -2)

        let feather = SliderRow(title: "Feather", range: 0...1, format: { String(format: "%.0f", $0 * 100) })
        #expect(abs(try #require(feather.value(forDisplayed: "50")) - 0.5) < 1e-9)
        let sharpen = SliderRow(title: "Amount", range: 0...1, format: { String(format: "%.0f", $0 * 150) })
        #expect(abs(try #require(sharpen.value(forDisplayed: "75")) - 0.5) < 1e-9)

        let strength = SliderRow(title: "Strength", range: 0...1, format: RimLightPanelViewController.percent)
        #expect(abs(try #require(strength.value(forDisplayed: "25%")) - 0.25) < 1e-9)
        let angle = SliderRow(title: "Angle", range: -180...180, format: RimLightPanelViewController.degrees)
        #expect(try #require(angle.value(forDisplayed: "−45°")) == -45)
    }

    @Test func kelvinAndTintParseTheirLabels() throws {
        let temperature = SliderRow(
            title: "Temp", range: WhiteBalanceEstimator.temperatureRange, defaultValue: 6500,
            format: AdjustmentsPanelViewController.temperatureText, scale: .logarithmic(WhiteBalanceEstimator.temperatureRange)
        )
        #expect(abs(try #require(temperature.value(forDisplayed: "5500")) - 5500) < 1e-6)
        #expect(abs(try #require(temperature.value(forDisplayed: temperature.displayedValue)) - 6500) < 1e-6)

        let tint = SliderRow(title: "Tint", range: WhiteBalanceEstimator.tintRange, format: AdjustmentsPanelViewController.tintText)
        #expect(try #require(tint.value(forDisplayed: "\u{2212}22")) == -22)
    }

    @Test func outOfRangeValuesClampAndNonNumbersAreIgnored() {
        let exposure = SliderRow(title: "Exposure", range: -5...5)
        #expect(exposure.value(forDisplayed: "12") == 5)
        #expect(exposure.value(forDisplayed: "-12") == -5)
        #expect(exposure.value(forDisplayed: "") == nil)
        #expect(exposure.value(forDisplayed: "abc") == nil)
    }

    @Test func returnEntersTheValueAndEscapeKeepsTheOldOne() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        let row = SliderRow(title: "Exposure", range: -5...5)
        row.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        window.contentView?.addSubview(row)
        var changes: [(Double, Bool)] = []
        row.onChange = { changes.append(($0, $1)) }

        row.beginEditingValue()
        #expect(row.isEditingValue)
        let editor = try #require(window.fieldEditor(false, for: nil) as? NSTextView)
        editor.string = "1.25"
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(!row.isEditingValue)
        #expect(row.value == 1.25)
        #expect(row.displayedValue == "+1.25")
        #expect(changes.count == 1 && changes[0].0 == 1.25 && changes[0].1, "a typed value is final, for undo")

        row.beginEditingValue()
        let escapeEditor = try #require(window.fieldEditor(false, for: nil) as? NSTextView)
        escapeEditor.string = "3"
        escapeEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!row.isEditingValue)
        #expect(row.value == 1.25)
        #expect(row.displayedValue == "+1.25")
        #expect(changes.count == 1)
    }
}
