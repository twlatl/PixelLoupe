import AppKit

/// Covers the Develop preview while an eyedropper (defringe, white balance) is on: a crosshair, and
/// a click picks the spot under it.
final class FringePickerView: NSView {
    /// The clicked point, in this view's coordinates (which match the preview's).
    var onPick: (CGPoint) -> Void = { _ in }

    init(label: String = "Pick a fringe color on the photo", identifier: String = "fringePicker") {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        onPick(convert(event.locationInWindow, from: nil))
    }
}
