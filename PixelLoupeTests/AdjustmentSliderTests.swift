import AppKit
import Testing
@testable import PixelLoupe

/// Double-clicking a side-panel slider's knob resets it, and Option-dragging moves it in large steps (RAW-77).
@MainActor
struct AdjustmentSliderTests {
    @Test func optionDragStepsAreATenthOfTheRangeFromTheDefault() {
        let exposure = AdjustmentSlider(value: 0, minValue: -5, maxValue: 5)
        #expect(exposure.largeStep == 1)
        #expect(exposure.stepped(0.4) == 0)
        #expect(exposure.stepped(0.6) == 1)
        #expect(exposure.stepped(-2.7) == -3)
        #expect(exposure.stepped(4.9) == 5)

        // Counted from the default, not the end of the range.
        let temperature = AdjustmentSlider(value: 5500, minValue: 2000, maxValue: 50000)
        #expect(temperature.largeStep == 4800)
        #expect(temperature.stepped(5600) == 5500)
        #expect(temperature.stepped(8000) == 5500 + 4800)
        #expect(temperature.stepped(2100) == 2000, "kept within the range")

        let amount = AdjustmentSlider(value: 100, minValue: 0, maxValue: 200)
        #expect(amount.stepped(131) == 140)
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
        #expect(values == [1, 1.4], "snapped to a whole step only while Option is held")
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
