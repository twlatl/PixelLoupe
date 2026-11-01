import AppKit

/// The Tone Curve's "Adjust:" row, as in Lightroom: a parametric curve icon, then a circle for the
/// point curve and each of red, green and blue. The selected one is filled, and a dot under a button
/// shows its curve has been changed.
final class CurveModePicker: NSView {
    struct Mode {
        let title: String
        let symbol: String
        /// Symbol shown while selected (the parametric icon has no filled form, so it uses the same one).
        let selectedSymbol: String
        let color: NSColor
    }

    var selectedIndex = 0 { didSet { update() } }
    /// Which modes' curves differ from their defaults.
    var edited: [Bool] = [] { didSet { update() } }
    var onSelect: ((Int) -> Void)?

    private let modes: [Mode]
    private var buttons: [NSButton] = []
    private var dots: [NSImageView] = []

    init(modes: [Mode]) {
        self.modes = modes
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: "Adjust:")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.setAccessibilityElement(false)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.addArrangedSubview(label)
        row.setCustomSpacing(10, after: label)
        for (index, mode) in modes.enumerated() {
            let button = NSButton(image: NSImage(), target: self, action: #selector(select(_:)))
            button.tag = index
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = mode.title
            button.setAccessibilityLabel(mode.title)
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityIdentifier("curveMode.\(mode.title)")
            button.widthAnchor.constraint(equalToConstant: 20).isActive = true
            button.heightAnchor.constraint(equalToConstant: 18).isActive = true

            let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil) ?? NSImage())
            dot.symbolConfiguration = .init(pointSize: 4, weight: .regular)
            dot.contentTintColor = .secondaryLabelColor
            dot.setAccessibilityElement(false)

            let column = NSStackView(views: [button, dot])
            column.orientation = .vertical
            column.spacing = 1
            row.addArrangedSubview(column)
            buttons.append(button)
            dots.append(dot)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Curve")
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func select(_ sender: NSButton) {
        guard sender.tag != selectedIndex else { return }
        selectedIndex = sender.tag
        onSelect?(sender.tag)
    }

    private func update() {
        for (index, mode) in modes.enumerated() {
            let selected = index == selectedIndex
            let isEdited = edited.indices.contains(index) && edited[index]
            let button = buttons[index]
            button.image = NSImage(systemSymbolName: selected ? mode.selectedSymbol : mode.symbol, accessibilityDescription: nil)
            button.symbolConfiguration = .init(pointSize: 14, weight: selected ? .semibold : .regular)
            // The parametric icon shows selection by brightness; the circles by being filled.
            button.contentTintColor = mode.symbol == mode.selectedSymbol && !selected ? .tertiaryLabelColor : mode.color
            button.state = selected ? .on : .off
            button.setAccessibilityValue([selected ? "selected" : nil, isEdited ? "edited" : nil].compactMap { $0 }.joined(separator: ", "))
            dots[index].alphaValue = isEdited ? 1 : 0
        }
    }
}
