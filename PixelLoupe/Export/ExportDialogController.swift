import AppKit
import UniformTypeIdentifiers

/// File ▸ Export…, laid out like Lightroom's Export dialog: Export To at the top, presets on the
/// left (PixelLoupe's and the user's), and the export's settings on the right in collapsible
/// sections. Done keeps the settings, Cancel discards them, Export keeps them and exports.
final class ExportDialogController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                    NSMenuDelegate {
    private static let sectionStateKey = "ExportDialogExpanded"

    let items: [ExportItem]
    let presets: ExportPresets
    let watermarks: WatermarkPresets
    /// (settings, export): nil settings for Cancel; export is false for Done.
    var onFinish: ((ExportSettings?, Bool) -> Void)?

    /// The preset last chosen in the list.
    private(set) var presetName: String?

    /// The export's settings controls.
    let form: ExportSettingsForm
    /// The settings being edited.
    var settings: ExportSettings { form.settings }

    // MARK: Controls

    let exportToPopUp = NSPopUpButton()
    let presetList = NSOutlineView()
    let addPresetButton = NSButton(title: "Add", target: nil, action: nil)
    let removePresetButton = NSButton(title: "Remove", target: nil, action: nil)
    let exportButton = NSButton(title: "Export", target: nil, action: nil)

    init(items: [ExportItem], settings: ExportSettings, presets: ExportPresets = .shared, watermarks: WatermarkPresets = .shared) {
        self.items = items
        self.presets = presets
        self.watermarks = watermarks
        form = ExportSettingsForm(settings: settings, watermarks: watermarks)
        form.example = items.first.map { ($0, items.count) }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 820),
            styleMask: [.titled, .resizable], backing: .buffered, defer: true
        )
        window.title = items.count == 1 ? "Export 1 File" : "Export \(items.count.formatted()) Files"
        window.contentMinSize = NSSize(width: 800, height: 600)
        window.setAccessibilityIdentifier("exportDialog")
        super.init(window: window)
        window.delegate = self
        form.window = window
        buildContent()
        presetList.expandItem(nil, expandChildren: true)
        exportButton.isEnabled = !items.isEmpty
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Finishing

    @objc func export(_ sender: Any?) {
        commitEditing()
        onFinish?(settings, true)
    }

    @objc func done(_ sender: Any?) {
        commitEditing()
        onFinish?(settings, false)
    }

    @objc func cancel(_ sender: Any?) {
        onFinish?(nil, false)
    }

    /// Ends typing in a field so its value is saved.
    private func commitEditing() {
        window?.makeFirstResponder(nil)
    }

    // MARK: - Presets

    private enum PresetGroup: String, CaseIterable {
        case pixelLoupe = "PixelLoupe Presets", user = "User Presets"
    }

    private final class PresetRow: NSObject {
        let name: String
        init(_ name: String) { self.name = name }
    }

    private var presetRows: [PresetGroup: [PresetRow]] = [:]
    private let groupItems = PresetGroup.allCases.map { $0.rawValue as NSString }

    private func reloadPresets() {
        presetRows[.pixelLoupe] = ExportPresets.builtIn.map { PresetRow($0.name) }
        presetRows[.user] = presets.userPresets.map { PresetRow($0.name) }
        presetList.reloadData()
        presetList.expandItem(nil, expandChildren: true)
        selectPresetRow()
    }

    private func selectPresetRow() {
        let row = presetName.flatMap { name in
            (0..<presetList.numberOfRows).first { (presetList.item(atRow: $0) as? PresetRow)?.name == name }
        }
        if let row {
            presetList.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            presetList.deselectAll(nil)
        }
        removePresetButton.isEnabled = presetName.map { !ExportPresets.isBuiltIn($0) } ?? false
    }

    /// Loads a preset's settings.
    func choosePreset(named name: String) {
        guard let preset = presets.preset(named: name) else { return }
        presetName = name
        form.settings = preset.settings
        selectPresetRow()
    }

    /// Saves the current settings as a user preset.
    func addPreset(named name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !ExportPresets.isBuiltIn(name) else { return }
        try presets.save(ExportPreset(name: name, settings: settings))
        presetName = name
        reloadPresets()
    }

    func removePreset(named name: String) {
        guard !ExportPresets.isBuiltIn(name) else { return }
        presets.delete(named: name)
        if presetName == name { presetName = nil }
        reloadPresets()
    }

    @objc private func addPresetClicked(_ sender: Any?) {
        commitEditing()
        askForName(title: "New Preset", defaultName: "Untitled Preset") { [weak self] name in
            do { try self?.addPreset(named: name) } catch { self?.presentError(error) }
        }
    }

    @objc private func removePresetClicked(_ sender: Any?) {
        guard let name = presetName, !ExportPresets.isBuiltIn(name), let window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove the export preset “\(name)”?"
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.removePreset(named: name) }
        }
    }

    @objc private func updatePreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        commitEditing()
        do {
            try presets.save(ExportPreset(name: name, settings: settings))
            presetName = name
            reloadPresets()
        } catch {
            presentError(error)
        }
    }

    @objc private func renamePreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        askForName(title: "Rename Preset", defaultName: name) { [weak self] newName in
            guard let self else { return }
            do {
                try presets.rename(name, to: newName)
                if presetName == name { presetName = newName }
                reloadPresets()
            } catch {
                presentError(error)
            }
        }
    }

    @objc private func deletePreset(_ sender: NSMenuItem) {
        (sender.representedObject as? String).map(removePreset(named:))
    }

    private func askForName(title: String, defaultName: String, then completion: @escaping (String) -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Preset Name:"
        let field = NSTextField(string: defaultName)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if response == .alertFirstButtonReturn, !name.isEmpty { completion(name) }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return groupItems.count }
        return (item as? NSString).flatMap { PresetGroup(rawValue: $0 as String) }.map { presetRows[$0]?.count ?? 0 } ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return groupItems[index] }
        let group = PresetGroup(rawValue: (item as! NSString) as String)!
        return presetRows[group]![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is NSString }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is NSString }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is PresetRow }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier(item is NSString ? "Group" : "Preset")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.textField?.stringValue = (item as? PresetRow)?.name ?? (item as? NSString).map { $0 as String } ?? ""
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard let row = presetList.item(atRow: presetList.selectedRow) as? PresetRow, row.name != presetName else {
            removePresetButton.isEnabled = presetName.map { !ExportPresets.isBuiltIn($0) } ?? false
            return
        }
        choosePreset(named: row.name)
    }

    /// The preset list's right-click menu: update, rename or delete a user preset.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let row = presetList.item(atRow: presetList.clickedRow) as? PresetRow, !ExportPresets.isBuiltIn(row.name) else { return }
        for (title, action) in [
            ("Update with Current Settings", #selector(updatePreset(_:))),
            ("Rename…", #selector(renamePreset(_:))),
            ("Delete", #selector(deletePreset(_:))),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = row.name
            menu.addItem(item)
        }
    }

    // MARK: - Layout

    private func buildContent() {
        guard let contentView = window?.contentView else { return }
        exportToPopUp.addItem(withTitle: "Hard Drive")
        exportToPopUp.setAccessibilityIdentifier("exportToPopUp")
        let exportTo = NSStackView(views: [NSTextField(labelWithString: "Export To:"), exportToPopUp])

        // Presets.
        let presetsLabel = FormLayout.secondaryLabel("Preset:")
        let column = NSTableColumn(identifier: .init("Preset"))
        presetList.addTableColumn(column)
        presetList.outlineTableColumn = column
        presetList.headerView = nil
        presetList.style = .sourceList
        presetList.dataSource = self
        presetList.delegate = self
        presetList.menu = NSMenu()
        presetList.menu?.delegate = self
        presetList.setAccessibilityIdentifier("exportPresetList")
        let presetScroll = NSScrollView()
        presetScroll.documentView = presetList
        presetScroll.hasVerticalScroller = true
        presetScroll.borderType = .bezelBorder
        addPresetButton.target = self
        addPresetButton.action = #selector(addPresetClicked(_:))
        removePresetButton.target = self
        removePresetButton.action = #selector(removePresetClicked(_:))
        let presetButtons = NSStackView(views: [addPresetButton, removePresetButton])
        presetButtons.distribution = .fillEqually
        reloadPresets()

        // Settings.
        let countLabel = FormLayout.secondaryLabel(window?.title ?? "")
        let sections = NSStackView(views: [
            .exportLocation, .fileNaming, .video, .fileSettings, .imageSizing, .outputSharpening, .metadata, .watermarking, .postProcessing,
        ].map { form.section($0, stateKey: Self.sectionStateKey) })
        sections.orientation = .vertical
        sections.alignment = .leading
        sections.spacing = 12
        sections.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 12, right: 16)
        for view in sections.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: sections.widthAnchor, constant: -28).isActive = true
        }
        let settingsScroll = NSScrollView()
        settingsScroll.hasVerticalScroller = true
        settingsScroll.borderType = .bezelBorder
        let clip = FlippedClipView()
        settingsScroll.contentView = clip
        settingsScroll.documentView = sections
        sections.translatesAutoresizingMaskIntoConstraints = false

        // Buttons.
        let doneButton = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        exportButton.target = self
        exportButton.action = #selector(export(_:))
        exportButton.keyEquivalent = "\r"
        exportButton.setAccessibilityIdentifier("exportButton")
        let buttons = NSStackView(views: [doneButton, cancelButton, exportButton])
        buttons.spacing = 12
        for button in [doneButton, cancelButton, exportButton] { button.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true }

        for view in [exportTo, presetsLabel, presetScroll, presetButtons, countLabel, settingsScroll, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        let margin: CGFloat = 20
        NSLayoutConstraint.activate([
            exportTo.topAnchor.constraint(equalTo: contentView.topAnchor, constant: margin),
            exportTo.trailingAnchor.constraint(equalTo: settingsScroll.leadingAnchor, constant: 120),

            presetsLabel.topAnchor.constraint(equalTo: exportTo.bottomAnchor, constant: 16),
            presetsLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            presetScroll.topAnchor.constraint(equalTo: presetsLabel.bottomAnchor, constant: 6),
            presetScroll.leadingAnchor.constraint(equalTo: presetsLabel.leadingAnchor),
            presetScroll.widthAnchor.constraint(equalToConstant: 230),
            presetButtons.topAnchor.constraint(equalTo: presetScroll.bottomAnchor, constant: 6),
            presetButtons.leadingAnchor.constraint(equalTo: presetScroll.leadingAnchor),
            presetButtons.trailingAnchor.constraint(equalTo: presetScroll.trailingAnchor),
            presetButtons.bottomAnchor.constraint(equalTo: settingsScroll.bottomAnchor),

            countLabel.firstBaselineAnchor.constraint(equalTo: presetsLabel.firstBaselineAnchor),
            countLabel.leadingAnchor.constraint(equalTo: settingsScroll.leadingAnchor),
            settingsScroll.topAnchor.constraint(equalTo: presetScroll.topAnchor),
            settingsScroll.leadingAnchor.constraint(equalTo: presetScroll.trailingAnchor, constant: 16),
            settingsScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),
            settingsScroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -20),
            sections.widthAnchor.constraint(equalTo: settingsScroll.contentView.widthAnchor),
            sections.topAnchor.constraint(equalTo: settingsScroll.contentView.topAnchor),

            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -margin),
        ])
    }
}
