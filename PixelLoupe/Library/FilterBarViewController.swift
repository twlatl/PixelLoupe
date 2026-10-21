import AppKit
import CoreData
import SwiftUI

/// Lightroom's Library Filter bar above the grid: a header to choose the modes (Text, Attribute,
/// Metadata or None), then a row of criteria for each active mode. Click a mode to show just it,
/// Shift-click to add or remove it; the active modes' criteria all apply. \ hides the bar without
/// clearing it.
final class FilterBarViewController: NSViewController, NSSearchFieldDelegate, NSMenuDelegate {
    private let store: CatalogStore
    private let state: LibraryState
    private let presets: FilterPresets
    /// The filter presets, at the right of the header, titled with the preset the filter matches.
    private let presetsPopUp = NSPopUpButton(frame: .zero, pullsDown: true)

    /// Text, Attribute, Metadata and None, in that order.
    private let modeSelection = FilterModeSelection()
    private lazy var modeControl = NSHostingView(rootView: FilterModePicker(selection: modeSelection))
    private var rows: [LibraryFilter.Mode: NSStackView] = [:]
    /// The Attribute groups in two halves, side by side or (in a narrow grid) one above the other.
    private let attributeHalves = NSStackView()

    /// Holds the Metadata columns, made the first time the mode shows (they count photos as they go).
    private let metadataContainer = NSView()
    private var metadataBrowser: MetadataBrowserView?
    private let searchField = ClickToFocusSearchField()
    private let textFieldPopUp = NSPopUpButton()
    private let textRulePopUp = NSPopUpButton()
    /// The search typed so far, applied after a short pause so each key doesn't refetch the grid.
    private var pendingSearch: DispatchWorkItem?
    static let searchDelay: TimeInterval = 0.15

    /// Gives the keyboard back to the grid (Esc in the search field).
    var onEndSearch: (() -> Void)?

    init(store: CatalogStore, state: LibraryState, presets: FilterPresets = .shared) {
        self.store = store
        self.state = state
        self.presets = presets
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

    override func viewDidLayout() {
        super.viewDidLayout()
        // Room for the row's title, its × and margins besides the groups.
        let halves = attributeHalves.arrangedSubviews.map(\.fittingSize.width)
        let needed = halves.reduce(0, +) + attributeHalves.spacing + 160
        let orientation: NSUserInterfaceLayoutOrientation = view.bounds.width >= needed ? .horizontal : .vertical
        if attributeHalves.orientation != orientation { attributeHalves.orientation = orientation }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        update()
        state.addObserver(self) { [weak self] change in
            if change == .filter { self?.update() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(presetsDidChange(_:)), name: FilterPresets.didChangeNotification, object: presets
        )
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

        modeSelection.onClick = { [weak self] mode, extending in
            guard let self else { return }
            state.filter.modes = LibraryFilter.Mode.modes(afterClicking: mode, in: state.filter.modes, extending: extending)
        }
        modeControl.sizingOptions = .intrinsicContentSize
        modeControl.setAccessibilityLabel("Library filter modes")
        modeControl.setAccessibilityIdentifier("filterModes")

        let leading = NSView()
        let trailing = NSView()
        let header = NSStackView(views: [leading, title, modeControl, trailing])
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 2, left: 12, bottom: 2, right: 12)
        leading.widthAnchor.constraint(equalTo: trailing.widthAnchor).isActive = true

        // Outside the centered arrangement, so the modes stay centered.
        presetsPopUp.controlSize = .small
        presetsPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        presetsPopUp.menu?.delegate = self
        presetsPopUp.toolTip = "Filter presets"
        presetsPopUp.setAccessibilityLabel("Filter presets")
        presetsPopUp.setAccessibilityIdentifier("filterPresets")
        presetsPopUp.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(presetsPopUp)
        NSLayoutConstraint.activate([
            presetsPopUp.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            presetsPopUp.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            presetsPopUp.leadingAnchor.constraint(greaterThanOrEqualTo: modeControl.trailingAnchor, constant: 12),
        ])
        return header
    }

    private func row(for mode: LibraryFilter.Mode) -> NSStackView {
        let content: [NSView] = switch mode {
        case .text:
            textRow()
        case .attribute:
            attributeRow()
        case .metadata:
            metadataRow()
        }
        // The Metadata columns fill the row; the other rows' controls sit at its left.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.isHidden = mode == .metadata

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
        // A row wider than the grid (Attribute in a narrow window) clips rather than widening the window.
        row.setClippingResistancePriority(.defaultLow, for: .horizontal)
        if mode == .metadata { row.alignment = .top }
        row.setAccessibilityIdentifier("filterRow.\(mode.rawValue)")
        return row
    }

    /// Lightroom's Text row: which fields, how the words match, and the words.
    private func textRow() -> [NSView] {
        for (popUp, titles, identifier, label) in [
            (textFieldPopUp, LibraryFilter.TextSearch.Field.allCases.map(\.title), "textFilterField", "Fields to search"),
            (textRulePopUp, LibraryFilter.TextSearch.Rule.allCases.map(\.title), "textFilterRule", "How the words match"),
        ] {
            popUp.controlSize = .small
            popUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            popUp.addItems(withTitles: titles)
            popUp.target = self
            popUp.action = #selector(textOptionChanged(_:))
            popUp.setAccessibilityLabel(label)
            popUp.setAccessibilityIdentifier(identifier)
        }
        searchField.placeholderString = "Search"
        searchField.toolTip = "!word leaves out photos with the word, +word matches the start of a word, word+ the end"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        // Return applies the search at once; typing applies it after a pause (controlTextDidChange).
        searchField.sendsWholeSearchString = true
        searchField.setAccessibilityIdentifier("metadataSearch")
        // Shorter than standard, to sit with the small pop-ups beside it.
        searchField.heightAnchor.constraint(equalToConstant: 20).isActive = true
        searchField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        return [textFieldPopUp, textRulePopUp, searchField]
    }

    /// Lightroom's Attribute groups: Flag, Edit, Rating, Color, Kind, and (PixelLoupe's own) Stack.
    private func attributeRow() -> [NSView] {
        typealias Attributes = LibraryFilter.Attributes
        let edit = AttributeToggleControl(state: state, choices: AttributeToggleControl.choices(
            Attributes.EditStatus.allCases, \.editStatus, title: { "\($0.title) Photos" },
            symbol: { $0 == .edited ? "slider.horizontal.3" : "photo" },
            identifier: { "editFilter.\($0.rawValue)" }
        ))
        let kind = AttributeToggleControl(state: state, choices: AttributeToggleControl.choices(
            Attributes.Kind.allCases, \.kinds, title: \.title,
            symbol: { kind in
                switch kind {
                case .original: "photo.fill"
                case .virtualCopy: "square.on.square"
                case .video: "video.fill"
                }
            },
            identifier: { "kindFilter.\($0.rawValue)" }
        ))
        let stack = AttributeToggleControl(state: state, choices: AttributeToggleControl.choices(
            Attributes.StackStatus.allCases, \.stackStatus, title: { "\($0.title) Photos" },
            symbol: { $0 == .stacked ? "square.stack.3d.up.fill" : "square" },
            identifier: { "stackFilter.\($0.rawValue)" }
        ))
        let first = NSStackView(views: [
            label("Flag"), FlagFilterControl(state: state, identifierPrefix: "filterBar."), divider(),
            label("Edit"), edit, divider(),
            label("Rating"), RatingFilterControl(state: state),
        ])
        let second = NSStackView(views: [
            label("Color"), ColorLabelFilterControl(state: state), divider(),
            label("Kind"), kind, divider(),
            label("Stack"), stack,
        ])
        for half in [first, second] { half.spacing = 8 }
        attributeHalves.setViews([first, second], in: .leading)
        attributeHalves.spacing = 16
        attributeHalves.alignment = .leading
        return [attributeHalves]
    }

    private func metadataRow() -> [NSView] {
        metadataContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return [metadataContainer]
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

    private func installMetadataBrowser() {
        guard metadataBrowser == nil else { return }
        let browser = MetadataBrowserView(store: store, state: state)
        browser.translatesAutoresizingMaskIntoConstraints = false
        metadataContainer.addSubview(browser)
        NSLayoutConstraint.activate([
            browser.topAnchor.constraint(equalTo: metadataContainer.topAnchor),
            browser.leadingAnchor.constraint(equalTo: metadataContainer.leadingAnchor),
            browser.trailingAnchor.constraint(equalTo: metadataContainer.trailingAnchor),
            browser.bottomAnchor.constraint(equalTo: metadataContainer.bottomAnchor),
        ])
        metadataBrowser = browser
    }

    private func update() {
        let filter = state.filter
        if modeSelection.modes != filter.modes { modeSelection.modes = filter.modes }
        for (mode, row) in rows {
            row.isHidden = !filter.modes.contains(mode)
        }
        if filter.modes.contains(.metadata) { installMetadataBrowser() }
        updatePresetsTitle()
        textFieldPopUp.selectItem(at: LibraryFilter.TextSearch.Field.allCases.firstIndex(of: filter.text.field) ?? 0)
        textRulePopUp.selectItem(at: LibraryFilter.TextSearch.Rule.allCases.firstIndex(of: filter.text.rule) ?? 0)
        // Leave the field alone while a typed search is waiting to apply.
        if pendingSearch == nil, searchField.stringValue != filter.text.query {
            searchField.stringValue = filter.text.query
        }
    }

    // MARK: - Actions

    @objc private func clearMode(_ sender: NSButton) {
        switch LibraryFilter.Mode.allCases[sender.tag] {
        case .text: state.filter.text = .init()
        case .attribute: state.filter.attributes = .init()
        case .metadata: state.filter.metadata = .init()
        }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        applySearch()
    }

    private func applySearch() {
        pendingSearch?.cancel()
        pendingSearch = nil
        state.filter.text.query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
    }

    @objc private func textOptionChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if sender === textFieldPopUp {
            state.filter.text.field = LibraryFilter.TextSearch.Field.allCases[index]
        } else {
            state.filter.text.rule = LibraryFilter.TextSearch.Rule.allCases[index]
        }
    }

    // MARK: - Presets

    /// The matching preset's name, or Custom Filter.
    var presetTitle: String { presets.preset(matching: state.filter.criteria)?.name ?? "Custom Filter" }

    /// The custom preset the filter matches, which Update, Rename and Delete act on.
    private var currentCustomPreset: FilterPreset? {
        presets.custom.first { $0.criteria.filtersLike(state.filter.criteria) }
    }

    private func updatePresetsTitle() {
        presetsPopUp.removeAllItems()
        presetsPopUp.addItem(withTitle: presetTitle)
    }

    @objc private func presetsDidChange(_ notification: Notification) {
        updatePresetsTitle()
    }

    /// Built-in presets, then the user's, then Save, Update, Rename and Delete.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === presetsPopUp.menu else { return }
        let title = presetTitle
        menu.removeAllItems()
        // Pull-down menus use the first item as the button title.
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        func add(_ preset: FilterPreset) {
            let item = NSMenuItem(title: preset.name, action: #selector(applyPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.name
            item.state = preset.name == title ? .on : .off
            menu.addItem(item)
        }
        FilterPreset.builtIn.forEach(add)
        if !presets.custom.isEmpty {
            menu.addItem(.separator())
            presets.custom.forEach(add)
        }
        menu.addItem(.separator())
        let save = NSMenuItem(title: "Save Current Settings as New Preset…", action: #selector(saveNewPreset(_:)), keyEquivalent: "")
        save.target = self
        menu.addItem(save)
        if let custom = currentCustomPreset {
            for (title, action) in [
                ("Update Preset \u{201C}\(custom.name)\u{201D}", #selector(updatePreset(_:))),
                ("Rename Preset \u{201C}\(custom.name)\u{201D}…", #selector(renamePreset(_:))),
                ("Delete Preset \u{201C}\(custom.name)\u{201D}", #selector(deletePreset(_:))),
            ] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = custom.name
                menu.addItem(item)
            }
        }
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let preset = (presets.custom + FilterPreset.builtIn).first(where: { $0.name == name }) else { return }
        state.filter.apply(preset)
    }

    @objc private func saveNewPreset(_ sender: Any?) {
        askForPresetName(message: "New Preset", button: "Create", initial: "") { [weak self] name in
            guard let self else { return }
            presets.save(state.filter.criteria, as: name)
        }
    }

    @objc private func updatePreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        presets.save(state.filter.criteria, as: name)
    }

    @objc private func renamePreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        askForPresetName(message: "Rename Preset", button: "Rename", initial: name) { [weak self] newName in
            self?.presets.rename(name, to: newName)
        }
    }

    @objc private func deletePreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        presets.delete(name)
    }

    /// Asks for a preset's name in a sheet; a built-in preset's name isn't accepted.
    private func askForPresetName(message: String, button: String, initial: String, then save: @escaping (String) -> Void) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "Saves the Library Filter's modes and their settings, for every catalog."
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.placeholderString = "Preset Name"
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        field.setAccessibilityIdentifier("presetName")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let self, response == .alertFirstButtonReturn, !name.isEmpty else { return }
            guard !presets.isBuiltIn(name) else {
                let taken = NSAlert()
                taken.messageText = "\u{201C}\(name)\u{201D} is a built-in preset."
                taken.informativeText = "Choose another name."
                taken.beginSheetModal(for: window)
                return
            }
            save(name)
        }
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSSearchField === searchField else { return }
        pendingSearch?.cancel()
        let search = DispatchWorkItem { [weak self] in self?.applySearch() }
        pendingSearch = search
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.searchDelay, execute: search)
    }

    /// Esc clears the search and gives the keyboard back to the grid.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField, commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        searchField.stringValue = ""
        applySearch()
        onEndSearch?()
        return true
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

/// The bar's background: a gradient that lightens toward the grid, set apart from the panels around it.
final class FilterBarBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let stops = Self.stops(for: effectiveAppearance)
        var locations = stops.map(\.location)
        let gradient = NSGradient(
            colors: stops.map { NSColor(srgbRed: $0.color.r, green: $0.color.g, blue: $0.color.b, alpha: 1) },
            atLocations: &locations, colorSpace: .sRGB)
        // From the top down.
        gradient?.draw(in: bounds, angle: -90)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // Light and Gray share an appearance, so switching between them only shows up as a setting change.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: AppSettings.didChangeNotification, object: nil)
        guard window != nil else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange(_:)), name: AppSettings.didChangeNotification, object: nil)
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        needsDisplay = true
    }

    typealias Stop = (location: CGFloat, color: (r: CGFloat, g: CGFloat, b: CGFloat))

    /// From the top of the bar down. Light mode holds a warm gray for the top half, then lightens; Gray
    /// sits a shade darker than its chrome, as Aperture's bars did.
    static func stops(for appearance: NSAppearance) -> [Stop] {
        func rgb(_ hex: UInt32) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            (CGFloat(hex >> 16 & 0xFF) / 255, CGFloat(hex >> 8 & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
        }
        return switch AppSettings.theme(for: appearance) {
        case .dark: [(0, rgb(0x393939)), (1, rgb(0x4A4A4A))]
        case .gray: [(0, rgb(0xAFAFAF)), (1, rgb(0xBEBEBE))]
        default: [(0, rgb(0xD3D0D1)), (0.48, rgb(0xD3D1D2)), (1, rgb(0xF1F1F1))]
        }
    }
}

/// The modes the header's picker shows selected, and where its clicks go.
@Observable
final class FilterModeSelection {
    var modes: Set<LibraryFilter.Mode> = []
    /// The mode clicked (`nil` for None), and whether Shift was down to add or remove it.
    var onClick: (LibraryFilter.Mode?, _ extending: Bool) -> Void = { _, _ in }
}

/// Text, Attribute, Metadata and None, drawn like the Library/Develop switcher: the active modes are
/// accent-tinted glass capsules (gray in Monochrome Mode). A click shows just that mode; Shift-click
/// adds or removes it.
struct FilterModePicker: View {
    var selection: FilterModeSelection

    static let options: [LibraryFilter.Mode?] = LibraryFilter.Mode.allCases + [nil]

    var body: some View {
        CapsulePicker(
            options: Self.options,
            isSelected: { $0.map(selection.modes.contains) ?? selection.modes.isEmpty },
            title: { $0?.title ?? "None" },
            identifier: { "filterMode.\($0?.rawValue ?? "none")" },
            onSelect: { selection.onClick($0, NSEvent.modifierFlags.contains(.shift)) },
            size: .small,
            help: { $0.map { "Filter by \($0.title.lowercased()); Shift-click to combine with other modes" } ?? "Turn off the filters" })
    }
}
