import AppKit
import UniformTypeIdentifiers

/// Develop's Presets panel: the library's presets by group, searchable by name. Double-click (or
/// Apply) applies one to the photo; Copy puts it on the settings clipboard so Paste Settings (⇧⌘V)
/// applies it to any photos, in Develop or the Library.
final class PresetsPanelViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    final class Group {
        let name: String
        var presets: [DevelopPreset]
        init(name: String, presets: [DevelopPreset]) {
            self.name = name
            self.presets = presets
        }
    }

    final class Item {
        let preset: DevelopPreset
        init(_ preset: DevelopPreset) { self.preset = preset }
    }

    /// Called to apply a preset to the photo in Develop.
    var onApply: ((DevelopPreset) -> Void)?
    /// The photo's current settings, for Create Preset and Update with Current Settings.
    var currentSettings: () -> PhotoAdjustments? = { nil }
    /// Called as the Amount slider moves (`isFinal` when it's let go), with 0…2.
    var onAmountChange: ((Double, Bool) -> Void)?
    /// Called after a preset was copied (for the window to update its menus).
    var onCopy: ((DevelopPreset) -> Void)?
    /// Called as the pointer moves over a preset (to preview it on the photo) and off the list (`nil`).
    var onHover: ((DevelopPreset?) -> Void)?
    var isEditingEnabled = true {
        didSet {
            updateButtons()
            if !isEditingEnabled { setHovered(nil) }
        }
    }
    /// The photo in Develop, which presets are checked against (Lightroom hides the ones for other
    /// photos and dims the ones that only partly apply).
    var photo: DevelopPreset.Photo? {
        didSet { if photo != oldValue { reloadList() } }
    }
    /// Lightroom's Show Partially Compatible Presets.
    var showsPartiallyCompatible: Bool {
        get { defaults.object(forKey: Self.partiallyCompatibleKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.partiallyCompatibleKey)
            reloadList()
        }
    }
    private static let partiallyCompatibleKey = "ShowPartiallyCompatiblePresets"
    private let defaults: UserDefaults

    let library: PresetLibrary
    let searchField = ClickToFocusSearchField()
    let outline = NSOutlineView()
    let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    /// Lightroom's preset Amount, for the preset just applied (when it supports one).
    let amountSlider = AdjustmentSlider(value: 100, minValue: 0, maxValue: 200)
    let amountLabel = NSTextField(labelWithString: "")
    private let amountValue = NSTextField(labelWithString: "100")
    private let amountRow = NSStackView()
    private let importButton = NSButton()
    private let createButton = NSButton()
    private let emptyView = NSStackView()
    private let scroll = NSScrollView()
    private(set) var groups: [Group] = []
    private var items: [URL: Item] = [:]
    /// Why a listed preset only partly applies to the photo, by file.
    private var partialReasons: [URL: String] = [:]
    /// The preset under the pointer.
    private(set) var hoveredPreset: DevelopPreset?
    private var hoverTask: Task<Void, Never>?

    init(library: PresetLibrary = .shared, defaults: UserDefaults = Defaults.store) {
        self.library = library
        self.defaults = defaults
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The preset selected in the list.
    var selectedPreset: DevelopPreset? {
        (outline.item(atRow: outline.selectedRow) as? Item)?.preset
    }

    override func loadView() {
        let heading = NSTextField(labelWithString: "PRESETS")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = .secondaryLabelColor

        importButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Preset Options")
        importButton.isBordered = false
        importButton.toolTip = "Import presets and choose which to show"
        importButton.target = self
        importButton.action = #selector(showImportMenu(_:))
        importButton.setAccessibilityIdentifier("importPresetsButton")
        createButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Create Preset")
        createButton.isBordered = false
        createButton.toolTip = "Create a preset from this photo’s settings"
        createButton.target = self
        createButton.action = #selector(showCreatePreset(_:))
        createButton.setAccessibilityIdentifier("createPresetButton")
        let header = NSStackView(views: [heading, NSView(), createButton, importButton])

        searchField.placeholderString = "Search presets"
        searchField.controlSize = .small
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setAccessibilityIdentifier("presetSearch")

        let column = NSTableColumn(identifier: .init("preset"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 20
        outline.style = .plain
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(applySelected(_:))
        outline.setAccessibilityIdentifier("presetList")
        let rowMenu = NSMenu()
        rowMenu.delegate = self
        outline.menu = rowMenu
        outline.setAccessibilityLabel("Presets")
        // Hovering a preset previews it, as in Lightroom.
        outline.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .bezelBorder

        for (button, identifier, tip, action) in [
            (applyButton, "applyPreset", "Apply the preset to this photo (or double-click it)", #selector(applySelected(_:))),
            (copyButton, "copyPreset", "Copy the preset; Photo ▸ Paste Settings (⇧⌘V) applies it to the selected photos", #selector(copySelected(_:))),
        ] {
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.toolTip = tip
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(identifier)
        }
        let buttons = NSStackView(views: [applyButton, copyButton])
        buttons.spacing = 8

        amountLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        amountLabel.lineBreakMode = .byTruncatingTail
        amountLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        amountValue.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        amountValue.alignment = .right
        amountValue.widthAnchor.constraint(equalToConstant: 36).isActive = true
        amountSlider.controlSize = .small
        amountSlider.isContinuous = true
        amountSlider.target = self
        amountSlider.action = #selector(amountMoved(_:))
        amountSlider.setAccessibilityLabel("Preset amount")
        amountSlider.setAccessibilityIdentifier("presetAmount")
        let amountTitle = NSStackView(views: [amountLabel, NSView(), amountValue])
        amountRow.orientation = .vertical
        amountRow.alignment = .leading
        amountRow.spacing = 2
        amountRow.addArrangedSubview(amountTitle)
        amountRow.addArrangedSubview(amountSlider)
        amountTitle.widthAnchor.constraint(equalTo: amountRow.widthAnchor).isActive = true
        amountSlider.widthAnchor.constraint(equalTo: amountRow.widthAnchor).isActive = true
        amountRow.isHidden = true

        let emptyLabel = NSTextField(wrappingLabelWithString: "No presets yet. Import Lightroom presets (.xmp or .lrtemplate files) to use them here.")
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let importFiles = NSButton(title: "Import Presets…", target: self, action: #selector(importFiles(_:)))
        importFiles.controlSize = .small
        importFiles.setAccessibilityIdentifier("importPresetFiles")
        var emptyViews: [NSView] = [emptyLabel, importFiles]
        if !PresetLibrary.lightroomDirectories.isEmpty {
            let importLightroom = NSButton(title: "Import Lightroom’s Presets", target: self, action: #selector(importLightroom(_:)))
            importLightroom.controlSize = .small
            importLightroom.setAccessibilityIdentifier("importLightroomPresets")
            emptyViews.append(importLightroom)
        }
        emptyViews.forEach(emptyView.addArrangedSubview)
        emptyView.orientation = .vertical
        emptyView.alignment = .leading
        emptyView.spacing = 8
        emptyView.isHidden = true

        let stack = NSStackView(views: [header, searchField, emptyView, scroll, buttons, amountRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 14, right: 14)
        for view in [header, searchField, emptyView, scroll, amountRow] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        stack.setAccessibilityIdentifier("presetsPanel")
        view = stack
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(libraryDidChange(_:)), name: PresetLibrary.didChangeNotification, object: library
        )
        reloadList()
        Task { await library.load() }
    }

    @objc private func libraryDidChange(_ notification: Notification) {
        reloadList()
    }

    // MARK: - List

    /// Rebuilds the list from the library, filtered by the search text and by what suits the photo.
    func reloadList() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        let showsPartial = showsPartiallyCompatible
        partialReasons = [:]
        groups = library.groups.compactMap { group in
            let presets = group.presets.filter { preset in
                guard query.isEmpty || preset.name.localizedStandardContains(query) || group.name.localizedStandardContains(query) else { return false }
                guard let photo else { return true }
                switch preset.compatibility(with: photo, profiles: library.profiles) {
                case .compatible: return true
                case .partial(let reason):
                    partialReasons[preset.url] = reason
                    return showsPartial
                case .incompatible: return false
                }
            }
            return presets.isEmpty ? nil : Group(name: group.name, presets: presets)
        }
        items = [:]
        setHovered(nil)
        outline.reloadData()
        // While searching, show every match.
        if !query.isEmpty { groups.forEach { outline.expandItem($0) } }
        let isEmpty = library.isLoaded && library.presets.isEmpty
        emptyView.isHidden = !isEmpty
        scroll.isHidden = isEmpty
        updateButtons()
    }

    func controlTextDidChange(_ notification: Notification) {
        reloadList()
    }

    private func item(for preset: DevelopPreset) -> Item {
        if let item = items[preset.url] { return item }
        let item = Item(preset)
        items[preset.url] = item
        return item
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Group)?.presets.count ?? (item == nil ? groups.count : 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? Group { return self.item(for: group.presets[index]) }
        return groups[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is Group }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let text: String, isGroup: Bool
        var partialReason: String?
        if let group = item as? Group {
            text = group.name
            isGroup = true
        } else if let item = item as? Item {
            text = item.preset.name
            isGroup = false
            partialReason = partialReasons[item.preset.url]
        } else {
            return nil
        }
        let label = NSTextField(labelWithString: text)
        label.font = isGroup ? .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold) : .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = partialReason.map { "\(text) — partially compatible: \($0)" } ?? text
        // Partially compatible presets are dimmed, as in Lightroom.
        if partialReason != nil {
            label.textColor = .tertiaryLabelColor
            label.setAccessibilityValueDescription("Partially compatible")
        }
        let cell = NSTableCellView()
        cell.textField = label
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    /// Whether a listed preset only partly applies to the photo (and why).
    func partialCompatibility(of preset: DevelopPreset) -> String? { partialReasons[preset.url] }

    // MARK: - Hover preview

    override func mouseMoved(with event: NSEvent) {
        let row = outline.row(at: outline.convert(event.locationInWindow, from: nil))
        setHovered(row >= 0 ? (outline.item(atRow: row) as? Item)?.preset : nil)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    /// Previews `preset` after the pointer rests on it a moment (sweeping across the list doesn't
    /// render every row); `nil` ends the preview at once.
    func setHovered(_ preset: DevelopPreset?) {
        let preset = isEditingEnabled ? preset : nil
        guard preset != hoveredPreset else { return }
        hoveredPreset = preset
        hoverTask?.cancel()
        guard let preset else {
            onHover?(nil)
            return
        }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, let self, hoveredPreset == preset else { return }
            onHover?(preset)
        }
    }

    private func updateButtons() {
        applyButton.isEnabled = isEditingEnabled && selectedPreset != nil
        copyButton.isEnabled = selectedPreset != nil
    }

    // MARK: - Your own presets

    /// Lightroom's New Develop Preset: a name, a group, and which settings to include.
    @objc func showCreatePreset(_ sender: Any?) {
        guard let settings = currentSettings() else { return }
        let alert = NSAlert()
        alert.messageText = "New Preset"
        alert.informativeText = "Saves the chosen settings of this photo as a preset."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let name = NSTextField(string: "")
        name.placeholderString = "Preset name"
        name.setAccessibilityIdentifier("newPresetName")
        let group = NSComboBox()
        group.addItems(withObjectValues: Array(Set(library.presets.map(\.group) + ["User Presets"])).sorted())
        group.stringValue = "User Presets"
        group.setAccessibilityLabel("Group")
        var boxes: [(PresetSection, NSButton)] = []
        let checks = NSStackView()
        checks.orientation = .vertical
        checks.alignment = .leading
        checks.spacing = 4
        for section in PresetSection.allCases {
            let box = NSButton(checkboxWithTitle: section.title, target: nil, action: nil)
            box.state = .on
            boxes.append((section, box))
            checks.addArrangedSubview(box)
        }
        let groupRow = NSStackView(views: [NSTextField(labelWithString: "Group:"), group])
        let stack = NSStackView(views: [name, groupRow, checks])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        name.widthAnchor.constraint(equalToConstant: 300).isActive = true
        group.widthAnchor.constraint(equalToConstant: 240).isActive = true
        alert.accessoryView = Self.alertAccessory(stack)
        alert.window.initialFirstResponder = name
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let sections = Set(boxes.filter { $0.1.state == .on }.map(\.0))
            Task { await self.createPreset(name: name.stringValue, group: group.stringValue, from: settings, sections: sections) }
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    /// `content` in a plain view of its size, for an alert's accessory. An alert lines a plain view up
    /// with its text, but puts a stack view at its left edge.
    static func alertAccessory(_ content: NSView) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: content.fittingSize))
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    /// Creates a preset and selects it. Errors (a name already used) are shown.
    func createPreset(name: String, group: String, from settings: PhotoAdjustments, sections: Set<PresetSection>) async {
        do {
            let preset = try await library.createPreset(name: name, group: group, from: settings, sections: sections)
            select(preset)
        } catch {
            show(error)
        }
    }

    private func select(_ preset: DevelopPreset) {
        searchField.stringValue = ""
        reloadList()
        guard let group = groups.first(where: { $0.name == preset.group }) else { return }
        outline.expandItem(group)
        let row = outline.row(forItem: item(for: preset))
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    private func show(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
    }

    /// Asks for a name; `nil` when cancelled.
    private func askName(title: String, initial: String, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { completion(field.stringValue) }
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let item = outline.item(atRow: outline.clickedRow)
        func add(_ title: String, _ action: @escaping () -> Void) {
            let target = ActionTarget { _ in action() }
            menuTargets.append(target)
            let entry = NSMenuItem(title: title, action: #selector(ActionTarget.fire(_:)), keyEquivalent: "")
            entry.target = target
            menu.addItem(entry)
        }
        menuTargets = []
        if let preset = (item as? Item)?.preset {
            add("Apply") { [weak self] in if self?.isEditingEnabled == true { self?.onApply?(preset) } }
            add("Copy") { SettingsClipboard.content = .preset(preset) }
            menu.addItem(.separator())
            add("Update with Current Settings") { [weak self] in
                guard let self, let settings = currentSettings() else { return }
                Task { do { try await self.library.update(preset, with: settings) } catch { self.show(error) } }
            }
            add("Rename…") { [weak self] in
                self?.askName(title: "Rename Preset", initial: preset.name) { name in
                    Task { do { try await self?.library.rename(preset, to: name) } catch { self?.show(error) } }
                }
            }
            add("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([preset.url]) }
            menu.addItem(.separator())
            add("Delete") { [weak self] in
                Task { do { try await self?.library.delete(preset) } catch { self?.show(error) } }
            }
        } else if let group = item as? Group {
            add("Rename Group…") { [weak self] in
                self?.askName(title: "Rename Group", initial: group.name) { name in
                    Task { do { try await self?.library.renameGroup(group.name, to: name) } catch { self?.show(error) } }
                }
            }
        }
    }

    private var menuTargets: [ActionTarget] = []

    // MARK: - Amount

    /// Shows the Amount slider for `name` at `amount` (0…2), or hides it (`nil`).
    func showAmount(for name: String?, amount: Double = 1) {
        amountRow.isHidden = name == nil
        guard let name else { return }
        amountLabel.stringValue = "Amount: \(name)"
        amountSlider.doubleValue = amount * 100
        amountValue.stringValue = "\(Int((amount * 100).rounded()))"
    }

    var isShowingAmount: Bool { !amountRow.isHidden }

    @objc func amountMoved(_ sender: NSSlider) {
        let amount = sender.doubleValue / 100
        amountValue.stringValue = "\(Int(sender.doubleValue.rounded()))"
        // One undoable step per drag: final when the mouse is let go (or for a keyboard change).
        let isFinal = NSApp.currentEvent.map { $0.type != .leftMouseDragged } ?? true
        onAmountChange?(amount, isFinal)
    }

    // MARK: - Actions

    @objc func applySelected(_ sender: Any?) {
        guard isEditingEnabled, let preset = selectedPreset else { return }
        onApply?(preset)
    }

    @objc func copySelected(_ sender: Any?) {
        guard let preset = selectedPreset else { return }
        SettingsClipboard.content = .preset(preset)
        onCopy?(preset)
    }

    @objc private func showImportMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Import Presets…", action: #selector(importFiles(_:)), keyEquivalent: "").target = self
        if !PresetLibrary.lightroomDirectories.isEmpty {
            menu.addItem(withTitle: "Import Lightroom’s Presets", action: #selector(importLightroom(_:)), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Presets Folder", action: #selector(showFolder(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let partial = NSMenuItem(title: "Show Partially Compatible Presets", action: #selector(togglePartiallyCompatible(_:)), keyEquivalent: "")
        partial.target = self
        partial.state = showsPartiallyCompatible ? .on : .off
        menu.addItem(partial)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc func togglePartiallyCompatible(_ sender: Any?) {
        showsPartiallyCompatible.toggle()
    }

    @objc func importFiles(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Import Presets"
        panel.message = "Choose Lightroom presets (.xmp or .lrtemplate), or folders of them."
        panel.prompt = "Import"
        panel.allowedContentTypes = ["xmp", LegacyPreset.fileExtension].map { UTType(filenameExtension: $0) ?? .data }
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        importPresets(from: panel.urls)
    }

    @objc func importLightroom(_ sender: Any?) {
        importPresets(from: PresetLibrary.lightroomDirectories)
    }

    @objc private func showFolder(_ sender: Any?) {
        try? FileManager.default.createDirectory(at: library.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([library.directory])
    }

    private func importPresets(from sources: [URL]) {
        Task {
            let result = await library.importPresets(from: sources)
            guard result == .init(), let window = view.window else { return }
            let alert = NSAlert()
            alert.messageText = "No presets were imported"
            alert.informativeText = "The files chosen aren’t Lightroom presets or profiles."
            alert.beginSheetModal(for: window, completionHandler: nil)
        }
    }
}
