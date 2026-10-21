import AppKit
import CoreData

/// Lightroom's Library Filter bar above the grid: a header to choose the modes (Text, Attribute,
/// Metadata or None), then a row of criteria for each active mode. Click a mode to show just it,
/// Shift-click to add or remove it; the active modes' criteria all apply. \ hides the bar without
/// clearing it.
final class FilterBarViewController: NSViewController, NSMenuDelegate, NSSearchFieldDelegate {
    private let store: CatalogStore
    private let state: LibraryState

    /// Text, Attribute, Metadata and None, in that order.
    private let modeControl = NSSegmentedControl()
    private static let segmentModes: [LibraryFilter.Mode?] = LibraryFilter.Mode.allCases + [nil]
    private var rows: [LibraryFilter.Mode: NSStackView] = [:]

    private let tagsPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    private let searchField = ClickToFocusSearchField()

    init(store: CatalogStore, state: LibraryState) {
        self.store = store
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let stack = NSStackView(views: [header()] + LibraryFilter.Mode.allCases.map { mode in
            let row = row(for: mode)
            rows[mode] = row
            return row
        })
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false

        let background = FilterBarBackground()
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        // The stack only sets a minimum height, and the grid below has no height of its own, so
        // without this layout may hand the grid's space to the bar. Weaker than the rows' padding.
        let compact = background.heightAnchor.constraint(equalToConstant: 0)
        compact.priority = .defaultLow - 10
        compact.isActive = true
        background.setAccessibilityIdentifier("libraryFilter")
        view = background
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        update()
        state.addObserver(self) { [weak self] change in
            if change == .filter { self?.update() }
        }
    }

    /// ⌘F: shows the bar and the Text mode (alongside any others) and puts the cursor in its field.
    func focusSearch() {
        state.isFilterBarVisible = true
        state.filter.modes.insert(.text)
        searchField.allowsFocusOnce = true
        defer { searchField.allowsFocusOnce = false }
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: - Layout

    /// "Library Filter:  Text | Attribute | Metadata | None", centered.
    private func header() -> NSView {
        let title = NSTextField(labelWithString: "Library Filter:")
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        title.textColor = .secondaryLabelColor

        modeControl.segmentCount = Self.segmentModes.count
        modeControl.trackingMode = .selectAny
        modeControl.controlSize = .small
        modeControl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for (index, mode) in Self.segmentModes.enumerated() {
            modeControl.setLabel(mode?.title ?? "None", forSegment: index)
            modeControl.setToolTip(mode.map { "Filter by \($0.title.lowercased()); Shift-click to combine with other modes" }
                ?? "Turn off the filters", forSegment: index)
        }
        modeControl.target = self
        modeControl.action = #selector(modeClicked(_:))
        modeControl.setAccessibilityLabel("Library filter modes")
        modeControl.setAccessibilityIdentifier("filterModes")

        let leading = NSView()
        let trailing = NSView()
        let header = NSStackView(views: [leading, title, modeControl, trailing])
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 2, left: 12, bottom: 2, right: 12)
        leading.widthAnchor.constraint(equalTo: trailing.widthAnchor).isActive = true
        return header
    }

    private func row(for mode: LibraryFilter.Mode) -> NSStackView {
        let content: [NSView] = switch mode {
        case .text:
            textRow()
        case .attribute:
            [
                label("Flag"), FlagFilterControl(state: state, identifierPrefix: "filterBar."), divider(),
                label("Rating"), RatingFilterControl(state: state), divider(),
                label("Color"), ColorLabelFilterControl(state: state),
            ]
        case .metadata:
            metadataRow()
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let clear = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)!,
                             target: self, action: #selector(clearMode(_:)))
        clear.isBordered = false
        clear.contentTintColor = .tertiaryLabelColor
        clear.tag = LibraryFilter.Mode.allCases.firstIndex(of: mode)!
        clear.toolTip = "Clear the \(mode.title.lowercased()) filter"
        clear.setAccessibilityLabel("Clear \(mode.title) filter")
        clear.setAccessibilityIdentifier("clearFilter.\(mode.rawValue)")

        let row = NSStackView(views: [label(mode.title + ":", emphasized: true)] + content + [spacer, clear])
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        row.setAccessibilityIdentifier("filterRow.\(mode.rawValue)")
        return row
    }

    private func textRow() -> [NSView] {
        searchField.placeholderString = "Search camera or lens"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.setAccessibilityIdentifier("metadataSearch")
        searchField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        return [searchField]
    }

    private func metadataRow() -> [NSView] {
        tagsPopUp.controlSize = .small
        tagsPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tagsPopUp.menu?.delegate = self
        tagsPopUp.setAccessibilityIdentifier("tagFilter")
        tagsPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        return [label("Keyword"), tagsPopUp]
    }

    private func label(_ string: String, emphasized: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = emphasized ? .boldSystemFont(ofSize: NSFont.smallSystemFontSize) : .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = emphasized ? .labelColor : .secondaryLabelColor
        return label
    }

    private func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return box
    }

    private func update() {
        let filter = state.filter
        for (index, mode) in Self.segmentModes.enumerated() {
            modeControl.setSelected(mode.map { filter.modes.contains($0) } ?? filter.modes.isEmpty, forSegment: index)
        }
        for (mode, row) in rows {
            row.isHidden = !filter.modes.contains(mode)
        }
        updateTagsTitle()
        if searchField.stringValue != filter.text.query {
            searchField.stringValue = filter.text.query
        }
    }

    private func updateTagsTitle() {
        let tags = state.filter.metadata.tags
        let title = switch tags.count {
        case 0: "Any"
        case 1: tags.first!.components(separatedBy: Tag.pathSeparator).last ?? tags.first!
        default: "\(tags.count) tags"
        }
        tagsPopUp.removeAllItems()
        tagsPopUp.addItem(withTitle: title)
    }

    // MARK: - Actions

    /// Finds the segment whose selection the click changed (the control toggles it before calling us).
    @objc private func modeClicked(_ sender: NSSegmentedControl) {
        let modes = state.filter.modes
        guard let index = Self.segmentModes.indices.first(where: { index in
            sender.isSelected(forSegment: index) != (Self.segmentModes[index].map { modes.contains($0) } ?? modes.isEmpty)
        }) else { return update() }
        let extending = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        state.filter.modes = LibraryFilter.Mode.modes(afterClicking: Self.segmentModes[index], in: modes, extending: extending)
        // The control's own toggling may not match (a plain click on an active mode among others).
        update()
    }

    @objc private func clearMode(_ sender: NSButton) {
        switch LibraryFilter.Mode.allCases[sender.tag] {
        case .text: state.filter.text = .init()
        case .attribute: state.filter.attributes = .init()
        case .metadata: state.filter.metadata = .init()
        }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        state.filter.text.query = sender.stringValue.trimmingCharacters(in: .whitespaces)
    }

    @objc private func toggleTag(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if state.filter.metadata.tags.contains(name) {
            state.filter.metadata.tags.remove(name)
        } else {
            state.filter.metadata.tags.insert(name)
        }
    }

    @objc private func clearTags(_ sender: Any?) {
        state.filter.metadata.tags = []
    }

    // MARK: - NSMenuDelegate

    /// Rebuilds the tag list each time the menu opens so it reflects newly imported keywords.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let title = menu.items.first?.title ?? "Any"
        menu.removeAllItems()
        // Pull-down menus use the first item as the button title.
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")

        // Keywords that have photos, and their parents (a parent matches everything below it).
        let request = Tag.fetchRequest()
        request.predicate = NSPredicate(format: "photos.@count > 0")
        var included = Set<Tag>()
        for tag in (try? store.viewContext.fetch(request)) ?? [] {
            var current: Tag? = tag
            while let tag = current, included.insert(tag).inserted { current = tag.parent }
        }
        let tags = included.sorted { $0.pathKey.localizedStandardCompare($1.pathKey) == .orderedAscending }

        if tags.isEmpty {
            let empty = NSMenuItem(title: "No Tags", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        let clear = NSMenuItem(title: "Any Tag", action: #selector(clearTags(_:)), keyEquivalent: "")
        clear.target = self
        clear.state = state.filter.metadata.tags.isEmpty ? .on : .off
        menu.addItem(clear)
        menu.addItem(.separator())
        for tag in tags {
            let item = NSMenuItem(title: tag.name, action: #selector(toggleTag(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tag.pathKey
            item.indentationLevel = tag.pathComponents.count - 1
            item.toolTip = tag.displayPath
            item.state = state.filter.metadata.tags.contains(tag.pathKey) ? .on : .off
            menu.addItem(item)
        }
    }
}

nonisolated extension LibraryFilter.Mode {
    /// The modes after a click on `mode` in the bar's header (`nil` is None), as in Lightroom: a click
    /// shows just that mode, or none if it was the only one; Shift-click adds or removes it.
    static func modes(afterClicking mode: Self?, in current: Set<Self>, extending: Bool) -> Set<Self> {
        guard let mode else { return [] }
        if extending { return current.symmetricDifference([mode]) }
        return current == [mode] ? [] : [mode]
    }
}

/// The bar's gray, set apart from the grid and panels around it: 40% gray in light mode, 60% in dark.
final class FilterBarBackground: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor(white: Self.white(for: effectiveAppearance), alpha: 1).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Brightness (0 black … 1 white): a 40% gray is 60% white.
    static func white(for appearance: NSAppearance) -> CGFloat {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.4 : 0.6
    }
}
