import AppKit

/// Keywords as pills, with a text field to add more: type a keyword and a comma (or Return) to
/// add it. Each pill has a close button on its left that removes the keyword. Keywords on only some
/// of the selected photos are dimmed and marked with an asterisk, as in Lightroom.
///
/// AppKit's token field has no close buttons, which the design calls for, so this is custom.
final class KeywordField: NSView, NSTextFieldDelegate {
    struct Keyword: Equatable {
        /// The keyword's own name, shown on its pill.
        var name: String
        /// Its full path (`Places > Ireland`), shown as a tooltip and used to remove it.
        var path: String
        /// On every selected photo (otherwise only some).
        var isOnAll = true
    }

    var keywords: [Keyword] = [] {
        didSet {
            guard keywords != oldValue else { return }
            rebuildPills()
        }
    }

    var isEnabled = true {
        didSet {
            input.isEnabled = isEnabled
            pills.forEach { $0.closeButton.isEnabled = isEnabled }
        }
    }

    var onAdd: ([String]) -> Void = { _ in }
    /// Called with the keyword's path.
    var onRemove: (String) -> Void = { _ in }

    private let input = ClickToFocusTextField()
    private var pills: [Pill] = []
    private let spacing: CGFloat = 5
    private var laidOutHeight: CGFloat = 24

    override init(frame: NSRect) {
        super.init(frame: frame)
        input.placeholderString = "Add keywords"
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        input.delegate = self
        input.target = self
        input.action = #selector(commit(_:))
        input.setAccessibilityLabel("Add keywords")
        input.setAccessibilityIdentifier("keywordInput")
        addSubview(input)
        setAccessibilityElement(false)
        setAccessibilityIdentifier("keywordField")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    // MARK: - Entering keywords

    /// A comma ends a keyword.
    func controlTextDidChange(_ notification: Notification) {
        guard input.stringValue.contains(",") else { return }
        var parts = input.stringValue.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let unfinished = parts.removeLast()
        input.stringValue = unfinished
        add(parts)
    }

    @objc private func commit(_ sender: NSTextField) {
        let text = input.stringValue
        input.stringValue = ""
        add([text])
    }

    private func add(_ texts: [String]) {
        let names = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return }
        onAdd(names)
    }

    /// Lets tests and the window type into the field.
    func enter(_ text: String) {
        input.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: input))
    }

    func commitTyping() { commit(input) }

    /// Puts the cursor in the field (Photo ▸ Add Keywords, ⌘K). Otherwise it only takes focus when
    /// clicked, never on its own (when the window opens, the panel appears or Tab is pressed).
    func focus() {
        input.allowsFocusOnce = true
        defer { input.allowsFocusOnce = false }
        window?.makeFirstResponder(input)
    }

    /// Whether the cursor is in the field.
    var isFocused: Bool {
        guard let editor = input.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    /// The text field, for tests.
    var inputField: NSTextField { input }

    // MARK: - Pills

    private func rebuildPills() {
        pills.forEach { $0.removeFromSuperview() }
        pills = keywords.map { keyword in
            let pill = Pill(keyword: keyword)
            pill.closeButton.target = self
            pill.closeButton.action = #selector(removePill(_:))
            pill.closeButton.isEnabled = isEnabled
            addSubview(pill)
            return pill
        }
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    @objc private func removePill(_ sender: NSButton) {
        guard let pill = pills.first(where: { $0.closeButton === sender }) else { return }
        onRemove(pill.keyword.path)
    }

    /// Wraps the pills like text, then the input field after them.
    override func layout() {
        super.layout()
        var x: CGFloat = 0, y: CGFloat = 0
        let lineHeight: CGFloat = 22
        for pill in pills {
            let size = pill.fittingSize
            if x > 0, x + size.width > bounds.width {
                x = 0
                y += lineHeight + spacing
            }
            pill.frame = NSRect(x: x, y: y + (lineHeight - size.height) / 2, width: min(size.width, bounds.width), height: size.height)
            x += size.width + spacing
        }
        if x > 0, bounds.width - x < 90 {
            x = 0
            y += lineHeight + spacing
        }
        input.frame = NSRect(x: x + 2, y: y + 3, width: max(60, bounds.width - x - 2), height: 17)
        let height = y + lineHeight
        if height != laidOutHeight {
            laidOutHeight = height
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: laidOutHeight) }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsLayout = true
    }

    /// The keywords shown, for tests and accessibility.
    var pillTitles: [String] { pills.map(\.title) }

    /// A keyword: close button, then the name, in a capsule.
    private final class Pill: NSView {
        let keyword: Keyword
        let closeButton = NSButton()
        private let label: NSTextField
        var title: String { label.stringValue }

        init(keyword: Keyword) {
            self.keyword = keyword
            label = NSTextField(labelWithString: keyword.isOnAll ? keyword.name : keyword.name + " *")
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 9
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = keyword.isOnAll ? .labelColor : .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            toolTip = keyword.isOnAll ? keyword.path : "\(keyword.path) (on some of the selected photos)"

            closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove \(keyword.name)")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            closeButton.isBordered = false
            closeButton.imagePosition = .imageOnly
            closeButton.contentTintColor = .secondaryLabelColor
            closeButton.setAccessibilityLabel("Remove keyword \(keyword.name)")
            closeButton.setAccessibilityIdentifier("removeKeyword.\(keyword.path)")

            let stack = NSStackView(views: [closeButton, label])
            stack.spacing = 3
            stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 8)
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            setAccessibilityElement(true)
            setAccessibilityRole(.group)
            setAccessibilityLabel(keyword.isOnAll ? keyword.name : "\(keyword.name), on some photos")
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func updateLayer() {
            layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }

        override var wantsUpdateLayer: Bool { true }
    }
}
