import AppKit
import CoreData

/// The Library Filter's Metadata mode: Lightroom's columns side by side, each a list of values with
/// photo counts under a header that picks its kind (and adds or removes columns). Click a value to
/// filter by it, ⌘-click to add more; "All" clears the column. Drag the bottom edge to resize.
///
/// The values are counted on a background context whenever the filter or the photos change, while
/// the panel is showing.
final class MetadataBrowserView: NSView {
    private let store: CatalogStore
    private let state: LibraryState
    private let stack = NSStackView()
    private var columnViews: [MetadataColumnView] = []
    private var heightConstraint: NSLayoutConstraint!
    private lazy var context = store.container.newBackgroundContext()
    /// Bumped by each recount, so a slower earlier one doesn't overwrite a newer one.
    private var generation = 0
    private var pendingRefresh: DispatchWorkItem?

    init(store: CatalogStore, state: LibraryState) {
        self.store = store
        self.state = state
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 1
        let handle = ResizeHandle()
        handle.onDrag = { [weak self] delta in self?.state.metadataBrowserHeight += delta }
        for view in [stack, handle] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        heightConstraint = heightAnchor.constraint(equalToConstant: state.metadataBrowserHeight)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            handle.topAnchor.constraint(equalTo: stack.bottomAnchor),
            handle.leadingAnchor.constraint(equalTo: leadingAnchor),
            handle.trailingAnchor.constraint(equalTo: trailingAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.heightAnchor.constraint(equalToConstant: 6),
            heightConstraint,
        ])
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setAccessibilityIdentifier("metadataBrowser")
        rebuildColumns()

        state.addObserver(self) { [weak self] change in
            guard let self else { return }
            switch change {
            case .filter:
                if columnViews.map(\.kind) != state.filter.metadata.columns.map(\.kind) { rebuildColumns() }
                scheduleRefresh()
            case .filterBar: scheduleRefresh()
            case .metadataBrowserHeight: heightConstraint.constant = state.metadataBrowserHeight
            default: break
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(contextDidSave(_:)), name: .NSManagedObjectContextDidSave, object: store.viewContext
        )
        scheduleRefresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Whether the counts are worth keeping current: the bar and this mode are showing.
    private var isShowing: Bool {
        state.isFilterBarVisible && state.filter.modes.contains(.metadata)
    }

    private func rebuildColumns() {
        for view in columnViews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        columnViews = state.filter.metadata.columns.indices.map { index in
            let view = MetadataColumnView(state: state, index: index)
            stack.addArrangedSubview(view)
            return view
        }
        // The lists read as one panel with rounded ends.
        columnViews.first?.roundedCorners.formUnion([.layerMinXMinYCorner, .layerMinXMaxYCorner])
        columnViews.last?.roundedCorners.formUnion([.layerMaxXMinYCorner, .layerMaxXMaxYCorner])
    }

    @objc private func contextDidSave(_ notification: Notification) {
        scheduleRefresh()
    }

    /// Recounts shortly, coalescing a burst of changes (typing, a save) into one.
    private func scheduleRefresh() {
        guard isShowing else { return }
        pendingRefresh?.cancel()
        let refresh = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: refresh)
    }

    /// Counts every column's values off the main thread, then shows them.
    func refresh() {
        pendingRefresh = nil
        generation += 1
        let generation = generation
        let filter = state.filter
        let context = context
        context.perform { [weak self] in
            // Fetched in the background context's own queue; only the plain values cross back.
            let values = (try? LibraryFilter.MetadataBrowser.values(
                for: filter.metadata.columns, base: filter.metadataBasePredicate, in: context
            )) ?? []
            context.reset()
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                for (view, values) in zip(self.columnViews, values) { view.show(values) }
            }
        }
    }

    /// A thin strip along the bottom edge that resizes the panel.
    private final class ResizeHandle: NSView {
        var onDrag: ((CGFloat) -> Void)?

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }

        override func mouseDragged(with event: NSEvent) {
            // A mouse event's deltaY is positive downward, which makes the panel taller.
            onDrag?(event.deltaY)
        }

        override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
        override func accessibilityLabel() -> String? { "Resize the metadata columns" }
    }
}

/// One Metadata column: its header menu (the kind, Add Column, Remove Column) and its values.
final class MetadataColumnView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let kind: MetadataColumn
    private let state: LibraryState
    private let index: Int
    private let header = NSPopUpButton()
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private var values: [MetadataColumn.Value] = []
    private var isApplyingSelection = false
    /// The first row: every photo the column is counted from.
    private static let allKey = "\u{0}all"

    init(state: LibraryState, index: Int) {
        self.state = state
        self.index = index
        kind = state.filter.metadata.columns[index].kind
        super.init(frame: .zero)

        header.controlSize = .small
        header.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        header.isBordered = false
        let menu = NSMenu()
        for kind in MetadataColumn.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(changeKind(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let count = state.filter.metadata.columns.count
        let add = NSMenuItem(title: "Add Column", action: count < LibraryFilter.MetadataBrowser.columnCountRange.upperBound ? #selector(addColumn(_:)) : nil, keyEquivalent: "")
        add.target = self
        let remove = NSMenuItem(title: "Remove Column", action: count > 1 ? #selector(removeColumn(_:)) : nil, keyEquivalent: "")
        remove.target = self
        menu.addItem(add)
        menu.addItem(remove)
        header.menu = menu
        header.selectItem(at: MetadataColumn.allCases.firstIndex(of: kind) ?? 0)
        header.setAccessibilityLabel("Metadata column \(index + 1)")
        header.setAccessibilityIdentifier("metadataColumnHeader.\(index)")

        let name = NSTableColumn(identifier: .init("name"))
        let number = NSTableColumn(identifier: .init("count"))
        number.width = 44
        number.minWidth = 30
        number.maxWidth = 70
        for column in [name, number] { outline.addTableColumn(column) }
        outline.outlineTableColumn = name
        outline.headerView = nil
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.rowSizeStyle = .small
        outline.style = .plain
        // layout() gives the names whatever width the counts leave.
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityIdentifier("metadataColumn.\(index)")

        scroll.documentView = outline
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.maskedCorners = []
        scroll.layer?.masksToBounds = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        for view in [header, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The list's corners to round: the outer ones of the first and last columns.
    var roundedCorners: CACornerMask = [] {
        didSet { scroll.layer?.maskedCorners = roundedCorners }
    }

    override func layout() {
        super.layout()
        guard let name = outline.tableColumns.first, let number = outline.tableColumns.last,
              let width = outline.enclosingScrollView?.contentSize.width else { return }
        let nameWidth = max(40, width - number.width - outline.intercellSpacing.width * 2)
        if abs(name.width - nameWidth) > 0.5 { name.width = nameWidth }
    }

    /// The values counted in the background, with "All" on top.
    func show(_ values: [MetadataColumn.Value]) {
        let total = values.reduce(0) { $0 + $1.count }
        self.values = [MetadataColumn.Value(key: Self.allKey, title: "All", count: total)] + values
        isApplyingSelection = true
        outline.reloadData()
        applySelection()
        isApplyingSelection = false
    }

    /// The titles of the values shown, for tests.
    var shownTitles: [String] { values.map(\.title) }

    private var selection: Set<String> {
        guard state.filter.metadata.columns.indices.contains(index) else { return [] }
        return state.filter.metadata.columns[index].selection
    }

    /// Selects the rows of the chosen values ("All" when there are none), opening dates to show them.
    private func applySelection() {
        let selection = selection
        if selection.isEmpty {
            outline.selectRowIndexes([0], byExtendingSelection: false)
            return
        }
        for value in values where value.children.contains(where: { selection.contains($0.key) || $0.children.contains { selection.contains($0.key) } }) {
            outline.expandItem(Box.of(value, in: self))
            for month in value.children where month.children.contains(where: { selection.contains($0.key) }) {
                outline.expandItem(Box.of(month, in: self))
            }
        }
        let rows = IndexSet((0..<outline.numberOfRows).filter { row in
            (outline.item(atRow: row) as? Box).map { selection.contains($0.value.key) } ?? false
        })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
    }

    // MARK: - Actions

    @objc private func changeKind(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = MetadataColumn(rawValue: raw), kind != self.kind else { return }
        state.filter.metadata.columns[index] = .init(kind: kind)
    }

    @objc private func addColumn(_ sender: Any?) {
        let used = Set(state.filter.metadata.columns.map(\.kind))
        let kind = MetadataColumn.allCases.first { !used.contains($0) } ?? .date
        state.filter.metadata.columns.insert(.init(kind: kind), at: index + 1)
    }

    @objc private func removeColumn(_ sender: Any?) {
        state.filter.metadata.columns.remove(at: index)
    }

    // MARK: - Data source

    /// Outline items must be objects that keep their identity across calls.
    final class Box {
        let value: MetadataColumn.Value
        init(_ value: MetadataColumn.Value) { self.value = value }

        static func of(_ value: MetadataColumn.Value, in column: MetadataColumnView) -> Box {
            if let box = column.boxes[value.key] { return box }
            let box = Box(value)
            column.boxes[value.key] = box
            return box
        }
    }

    private var boxes: [String: Box] = [:]

    private func children(of item: Any?) -> [MetadataColumn.Value] {
        (item as? Box)?.value.children ?? values
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { boxes = [:] }
        return children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        Box.of(children(of: item)[index], in: self)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Box)?.value.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let value = (item as? Box)?.value else { return nil }
        let isCount = tableColumn?.identifier.rawValue == "count"
        let identifier = NSUserInterfaceItemIdentifier(isCount ? "countCell" : "nameCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            if isCount {
                text.alignment = .right
                text.textColor = .secondaryLabelColor
            }
            return cell
        }()
        cell.textField?.stringValue = isCount ? value.count.formatted() : value.title
        cell.toolTip = isCount ? nil : value.toolTip
        return cell
    }

    // MARK: - Delegate

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        let keys = outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? Box)?.value.key }
        // "All", alone or with others, means no choice; so does nothing selected.
        let chosen: Set<String> = keys.contains(Self.allKey) && keys.count == 1 ? [] : Set(keys).subtracting([Self.allKey])
        guard state.filter.metadata.columns.indices.contains(index), chosen != selection else { return }
        state.filter.metadata.columns[index].selection = chosen
    }

    /// Clicking "All" while values are chosen leaves just "All".
    func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        guard proposed.contains(0), proposed.count > 1, !outline.selectedRowIndexes.contains(0) else {
            return proposed.count > 1 ? proposed.subtracting([0]) : proposed
        }
        return [0]
    }
}
