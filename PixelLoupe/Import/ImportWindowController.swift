import AppKit
import SwiftUI

/// The import window (File ▸ Import Photos…), laid out as in RAW-76's mockups: FROM, Copy / Add and
/// TO across the top; sources on the left; the source's photos in the middle, each checked for
/// import unless the catalog already has it; options on the right; the totals and Import below.
final class ImportWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    typealias Source = ImportWindowSource

    /// Called with the checked files, where they go, and the card to eject afterwards (Eject After
    /// Import) when Import is clicked. The window closes itself.
    var onImport: (([ImportService.Candidate], ImportTransfer, ImportDestination, ImportExtras, _ eject: URL?) -> Void)?
    /// Called when the window closes, imported or not.
    var onClose: (() -> Void)?

    static let thumbnailSizeRange: ClosedRange<Double> = 100...400
    /// The grid pane's narrowest: the filter and the sort pop-up, once "Sort" and the count have given way.
    static let centerMinimumWidth: CGFloat = 560
    private static let thumbnailSizeKey = "ImportThumbnailSize"
    private static let includeSubfoldersKey = "ImportIncludesSubfolders"
    private static let ejectAfterImportKey = "ImportEjectsAfterImport"
    private static let sortKey = "ImportSort"
    private static let fromItem = NSToolbarItem.Identifier("importFrom")
    private static let transferItem = NSToolbarItem.Identifier("importTransfer")
    private static let toItem = NSToolbarItem.Identifier("importTo")

    private let service: ImportService
    private let catalogURL: URL
    /// The choices the panel and top bar edit (internal for tests).
    let options: ImportOptionsModel
    private let previews = ImportPreviewLoader()
    private var selection = ImportSelection(files: [])
    private var currentSource: Source?
    private var scanTask: Task<Void, Never>?
    private var keyMonitor: Any?
    /// The photo filling the grid's space, if one is enlarged.
    private var enlargedIndex: Int?
    /// The checkbox clicked last, which Shift-clicking another checks or unchecks the range from.
    private var checkAnchor: Int?

    private let sources = ImportSourceList()
    private let panes = NSSplitViewController()
    private let includeSubfolders = NSButton(checkboxWithTitle: "Include Subfolders", target: nil, action: nil)
    private let ejectAfterImport = NSButton(checkboxWithTitle: "Eject After Import", target: nil, action: nil)
    // Top bar
    private let fromIcon = NSImageView()
    private let fromPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let fromPath = NSTextField(labelWithString: "")
    private let toPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let toPath = NSTextField(labelWithString: "")
    private let toIcon = NSImageView()
    // Grid
    private let selectedLabel = NSTextField(labelWithString: "")
    private let filterControl = NSSegmentedControl(labels: ImportSelection.Filter.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let sortPopUp = NSPopUpButton()
    private let layout = NSCollectionViewFlowLayout()
    private let collectionView = PhotoCollectionView()
    private let gridScrollView = NSScrollView()
    private let enlargedView = ImportEnlargedView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let viewControl = NSSegmentedControl()
    private let sizeSlider = NSSlider()
    // Footer
    private let summaryLabel = NSTextField(labelWithString: "")
    private let presetPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    /// The Import Preset chosen in the footer, if any.
    private var chosenPresetID: UUID?
    private let importButton = ProminentButton(label: "Import", target: nil, action: nil)

    init(service: ImportService, catalogURL: URL, info: CatalogInfo, source: Source? = nil) {
        self.service = service
        self.catalogURL = catalogURL
        options = ImportOptionsModel(settings: .load(for: catalogURL, info: info))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Import Photos"
        window.titleVisibility = .hidden
        window.identifier = NSUserInterfaceItemIdentifier("importWindow")
        window.isReleasedWhenClosed = false
        // Room for every pane at its narrowest, so the split view never has to overflow the window.
        window.minSize = NSSize(width: 200 + Self.centerMinimumWidth + 280 + 2, height: 560)
        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "ImportToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.transferItem]
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.contentView = makeContent()
        window.setFrameAutosaveName("ImportWindow")
        if !window.setFrameUsingName("ImportWindow") { window.center() }

        options.onChange = { [weak self] in self?.optionsChanged() }
        options.onChooseRoot = { [weak self] in self?.chooseDestination() }
        options.onChooseSecondCopy = { [weak self] in self?.chooseSecondCopy() }
        options.collections = service.collections()
        options.keywordSuggestions = service.keywordNames()

        sources.onSelect = { [weak self] source in self?.scan(source) }
        sources.onChooseFolder = { [weak self] in self?.chooseFolder() }
        sources.hasNewPhotos = { [service] card in (try? await service.hasNewPhotos(in: [card])) ?? false }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
            return handled ? nil : event
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange(_:)), name: AppSettings.didChangeNotification, object: nil)
        sources.reload(extra: source)
        updateTopBar()
        updateCounts()
        if let source {
            sources.select(source)
        } else if let recent = RecentImportSources.folders().first {
            sources.select(Source(urls: [recent]))
        } else {
            showMessage("Choose a volume or folder to see its photos.")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        loadPresetsIfNeeded()
    }

    /// The develop presets for Apply During Import, read from disk once the window is on screen.
    private func loadPresetsIfNeeded() {
        guard options.presetGroups.isEmpty, !isLoadingPresets else { return }
        isLoadingPresets = true
        Task { [weak self] in
            await PresetLibrary.shared.load()
            self?.options.presetGroups = PresetLibrary.shared.groups
        }
    }

    private var isLoadingPresets = false

    /// Shows `source`, from a drop on the catalog window while the import window is open.
    func open(_ source: Source) {
        sources.reload(extra: source)
        sources.select(source)
        showWindow(nil)
    }

    /// Import to this Folder: copies straight into `folder` (no subfolder or date folders).
    func copyInto(_ folder: URL) {
        options.transfer = .copy
        options.root = folder
        options.usesSubfolder = false
        options.layout = .oneFolder
    }

    /// Synchronize Folder: adds the folder's new photos where they are.
    func addInPlace() {
        options.transfer = .add
    }

    /// Monochrome Mode and the accent: the controls in the toolbar aren't in the content view, which
    /// `Accent` recolors when the window becomes key, so they're done here too.
    func windowDidBecomeKey(_ notification: Notification) {
        applyAccent()
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        applyAccent()
        collectionView.reloadData()
    }

    private func applyAccent() {
        guard let window else { return }
        if let content = window.contentView { Accent.apply(in: content) }
        for item in window.toolbar?.items ?? [] { if let view = item.view { Accent.apply(in: view) } }
    }

    func windowWillClose(_ notification: Notification) {
        scanTask?.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        // The window can outlive this controller for a moment (a layout pass still pending). Empty the
        // grid now, so that pass doesn't ask a released data source for items it no longer has, which
        // throws.
        selection = ImportSelection(files: [])
        collectionView.reloadData()
        collectionView.dataSource = nil
        onClose?()
    }

    // MARK: - Layout

    private func makeContent() -> NSView {
        // The split view controller enforces each pane's width limits itself; width constraints on the
        // panes fought the split view and pulled the sidebar away from the window's edge.
        func pane(_ view: NSView, minimum: CGFloat, maximum: CGFloat, holding: Float) -> NSSplitViewItem {
            let item = NSSplitViewItem(viewController: PaneController(view: view))
            item.minimumThickness = minimum
            item.maximumThickness = maximum
            item.holdingPriority = .init(holding)
            item.canCollapse = false
            return item
        }
        panes.splitViewItems = [
            pane(makeSidebar(), minimum: 200, maximum: 340, holding: 260),
            pane(makeCenter(), minimum: Self.centerMinimumWidth, maximum: NSSplitViewItem.unspecifiedDimension, holding: 240),
            pane(makeInspector(), minimum: 280, maximum: 420, holding: 260),
        ]
        let split = panes.splitView
        split.dividerStyle = .thin
        split.autosaveName = "ImportWindowPanes"

        let stack = NSStackView(views: [panes.view, separator(), makeFooter()])
        stack.orientation = .vertical
        stack.spacing = 0
        fillWidth(stack)
        panes.view.setContentHuggingPriority(.init(1), for: .vertical)
        DispatchQueue.main.async {
            // Starting widths, unless the user has dragged the dividers before.
            if split.subviews[0].frame.width < 210 || split.subviews[0].frame.width > 330 {
                split.setPosition(240, ofDividerAt: 0)
                split.setPosition(split.frame.width - 330, ofDividerAt: 1)
            }
        }
        return stack
    }

    /// Pins each row of a vertical stack to the stack's full width. (A vertical stack view lets rows be
    /// narrower than itself and centers them, which left the panes floating in the middle of the window
    /// with a gap at the left.)
    private func fillWidth(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func makeSidebar() -> NSView {
        let scroll = NSScrollView()
        scroll.documentView = sources.outlineView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        includeSubfolders.state = Defaults.store.object(forKey: Self.includeSubfoldersKey) as? Bool ?? true ? .on : .off
        includeSubfolders.target = self
        includeSubfolders.action = #selector(includeSubfoldersChanged(_:))
        ejectAfterImport.state = Defaults.store.bool(forKey: Self.ejectAfterImportKey) ? .on : .off
        ejectAfterImport.target = self
        ejectAfterImport.action = #selector(ejectAfterImportChanged(_:))
        ejectAfterImport.isEnabled = false
        ejectAfterImport.toolTip = "Ejects the memory card once its photos are imported"
        ejectAfterImport.setAccessibilityIdentifier("importEjectAfterImport")
        let footer = NSStackView(views: [includeSubfolders, ejectAfterImport])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 14)

        let stack = NSStackView(views: [scroll, separator(), footer])
        stack.orientation = .vertical
        stack.spacing = 0
        fillWidth(stack)
        scroll.setContentHuggingPriority(.init(1), for: .vertical)

        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        pin(stack, in: background)
        return background
    }

    private func makeCenter() -> NSView {
        // Header: the count, the filter and the sort.
        selectedLabel.textColor = .secondaryLabelColor
        selectedLabel.setAccessibilityIdentifier("importSelectedCount")
        filterControl.selectedSegment = ImportSelection.Filter.all.rawValue
        filterControl.target = self
        filterControl.action = #selector(filterChanged(_:))
        filterControl.setAccessibilityLabel("Show")
        let sortLabel = NSTextField(labelWithString: "Sort")
        sortLabel.textColor = .secondaryLabelColor
        for sort in ImportSelection.Sort.allCases {
            sortPopUp.addItem(withTitle: sort.title)
            sortPopUp.lastItem?.representedObject = sort.rawValue
        }
        let storedSort = Defaults.store.string(forKey: Self.sortKey).flatMap(ImportSelection.Sort.init) ?? .captureTime
        sortPopUp.selectItem(at: ImportSelection.Sort.allCases.firstIndex(of: storedSort) ?? 0)
        selection.setSort(storedSort)
        sortPopUp.target = self
        sortPopUp.action = #selector(sortChanged(_:))
        sortPopUp.setAccessibilityLabel("Sort")
        let header = bar([selectedLabel, flexible(), filterControl, flexible(), sortLabel, sortPopUp])
        // When the pane is narrow, "Sort" goes first and then the count, rather than the bar forcing the
        // pane wider than the split view allows.
        header.setVisibilityPriority(.init(rawValue: 800), for: sortLabel)
        header.setVisibilityPriority(.init(rawValue: 850), for: selectedLabel)

        // The grid, or one photo enlarged, on the matte.
        let size = Defaults.store.object(forKey: Self.thumbnailSizeKey) as? Double ?? 140
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        layout.sectionHeadersPinToVisibleBounds = true
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.photoDelegate = self
        collectionView.register(ImportGridItem.self, forItemWithIdentifier: ImportGridItem.identifier)
        collectionView.register(
            ImportFolderHeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: ImportFolderHeaderView.identifier)
        collectionView.setAccessibilityIdentifier("importGrid")
        gridScrollView.documentView = collectionView
        gridScrollView.hasVerticalScroller = true
        gridScrollView.autohidesScrollers = true
        gridScrollView.drawsBackground = false
        gridScrollView.contentView.drawsBackground = false

        enlargedView.isHidden = true
        enlargedView.onToggle = { [weak self] in self?.toggleEnlarged() }
        enlargedView.onDoubleClick = { [weak self] in self?.showGrid() }
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        spinner.style = .spinning
        spinner.isDisplayedWhenStopped = false

        let matte = MatteView()
        for view in [gridScrollView, enlargedView] as [NSView] { pin(view, in: matte) }
        for view in [emptyLabel, spinner] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            matte.addSubview(view)
        }
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: matte.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: matte.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            spinner.centerXAnchor.constraint(equalTo: matte.centerXAnchor),
            spinner.bottomAnchor.constraint(equalTo: emptyLabel.topAnchor, constant: -10),
        ])
        matte.onMatteChange = { [weak self] in self?.collectionView.reloadData() }

        // Bottom: grid or loupe, check all or none, thumbnail size.
        viewControl.segmentCount = 2
        viewControl.trackingMode = .selectOne
        viewControl.setImage(NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Grid"), forSegment: 0)
        viewControl.setImage(NSImage(systemSymbolName: "square", accessibilityDescription: "Loupe"), forSegment: 1)
        viewControl.setToolTip("Grid", forSegment: 0)
        viewControl.setToolTip("Loupe: the selected photo enlarged", forSegment: 1)
        viewControl.selectedSegment = 0
        viewControl.target = self
        viewControl.action = #selector(viewChanged(_:))
        let checkAll = NSButton(title: "Check All", target: self, action: #selector(checkAll(_:)))
        let uncheckAll = NSButton(title: "Uncheck All", target: self, action: #selector(uncheckAll(_:)))
        sizeSlider.minValue = Self.thumbnailSizeRange.lowerBound
        sizeSlider.maxValue = Self.thumbnailSizeRange.upperBound
        sizeSlider.doubleValue = min(max(size, Self.thumbnailSizeRange.lowerBound), Self.thumbnailSizeRange.upperBound)
        sizeSlider.controlSize = .small
        sizeSlider.target = self
        sizeSlider.action = #selector(thumbnailSizeChanged(_:))
        sizeSlider.setAccessibilityLabel("Thumbnail size")
        // The slider shrinks before anything else in the bar is squeezed.
        let sliderWidth = sizeSlider.widthAnchor.constraint(equalToConstant: 150)
        sliderWidth.priority = .init(400)
        sliderWidth.isActive = true
        sizeSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
        let small = NSImageView(image: NSImage(systemSymbolName: "square", accessibilityDescription: nil) ?? NSImage())
        let large = NSImageView(image: NSImage(systemSymbolName: "square", accessibilityDescription: nil) ?? NSImage())
        small.symbolConfiguration = .init(pointSize: 8, weight: .regular)
        large.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        for view in [small, large] { view.contentTintColor = .secondaryLabelColor }
        let bottom = bar([viewControl, checkAll, uncheckAll, flexible(), small, sizeSlider, large])
        for icon in [small, large] { bottom.setVisibilityPriority(.init(rawValue: 800), for: icon) }
        updateItemSize()

        let stack = NSStackView(views: [header, separator(), matte, separator(), bottom])
        stack.orientation = .vertical
        stack.spacing = 0
        fillWidth(stack)
        matte.setContentHuggingPriority(.init(1), for: .vertical)
        return stack
    }

    private func makeInspector() -> NSView {
        let hosting = NSHostingView(rootView: ImportOptionsPanel(model: options))
        hosting.sizingOptions = []
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        pin(hosting, in: background)
        return background
    }

    private func makeFooter() -> NSView {
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.setAccessibilityIdentifier("importSummary")
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        cancel.controlSize = .large
        importButton.target = self
        importButton.action = #selector(importChecked(_:))
        importButton.setAccessibilityIdentifier("importButton")
        let presetLabel = NSTextField(labelWithString: "Import Preset")
        presetLabel.textColor = .secondaryLabelColor
        presetPopUp.setAccessibilityLabel("Import Preset")
        presetPopUp.setAccessibilityIdentifier("importPreset")
        presetPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        chosenPresetID = ImportPreset.chosen(for: catalogURL)
        updatePresetMenu()
        // The preset sits in the middle of the footer, as in the mockups.
        let left = flexible(), right = flexible()
        let footer = bar([summaryLabel, left, presetLabel, presetPopUp, right, cancel, importButton])
        left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        footer.setVisibilityPriority(.init(rawValue: 800), for: presetLabel)
        footer.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 12, right: 16)
        return footer
    }

    private func bar(_ views: [NSView]) -> NSStackView {
        let bar = NSStackView(views: views)
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        return bar
    }

    private func flexible() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        return spacer
    }

    private func pin(_ view: NSView, in container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Top bar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.fromItem, .flexibleSpace, Self.transferItem, .flexibleSpace, Self.toItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.isBordered = false
        switch identifier {
        case Self.fromItem:
            item.label = "From"
            item.view = makeFromView()
        case Self.transferItem:
            item.label = "Copy or Add"
            item.view = makeTransferView()
        case Self.toItem:
            item.label = "To"
            item.view = makeToView()
        default:
            return nil
        }
        return item
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func configure(_ popUp: NSPopUpButton, path: NSTextField) {
        popUp.isBordered = false
        popUp.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        (popUp.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtCenter
        path.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingHead
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        path.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
    }

    private func makeFromView() -> NSView {
        configure(fromPopUp, path: fromPath)
        fromPopUp.setAccessibilityLabel("Import from")
        fromPopUp.setAccessibilityIdentifier("importFrom")
        fromIcon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        fromIcon.contentTintColor = .secondaryLabelColor
        let title = NSStackView(views: [caption("FROM"), fromPopUp])
        title.spacing = 4
        let text = NSStackView(views: [title, fromPath])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let view = NSStackView(views: [fromIcon, text])
        view.spacing = 10
        return view
    }

    private func makeTransferView() -> NSView {
        let view = NSHostingView(rootView: ImportTransferBar(model: options))
        view.sizingOptions = [.intrinsicContentSize]
        return view
    }

    private func makeToView() -> NSView {
        configure(toPopUp, path: toPath)
        toPath.alignment = .right
        toPopUp.setAccessibilityLabel("Import to")
        toPopUp.setAccessibilityIdentifier("importTo")
        toIcon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        toIcon.contentTintColor = .secondaryLabelColor
        let title = NSStackView(views: [caption("TO"), toPopUp])
        title.spacing = 4
        let text = NSStackView(views: [title, toPath])
        text.orientation = .vertical
        text.alignment = .trailing
        text.spacing = 0
        let view = NSStackView(views: [text, toIcon])
        view.spacing = 10
        return view
    }

    private func updateTopBar() {
        // FROM: the source, with the places it could be instead.
        let fromMenu = NSMenu()
        fromMenu.addItem(withTitle: currentSource?.title ?? "Choose a Source", action: nil, keyEquivalent: "")
        for root in sources.roots {
            fromMenu.addItem(.separator())
            for node in root.children ?? [] {
                if let source = node.source {
                    let item = fromMenu.addItem(withTitle: node.title, action: #selector(fromMenuChose(_:)), keyEquivalent: "")
                    item.target = self
                    item.image = NSImage(systemSymbolName: node.symbol, accessibilityDescription: nil)
                    item.representedObject = source.urls
                    item.state = source == currentSource ? .on : .off
                } else {
                    let item = fromMenu.addItem(withTitle: node.title, action: #selector(chooseFolder(_:)), keyEquivalent: "")
                    item.target = self
                }
            }
        }
        fromPopUp.menu = fromMenu
        fromPath.stringValue = currentSource?.breadcrumb ?? "No source chosen"
        fromIcon.image = NSImage(systemSymbolName: currentSource?.symbol ?? "folder", accessibilityDescription: nil)

        let transfer = options.effectiveTransfer

        // TO: where copies go, or that photos stay put.
        let toMenu = NSMenu()
        let destination = options.destination
        toMenu.addItem(withTitle: FileManager.default.displayName(atPath: destination.root.path(percentEncoded: false)), action: nil, keyEquivalent: "")
        for directory in [FileManager.SearchPathDirectory.picturesDirectory, .desktopDirectory] {
            guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first else { continue }
            let item = toMenu.addItem(withTitle: FileManager.default.displayName(atPath: url.path(percentEncoded: false)),
                                      action: #selector(toMenuChose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.state = url.standardizedFileURL == destination.root.standardizedFileURL ? .on : .off
        }
        toMenu.addItem(.separator())
        let other = toMenu.addItem(withTitle: "Choose Folder…", action: #selector(chooseDestinationFromMenu(_:)), keyEquivalent: "")
        other.target = self
        toPopUp.menu = toMenu
        toPopUp.isEnabled = transfer == .copy
        if transfer == .copy {
            let sample = selection.files.first?.captureDate ?? Date()
            toPath.stringValue = ImportWindowSource.breadcrumb(for: destination.folder(for: sample))
            toIcon.image = NSImage(systemSymbolName: ImportWindowSource(urls: [destination.root]).symbol == "externaldrive" ? "externaldrive" : "internaldrive", accessibilityDescription: nil)
        } else {
            toPath.stringValue = "Photos stay where they are"
            toIcon.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)
        }
        applyAccent()
    }

    @objc private func fromMenuChose(_ sender: NSMenuItem) {
        guard let urls = sender.representedObject as? [URL] else { return }
        sources.select(Source(urls: urls))
    }

    @objc private func toMenuChose(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        options.root = url
    }

    @objc private func chooseDestinationFromMenu(_ sender: Any?) {
        chooseDestination()
    }

    private func chooseSecondCopy() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose the folder for second copies. Each import goes in an “Imported on” folder in it."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = options.secondCopy
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            options.secondCopy = url
        }
    }

    private func chooseDestination() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose the folder to copy photos into."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = options.root
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            options.root = url
        }
    }

    // MARK: - Import presets

    private var chosenPreset: ImportPreset? {
        ImportPreset.all().first { $0.id == chosenPresetID }
    }

    /// The footer's Import Preset menu: None, the presets (the chosen one marked "edited" once its
    /// choices are changed), and saving, updating, renaming and deleting.
    private func updatePresetMenu() {
        let presets = ImportPreset.all()
        if let chosenPresetID, !presets.contains(where: { $0.id == chosenPresetID }) { self.chosenPresetID = nil }
        let chosen = presets.first { $0.id == chosenPresetID }
        let isEdited = chosen.map { $0.settings != options.settings } ?? false
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector?, enabled: Bool = true) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            return item
        }
        let none = add("None", #selector(choosePreset(_:)))
        for preset in presets {
            let item = add(preset.id == chosenPresetID && isEdited ? "\(preset.name) (edited)" : preset.name, #selector(choosePreset(_:)))
            item.representedObject = preset.id
        }
        menu.addItem(.separator())
        _ = add("Save Current Settings as New Preset…", #selector(savePreset(_:)))
        if let chosen {
            _ = add("Update Preset “\(chosen.name)”", #selector(updatePreset(_:)), enabled: isEdited)
            _ = add("Rename Preset “\(chosen.name)”…", #selector(renamePreset(_:)))
            _ = add("Delete Preset “\(chosen.name)”…", #selector(deletePreset(_:)))
        }
        menu.autoenablesItems = false
        presetPopUp.menu = menu
        presetPopUp.select(menu.items.first { ($0.representedObject as? UUID) == chosenPresetID && chosenPresetID != nil } ?? none)
    }

    @objc private func choosePreset(_ sender: NSMenuItem) {
        chosenPresetID = sender.representedObject as? UUID
        ImportPreset.setChosen(chosenPresetID, for: catalogURL)
        if let preset = chosenPreset { options.apply(preset.settings) }
        updatePresetMenu()
    }

    @objc private func savePreset(_ sender: Any?) {
        askForName(title: "New Import Preset", message: "Saves Copy or Add, the right panel's choices and the destination (not keywords).",
                   initial: "", confirm: "Save") { [weak self] name in
            guard let self else { return }
            let preset = ImportPreset(name: name, settings: options.settings)
            ImportPreset.save(ImportPreset.all() + [preset])
            chosenPresetID = preset.id
            ImportPreset.setChosen(preset.id, for: catalogURL)
            updatePresetMenu()
        }
        updatePresetMenu()
    }

    @objc private func updatePreset(_ sender: Any?) {
        guard let chosenPresetID else { return }
        ImportPreset.save(ImportPreset.all().map { $0.id == chosenPresetID ? ImportPreset(id: $0.id, name: $0.name, settings: options.settings) : $0 })
        updatePresetMenu()
    }

    @objc private func renamePreset(_ sender: Any?) {
        guard let chosen = chosenPreset else { return }
        askForName(title: "Rename Import Preset", message: nil, initial: chosen.name, confirm: "Rename") { [weak self] name in
            ImportPreset.save(ImportPreset.all().map { $0.id == chosen.id ? ImportPreset(id: $0.id, name: name, settings: $0.settings) : $0 })
            self?.updatePresetMenu()
        }
        updatePresetMenu()
    }

    @objc private func deletePreset(_ sender: Any?) {
        guard let chosen = chosenPreset, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the import preset “\(chosen.name)”?"
        alert.informativeText = "The window's current choices stay as they are."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            ImportPreset.save(ImportPreset.all().filter { $0.id != chosen.id })
            chosenPresetID = nil
            ImportPreset.setChosen(nil, for: catalogURL)
            updatePresetMenu()
        }
        updatePresetMenu()
    }

    private func askForName(title: String, message: String?, initial: String, confirm: String, then: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message ?? ""
        let field = NSTextField(string: initial)
        field.placeholderString = "Preset name"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            then(name)
        }
    }

    private func optionsChanged() {
        updatePresetMenu()
        options.settings.save(for: catalogURL)
        selection.setTransfer(options.effectiveTransfer)
        selection.setDestination(options.destination)
        selection.setAllowsDuplicates(!options.skipsDuplicates)
        selection.setSkipsRejected(options.skipsRejected)
        if enlargedIndex == nil { collectionView.reloadData() } else { refreshChecks() }
        updateTopBar()
        updateCounts()
    }

    // MARK: - Sources

    private func scan(_ source: Source) {
        currentSource = source
        // A card's photos are copied: added in place, they'd be gone once the card is ejected.
        let onCard = ImportCards.isOnCard(source.urls)
        options.addUnavailableReason = onCard ? "Add isn't available for memory cards; photos on them are copied" : nil
        ejectAfterImport.isEnabled = onCard
        scanTask?.cancel()
        showGrid()
        replaceSelection(with: [])
        updateTopBar()
        showMessage("Reading photos…", busy: true)
        let includeSubfolders = includeSubfolders.state == .on
        scanTask = Task { [weak self, service] in
            do {
                let result = try await service.scan(source.urls, includeSubfolders: includeSubfolders)
                guard let self, !Task.isCancelled else { return }
                show(result, from: source)
            } catch is CancellationError {
                return
            } catch {
                self?.showMessage(error.localizedDescription)
            }
        }
    }

    private func replaceSelection(with files: [ImportService.ScannedFile]) {
        checkAnchor = nil
        selection = ImportSelection(
            files: files, transfer: options.effectiveTransfer, sort: selection.sort, filter: selection.filter,
            destination: options.destination, allowsDuplicates: !options.skipsDuplicates, skipsRejected: options.skipsRejected)
        collectionView.reloadData()
        updateCounts()
    }

    private func show(_ result: ImportService.ScanResult, from source: Source) {
        replaceSelection(with: result.files)
        sources.setCount(result.files.count, for: source)
        updateTopBar()
        if result.files.isEmpty {
            showMessage(result.unreadable.isEmpty ? "No photos or videos were found." : "None of the files could be read.")
        } else {
            showMessage(nil)
            if !selection.sections.isEmpty {
                collectionView.scrollToItems(at: [IndexPath(item: 0, section: 0)], scrollPosition: .top)
            }
        }
    }

    private func showMessage(_ message: String?, busy: Bool = false) {
        emptyLabel.stringValue = message ?? ""
        emptyLabel.isHidden = message == nil
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc private func chooseFolder(_ sender: Any? = nil) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a folder of photos to import."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            let source = Source(urls: [url])
            sources.reload(extra: source)
            sources.select(source)
        }
    }

    @objc private func ejectAfterImportChanged(_ sender: NSButton) {
        Defaults.store.set(sender.state == .on, forKey: Self.ejectAfterImportKey)
    }

    @objc private func includeSubfoldersChanged(_ sender: NSButton) {
        Defaults.store.set(sender.state == .on, forKey: Self.includeSubfoldersKey)
        if let currentSource { scan(currentSource) }
    }

    // MARK: - Grid

    @objc private func filterChanged(_ sender: NSSegmentedControl) {
        guard let filter = ImportSelection.Filter(rawValue: sender.selectedSegment) else { return }
        selection.setFilter(filter)
        layout.headerReferenceSize = NSSize(width: 0, height: filter == .destinationFolders ? ImportGridItem.headerHeight : 0)
        showGrid()
        collectionView.reloadData()
    }

    @objc private func sortChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let sort = ImportSelection.Sort(rawValue: raw) else { return }
        Defaults.store.set(raw, forKey: Self.sortKey)
        selection.setSort(sort)
        collectionView.reloadData()
    }

    @objc private func thumbnailSizeChanged(_ sender: NSSlider) {
        Defaults.store.set(sender.doubleValue, forKey: Self.thumbnailSizeKey)
        updateItemSize()
    }

    private func updateItemSize() {
        let side = sizeSlider.doubleValue
        layout.itemSize = NSSize(width: side, height: side * 1.2)
        layout.invalidateLayout()
    }

    // MARK: - Checking

    private func updateCounts() {
        options.duplicateCount = selection.duplicateCount
        let example = selection.shown.first { selection.isChecked($0) } ?? selection.shown.first
        options.exampleFile = example.map { (selection.files[$0].candidate.source.url.lastPathComponent, selection.files[$0].captureDate) }
        options.rejectedCount = selection.files.indices.count(where: selection.isRejected)
        selectedLabel.stringValue = selection.files.isEmpty ? "" : "\(selection.checkedCount) of \(selection.files.count) selected"
        let count = selection.checkedCount
        let photos = count == 1 ? "1 photo" : "\(count) photos"
        summaryLabel.stringValue = selection.files.isEmpty
            ? "" : "\(photos) · \(ByteCountFormatter.string(fromByteCount: selection.checkedBytes, countStyle: .file))"
        importButton.label = count == 0 ? "Import" : count == 1 ? "Import 1 Photo" : "Import \(count) Photos"
        importButton.isEnabled = count > 0
    }

    /// Updates the checkboxes on screen after the checks change.
    private func refreshChecks() {
        for indexPath in collectionView.indexPathsForVisibleItems() {
            let index = selection.index(at: indexPath)
            (collectionView.item(at: indexPath) as? ImportGridItem)?
                .setCheck(selection.check(index))
        }
        if let enlargedIndex {
            enlargedView.setCheck(selection.check(enlargedIndex))
        }
        updateCounts()
    }

    private func toggle(_ indexes: [Int]) {
        guard !indexes.isEmpty else { return }
        selection.toggle(indexes)
        refreshChecks()
    }

    private func checkboxClicked(_ index: Int, extendsRange: Bool) {
        if extendsRange, let checkAnchor, checkAnchor != index {
            selection.checkRange(from: checkAnchor, to: index)
            refreshChecks()
        } else {
            toggle([index])
        }
        checkAnchor = index
    }

    /// Space: checks or unchecks the enlarged photo, or the selected photos.
    private func toggleSelected() {
        if let enlargedIndex {
            toggle([enlargedIndex])
        } else {
            toggle(collectionView.selectionIndexPaths.sorted().map { selection.index(at: $0) })
        }
    }

    private func toggleEnlarged() {
        if let enlargedIndex { toggle([enlargedIndex]) }
    }

    @objc private func checkAll(_ sender: Any?) {
        selection.setAll(true)
        refreshChecks()
    }

    @objc private func uncheckAll(_ sender: Any?) {
        selection.setAll(false)
        refreshChecks()
    }

    // MARK: - Enlarged photo

    @objc private func viewChanged(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 1 {
            let selected = collectionView.selectionIndexPaths.min().map { selection.index(at: $0) }
            guard let index = selected ?? selection.shown.first else {
                sender.selectedSegment = 0
                return
            }
            enlarge(index)
        } else {
            showGrid()
        }
    }

    private func enlarge(_ index: Int) {
        enlargedIndex = index
        enlargedView.show(
            selection.files[index], number: selection.number(of: index), check: selection.check(index), previews: previews)
        enlargedView.isHidden = false
        gridScrollView.isHidden = true
        viewControl.selectedSegment = 1
        if let indexPath = selection.indexPath(of: index) {
            collectionView.selectionIndexPaths = [indexPath]
        }
        window?.makeFirstResponder(enlargedView)
    }

    private func showGrid() {
        viewControl.selectedSegment = 0
        guard let enlargedIndex else { return }
        self.enlargedIndex = nil
        enlargedView.isHidden = true
        enlargedView.clear()
        gridScrollView.isHidden = false
        if let indexPath = selection.indexPath(of: enlargedIndex) {
            collectionView.selectionIndexPaths = [indexPath]
            collectionView.scrollToItems(at: [indexPath], scrollPosition: .nearestHorizontalEdge)
        }
        window?.makeFirstResponder(collectionView)
    }

    /// ← and → while a photo is enlarged, in the grid's order.
    private func step(_ offset: Int) {
        let shown = selection.shown
        guard let enlargedIndex, let position = shown.firstIndex(of: enlargedIndex),
              shown.indices.contains(position + offset) else { return }
        enlarge(shown[position + offset])
    }

    // MARK: - Keys

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.window === window, window?.attachedSheet == nil,
              !((window?.firstResponder as? NSText)?.isEditable ?? false),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if event.charactersIgnoringModifiers == " " {
            toggleSelected()
            return true
        }
        guard enlargedIndex != nil else { return false }
        switch event.specialKey {
        case .leftArrow?: step(-1); return true
        case .rightArrow?: step(1); return true
        default: break
        }
        if event.keyCode == 53 {   // Escape
            showGrid()
            return true
        }
        return false
    }

    // MARK: - Actions

    @objc private func cancel(_ sender: Any?) {
        // Escape leaves the enlarged photo first (handled before this), so here it closes the window.
        window?.performClose(nil)
    }

    @objc private func importChecked(_ sender: Any?) {
        let candidates = selection.checkedCandidates
        guard !candidates.isEmpty else { return }
        // Cards come and go; they're listed under Devices while they're in.
        if let currentSource, currentSource.isSingleFolder, !ImportCards.isOnCard(currentSource.urls) {
            RecentImportSources.note(currentSource.urls[0])
        }
        options.settings.save(for: catalogURL)
        let card = ejectAfterImport.state == .on ? currentSource.flatMap { ImportCards.isOnCard($0.urls) ? ImportCards.card(containing: $0.urls[0]) : nil } : nil
        onImport?(candidates, options.effectiveTransfer, options.destination, options.extras, card)
        close()
    }
}

// MARK: - Grid data

extension ImportWindowController: NSCollectionViewDataSource, PhotoCollectionViewDelegate {
    func numberOfSections(in collectionView: NSCollectionView) -> Int { selection.sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        selection.sections[section].items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ImportGridItem.identifier, for: indexPath)
        if let item = item as? ImportGridItem {
            let index = selection.index(at: indexPath)
            item.configure(
                with: selection.files[index], number: selection.number(of: index), check: selection.check(index), previews: previews)
            item.onToggle = { [weak self] extendsRange in self?.checkboxClicked(index, extendsRange: extendsRange) }
        }
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath
    ) -> NSView {
        let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: ImportFolderHeaderView.identifier, for: indexPath)
        if let header = view as? ImportFolderHeaderView, selection.sections.indices.contains(indexPath.section) {
            let section = selection.sections[indexPath.section]
            header.configure(title: section.title ?? "", count: section.items.count)
        }
        return view
    }

    func collectionView(_ collectionView: PhotoCollectionView, menuForItemAt indexPath: IndexPath) -> NSMenu? { nil }

    func collectionView(_ collectionView: PhotoCollectionView, didDoubleClickItemAt indexPath: IndexPath) {
        enlarge(selection.index(at: indexPath))
    }
}

/// A view controller around a view built in code, for a split view pane.
private final class PaneController: NSViewController {
    private let content: NSView

    init(view: NSView) {
        content = view
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() { view = content }
}
