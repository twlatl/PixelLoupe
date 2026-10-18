import AppKit

/// Decides whether a field may take keyboard focus: only when clicked, or when asked to
/// (`allowsFocusOnce`, for a menu command like ⌘K). AppKit otherwise hands focus to the first
/// editable field when the view changes (enlarging a photo, switching modules), and Tab would
/// reach it too.
@MainActor
private func mayTakeFocus(_ view: NSView, allowed: Bool) -> Bool {
    if allowed { return true }
    // AppKit makes a clicked view first responder while handling the mouse-down.
    guard let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .rightMouseDown,
          event.window === view.window else { return false }
    return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
}

/// A text field that takes keyboard focus only when clicked or asked to, never on its own, and is
/// left out of the Tab order (Tab toggles the sidebars). Used for the right sidebar's Keywords and
/// Metadata fields.
class ClickToFocusTextField: NSTextField {
    var allowsFocusOnce = false

    override var acceptsFirstResponder: Bool { mayTakeFocus(self, allowed: allowsFocusOnce) }

    /// Also refuses code that makes it first responder directly (which skips `acceptsFirstResponder`).
    override func becomeFirstResponder() -> Bool {
        mayTakeFocus(self, allowed: allowsFocusOnce) && super.becomeFirstResponder()
    }

    override var canBecomeKeyView: Bool { false }
}

/// The same, for search fields (the sidebar's Filter Collections).
class ClickToFocusSearchField: NSSearchField {
    var allowsFocusOnce = false

    override var acceptsFirstResponder: Bool { mayTakeFocus(self, allowed: allowsFocusOnce) }

    override func becomeFirstResponder() -> Bool {
        mayTakeFocus(self, allowed: allowsFocusOnce) && super.becomeFirstResponder()
    }

    override var canBecomeKeyView: Bool { false }
}
