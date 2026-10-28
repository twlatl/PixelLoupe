import AppKit

/// The slider used for adjustments in the side panels. Double-clicking its knob resets it to
/// `defaultValue`; Option-dragging snaps to its ticks (`MonochromeSlider`).
class AdjustmentSlider: MonochromeSlider {
    var defaultValue: Double = 0
    /// Called instead of sending the action when the knob is double-clicked, for an owner that records
    /// the reset itself (`SliderRow`).
    var onReset: (() -> Void)?

    convenience init(value: Double, minValue: Double, maxValue: Double, defaultValue: Double? = nil) {
        self.init(value: value, minValue: minValue, maxValue: maxValue, target: nil, action: nil)
        self.defaultValue = defaultValue ?? value
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

    private func isOnKnob(_ event: NSEvent) -> Bool {
        guard let cell = cell as? NSSliderCell else { return false }
        // A little slack around the knob, which is small on these sliders.
        let knob = cell.knobRect(flipped: isFlipped).insetBy(dx: -3, dy: -3)
        return knob.contains(convert(event.locationInWindow, from: nil))
    }
}

/// A slider whose track is a color gradient, as Lightroom draws white balance's Temp (blue to
/// yellow) and Tint (green to magenta). Only the track differs from `MonochromeSlider`.
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

final class GradientSliderCell: MonochromeSliderCell {
    var colors: [NSColor] = []

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        guard colors.count >= 2, let gradient = NSGradient(colors: colors) else {
            return super.drawBar(inside: rect, flipped: flipped)
        }
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        gradient.draw(in: path, angle: 0)
        NSColor.separatorColor.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}
