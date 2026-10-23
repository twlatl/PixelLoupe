import AppKit
import CoreData

/// Source list showing "All Photographs", "Previous Import", the catalog's folder tree and its
/// collections, with photo counts.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate,
                                   NSSearchFieldDelegate {
    final class Item: NSObject {
        enum Kind {
            case header
            case allPhotos
            /// The most recent import, or nil (a dimmed row) when there's none.
            case previousImport(id: UUID?)
            case folder(path: String)
            /// The Collections header, with its + menu.
            case collectionsHeader
            /// The Filter Collections field.
            case collectionFilter
            case collection(id: UUID, kind: PhotoCollection.Kind)
            /// A publish service, under the Publishing header (RAW-179).
            case publishService(id: UUID)
        }

        let kind: Kind
        let title: String
        var children: [Item] = []
        /// Nil for rows without a count (collection sets).
        var count: Int? = 0
        var content: CollectionContent?
        var isTarget = false
        /// Why an imported smart collection may not match Lightroom's (shown with a warning icon).
        var warning: String?
        /// A folder marked as a favorite (a star on its icon).
        var isFavorite = false
        /// A folder's color label (its icon's color).
        var label: ColorLabel = .none
        /// Where a publish service publishes, for its tooltip.
        var detail: String?

        init(kind: Kind, title: String) {
            self.kind = kind
            self.title = title
        }

        var scope: LibraryFilter.Scope? {
            switch kind {
            case .header, .collectionsHeader, .collectionFilter: nil
            case .allPhotos: .allPhotos
            case .previousImport(let id): id.map { .previousImport(id: $0) }
            case .folder(let path): .folder(path: path)
            case .collection(let id, _): content.map { .collection(id: id, content: $0) }
            case .publishService(let id): .publishService(id: id)
            }
        }

        var publishServiceID: UUID? {
            if case .publishService(let id) = kind { id } else { nil }
        }

        var collectionID: UUID? {
            if case .collection(let id, _) = kind { id } else { nil }
        }

        var collectionKind: PhotoCollection.Kind? {
            if case .collection(_, let kind) = kind { kind } else { nil }
        }
    }

    enum CollectionSort: String {
        case name, kind
    }

    private static let sortKey = "CollectionSort"
    private static let showFilterKey = "ShowCollectionFilter"

    private(set) var collectionSort: CollectionSort {
        get { CollectionSort(rawValue: Defaults.store.string(forKey: Self.sortKey) ?? "") ?? .kind }
        set { Defaults.store.set(newValue.rawValue, forKey: Self.sortKey); reload() }
    }

    private(set) var showsCollectionFilter: Bool {
        get { Defaults.store.object(forKey: Self.showFilterKey) as? Bool ?? true }
        set { Defaults.store.set(newValue, forKey: Self.showFilterKey); reload() }
    }

    /// Typed in Filter Collections.
    private(set) var collectionFilterText = ""
    let collectionFilterField = ClickToFocusSearchField()
    private let catalogNameLabel = NSTextField(labelWithString: "")
    private let storageLabel = NSTextField(labelWithString: "")
    private(set) lazy var navigator = NavigatorViewController(store: store, state: state)
    /// Collection sets collapsed (sets start expanded).
    private var collapsedSets: Set<UUID> = []

    private let store: CatalogStore
    private let state: LibraryState
    private let outlineView = SidebarOutlineView()
    private var roots: [Item] = []
    private var isReloading = false
    private var reloadScheduled = false
    /// Paths of expanded folders, including ones inside collapsed parents (so expanding a parent
    /// brings back its subfolders as they were). Saved with the catalog and restored on launch.
    private var expandedPaths: Set<String>

    init(store: CatalogStore, state: LibraryState) {
        self.store = store
        self.state = state
        self.expandedPaths = store.viewState.expandedFolderPaths
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .sourceList
        // Compact rows like Finder's sidebar; the default source-list size is much taller.
        outlineView.rowSizeStyle = .custom
        outlineView.rowHeight = SidebarCellView.rowHeight
        outlineView.floatsGroupRows = false
        outlineView.autosaveExpandedItems = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.setAccessibilityIdentifier("sidebarOutline")
        outlineView.registerForDraggedTypes([.pixelLoupePhotos])
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: true)
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        collectionFilterField.placeholderString = "Filter Collections"
        collectionFilterField.controlSize = .small
        collectionFilterField.sendsSearchStringImmediately = true
        collectionFilterField.delegate = self
        collectionFilterField.setAccessibilityIdentifier("collectionFilter")

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        // At the very top: the catalog's name and where its photos are kept; then the Navigator.
        catalogNameLabel.stringValue = store.name
        catalogNameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        catalogNameLabel.lineBreakMode = .byTruncatingTail
        catalogNameLabel.setAccessibilityIdentifier("sidebarCatalogName")
        storageLabel.stringValue = store.info.storageDescription
        storageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        storageLabel.textColor = .secondaryLabelColor
        storageLabel.lineBreakMode = .byTruncatingTail
        storageLabel.setAccessibilityIdentifier("sidebarCatalogStorage")
        for label in [catalogNameLabel, storageLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.toolTip = label.stringValue
        }
        addChild(navigator)

        let container = NSView()
        for subview in [catalogNameLabel, storageLabel, navigator.view, scrollView] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            catalogNameLabel.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 4),
            catalogNameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            catalogNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            storageLabel.topAnchor.constraint(equalTo: catalogNameLabel.bottomAnchor, constant: 1),
            storageLabel.leadingAnchor.constraint(equalTo: catalogNameLabel.leadingAnchor),
            storageLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            navigator.view.topAnchor.constraint(equalTo: storageLabel.bottomAnchor, constant: 8),
            navigator.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            navigator.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: navigator.view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
        NotificationCenter.default.addObserver(
            self, selector: #selector(contextObjectsDidChange(_:)),
            name: .NSManagedObjectContextObjectsDidChange, object: store.viewContext
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(availabilityDidChange(_:)),
            name: FileAvailability.didChangeNotification, object: store.availability
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange(_:)), name: AppSettings.didChangeNotification, object: nil
        )
    }

    /// Monochrome Mode recolors the icons and the selection.
    @objc private func settingsDidChange(_ notification: Notification) {
        outlineView.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
            (rowView.view(atColumn: 0) as? SidebarCellView)?.updateIconTint()
        }
        // Rebuild the rows too, so the icons pick up the change in vibrancy (AppKit sets it up as views
        // draw). Only for Monochrome Mode itself: other settings (matte, appearance) don't touch the icons.
        let monochrome = AppSettings.shared.isMonochrome
        guard monochrome != iconsAreMonochrome else { return }
        iconsAreMonochrome = monochrome
        reload()
    }

    private lazy var iconsAreMonochrome = AppSettings.shared.isMonochrome

    /// Dims folders that went offline (or comes back online) without rebuilding the outline.
    @objc private func availabilityDidChange(_ notification: Notification) {
        guard !isStopped else { return }
        let rows = outlineView.rows(in: outlineView.visibleRect)
        outlineView.reloadData(forRowIndexes: IndexSet(integersIn: rows.lowerBound..<rows.upperBound), columnIndexes: IndexSet(integer: 0))
    }

    /// Set when the catalog window closes: a closed window's sidebar stops following the catalog
    /// (which may be gone by the time a pending reload would run).
    private var isStopped = false

    func stop() {
        isStopped = true
        NotificationCenter.default.removeObserver(self, name: .NSManagedObjectContextObjectsDidChange, object: store.viewContext)
    }

    /// How long after a catalog change the sidebar's counts are refreshed.
    static let reloadDelay: TimeInterval = 0.25

    @objc private func contextObjectsDidChange(_ notification: Notification) {
        let keys = [NSInsertedObjectsKey, NSDeletedObjectsKey]
        var changed = keys.contains { key in
            (notification.userInfo?[key] as? Set<NSManagedObject>)?.contains {
                $0 is Photo || $0 is Folder || $0 is PhotoCollection || $0 is PublishService || $0 is PublishedPhoto
            } ?? false
        }
        // Edits to collections and folders, and to photos (which can change what smart collections hold).
        changed = changed || [NSUpdatedObjectsKey, NSRefreshedObjectsKey].contains { key in
            (notification.userInfo?[key] as? Set<NSManagedObject>)?.contains {
                $0 is PhotoCollection || $0 is Photo || $0 is Folder || $0 is PublishService || $0 is PublishedPhoto
            } ?? false
        }
        guard changed, !reloadScheduled else { return }
        // Coalesce the notifications an import (or a run of rating keystrokes) produces into one
        // reload shortly after the last of them. A reload costs about 100 ms on a 55,000-photo
        // catalog, so it must not run per edit, nor in the middle of a key press.
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reloadDelay) { [weak self] in
            guard let self, !isStopped else { return }
            reloadScheduled = false
            reload()
        }
    }

    // MARK: - Data

    /// How many times the outline has been rebuilt (tests check that edits coalesce).
    private(set) var reloadCount = 0

    func reload() {
        reloadCount += 1
        let context = store.viewContext
        let counts = folderCounts()

        func makeItem(for folder: Folder) -> Item {
            let item = Item(kind: .folder(path: folder.path), title: folder.name)
            item.isFavorite = folder.isFavorite
            item.label = folder.label
            item.children = folder.sortedChildren.map(makeItem)
            item.count = (counts[folder.objectID] ?? 0) + item.children.reduce(0) { $0 + ($1.count ?? 0) }
            return item
        }

        let request = Folder.fetchRequest()
        request.predicate = NSPredicate(format: "parent == nil")
        request.relationshipKeyPathsForPrefetching = ["children"]
        let rootFolders = ((try? context.fetch(request)) ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let all = Item(kind: .allPhotos, title: "All Photographs")
        all.count = (try? context.count(for: Photo.fetchRequest())) ?? 0
        // An import under way is the latest from its start, before its first photo is in.
        let latestImport = state.importingID ?? Photo.latestImportID(in: context)
        let previousImport = Item(kind: .previousImport(id: latestImport), title: "Previous Import")
        previousImport.count = latestImport.map { id in
            let photos = Photo.fetchRequest()
            photos.predicate = NSPredicate(format: "importID == %@", id as CVarArg)
            return (try? context.count(for: photos)) ?? 0
        }
        let catalogHeader = Item(kind: .header, title: "Catalog")
        catalogHeader.children = [all, previousImport]
        let foldersHeader = Item(kind: .header, title: "Folders")
        foldersHeader.children = rootFolders.map(makeItem)

        let collectionsHeader = Item(kind: .collectionsHeader, title: "Collections")
        collectionsHeader.children = collectionItems()

        roots = [catalogHeader, foldersHeader, collectionsHeader]
        let publishingHeader = Item(kind: .header, title: Self.publishingTitle)
        publishingHeader.children = publishServiceItems()
        if !publishingHeader.children.isEmpty { roots.append(publishingHeader) }
        // Forget folders that are no longer in the catalog.
        var paths = Set<String>()
        func collect(_ items: [Item]) {
            for item in items {
                if case .folder(let path) = item.kind { paths.insert(path) }
                collect(item.children)
            }
        }
        collect(foldersHeader.children)
        expandedPaths.formIntersection(paths)
        saveExpansion()

        isReloading = true
        outlineView.reloadData()
        // Headers the user collapsed stay collapsed.
        if !collapsedHeaders.contains(catalogHeader.title) { outlineView.expandItem(catalogHeader) }
        if !collapsedHeaders.contains(foldersHeader.title) {
            outlineView.expandItem(foldersHeader)
            restoreExpansion(expandedPaths, in: foldersHeader.children)
        }
        if !isCollectionsCollapsed { outlineView.expandItem(collectionsHeader) }
        if !isCollectionsCollapsed { expandSets(in: collectionsHeader.children) }
        if !collapsedHeaders.contains(publishingHeader.title) { outlineView.expandItem(publishingHeader) }
        refreshCollectionScope(in: collectionsHeader.children)
        // Previous Import moves on to a new import as it comes in (and back to the one before when
        // every photo of the last is removed).
        if case .previousImport(let id) = state.filter.scope, id != latestImport {
            state.filter.scope = latestImport.map { .previousImport(id: $0) } ?? .allPhotos
        }
        selectItem(matching: state.filter.scope)
        isReloading = false
    }

    // MARK: - Publishing

    static let publishingTitle = "Publishing"

    /// The Publishing section's rows: each publish service, with the photos it has (those waiting to be
    /// removed aside). Only shown once a service is set up in the Publishing Manager.
    private func publishServiceItems() -> [Item] {
        PublishService.all(in: store.viewContext).map { service in
            let item = Item(kind: .publishService(id: service.id), title: service.displayName)
            item.count = service.publishedPhotos.count { $0.photo != nil && !$0.isRemovalPending && !$0.isDeleted }
            item.detail = switch service.kind {
            case .hardDrive: (service.settings.export.folderPath as NSString).abbreviatingWithTildeInPath
            case .flickr: service.accountName.map { "Flickr: \($0)" } ?? "Flickr: not signed in"
            }
            return item
        }
    }

    /// A publish service's context menu, each item carrying the service's ID.
    func publishServiceMenu(id: UUID) -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Publish Now", #selector(PixelLoupeActions.publishNow(_:))),
                                ("Edit Settings…", #selector(PixelLoupeActions.editPublishService(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.representedObject = id
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Publishing Manager…", action: #selector(PixelLoupeActions.showPublishingManager(_:)), keyEquivalent: ""))
        return menu
    }

    // MARK: - Collections

    /// The Collections section's rows: the filter field (when shown), then the collections,
    /// sorted by kind (sets, smart collections, collections) or name, and filtered by name.
    private func collectionItems() -> [Item] {
        let context = store.viewContext
        let request = PhotoCollection.fetchRequest()
        request.relationshipKeyPathsForPrefetching = ["children"]
        let all = (try? context.fetch(request)) ?? []
        let target = store.viewState.targetCollectionID
        let filter = collectionFilterText.trimmingCharacters(in: .whitespaces)

        func make(_ collection: PhotoCollection) -> Item? {
            let item = Item(kind: .collection(id: collection.id, kind: collection.kind), title: collection.name)
            item.content = collection.content
            item.isTarget = collection.id == target
            item.warning = collection.importWarning
            item.children = sorted(collection.children.compactMap(make))
            switch collection.kind {
            case .set:
                item.count = nil
            case .collection, .smart:
                let photos = Photo.fetchRequest()
                photos.predicate = collection.content.predicate
                item.count = (try? context.count(for: photos)) ?? 0
            }
            // Filtering keeps matches, and sets with matches inside.
            if !filter.isEmpty, collection.name.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) == nil,
               item.children.isEmpty {
                return nil
            }
            return item
        }

        func sorted(_ items: [Item]) -> [Item] {
            items.sorted { lhs, rhs in
                if collectionSort == .kind, let left = lhs.collectionKind, let right = rhs.collectionKind, left != right {
                    // Sets, then smart collections, then collections.
                    let order: [PhotoCollection.Kind] = [.set, .smart, .collection]
                    return order.firstIndex(of: left)! < order.firstIndex(of: right)!
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }

        let items = sorted(all.filter { $0.parent == nil }.compactMap(make))
        return showsCollectionFilter ? [Item(kind: .collectionFilter, title: "")] + items : items
    }

    private func expandSets(in items: [Item]) {
        for item in items where item.collectionKind == .set {
            // While filtering, every set opens to show its matches.
            if !collectionFilterText.isEmpty || !collapsedSets.contains(item.collectionID!) {
                outlineView.expandItem(item)
            }
            expandSets(in: item.children)
        }
    }

    /// Keeps the Library's scope current when the selected collection changes (its rules, or what
    /// a set contains).
    private func refreshCollectionScope(in items: [Item]) {
        guard let id = state.filter.scope.collectionID else { return }
        func find(_ items: [Item]) -> Item? {
            for item in items {
                if item.collectionID == id { return item }
                if let found = find(item.children) { return found }
            }
            return nil
        }
        // A filtered-out collection is still the one being shown.
        guard let item = find(items), let scope = item.scope, scope != state.filter.scope else { return }
        state.filter.scope = scope
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === collectionFilterField else { return }
        collectionFilterText = collectionFilterField.stringValue
        reload()
        // Reloading rebuilds the rows; keep typing in the field.
        if view.window?.firstResponder !== collectionFilterField.currentEditor() {
            collectionFilterField.allowsFocusOnce = true
            view.window?.makeFirstResponder(collectionFilterField)
            collectionFilterField.allowsFocusOnce = false
            collectionFilterField.currentEditor()?.selectedRange = NSRange(location: collectionFilterField.stringValue.utf16.count, length: 0)
        }
    }

    /// The Collections header's + menu.
    func collectionsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Create Collection…", action: #selector(PixelLoupeActions.newCollection(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Create Smart Collection…", action: #selector(PixelLoupeActions.newSmartCollection(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Create Collection Set…", action: #selector(PixelLoupeActions.newCollectionSet(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        for (title, sort) in [("Sort by Name", CollectionSort.name), ("Sort by Kind", .kind)] {
            let item = NSMenuItem(title: title, action: #selector(sortCollections(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = sort.rawValue
            item.state = collectionSort == sort ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let filter = NSMenuItem(title: "Show Collection Filter", action: #selector(toggleCollectionFilter(_:)), keyEquivalent: "")
        filter.target = self
        filter.state = showsCollectionFilter ? .on : .off
        menu.addItem(filter)
        return menu
    }

    @objc private func sortCollections(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let sort = CollectionSort(rawValue: raw) else { return }
        collectionSort = sort
    }

    @objc private func toggleCollectionFilter(_ sender: Any?) {
        if showsCollectionFilter {
            collectionFilterText = ""
            collectionFilterField.stringValue = ""
        }
        showsCollectionFilter.toggle()
    }

    /// The Collections header's + (a pull-down menu, rebuilt each time it opens).
    private(set) lazy var collectionsButton: NSPopUpButton = {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.menu?.delegate = self
        button.setAccessibilityLabel("Collection options")
        button.setAccessibilityIdentifier("collectionsAddButton")
        rebuildCollectionsButtonMenu(button.menu!)
        return button
    }()

    private static let collapsedKey = "CollectionsCollapsed"
    private static let collapsedHeadersKey = "CollapsedSidebarHeaders"

    /// The titles of the Catalog and Folders headers the user collapsed with their Show/Hide
    /// buttons (remembered).
    private var collapsedHeaders: Set<String> {
        get { Set(Defaults.store.stringArray(forKey: Self.collapsedHeadersKey) ?? []) }
        set { Defaults.store.set(newValue.sorted(), forKey: Self.collapsedHeadersKey) }
    }

    /// Whether the Collections section is collapsed to its heading (remembered).
    private(set) var isCollectionsCollapsed: Bool {
        get { Defaults.store.bool(forKey: Self.collapsedKey) }
        set {
            Defaults.store.set(newValue, forKey: Self.collapsedKey)
            updateCollectionsDisclosure()
        }
    }

    /// The Collections header's disclosure chevron, at its right (where the ⊕ menu sits beside it).
    private(set) lazy var collectionsDisclosure: NSButton = {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(toggleCollections(_:))
        button.setAccessibilityIdentifier("collectionsDisclosure")
        return button
    }()

    /// The ⊕ menu and the chevron, side by side.
    private lazy var collectionsHeaderAccessory: NSView = {
        collectionsButton.contentTintColor = .secondaryLabelColor
        let stack = NSStackView(views: [collectionsButton, collectionsDisclosure])
        stack.spacing = 4
        updateCollectionsDisclosure()
        return stack
    }()

    private func updateCollectionsDisclosure() {
        let collapsed = isCollectionsCollapsed
        collectionsDisclosure.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
                                              accessibilityDescription: collapsed ? "Show Collections" : "Hide Collections")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        collectionsDisclosure.toolTip = collapsed ? "Show collections" : "Hide collections"
        collectionsDisclosure.setAccessibilityValue(collapsed ? "collapsed" : "expanded")
    }

    @objc private func toggleCollections(_ sender: Any?) {
        isCollectionsCollapsed.toggle()
        // Reloading lays the section out collapsed or expanded (AppKit won't collapse a group row
        // without an outline cell directly).
        reload()
    }

    private func rebuildCollectionsButtonMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        // A pull-down's first item is its face.
        let face = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        face.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Collection options")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        menu.addItem(face)
        collectionsMenu().items.forEach { menu.addItem($0.copy() as! NSMenuItem) }
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === collectionsButton.menu {
            rebuildCollectionsButtonMenu(menu)
            return
        }
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? Item else { return }
        switch item.kind {
        case .collectionsHeader, .collectionFilter:
            collectionsMenu().items.forEach { menu.addItem($0.copy() as! NSMenuItem) }
        case .collection(let id, let kind):
            func add(_ title: String, _ action: Selector) {
                let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
                menuItem.representedObject = id
                menu.addItem(menuItem)
            }
            if kind == .collection {
                add(item.isTarget ? "Clear Target Collection" : "Set as Target Collection", #selector(PixelLoupeActions.setTargetCollection(_:)))
                menu.addItem(.separator())
            }
            if kind == .smart { add("Edit Smart Collection…", #selector(PixelLoupeActions.editSmartCollection(_:))) }
            add("Rename…", #selector(PixelLoupeActions.renameCollection(_:)))
            add(kind == .set ? "Delete Collection Set…" : "Delete…", #selector(PixelLoupeActions.deleteCollection(_:)))
            if kind == .set {
                menu.addItem(.separator())
                add("Create Collection…", #selector(PixelLoupeActions.newCollection(_:)))
                add("Create Smart Collection…", #selector(PixelLoupeActions.newSmartCollection(_:)))
                add("Create Collection Set…", #selector(PixelLoupeActions.newCollectionSet(_:)))
            }
        case .publishService(let id):
            publishServiceMenu(id: id).items.forEach { menu.addItem($0.copy() as! NSMenuItem) }
        case .header where item.title == Self.publishingTitle:
            menu.addItem(NSMenuItem(title: "Publishing Manager…", action: #selector(PixelLoupeActions.showPublishingManager(_:)), keyEquivalent: ""))
        case .folder(let path):
            let folderMenu = folderMenu(for: item, path: path)
            for menuItem in folderMenu.items {
                folderMenu.removeItem(menuItem)
                menu.addItem(menuItem)
            }
        default:
            break
        }
    }

    /// A folder's context menu (Lightroom's), each item carrying the folder's path.
    func folderMenu(for item: Item, path: String) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, to menu: NSMenu = menu, tag: Int = 0) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.representedObject = path
            menuItem.tag = tag
            menu.addItem(menuItem)
            return menuItem
        }
        let name = item.title
        _ = add("Create Folder Inside “\(name)”…", #selector(PixelLoupeActions.createFolderInside(_:)))
        _ = add("Create Collection Set “\(name)”", #selector(PixelLoupeActions.createCollectionSetFromFolder(_:)))
        _ = add("Create Collection “\(name)”", #selector(PixelLoupeActions.createCollectionFromFolder(_:)))
        menu.addItem(.separator())
        _ = add(item.isFavorite ? "Remove from Favorites" : "Add to Favorites", #selector(PixelLoupeActions.toggleFolderFavorite(_:)))
        let labels = NSMenu(title: "Add Color Label to Folder")
        for label in ColorLabel.allCases {
            let labelItem = add(label == .none ? "No Label" : label.title, #selector(PixelLoupeActions.setFolderColorLabel(_:)),
                                to: labels, tag: Int(label.rawValue))
            labelItem.state = item.label == label ? .on : .off
            if label != .none { labelItem.image = Self.swatch(label.color) }
        }
        let labelsItem = NSMenuItem(title: "Add Color Label to Folder", action: nil, keyEquivalent: "")
        labelsItem.submenu = labels
        menu.addItem(labelsItem)
        menu.addItem(.separator())
        _ = add("Rename…", #selector(PixelLoupeActions.renameFolder(_:)))
        _ = add("Remove…", #selector(PixelLoupeActions.removeFolder(_:)))
        menu.addItem(.separator())
        _ = add("Hide This Parent", #selector(PixelLoupeActions.hideFolderParent(_:)))
        _ = add("Show Parent Folder", #selector(PixelLoupeActions.showFolderParent(_:)))
        menu.addItem(.separator())
        _ = add("Synchronize Folder…", #selector(PixelLoupeActions.synchronizeFolder(_:)))
        if store.availability.isOffline(folderPath: path) {
            _ = add("Find Missing Folder…", #selector(PixelLoupeActions.findMissingFolder(_:)))
        }
        _ = add("Update Folder Location…", #selector(PixelLoupeActions.findMissingFolder(_:)))
        _ = add("Import to this Folder…", #selector(PixelLoupeActions.importToFolder(_:)))
        _ = add("Export this Folder as a Catalog…", #selector(PixelLoupeActions.exportFolderAsCatalog(_:)))
        menu.addItem(.separator())
        _ = add("Show in Finder", #selector(PixelLoupeActions.showFolderInFinder(_:)))
        _ = add("Get Info", #selector(PixelLoupeActions.getFolderInfo(_:)))
        return menu
    }

    /// A color label's swatch for menus.
    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    /// Keeps a renamed folder's subfolders expanded.
    func renameExpandedFolders(from oldPath: String, to newPath: String) {
        expandedPaths = Set(expandedPaths.map { path in
            path == oldPath || path.hasPrefix(oldPath + "/") ? newPath + String(path.dropFirst(oldPath.count)) : path
        })
        saveExpansion()
        reload()
    }

    // MARK: - Dropping photos on collections

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let item = item as? Item, item.collectionKind == .collection || item.publishServiceID != nil,
              !PhotoDrag.objectIDs(from: info.draggingPasteboard, store: store).isEmpty
        else { return [] }
        outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        if let item = item as? Item, let serviceID = item.publishServiceID {
            let ids = PhotoDrag.objectIDs(from: info.draggingPasteboard, store: store)
            guard !ids.isEmpty else { return false }
            PublishEditing(store: store).add(ids, to: serviceID)
            return true
        }
        guard let item = item as? Item, item.collectionKind == .collection, let id = item.collectionID else { return false }
        let ids = PhotoDrag.objectIDs(from: info.draggingPasteboard, store: store)
        guard !ids.isEmpty else { return false }
        CollectionEditing(store: store).add(ids, to: id)
        return true
    }

    /// Number of photos directly in each folder, computed in a single grouped fetch.
    private func folderCounts() -> [NSManagedObjectID: Int] {
        let countDescription = NSExpressionDescription()
        countDescription.name = "count"
        countDescription.expression = NSExpression(forFunction: "count:", arguments: [NSExpression(forKeyPath: "id")])
        countDescription.expressionResultType = .integer64AttributeType

        let request = NSFetchRequest<NSDictionary>(entityName: "Photo")
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["folder", countDescription]
        request.propertiesToGroupBy = ["folder"]

        var counts: [NSManagedObjectID: Int] = [:]
        for row in (try? store.viewContext.fetch(request)) ?? [] {
            if let folderID = row["folder"] as? NSManagedObjectID, let count = row["count"] as? Int {
                counts[folderID] = count
            }
        }
        return counts
    }

    private func saveExpansion() {
        store.viewState.expandedFolderPaths = expandedPaths
    }

    private func restoreExpansion(_ paths: Set<String>, in items: [Item]) {
        for item in items {
            if case .folder(let path) = item.kind, paths.contains(path) {
                outlineView.expandItem(item)
                restoreExpansion(paths, in: item.children)
            }
        }
    }

    private func selectItem(matching scope: LibraryFilter.Scope) {
        // Shown from the Lightroom import report: no sidebar row stands for it.
        if case .importDifference = scope {
            outlineView.deselectAll(nil)
            return
        }
        func matches(_ item: Item) -> Bool {
            if let id = scope.collectionID { return item.collectionID == id }
            if case .previousImport = scope, case .previousImport = item.kind { return true }
            return item.scope == scope
        }
        func find(in items: [Item]) -> Item? {
            for item in items {
                if matches(item) { return item }
                if let match = find(in: item.children) { return match }
            }
            return nil
        }
        guard let item = find(in: roots) else {
            state.filter.scope = .allPhotos
            selectItem(matching: .allPhotos)
            return
        }
        // Make sure ancestors are expanded so the row exists.
        var ancestors: [Item] = []
        func path(to target: Item, in items: [Item]) -> Bool {
            for candidate in items {
                if candidate === target { return true }
                ancestors.append(candidate)
                if path(to: target, in: candidate.children) { return true }
                ancestors.removeLast()
            }
            return false
        }
        _ = path(to: item, in: roots)
        for ancestor in ancestors {
            // A collapsed section stays collapsed (the item just isn't highlighted).
            if case .collectionsHeader = ancestor.kind, isCollectionsCollapsed { break }
            if case .header = ancestor.kind, collapsedHeaders.contains(ancestor.title) { break }
            outlineView.expandItem(ancestor)
            if case .folder(let path) = ancestor.kind { expandedPaths.insert(path) }
        }
        saveExpansion()
        let row = outlineView.row(forItem: item)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Item)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Item)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Item)?.children.isEmpty ?? true)
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        switch (item as? Item)?.kind {
        case .header?, .collectionsHeader?: true
        default: false
        }
    }

    /// No Show/Hide button on the Collections header: it has its own chevron (beside the ⊕ menu).
    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        if case .collectionsHeader? = (item as? Item)?.kind { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? Item)?.scope != nil
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SidebarRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? Item else { return nil }
        if case .collectionsHeader = item.kind {
            let identifier = NSUserInterfaceItemIdentifier("CollectionsHeaderCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? SidebarCellView.header(identifier: identifier, accessory: collectionsHeaderAccessory)
            cell.textField?.stringValue = item.title
            return cell
        }
        if case .collectionFilter = item.kind {
            let identifier = NSUserInterfaceItemIdentifier("CollectionFilterCell")
            if let cell = outlineView.makeView(withIdentifier: identifier, owner: self) { return cell }
            let cell = NSTableCellView()
            cell.identifier = identifier
            collectionFilterField.removeFromSuperview()
            collectionFilterField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(collectionFilterField)
            NSLayoutConstraint.activate([
                collectionFilterField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                collectionFilterField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                collectionFilterField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
        if case .header = item.kind {
            let identifier = NSUserInterfaceItemIdentifier("HeaderCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
                ?? SidebarCellView.header(identifier: identifier)
            cell.textField?.stringValue = item.title
            return cell
        }
        let identifier = NSUserInterfaceItemIdentifier("DataCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarCellView
            ?? SidebarCellView(identifier: identifier)
        let symbol = switch item.kind {
        case .allPhotos: "photo.on.rectangle"
        case .previousImport: "square.and.arrow.down"
        case .collection(_, .collection): "rectangle.stack"
        case .collection(_, .smart): "gearshape.2"
        case .collection(_, .set): "archivebox"
        case .publishService: "folder"
        default: "folder.fill"
        }
        // Lightroom marks the target collection with a +.
        var isOffline = false
        if case .folder(let path) = item.kind { isOffline = store.availability.isOffline(folderPath: path) }
        // Previous Import is dimmed until there's an import to show.
        var isEnabled = true
        if case .previousImport(nil) = item.kind { isEnabled = false }
        cell.configure(
            title: item.isTarget ? "\(item.title) +" : item.title, symbolName: isOffline ? "questionmark.folder" : symbol,
            count: item.count, isOffline: isOffline, isEnabled: isEnabled, warning: item.warning, isFavorite: item.isFavorite,
            label: item.label)
        // Cells are reused from row to row, so each row sets (or clears) its identifier.
        let accessibilityIdentifier: String? = switch item.kind {
        case .collection(let id, _): "collection.\(id.uuidString)"
        case .publishService(let id): "publishService.\(id.uuidString)"
        case .previousImport: "previousImport"
        default: nil
        }
        cell.setAccessibilityIdentifier(accessibilityIdentifier)
        if !isEnabled { cell.toolTip = "The photos of your next import will appear here." }
        if let detail = item.detail { cell.toolTip = detail }
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if !isReloading, let item = notification.userInfo?["NSObject"] as? Item, case .header = item.kind {
            collapsedHeaders.remove(item.title)
            // Bring back the folders that were expanded inside it.
            isReloading = true
            restoreExpansion(expandedPaths, in: item.children)
            isReloading = false
        }
        if !isReloading, let item = notification.userInfo?["NSObject"] as? Item, let id = item.collectionID {
            collapsedSets.remove(id)
        }
        guard !isReloading, let item = notification.userInfo?["NSObject"] as? Item,
              case .folder(let path) = item.kind else { return }
        expandedPaths.insert(path)
        // Bring back subfolders that were expanded before (or saved expanded on the last launch).
        isReloading = true
        restoreExpansion(expandedPaths, in: item.children)
        isReloading = false
        saveExpansion()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if !isReloading, let item = notification.userInfo?["NSObject"] as? Item, case .header = item.kind {
            collapsedHeaders.insert(item.title)
        }
        if !isReloading, collectionFilterText.isEmpty, let item = notification.userInfo?["NSObject"] as? Item, let id = item.collectionID {
            collapsedSets.insert(id)
        }
        guard !isReloading, let item = notification.userInfo?["NSObject"] as? Item,
              case .folder(let path) = item.kind else { return }
        // Collapsing a folder also reports its expanded subfolders as collapsed; they keep their
        // state (and come back when it's expanded again), so only a folder collapsed itself is
        // forgotten, which is one whose parent is still expanded.
        if let parent = outlineView.parent(forItem: item), !outlineView.isItemExpanded(parent) { return }
        expandedPaths.remove(path)
        saveExpansion()
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading,
              let item = outlineView.item(atRow: outlineView.selectedRow) as? Item,
              let scope = item.scope else { return }
        state.filter.scope = scope
    }
}

/// Sidebar row: icon, title and a right-aligned photo count.
final class SidebarCellView: NSTableCellView {
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateIconTint() }
    }

    static let rowHeight: CGFloat = 24

    private let countLabel = NSTextField(labelWithString: "")
    private let warningView = NSImageView()
    /// The yellow star on a favorite folder's icon.
    let favoriteBadge = NSImageView()
    /// The folder's color label, which colors its icon.
    private(set) var label: ColorLabel = .none

    static func header(identifier: NSUserInterfaceItemIdentifier, accessory: NSView? = nil) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(accessory)
            NSLayoutConstraint.activate([
                accessory.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                accessory.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        let image = SidebarIconView()
        image.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        warningView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")
        warningView.contentTintColor = .systemYellow
        warningView.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        warningView.isHidden = true
        warningView.setContentHuggingPriority(.required, for: .horizontal)
        warningView.setContentCompressionResistancePriority(.required, for: .horizontal)
        favoriteBadge.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)
        favoriteBadge.symbolConfiguration = .init(pointSize: 8, weight: .bold)
        favoriteBadge.contentTintColor = .systemYellow
        favoriteBadge.isHidden = true
        for view in [image, title, warningView, countLabel, favoriteBadge] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        imageView = image
        textField = title

        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            warningView.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 4),
            warningView.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -4),
            warningView.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            favoriteBadge.trailingAnchor.constraint(equalTo: image.trailingAnchor, constant: 2),
            favoriteBadge.bottomAnchor.constraint(equalTo: image.bottomAnchor, constant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, symbolName: String, count: Int?, isOffline: Bool = false, isEnabled: Bool = true,
                   warning: String? = nil, isFavorite: Bool = false, label: ColorLabel = .none) {
        self.label = label
        favoriteBadge.isHidden = !isFavorite
        warningView.isHidden = warning == nil
        warningView.toolTip = warning
        textField?.stringValue = title
        imageView?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        imageView?.setAccessibilityElement(false)
        updateIconTint()
        countLabel.stringValue = count?.formatted() ?? ""
        // Folders whose directory can't be found are dimmed, with a question mark on the icon, as are
        // rows with nothing to show.
        textField?.textColor = isOffline || !isEnabled ? .tertiaryLabelColor : .labelColor
        imageView?.alphaValue = isOffline || !isEnabled ? 0.5 : 1
        setAccessibilityEnabled(isEnabled)
        toolTip = isOffline ? "This folder can’t be found. Control-click it and choose Find Missing Folder…" : warning
        let details = [isOffline ? "Missing" : nil, isFavorite ? "Favorite" : nil, label == .none ? nil : "\(label.title) label"]
            .compactMap { $0 }
        setAccessibilityValue(details.isEmpty ? nil : details.joined(separator: ", "))
    }
}

extension SidebarCellView {
    /// Source-list icons take the accent color on their own; in Monochrome Mode they're black (Light
    /// Mode) or dark gray (Dark Mode) instead, and white on the selected row so they stay visible.
    func updateIconTint(monochrome: Bool = AppSettings.shared.isMonochrome) {
        // A labeled folder takes its label's color (white on the selected row, so it stays visible).
        if label != .none {
            (imageView as? SidebarIconView)?.isExactColor = true
            imageView?.contentTintColor = backgroundStyle == .emphasized ? .white : label.color
            return
        }
        (imageView as? SidebarIconView)?.isExactColor = monochrome
        guard monochrome else {
            imageView?.contentTintColor = nil
            return
        }
        imageView?.contentTintColor = backgroundStyle == .emphasized ? .white : Accent.monochrome
    }
}

/// A sidebar icon. The sidebar is vibrant, and a vibrant view blends its tint with the material behind
/// it (#545454 came out near #2F3030 in Dark Mode). In Monochrome Mode the icon opts out, so it draws
/// exactly the accent color it's given.
final class SidebarIconView: NSImageView {
    var isExactColor = false {
        didSet { if isExactColor != oldValue { needsDisplay = true } }
    }

    override var allowsVibrancy: Bool { isExactColor ? false : super.allowsVibrancy }
}

/// A sidebar row. In Monochrome Mode the selected row is filled with the monochrome color instead of
/// the accent color.
final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard AppSettings.shared.isMonochrome, selectionHighlightStyle != .none else {
            super.drawSelection(in: dirtyRect)
            return
        }
        (isEmphasized ? Accent.monochrome : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 0), xRadius: 5, yRadius: 5).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        AppSettings.shared.isMonochrome && isSelected && !isEmphasized ? .normal : super.interiorBackgroundStyle
    }
}

/// The sidebar's outline: controls in rows (the Collections + menu, the filter field) get their
/// own clicks, including in group header rows.
final class SidebarOutlineView: NSOutlineView {
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is NSButton || responder is NSSearchField { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}
