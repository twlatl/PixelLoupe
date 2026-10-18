import AppKit

/// Somewhere to import from: a folder, or files and folders dropped on the catalog window.
struct ImportWindowSource: Hashable {
    var urls: [URL]

    init(urls: [URL]) {
        self.urls = urls.map { $0.standardizedFileURL }
    }

    var title: String {
        urls.count == 1 ? FileManager.default.displayName(atPath: urls[0].path(percentEncoded: false)) : "\(urls.count) Items"
    }

    var isSingleFolder: Bool {
        guard urls.count == 1 else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: urls[0].path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// "Untitled › DCIM › 100MSDCF": the folder's path from its volume, as the top bar shows it.
    var breadcrumb: String {
        guard urls.count == 1 else { return urls.map(\.lastPathComponent).joined(separator: ", ") }
        return ImportWindowSource.breadcrumb(for: urls[0])
    }

    static func breadcrumb(for url: URL) -> String {
        let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume?.standardizedFileURL
        let volumeName = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
        let components = url.standardizedFileURL.pathComponents
        let start = volume.map { $0.pathComponents.count } ?? 1
        return ([volumeName].compactMap { $0 } + components.dropFirst(start)).joined(separator: " › ")
    }

    /// The SF Symbol for the source's kind of place.
    var symbol: String {
        guard isSingleFolder else { return "doc.on.doc" }
        let values = try? urls[0].resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsRemovableKey])
        if values?.volumeIsRemovable == true { return "sdcard" }
        return values?.volumeIsInternal == false ? "externaldrive" : "folder"
    }
}

/// One row of the import window's source list.
final class ImportSourceNode: NSObject {
    enum Kind {
        case header
        /// A camera card: shown under Devices, with its camera and a New badge.
        case card
        case volume(ejectable: Bool)
        case folder
        case dropped
        case chooseFolder
    }

    let kind: Kind
    let title: String
    let symbol: String
    let source: ImportWindowSource?
    /// Section rows' rows, or a folder's subfolders once they've been listed.
    var children: [ImportSourceNode]?
    /// Photos found when this source was last read, shown at the right of the row.
    var count: Int?
    /// A card's second line: "Memory card · Sony ILCE-7M4".
    var subtitle: String?
    /// Whether a card has photos the catalog doesn't (the New badge).
    var isNew = false

    init(kind: Kind, title: String, symbol: String, source: ImportWindowSource? = nil, children: [ImportSourceNode]? = nil) {
        self.kind = kind
        self.title = title
        self.symbol = symbol
        self.source = source
        self.children = children
    }

    var isExpandable: Bool {
        switch kind {
        case .header: true
        case .card, .volume, .folder: children?.isEmpty != true
        case .dropped, .chooseFolder: false
        }
    }

    static func folder(_ url: URL, title: String? = nil, symbol: String = "folder") -> ImportSourceNode {
        ImportSourceNode(kind: .folder, title: title ?? FileManager.default.displayName(atPath: url.path(percentEncoded: false)),
                         symbol: symbol, source: ImportWindowSource(urls: [url]))
    }
}

/// The import window's sidebar: Devices (camera cards), Volumes and Locations (with recent folders),
/// as folder trees that expand as they're opened, and Choose Folder….
final class ImportSourceList: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onSelect: ((ImportWindowSource) -> Void)?
    var onChooseFolder: (() -> Void)?
    /// Whether a card has photos the catalog doesn't, for its New badge.
    var hasNewPhotos: ((URL) async -> Bool)?

    let outlineView = NSOutlineView()
    private(set) var roots: [ImportSourceNode] = []
    private var selectedSource: ImportWindowSource?
    /// A folder chosen with Choose Folder… or dropped, listed under Locations until it's a recent one.
    private var extra: ImportWindowSource?
    private var workspaceObservers: [Any] = []

    override init() {
        super.init()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.floatsGroupRows = false
        outlineView.rowSizeStyle = .default
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityLabel("Sources")
        outlineView.setAccessibilityIdentifier("importSources")
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))

        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange(_:)), name: AppSettings.didChangeNotification, object: nil)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
    }

    isolated deinit {
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    /// Rebuilds the list, keeping `extra` (a chosen or dropped source) under Locations.
    func reload(extra: ImportWindowSource? = nil) {
        if let extra { self.extra = extra }
        let recents = RecentImportSources.folders().filter { !ImportCards.isCard($0) }.map { ImportWindowSource(urls: [$0]) }
        // A card is listed under Devices, not as a chosen folder too.
        if let current = self.extra, recents.contains(current) || (current.urls.count == 1 && ImportCards.isCard(current.urls[0])) {
            self.extra = nil
        }

        let fileManager = FileManager.default
        let mounted = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey],
            options: [.skipHiddenVolumes]) ?? []
        let cards = mounted.filter { $0.path(percentEncoded: false) != "/" && ImportCards.isCard($0) }.map { url in
            let name = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
            let node = ImportSourceNode(kind: .card, title: name ?? url.lastPathComponent, symbol: "sdcard",
                                        source: ImportWindowSource(urls: [url]))
            node.subtitle = "Memory card"
            return node
        }
        let volumes = mounted.filter { url in !cards.contains { $0.source?.urls.first == url.standardizedFileURL } }.map { url in
            let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsRemovableKey])
            let ejectable = values?.volumeIsEjectable == true || values?.volumeIsRemovable == true
            return ImportSourceNode(
                kind: .volume(ejectable: ejectable && url.path(percentEncoded: false) != "/"),
                title: values?.volumeLocalizedName ?? url.lastPathComponent,
                symbol: values?.volumeIsInternal == false ? "externaldrive" : "internaldrive",
                source: ImportWindowSource(urls: [url]))
        }

        var locations: [ImportSourceNode] = []
        for (directory, symbol) in [(FileManager.SearchPathDirectory.picturesDirectory, "photo.on.rectangle"),
                                    (.desktopDirectory, "menubar.dock.rectangle"), (.downloadsDirectory, "arrow.down.circle")] {
            if let url = fileManager.urls(for: directory, in: .userDomainMask).first {
                locations.append(.folder(url, symbol: symbol))
            }
        }
        let fixed = Set(locations.compactMap(\.source))
        for source in ([self.extra].compactMap { $0 } + recents) where !fixed.contains(source) {
            if source.isSingleFolder {
                locations.append(.folder(source.urls[0], symbol: "clock"))
            } else {
                locations.append(ImportSourceNode(kind: .dropped, title: source.title, symbol: "doc.on.doc", source: source))
            }
        }
        locations.append(ImportSourceNode(kind: .chooseFolder, title: "Choose Folder…", symbol: "plus"))

        roots = (cards.isEmpty ? [] : [ImportSourceNode(kind: .header, title: "Devices", symbol: "", children: cards)]) + [
            ImportSourceNode(kind: .header, title: "Volumes", symbol: "", children: volumes),
            ImportSourceNode(kind: .header, title: "Locations", symbol: "", children: locations),
        ]
        outlineView.reloadData()
        for root in roots { outlineView.expandItem(root) }
        if let selectedSource { select(selectedSource, notify: false) }
        for card in cards { describe(card) }
    }

    /// The cards listed under Devices.
    var cards: [ImportWindowSource] {
        roots.first { $0.title == "Devices" }?.children?.compactMap(\.source) ?? []
    }

    /// Fills in a card's camera and New badge, which need its files read.
    private func describe(_ card: ImportSourceNode) {
        guard let url = card.source?.urls.first else { return }
        Task { [weak self] in
            let camera = await ImportCards.cameraName(on: url)
            let isNew = await self?.hasNewPhotos?(url) ?? false
            guard let self else { return }
            card.subtitle = ["Memory card", camera].compactMap { $0 }.joined(separator: " · ")
            card.isNew = isNew
            outlineView.reloadItem(card)
        }
    }

    /// Checks the cards' New badges again (after photos are imported).
    func refreshCards() {
        for node in roots.first(where: { $0.title == "Devices" })?.children ?? [] { describe(node) }
    }

    /// Selects the row for `source`, if it's listed.
    func select(_ source: ImportWindowSource, notify: Bool = true) {
        selectedSource = source
        if let node = node(for: source) {
            let row = outlineView.row(forItem: node)
            if row >= 0 {
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
                outlineView.scrollRowToVisible(row)
            }
        }
        if notify { onSelect?(source) }
    }

    /// Shows the number of photos found in `source`.
    func setCount(_ count: Int?, for source: ImportWindowSource) {
        for node in allNodes() where node.source == source || node.count != nil {
            node.count = node.source == source ? count : nil
            outlineView.reloadItem(node)
        }
    }

    private func node(for source: ImportWindowSource) -> ImportSourceNode? {
        allNodes().first { $0.source == source }
    }

    private func allNodes() -> [ImportSourceNode] {
        var result: [ImportSourceNode] = []
        func walk(_ nodes: [ImportSourceNode]) {
            for node in nodes {
                result.append(node)
                if outlineView.isItemExpanded(node) || node.kind.isHeader { walk(node.children ?? []) }
            }
        }
        walk(roots)
        return result
    }

    /// Monochrome Mode recolors the selection and the icons, as in the catalog window's sidebar.
    @objc private func settingsDidChange(_ notification: Notification) {
        outlineView.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
            (rowView.view(atColumn: 0) as? ImportSourceCell)?.updateIconTint()
        }
    }

    @objc private func rowClicked(_ sender: Any?) {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? ImportSourceNode,
              case .chooseFolder = node.kind else { return }
        onChooseFolder?()
    }

    @objc private func eject(_ sender: NSButton) {
        guard let node = outlineView.item(atRow: outlineView.row(for: sender)) as? ImportSourceNode,
              let url = node.source?.urls.first else { return }
        Task {
            if let error = await ImportCards.eject(url) { NSAlert(error: error).runModal() }
        }
    }

    // MARK: - Folder listing

    private func loadChildren(of node: ImportSourceNode) {
        guard node.children == nil, let url = node.source?.urls.first else { return }
        node.children = []
        Task { [weak self] in
            let folders = await Self.subfolders(of: url)
            guard let self else { return }
            node.children = folders.map { ImportSourceNode.folder($0) }
            outlineView.reloadItem(node, reloadChildren: true)
        }
    }

    @concurrent
    nonisolated private static func subfolders(of url: URL) async -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
        return contents.filter {
            let values = try? $0.resourceValues(forKeys: Set(keys))
            return values?.isDirectory == true && values?.isPackage != true
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? ImportSourceNode else { return roots.count }
        if node.children == nil { loadChildren(of: node) }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? ImportSourceNode else { return roots[index] }
        return node.children?[index] as Any
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ImportSourceNode)?.isExpandable ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? ImportSourceNode)?.kind.isHeader ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? ImportSourceNode else { return false }
        switch node.kind {
        case .header, .chooseFolder: return false
        default: return true
        }
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        !((item as? ImportSourceNode)?.kind.isHeader ?? false)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let node = outlineView.item(atRow: outlineView.selectedRow) as? ImportSourceNode,
              let source = node.source, source != selectedSource else { return }
        selectedSource = source
        onSelect?(source)
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if let node = item as? ImportSourceNode, case .card = node.kind { return 40 }
        return 26
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SidebarRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ImportSourceNode else { return nil }
        if node.kind.isHeader {
            let identifier = NSUserInterfaceItemIdentifier("ImportSourceHeader")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let text = NSTextField(labelWithString: "")
                text.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(text)
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                cell.textField = text
                return cell
            }()
            cell.textField?.stringValue = node.title
            return cell
        }

        let cell = outlineView.makeView(withIdentifier: ImportSourceCell.identifier, owner: nil) as? ImportSourceCell ?? ImportSourceCell()
        cell.textField?.stringValue = node.title
        cell.imageView?.image = NSImage(systemSymbolName: node.symbol, accessibilityDescription: nil)
        cell.updateIconTint()
        cell.count.stringValue = node.count.map(String.init) ?? ""
        // A card's row has its badge and eject button instead; its folders show their counts (as in the mockups).
        cell.count.isHidden = node.count == nil || node.kind.isCard
        cell.subtitle.stringValue = node.subtitle ?? ""
        cell.subtitle.isHidden = node.subtitle == nil
        cell.newBadge.isHidden = !node.isNew
        let ejectable: Bool
        switch node.kind {
        case .card: ejectable = true
        case .volume(let canEject): ejectable = canEject
        default: ejectable = false
        }
        if ejectable {
            cell.eject.isHidden = false
            cell.eject.target = self
            cell.eject.action = #selector(eject(_:))
            cell.eject.setAccessibilityLabel("Eject \(node.title)")
        } else {
            cell.eject.isHidden = true
        }
        if case .chooseFolder = node.kind {
            cell.textField?.textColor = .secondaryLabelColor
            cell.setAccessibilityIdentifier("importChooseFolder")
        } else {
            cell.textField?.textColor = .labelColor
            cell.setAccessibilityIdentifier(nil)
        }
        cell.toolTip = node.source?.urls.map { $0.path(percentEncoded: false) }.joined(separator: "\n")
        return cell
    }
}

private extension ImportSourceNode.Kind {
    var isHeader: Bool { if case .header = self { true } else { false } }
    var isCard: Bool { if case .card = self { true } else { false } }
}

/// A source row: icon, name, the photo count once read, and an eject button for removable volumes.
final class ImportSourceCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ImportSourceCell")

    let count = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let newBadge = NSTextField(labelWithString: "New")
    let eject = NSButton(image: NSImage(systemSymbolName: "eject", accessibilityDescription: "Eject") ?? NSImage(), target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let image = SidebarIconView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        // The name gives way after the card's second line does.
        text.setContentCompressionResistancePriority(.init(260), for: .horizontal)
        count.textColor = .secondaryLabelColor
        count.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        eject.isBordered = false
        eject.contentTintColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        subtitle.isHidden = true
        // A capsule outline, as in the mockups.
        newBadge.font = .systemFont(ofSize: 10, weight: .semibold)
        newBadge.alignment = .center
        newBadge.wantsLayer = true
        newBadge.layer?.cornerRadius = 7
        newBadge.layer?.borderWidth = 1
        newBadge.isHidden = true
        newBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        newBadge.widthAnchor.constraint(equalToConstant: 34).isActive = true
        newBadge.heightAnchor.constraint(equalToConstant: 15).isActive = true
        newBadge.toolTip = "Has photos that aren't in this catalog"
        let titles = NSStackView(views: [text, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 0
        titles.setContentCompressionResistancePriority(.init(260), for: .horizontal)
        let stack = NSStackView(views: [image, titles, newBadge, count, eject])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        imageView = image
        textField = text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            updateIconTint()
            updateBadge()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBadge()
    }

    private func updateBadge() {
        let color: NSColor = backgroundStyle == .emphasized ? .white : .secondaryLabelColor
        newBadge.textColor = color
        effectiveAppearance.performAsCurrentDrawingAppearance {
            newBadge.layer?.borderColor = color.cgColor
        }
        subtitle.textColor = backgroundStyle == .emphasized ? .white.withAlphaComponent(0.8) : .secondaryLabelColor
    }

    /// Icons take the accent color on their own; in Monochrome Mode they're the monochrome color, and
    /// white on the selected row (as `SidebarCellView.updateIconTint` does).
    func updateIconTint(monochrome: Bool = AppSettings.shared.isMonochrome) {
        (imageView as? SidebarIconView)?.isExactColor = monochrome
        guard monochrome else {
            imageView?.contentTintColor = nil
            return
        }
        imageView?.contentTintColor = backgroundStyle == .emphasized ? .white : Accent.monochrome
    }
}
