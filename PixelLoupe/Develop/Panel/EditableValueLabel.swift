import AppKit

/// A slider's value label that turns into a text field when clicked, for typing a new value (as in Lightroom).
/// Return, Tab or clicking elsewhere enters the typed text; Escape keeps the old value. The owner parses the text,
/// since only it knows the label's units, and shows its value again when the edit ends.
final class EditableValueLabel: NSTextField, NSTextFieldDelegate {
    /// Called when an edit ends: with the typed text when it was entered, or nil when Escape cancelled it.
    var onEndEditing: (String?) -> Void = { _ in }
    /// The field's width while it's edited, for a label with no fixed width: an editable field has no width of its
    /// own and would otherwise stretch across its row. Nil leaves the label's own constraints alone.
    var editingWidth: (() -> CGFloat)?
    /// Where keyboard focus goes when Escape cancels the edit (the slider, so arrow keys keep working).
    weak var focusAfterCancel: NSView?

    /// Whether the value is being typed.
    private(set) var isEditingValue = false
    private var cancelsEdit = false
    private lazy var editingWidthConstraint = widthAnchor.constraint(equalToConstant: 0)
    private lazy var click = NSClickGestureRecognizer(target: self, action: #selector(beginEditingValue))

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textColor = .secondaryLabelColor
        alignment = .right
        delegate = self
        toolTip = "Click to enter a value"
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Makes the label a text field with its text selected, for typing a new value.
    @objc func beginEditingValue() {
        guard !isEditingValue, let window else { return }
        isEditingValue = true
        cancelsEdit = false
        // Clicks while editing place the insertion point rather than starting another edit.
        click.isEnabled = false
        isEditable = true
        isSelectable = true
        isBezeled = true
        bezelStyle = .squareBezel
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textColor = .labelColor
        if let editingWidth {
            editingWidthConstraint.constant = editingWidth()
            editingWidthConstraint.isActive = true
        }
        window.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }

    override func accessibilityPerformPress() -> Bool {
        beginEditingValue()
        return true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(cancelOperation(_:)) else { return false }
        cancelsEdit = true
        window?.makeFirstResponder(focusAfterCancel)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard isEditingValue else { return }
        isEditingValue = false
        let typed = stringValue
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        editingWidthConstraint.isActive = false
        click.isEnabled = true
        onEndEditing(cancelsEdit ? nil : typed)
    }
}
