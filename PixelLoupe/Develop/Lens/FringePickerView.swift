import AppKit

/// Covers the Develop preview while an eyedropper (defringe, white balance) is on: a crosshair, and
/// a click picks the spot under it.
final class FringePickerView: NSView {
    /// The clicked point, in this view's coordinates (which match the preview's).
    var onPick: (CGPoint) -> Void = { _ in }
    /// The pointer over the preview while picking.
    let cursor: NSCursor

    init(label: String = "Pick a fringe color on the photo", identifier: String = "fringePicker", cursor: NSCursor = .crosshair) {
        self.cursor = cursor
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityIdentifier(identifier)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    /// The click that picks may also be the one that brings the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        onPick(convert(event.locationInWindow, from: nil))
    }
}
