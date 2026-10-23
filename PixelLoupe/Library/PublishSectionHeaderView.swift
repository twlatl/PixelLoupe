import AppKit

/// A publish service's group heading in the grid ("New Photos to Publish", "Published Photos"…), as in
/// Lightroom: a chevron and title on the left, the photo count on the right. Clicking it collapses or
/// expands the group.
final class PublishSectionHeaderView: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("PublishSectionHeader")
    static let height: CGFloat = 30

    private let disclosure = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    /// Called on a click.
    var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        let separator = NSBox()
        separator.boxType = .separator
        for view in [disclosure, titleLabel, countLabel, separator] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            countLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ state: PublishedPhoto.State, count: Int, isCollapsed: Bool, note: String? = nil) {
        titleLabel.stringValue = state.title
        countLabel.stringValue = (count == 1 ? "1 photo" : "\(count.formatted()) photos") + (note.map { " · \($0)" } ?? "")
        disclosure.image = NSImage(systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down",
                                   accessibilityDescription: nil)
        setAccessibilityLabel("\(state.title), \(countLabel.stringValue)")
        setAccessibilityValue(isCollapsed ? "collapsed" : "expanded")
        setAccessibilityIdentifier("publishSection.\(state)")
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return true
    }
}
