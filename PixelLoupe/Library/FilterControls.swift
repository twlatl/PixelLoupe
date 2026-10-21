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

/// Color label filter: a swatch for each color and one for "no label", like Lightroom's. Any
/// combination can be on; with none on, photos aren't filtered by label.
final class ColorLabelFilterControl: NSStackView {
    private let state: LibraryState
    private let buttons: [(label: ColorLabel, button: NSButton)]

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
