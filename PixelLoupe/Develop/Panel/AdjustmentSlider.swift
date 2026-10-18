import AppKit

/// The slider used for adjustments in the side panels. Double-clicking its knob resets it to
/// `defaultValue`, and Option-dragging moves it in large steps: a tenth of its full range, counted
/// from `defaultValue` (so a −5…+5 slider steps by 1.00 and passes through 0).
class AdjustmentSlider: NSSlider {
    var defaultValue: Double = 0
    /// Called instead of sending the action when the knob is double-clicked, for an owner that records
    /// the reset itself (`SliderRow`).
    var onReset: (() -> Void)?

    convenience init(value: Double, minValue: Double, maxValue: Double, defaultValue: Double? = nil) {
        self.init(value: value, minValue: minValue, maxValue: maxValue, target: nil, action: nil)
        self.defaultValue = defaultValue ?? value
    }

    /// The size of an Option-drag step.
    var largeStep: Double { (maxValue - minValue) / 10 }

    /// `value` moved to the nearest large step from `defaultValue`, within the slider's range.
    func stepped(_ value: Double) -> Double {
        guard largeStep > 0 else { return value }
        let steps = ((value - defaultValue) / largeStep).rounded()
        return min(max(defaultValue + steps * largeStep, minValue), maxValue)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, isOnKnob(event) {
            resetToDefault()
            return
        }
        super.mouseDown(with: event)
    }

    /// Sets the default value and reports it: through `onReset`, or by sending the action, which
    /// `isFinalControlEvent()` treats as final because the event is the double-click.
    func resetToDefault() {
        if let onReset { return onReset() }
        doubleValue = defaultValue
        _ = sendAction(action, to: target)
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if NSApp.currentEvent?.type == .leftMouseDragged, NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            doubleValue = stepped(doubleValue)
        }
        return super.sendAction(action, to: target)
    }

    private func isOnKnob(_ event: NSEvent) -> Bool {
        guard let cell = cell as? NSSliderCell else { return false }
        // A little slack around the knob, which is small on these sliders.
        let knob = cell.knobRect(flipped: isFlipped).insetBy(dx: -3, dy: -3)
        return knob.contains(convert(event.locationInWindow, from: nil))
    }
}

/// A slider whose track is a color gradient, as Lightroom draws white balance's Temp (blue to
/// yellow) and Tint (green to magenta).
final class GradientSlider: AdjustmentSlider {
    convenience init(colors: [NSColor]) {
        self.init(frame: .zero)
        (cell as? GradientSliderCell)?.colors = colors
    }

    override class var cellClass: AnyClass? {
        get { GradientSliderCell.self }
        set {}
    }
}

final class GradientSliderCell: NSSliderCell {
    var colors: [NSColor] = []

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        guard colors.count >= 2, let gradient = NSGradient(colors: colors) else {
            return super.drawBar(inside: rect, flipped: flipped)
        }
        let bar = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
        let path = NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2)
        gradient.draw(in: path, angle: 0)
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}
