import AppKit

/// Rating filter: a comparison pop-up (≥ = ≤) and five stars. Click a star to filter by it, click it
/// again to clear. Bound to `LibraryState.filter`, so every instance stays in sync.
final class RatingFilterControl: NSStackView {
    private let state: LibraryState
    private let comparisonPopUp = NSPopUpButton()
    private let starButtons: [NSButton] = (1...5).map { _ in NSButton() }

    init(state: LibraryState, identifierPrefix: String = "") {
        self.state = state
        super.init(frame: .zero)

        comparisonPopUp.controlSize = .small
        comparisonPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for comparison in LibraryFilter.RatingComparison.allCases {
            comparisonPopUp.addItem(withTitle: comparison.symbol)
            comparisonPopUp.lastItem?.representedObject = comparison.rawValue
        }
        comparisonPopUp.target = self
        comparisonPopUp.action = #selector(comparisonChanged(_:))
        comparisonPopUp.toolTip = "Rating comparison"
        comparisonPopUp.setAccessibilityLabel("Rating comparison")

        for (index, button) in starButtons.enumerated() {
            button.isBordered = false
            button.bezelStyle = .toolbar
            button.imagePosition = .imageOnly
            button.tag = index + 1
            button.target = self
            button.action = #selector(starClicked(_:))
            button.toolTip = "Filter by \(index + 1) star\(index == 0 ? "" : "s"); click again to clear"
            button.setAccessibilityIdentifier("\(identifierPrefix)ratingFilter\(index + 1)")
        }
        let stars = NSStackView(views: starButtons)
        stars.spacing = 0

        addArrangedSubview(comparisonPopUp)
        addArrangedSubview(stars)
        spacing = 4
        update()
        state.addObserver(self) { [weak self] change in
            if change == .filter { self?.update() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func update() {
        let filter = state.filter
        let rating = filter.attributes.rating ?? 0
        for button in starButtons {
            let filled = button.tag <= rating
            button.image = NSImage(systemSymbolName: filled ? "star.fill" : "star", accessibilityDescription: "\(button.tag) stars")
            button.contentTintColor = filled ? .systemYellow : .tertiaryLabelColor
            button.setAccessibilityValue(filled ? "on" : "off")
        }
        comparisonPopUp.selectItem(at: LibraryFilter.RatingComparison.allCases.firstIndex(of: filter.attributes.ratingComparison) ?? 0)
    }

    @objc private func starClicked(_ sender: NSButton) {
        state.filter.attributes.rating = state.filter.attributes.rating == sender.tag ? nil : sender.tag
    }

    @objc private func comparisonChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let comparison = LibraryFilter.RatingComparison(rawValue: raw) else { return }
        state.filter.attributes.ratingComparison = comparison
    }
}

/// Flag filter: toggles for Picked, Unflagged and Rejected, like Lightroom's filmstrip. With none on,
/// photos aren't filtered by flag.
final class FlagFilterControl: NSStackView {
    private let state: LibraryState
    private let buttons: [(flag: PhotoFlag, button: NSButton)]

    init(state: LibraryState, identifierPrefix: String = "") {
        self.state = state
        buttons = [
            (.picked, "flag.fill", "Picked"),
            (.unflagged, "flag", "Unflagged"),
            (.rejected, "xmark.circle.fill", "Rejected"),
        ].map { flag, symbol, title in
            let button = NSButton()
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .toolbar
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.toolTip = "Show \(title.lowercased()) photos"
            button.setAccessibilityLabel("\(title) filter")
            button.setAccessibilityIdentifier("\(identifierPrefix)flagFilter.\(title)")
            return (flag, button)
        }
        super.init(frame: .zero)
        for (_, button) in buttons {
            button.target = self
            button.action = #selector(toggled(_:))
            addArrangedSubview(button)
        }
        spacing = 2
        update()
        state.addObserver(self) { [weak self] change in
            if change == .filter { self?.update() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func update() {
        for (flag, button) in buttons {
            let on = state.filter.attributes.flags.contains(flag)
            button.state = on ? .on : .off
            button.contentTintColor = on ? (flag == .rejected ? .systemRed : Accent.color) : .tertiaryLabelColor
        }
    }

    @objc private func toggled(_ sender: NSButton) {
        guard let flag = buttons.first(where: { $0.button === sender })?.flag else { return }
        if state.filter.attributes.flags.contains(flag) {
            state.filter.attributes.flags.remove(flag)
        } else {
            state.filter.attributes.flags.insert(flag)
        }
    }
}

/// Color label filter: a swatch for each color, one for any other label (a custom Lightroom label,
/// which has no color here) and one for "no label", like Lightroom's. Any combination can be on;
/// with none on, photos aren't filtered by label.
final class ColorLabelFilterControl: NSStackView {
    private let state: LibraryState
    private let buttons: [(label: ColorLabel, button: NSButton)]
    private let otherButton = NSButton()

    init(state: LibraryState, identifierPrefix: String = "") {
        self.state = state
        buttons = (ColorLabel.colors + [.none]).map { label in
            let button = NSButton()
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .toolbar
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.toolTip = label == .none ? "Show photos without a color label" : "Show \(label.title.lowercased()) photos"
            button.setAccessibilityLabel(label == .none ? "No color label filter" : "\(label.title) label filter")
            button.setAccessibilityIdentifier("\(identifierPrefix)labelFilter.\(label.title)")
            return (label, button)
        }
        super.init(frame: .zero)
        otherButton.setButtonType(.pushOnPushOff)
        otherButton.bezelStyle = .toolbar
        otherButton.isBordered = false
        otherButton.imagePosition = .imageOnly
        otherButton.toolTip = "Show photos with another label (one with no color, such as a custom Lightroom label)"
        otherButton.setAccessibilityLabel("Other label filter")
        otherButton.setAccessibilityIdentifier("\(identifierPrefix)labelFilter.Other")
        otherButton.target = self
        otherButton.action = #selector(otherToggled(_:))
        for (label, button) in buttons {
            button.target = self
            button.action = #selector(toggled(_:))
            // Other label sits between the colors and "no label".
            if label == .none { addArrangedSubview(otherButton) }
            addArrangedSubview(button)
        }
        spacing = 2
        update()
        state.addObserver(self) { [weak self] change in
            if change == .filter { self?.update() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func update() {
        for (label, button) in buttons {
            let on = state.filter.attributes.colorLabels.contains(label)
            button.state = on ? .on : .off
            // A filled swatch, bright when it filters and muted otherwise. "None" is an empty circle.
            let symbol = label == .none ? (on ? "circle.slash" : "circle.dashed") : "circle.fill"
            let tint: NSColor = label == .none ? (on ? .labelColor : .tertiaryLabelColor) : label.color.withAlphaComponent(on ? 1 : 0.5)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label.title)
            button.contentTintColor = tint
            button.setAccessibilityValue(on ? "on" : "off")
        }
        let otherOn = state.filter.attributes.otherLabel
        otherButton.state = otherOn ? .on : .off
        otherButton.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "Other label")
        otherButton.contentTintColor = otherOn ? .labelColor : .tertiaryLabelColor
        otherButton.setAccessibilityValue(otherOn ? "on" : "off")
    }

    @objc private func otherToggled(_ sender: NSButton) {
        state.filter.attributes.otherLabel.toggle()
    }

    @objc private func toggled(_ sender: NSButton) {
        guard let label = buttons.first(where: { $0.button === sender })?.label else { return }
        if state.filter.attributes.colorLabels.contains(label) {
            state.filter.attributes.colorLabels.remove(label)
        } else {
            state.filter.attributes.colorLabels.insert(label)
        }
    }
}

/// A group of Attribute toggles (Edit, Kind, Stack): each shows photos with that attribute, any
/// combination can be on, and with none on the group doesn't filter.
final class AttributeToggleControl: NSStackView {
    struct Choice {
        let title: String
        let symbol: String
        let identifier: String
        let isOn: (LibraryFilter.Attributes) -> Bool
        let toggle: (inout LibraryFilter.Attributes) -> Void
    }

    private let state: LibraryState
    private let choices: [(choice: Choice, button: NSButton)]

    init(state: LibraryState, choices: [Choice]) {
        self.state = state
        self.choices = choices.map { choice in
            let button = NSButton()
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .toolbar
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: choice.symbol, accessibilityDescription: choice.title)
            button.toolTip = "Show \(choice.title.lowercased())"
            button.setAccessibilityLabel("\(choice.title) filter")
            button.setAccessibilityIdentifier(choice.identifier)
            return (choice, button)
        }
        super.init(frame: .zero)
        for (_, button) in self.choices {
            button.target = self
            button.action = #selector(toggled(_:))
            addArrangedSubview(button)
        }
        spacing = 2
        update()
        state.addObserver(self) { [weak self] change in
            if change == .filter { self?.update() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func update() {
        for (choice, button) in choices {
            let on = choice.isOn(state.filter.attributes)
            button.state = on ? .on : .off
            button.contentTintColor = on ? Accent.color : .tertiaryLabelColor
            button.setAccessibilityValue(on ? "on" : "off")
        }
    }

    @objc private func toggled(_ sender: NSButton) {
        guard let choice = choices.first(where: { $0.button === sender })?.choice else { return }
        choice.toggle(&state.filter.attributes)
    }

    /// Toggles for each case of a set-valued attribute group.
    static func choices<Value: Hashable>(
        _ values: [Value], _ keyPath: WritableKeyPath<LibraryFilter.Attributes, Set<Value>>,
        title: (Value) -> String, symbol: (Value) -> String, identifier: (Value) -> String
    ) -> [Choice] {
        values.map { value in
            Choice(
                title: title(value), symbol: symbol(value), identifier: identifier(value),
                isOn: { $0[keyPath: keyPath].contains(value) },
                toggle: { attributes in
                    if attributes[keyPath: keyPath].contains(value) {
                        attributes[keyPath: keyPath].remove(value)
                    } else {
                        attributes[keyPath: keyPath].insert(value)
                    }
                }
            )
        }
    }
}
