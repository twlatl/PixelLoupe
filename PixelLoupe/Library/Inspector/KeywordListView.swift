import AppKit
import CoreData

/// Lightroom's Keyword List: the catalog's keywords as a tree with photo counts, a filter field, a
/// checkbox for each keyword that adds it to (or removes it from) the selected photos, and a
/// context menu to create, rename, delete and edit keywords. The arrow beside a count shows that
/// keyword's photos.
final class KeywordListView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSSearchFieldDelegate {
    /// One row of the tree. Holds the object ID rather than the keyword, so a stale row can't touch
    /// a deleted object.
    final class Node: NSObject {
        /// `nil` for the People group, which isn't a keyword.
        let id: NSManagedObjectID?
        let name: String
        let isGroup: Bool
        let pathKey: String
        let displayPath: String
        let synonyms: String
        var count = 0
        var children: [Node] = []
        weak var parent: Node?

        init(tag: Tag) {
            id = tag.objectID
            name = tag.name
            isGroup = false
            pathKey = tag.pathKey
            displayPath = tag.displayPath
            synonyms = tag.synonymText ?? ""
        }

        /// A heading that gathers keywords, such as People.
        init(groupNamed name: String) {
            id = nil
            self.name = name
            isGroup = true
            pathKey = ""
            displayPath = name
            synonyms = ""
        }
    }

    enum Membership { case none, some, all }

    private let store: CatalogStore
    private let outline = NSOutlineView()
    private let filterField = ClickToFocusSearchField()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No keywords yet.")

    /// The top-level keywords, as of the last reload.
    private(set) var roots: [Node] = []
    /// What the tree shows: `roots`, or only the branches that match the filter.
    private var visibleRoots: [Node] = []
    private var memberships: [NSManagedObjectID: Membership] = [:]
    private var filterText = ""

    /// Called to add (`true`) or remove (`false`) a keyword on the selected photos.
    var onAssign: (NSManagedObjectID, Bool) -> Void = { _, _ in }
    /// Called to show the photos of the keyword with this path key.
    var onShowPhotos: (String) -> Void = { _ in }
    /// Called to give a context-menu command for a keyword (`nil` is the top level).
    var onCommand: (Command, NSManagedObjectID?) -> Void = { _, _ in }

    enum Command { case create, rename, delete, edit }

    static let rowHeight: CGFloat = 20
    static let maximumHeight: CGFloat = 260

    init(store: CatalogStore) {
        self.store = store
        super.init(frame: .zero)

        filterField.placeholderString = "Filter keywords"
        filterField.controlSize = .small
        filterField.delegate = self
        filterField.setAccessibilityIdentifier("keywordListFilter")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("keyword"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = Self.rowHeight
        outline.indentationPerLevel = 12
        outline.style = .plain
        outline.usesAlternatingRowBackgroundColors = false
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.allowsMultipleSelection = false
        outline.setAccessibilityLabel("Keyword List")
        outline.setAccessibilityIdentifier("keywordList")
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyLabel.isHidden = true

        for view in [filterField, scroll, emptyLabel] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight * 3)
        NSLayoutConstraint.activate([
            filterField.topAnchor.constraint(equalTo: topAnchor),
            filterField.leadingAnchor.constraint(equalTo: leadingAnchor),
            filterField.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 6),
        ])
        setAccessibilityIdentifier("keywordListView")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var heightConstraint: NSLayoutConstraint!

    // MARK: - Loading

    /// Rebuilds the tree from the catalog's keywords.
    func reload() {
        let context = store.viewContext
        let tags = (try? context.fetch(Tag.fetchRequest())) ?? []
        let counts = Self.photoCounts(in: context)
        var nodes: [NSManagedObjectID: Node] = [:]
        for tag in tags {
            let node = Node(tag: tag)
            node.count = counts[tag.pathKey] ?? 0
            nodes[tag.objectID] = node
        }
        roots = []
        for tag in tags {
            guard let node = nodes[tag.objectID] else { continue }
            if let parentID = tag.parent?.objectID, let parent = nodes[parentID] {
                node.parent = parent
                parent.children.append(node)
            } else {
                roots.append(node)
            }
        }
        func sort(_ list: inout [Node]) {
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for node in list { sort(&node.children) }
        }
        sort(&roots)
        // The people (keywords marked as a person, wherever they are in the tree) are also listed together.
        let people = tags.filter(\.isPerson).map { tag -> Node in
            let node = Node(tag: tag)
            node.count = counts[tag.pathKey] ?? 0
            return node
        }
        if !people.isEmpty {
            let group = Node(groupNamed: Self.peopleGroupName)
            group.children = people.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for person in group.children { person.parent = group }
            group.count = group.children.reduce(0) { $0 + $1.count }
            roots.insert(group, at: 0)
        }
        applyFilter()
    }

    static let peopleGroupName = "People"

    /// Photos per keyword (by `pathKey`, which is unique), in one query.
    static func photoCounts(in context: NSManagedObjectContext) -> [String: Int] {
        let count = NSExpressionDescription()
        count.name = "count"
        count.expression = NSExpression(forKeyPath: "photos.@count")
        count.expressionResultType = .integer64AttributeType
        let request = NSFetchRequest<NSDictionary>(entityName: "Tag")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["pathKey", count]
        var counts: [String: Int] = [:]
        for row in (try? context.fetch(request)) ?? [] {
            if let key = row["pathKey"] as? String, let value = row["count"] as? Int { counts[key] = value }
        }
        return counts
    }

    /// Which keywords the selected photos have: on all of them, on some, or none.
    func updateMembership(for photos: [Photo]) {
        var counts: [NSManagedObjectID: Int] = [:]
        for photo in photos { for tag in photo.tags { counts[tag.objectID, default: 0] += 1 } }
        memberships = counts.mapValues { $0 == photos.count ? .all : .some }
        isAssigningEnabled = !photos.isEmpty
        outline.enumerateAvailableRowViews { row, index in
            guard let cell = row.view(atColumn: 0) as? KeywordListCell, let node = outline.item(atRow: index) as? Node else { return }
            cell.configure(membership: node.id.flatMap { memberships[$0] } ?? .none, enabled: isAssigningEnabled && !node.isGroup)
        }
    }

    private var isAssigningEnabled = false

    func membership(of id: NSManagedObjectID) -> Membership { memberships[id] ?? .none }

    // MARK: - Filtering

    private func applyFilter() {
        let text = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            visibleRoots = roots
        } else {
            func matches(_ node: Node) -> Bool {
                node.displayPath.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || node.synonyms.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            // A match keeps its whole branch; an ancestor of a match is shown to reach it.
            func keep(_ node: Node) -> Bool { matches(node) || node.children.contains(where: keep) }
            visibleRoots = roots.filter(keep)
        }
        outline.reloadData()
        if !text.isEmpty { outline.expandItem(nil, expandChildren: true) }
        emptyLabel.stringValue = roots.isEmpty ? "No keywords yet." : "No matching keywords."
        emptyLabel.isHidden = !visibleRoots.isEmpty
        updateHeight()
    }

    private func updateHeight() {
        let rows = max(outline.numberOfRows, 3)
        heightConstraint.constant = min(CGFloat(rows) * (Self.rowHeight + outline.intercellSpacing.height), Self.maximumHeight)
    }

    func controlTextDidChange(_ obj: Notification) {
        filterText = filterField.stringValue
        applyFilter()
    }

    /// Sets the filter text (tests, and Show in Keyword List).
    func setFilter(_ text: String) {
        filterField.stringValue = text
        filterText = text
        applyFilter()
    }

    func outlineViewItemDidExpand(_ notification: Notification) { updateHeight() }
    func outlineViewItemDidCollapse(_ notification: Notification) { updateHeight() }

    // MARK: - Data source

    private func children(of item: Any?) -> [Node] {
        guard let node = item as? Node else { return visibleRoots }
        guard filterText.isEmpty else { return node.children }
        return node.children
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(of: item).count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(of: item)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? Node)?.children.isEmpty ?? true) }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("KeywordListCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? KeywordListCell ?? KeywordListCell(identifier: identifier)
        cell.configure(node: node, membership: node.id.flatMap { memberships[$0] } ?? .none, enabled: isAssigningEnabled)
        cell.onToggle = { [weak self] on in if let id = node.id { self?.onAssign(id, on) } }
        cell.onShowPhotos = { [weak self] in self?.onShowPhotos(node.pathKey) }
        return cell
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        let node = row >= 0 ? outline.item(atRow: row) as? Node : nil
        func add(_ title: String, _ command: Command) {
            let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = CommandBox(command: command, id: node?.id)
            menu.addItem(item)
        }
        if let node, !node.isGroup {
            add("Create Keyword Inside “\(node.name)”…", .create)
            menu.addItem(.separator())
            add("Rename…", .rename)
            add("Edit Keyword…", .edit)
            menu.addItem(.separator())
            add("Delete…", .delete)
        } else {
            add("Create Keyword…", .create)
        }
    }

    private final class CommandBox: NSObject {
        let command: Command
        let id: NSManagedObjectID?
        init(command: Command, id: NSManagedObjectID?) {
            self.command = command
            self.id = id
        }
    }

    @objc private func menuCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CommandBox else { return }
        onCommand(box.command, box.id)
    }

    // MARK: - For tests

    /// The names of the rows currently shown, indented by depth ("  Dublin").
    var shownTitles: [String] {
        (0..<outline.numberOfRows).compactMap { row in
            (outline.item(atRow: row) as? Node).map { String(repeating: "  ", count: outline.level(forRow: row)) + $0.name }
        }
    }

    var outlineView: NSOutlineView { outline }
    var filter: NSSearchField { filterField }
}

/// A row of the Keyword List: checkbox, name, count and the arrow that shows the keyword's photos.
final class KeywordListCell: NSTableCellView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let arrow = NSButton()
    var onToggle: (Bool) -> Void = { _ in }
    var onShowPhotos: () -> Void = {}
    private var node: KeywordListView.Node?
    private var membership = KeywordListView.Membership.none

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        checkbox.allowsMixedState = true  // shown for "some"; clicks are handled in toggled(_:)
        checkbox.controlSize = .small
        checkbox.target = self
        checkbox.action = #selector(toggled(_:))
        checkbox.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = title

        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        arrow.image = NSImage(systemSymbolName: "arrow.right.circle.fill", accessibilityDescription: "Show photos with this keyword")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        arrow.isBordered = false
        arrow.imagePosition = .imageOnly
        arrow.contentTintColor = .tertiaryLabelColor
        arrow.toolTip = "Show photos with this keyword"
        arrow.target = self
        arrow.action = #selector(showPhotos(_:))
        arrow.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [checkbox, title, countLabel, arrow])
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(node: KeywordListView.Node, membership: KeywordListView.Membership, enabled: Bool) {
        self.node = node
        textField?.stringValue = node.name
        textField?.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: node.isGroup ? .semibold : .regular)
        checkbox.isHidden = node.isGroup
        arrow.isHidden = node.isGroup
        toolTip = node.isGroup ? "Keywords that name a person" : node.displayPath
        countLabel.stringValue = node.count.formatted()
        setAccessibilityLabel(node.displayPath)
        setAccessibilityIdentifier("keywordRow.\(node.displayPath)")
        checkbox.setAccessibilityLabel("Assign keyword \(node.displayPath)")
        configure(membership: membership, enabled: enabled)
    }

    func configure(membership: KeywordListView.Membership, enabled: Bool) {
        self.membership = membership
        checkbox.state = switch membership {
        case .none: .off
        case .some: .mixed
        case .all: .on
        }
        checkbox.isEnabled = enabled
    }

    @objc private func toggled(_ sender: NSButton) {
        // On every selected photo: take it off. On some or none: put it on all of them.
        onToggle(membership != .all)
    }

    @objc private func showPhotos(_ sender: Any?) { onShowPhotos() }
}
