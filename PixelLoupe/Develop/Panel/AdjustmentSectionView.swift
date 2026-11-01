import AppKit

/// A collapsible section of the Adjust panel: disclosure arrow, icon and title, then Reset, an
/// optional Auto button and the on/off circle, with the section's controls below.
final class AdjustmentSectionView: NSView {
    let contentStack = NSStackView()

    var onReset: (() -> Void)?
    var onAuto: (() -> Void)?
    var onToggle: (() -> Void)?

    let title: String
    private let disclosureButton = NSButton()
    private let resetButton = NSButton()
    private let autoButton = NSButton(title: "AUTO", target: nil, action: nil)
    private let toggleButton = NSButton()
    private let separator = NSBox()

    /// Set apart from the photo's sections (a mask's are "Mask."), so each remembers its own.
    private let scope: String
    private var expandedKey: String { "AdjustSectionExpanded.\(scope)\(title)" }

    private(set) var isExpanded: Bool {
        get {
            Defaults.store.object(forKey: expandedKey) as? Bool ?? false
        }
        set {
            Defaults.store.set(newValue, forKey: expandedKey)
            updateExpansion()
        }
    }

    /// `formerTitle`: what the section was called before a rename, so it stays open or closed as it was.
    init(title: String, symbolName: String, hasAuto: Bool = false, expandedByDefault: Bool = false, scope: String = "",
         formerTitle: String? = nil) {
        self.title = title
        self.scope = scope
        super.init(frame: .zero)
        if Defaults.store.object(forKey: expandedKey) == nil {
            let formerKey = formerTitle.map { "AdjustSectionExpanded.\(scope)\($0)" }
            let former = formerKey.flatMap { Defaults.store.object(forKey: $0) as? Bool }
            Defaults.store.set(former ?? expandedByDefault, forKey: expandedKey)
        }
        setAccessibilityIdentifier("adjustSection.\(scope)\(title)")

        disclosureButton.bezelStyle = .disclosure
        disclosureButton.setButtonType(.pushOnPushOff)
        disclosureButton.title = ""
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleExpanded(_:))
        disclosureButton.setAccessibilityLabel("Show \(title) options")

        let icon = NSImageView(image: Self.symbol(symbolName, fallback: "slider.horizontal.3"))
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        let titleButton = NSButton(title: title, target: self, action: #selector(toggleExpanded(_:)))
        titleButton.isBordered = false
        titleButton.font = .systemFont(ofSize: 15, weight: .regular)
        titleButton.contentTintColor = .labelColor
        titleButton.setAccessibilityIdentifier("adjustSectionTitle.\(title)")

        resetButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Reset \(title)")
        resetButton.isBordered = false
        resetButton.contentTintColor = .secondaryLabelColor
        resetButton.toolTip = "Reset \(title)"
        resetButton.target = self
        resetButton.action = #selector(reset(_:))

        autoButton.bezelStyle = .push
        autoButton.controlSize = .mini
        autoButton.font = .systemFont(ofSize: 9, weight: .semibold)
        autoButton.toolTip = "Automatically adjust \(title)"
        autoButton.target = self
        autoButton.action = #selector(auto(_:))
        autoButton.isHidden = !hasAuto
        autoButton.setAccessibilityIdentifier("auto.\(title)")

        toggleButton.isBordered = false
        toggleButton.imagePosition = .imageOnly
        toggleButton.target = self
        toggleButton.action = #selector(toggle(_:))
        toggleButton.setAccessibilityIdentifier("toggle.\(title)")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [disclosureButton, icon, titleButton, spacer, resetButton, autoButton, toggleButton])
        header.spacing = 6
        header.setCustomSpacing(10, after: icon)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10
        contentStack.edgeInsets = NSEdgeInsets(top: 4, left: 26, bottom: 10, right: 0)

        separator.boxType = .separator

        let stack = NSStackView(views: [header, contentStack, separator])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contentStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        updateExpansion()
        setState(isModified: false, isApplied: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func symbol(_ name: String, fallback: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: nil)
            ?? NSImage()
    }

    /// Adds a control spanning the width of the section.
    func addControl(_ view: NSView) {
        contentStack.addArrangedSubview(view)
        view.widthAnchor.constraint(
            equalTo: contentStack.widthAnchor, constant: -contentStack.edgeInsets.left
        ).isActive = true
    }

    /// Adds a control spanning the width of the section, at `index` among the controls already there.
    func insertControl(_ view: NSView, at index: Int) {
        contentStack.insertArrangedSubview(view, at: index)
        view.widthAnchor.constraint(
            equalTo: contentStack.widthAnchor, constant: -contentStack.edgeInsets.left
        ).isActive = true
    }

    /// `isModified`: differs from defaults (shows Reset). `isApplied`: currently affects the photo.
    func setState(isModified: Bool, isApplied: Bool) {
        resetButton.isHidden = !isModified
        toggleButton.image = NSImage(
            systemSymbolName: isApplied ? "checkmark.circle.fill" : "circle",
            accessibilityDescription: isApplied ? "\(title) on" : "\(title) off"
        )
        toggleButton.contentTintColor = isApplied ? Accent.color : .tertiaryLabelColor
        toggleButton.toolTip = isApplied ? "Turn off \(title)" : "Turn on \(title)"
        toggleButton.setAccessibilityValue(isApplied ? "on" : "off")
    }

    private func updateExpansion() {
        let expanded = isExpanded
        disclosureButton.state = expanded ? .on : .off
        contentStack.isHidden = !expanded
    }

    @objc private func toggleExpanded(_ sender: Any?) {
        isExpanded.toggle()
        guard isExpanded else { return }
        // Bring newly revealed controls into view once layout has caught up.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            superview?.layoutSubtreeIfNeeded()
            scrollToVisible(bounds)
        }
    }

    @objc private func reset(_ sender: Any?) { onReset?() }
    @objc private func auto(_ sender: Any?) { onAuto?() }
    @objc private func toggle(_ sender: Any?) { onToggle?() }
}
