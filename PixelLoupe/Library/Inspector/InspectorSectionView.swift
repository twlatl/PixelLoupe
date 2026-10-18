import AppKit

/// A collapsible panel of the Library's right sidebar: a header (an optional accessory such as a
/// pop-up on the left, the title on the right with a disclosure button) above its content.
final class InspectorSectionView: NSView {
    let title: String
    private let disclosure = NSButton()
    private let content: NSView
    private let expandedKey: String

    private(set) var isExpanded: Bool {
        get { Defaults.store.object(forKey: expandedKey) as? Bool ?? true }
        set {
            Defaults.store.set(newValue, forKey: expandedKey)
            update()
        }
    }

    /// `stateKey` names where its expanded state is remembered (the Library sidebar's by default).
    init(title: String, accessory: NSView? = nil, content: NSView, stateKey: String = "LibraryInspectorExpanded") {
        self.title = title
        self.content = content
        expandedKey = "\(stateKey).\(title)"
        super.init(frame: .zero)
        setAccessibilityIdentifier("inspectorSection.\(title)")

        let titleButton = NSButton(title: title, target: nil, action: nil)
        titleButton.isBordered = false
        titleButton.font = .systemFont(ofSize: 15, weight: .regular)
        titleButton.contentTintColor = .labelColor
        titleButton.target = self
        titleButton.action = #selector(toggle(_:))
        titleButton.setAccessibilityIdentifier("inspectorSectionTitle.\(title)")

        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.title = ""
        disclosure.target = self
        disclosure.action = #selector(toggle(_:))
        disclosure.setAccessibilityLabel("Show \(title)")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [disclosure, titleButton, spacer]
        if let accessory { views.append(accessory) }
        let header = NSStackView(views: views)
        header.spacing = 4
        let separator = NSBox()
        separator.boxType = .separator

        for view in [header, content, separator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        expandedConstraints = [
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -12),
        ]
        collapsedConstraints = [header.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -8)]
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var expandedConstraints: [NSLayoutConstraint] = []
    private var collapsedConstraints: [NSLayoutConstraint] = []

    func expand() {
        if !isExpanded { isExpanded = true }
    }

    @objc private func toggle(_ sender: Any?) {
        isExpanded.toggle()
    }

    private func update() {
        disclosure.state = isExpanded ? .on : .off
        content.isHidden = !isExpanded
        // Deactivate before activating, so the two never conflict.
        NSLayoutConstraint.deactivate(isExpanded ? collapsedConstraints : expandedConstraints)
        NSLayoutConstraint.activate(isExpanded ? expandedConstraints : collapsedConstraints)
    }
}
