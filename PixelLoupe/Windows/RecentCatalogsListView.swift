import AppKit

/// The welcome window's Recent Catalogs panel (from the mockup): each recently opened catalog with
/// its thumbnail, name, folder and when it was opened, then Clear Menu. Clicking a catalog opens it
/// (`openRecentCatalog(_:)` along the responder chain); catalogs that can't be reached are dimmed and
/// can't be chosen.
final class RecentCatalogsListView: NSView, NSTableViewDataSource, NSTableViewDelegate, RecentCatalogSender {
    static let rowHeight: CGFloat = 38
    private static let headerHeight: CGFloat = 26
    private static let footerHeight: CGFloat = 32

    private let recents: RecentCatalogs
    private(set) var entries: [RecentCatalogs.Entry] = []
    let tableView = NSTableView()
    private let clearButton = NSButton(title: "Clear Menu", target: nil, action: #selector(PixelLoupeActions.clearRecentCatalogs(_:)))
    private var heightConstraint: NSLayoutConstraint!
    /// The catalog last clicked, for `openRecentCatalog(_:)`.
    private(set) var recentCatalogURL: URL?
    /// Where Open Recent is sent: up the responder chain to the app delegate (nil), or a stand-in in tests,
    /// which mustn't open catalogs or show the app's error alerts.
    var actionTarget: AnyObject?

    init(recents: RecentCatalogs = .shared) {
        self.recents = recents
        super.init(frame: .zero)

        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 10
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)

        let header = NSTextField(labelWithString: "Recent Catalogs")
        header.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        header.textColor = .secondaryLabelColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("catalog"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .inset
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked(_:))
        tableView.setAccessibilityLabel("Recent Catalogs")
        tableView.setAccessibilityIdentifier("recentCatalogsList")

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let separator = NSBox()
        separator.boxType = .separator

        clearButton.isBordered = false
        clearButton.alignment = .left
        clearButton.setAccessibilityIdentifier("clearRecentCatalogsButton")

        for view in [header, scroll, separator, clearButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            box.contentView?.addSubview(view)
        }
        guard let content = box.contentView else { return }
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,

            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.headerHeight),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 2),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            clearButton.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            clearButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            clearButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            clearButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Rereads the list; the panel is hidden while it's empty.
    func reload() {
        entries = recents.entries
        tableView.reloadData()
        heightConstraint.constant = Self.height(forRows: entries.count)
        isHidden = entries.isEmpty
    }

    /// Tall enough to show every entry (at most five) without scrolling.
    static func height(forRows rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        return headerHeight + CGFloat(rows) * (rowHeight + 2) + 10 + footerHeight
    }

    @objc private func rowClicked(_ sender: Any?) {
        open(row: tableView.clickedRow)
    }

    /// Opens the catalog in `row`, as clicking it does.
    func open(row: Int) {
        guard entries.indices.contains(row), entries[row].isAvailable else { return }
        recentCatalogURL = entries[row].url
        NSApp.sendAction(#selector(PixelLoupeActions.openRecentCatalog(_:)), to: actionTarget, from: self)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        entries[row].isAvailable
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: RecentCatalogCell.identifier, owner: nil) as? RecentCatalogCell ?? RecentCatalogCell()
        cell.configure(with: entries[row])
        return cell
    }
}

/// One row of the Recent Catalogs panel: thumbnail, name over folder, and the date on the right.
final class RecentCatalogCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("RecentCatalogCell")
    private let thumbnail = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private var path: String?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        imageView = thumbnail
        textField = name
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        folder.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        folder.textColor = .secondaryLabelColor
        folder.lineBreakMode = .byTruncatingMiddle
        date.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        date.textColor = .secondaryLabelColor
        date.setContentCompressionResistancePriority(.required, for: .horizontal)
        date.setContentHuggingPriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [name, folder])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for view in [thumbnail, text, date] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            thumbnail.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: RecentCatalogPreviews.size.width),
            thumbnail.heightAnchor.constraint(equalToConstant: RecentCatalogPreviews.size.height),
            text.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            date.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 8),
            date.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            date.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with entry: RecentCatalogs.Entry) {
        path = entry.path
        name.stringValue = entry.name
        folder.stringValue = entry.displayFolder
        date.stringValue = RecentCatalogs.relativeDate(entry.openedAt)
        alphaValue = entry.isAvailable ? 1 : 0.45
        thumbnail.image = RecentCatalogPreviews.image(for: entry) { [weak self] preview in
            if self?.path == entry.path { self?.thumbnail.image = preview }
        }
        setAccessibilityLabel([entry.name, entry.displayFolder, date.stringValue, entry.isAvailable ? nil : "unavailable"]
            .compactMap { $0 }.joined(separator: ", "))
    }

    /// Row text stays readable on the selection highlight.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            folder.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
            date.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
    }
}
