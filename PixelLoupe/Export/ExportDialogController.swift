import AppKit
import UniformTypeIdentifiers

/// File ▸ Export…, laid out like Lightroom's Export dialog: Export To at the top, presets on the
/// left (PixelLoupe's and the user's), and the export's settings on the right in collapsible
/// sections. Done keeps the settings, Cancel discards them, Export keeps them and exports.
final class ExportDialogController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                    NSMenuDelegate, NSTextFieldDelegate {
    private static let sectionStateKey = "ExportDialogExpanded"

    let items: [ExportItem]
    let presets: ExportPresets
    let watermarks: WatermarkPresets
    /// (settings, export): nil settings for Cancel; export is false for Done.
    var onFinish: ((ExportSettings?, Bool) -> Void)?

    /// The settings being edited.
    private(set) var settings: ExportSettings
    /// The preset last chosen in the list.
    private(set) var presetName: String?

    // MARK: Controls

    let exportToPopUp = NSPopUpButton()
    let presetList = NSOutlineView()
    let addPresetButton = NSButton(title: "Add", target: nil, action: nil)
    let removePresetButton = NSButton(title: "Remove", target: nil, action: nil)

    let destinationPopUp = NSPopUpButton()
    let folderLabel = NSTextField(labelWithString: "")
    let chooseFolderButton = NSButton(title: "Choose…", target: nil, action: nil)
    let subfolderCheckbox = NSButton(checkboxWithTitle: "Put in Subfolder:", target: nil, action: nil)
    let subfolderField = NSTextField()
    let existingFilesPopUp = NSPopUpButton()

    let renameCheckbox = NSButton(checkboxWithTitle: "Rename To:", target: nil, action: nil)
    let templatePopUp = NSPopUpButton()
    let customTextField = NSTextField()
    let startNumberField = NSTextField()
    let exampleLabel = NSTextField(labelWithString: "")
    let extensionsPopUp = NSPopUpButton()

    let formatPopUp = NSPopUpButton()
    let qualityRow = WatermarkValueRow(range: 0...100)
    let limitSizeCheckbox = NSButton(checkboxWithTitle: "Limit File Size To:", target: nil, action: nil)
    let sizeLimitField = NSTextField()
    let colorSpacePopUp = NSPopUpButton()
    let bitDepthPopUp = NSPopUpButton()
    let compressionPopUp = NSPopUpButton()

    let resizeCheckbox = NSButton(checkboxWithTitle: "Resize to Fit:", target: nil, action: nil)
    let resizeModePopUp = NSPopUpButton()
    let dontEnlargeCheckbox = NSButton(checkboxWithTitle: "Don’t Enlarge", target: nil, action: nil)
    let widthLabel = NSTextField(labelWithString: "W:")
    let widthField = NSTextField()
    let heightLabel = NSTextField(labelWithString: "H:")
    let heightField = NSTextField()
    let sizeUnitPopUp = NSPopUpButton()
    let sizeSuffixLabel = NSTextField(labelWithString: "")
    let resolutionField = NSTextField()
    let resolutionUnitPopUp = NSPopUpButton()

    let sharpenCheckbox = NSButton(checkboxWithTitle: "Sharpen For:", target: nil, action: nil)
    let sharpenMediumPopUp = NSPopUpButton()
    let sharpenAmountPopUp = NSPopUpButton()

    let metadataPopUp = NSPopUpButton()
    let removePersonCheckbox = NSButton(checkboxWithTitle: "Remove Person Info", target: nil, action: nil)
    let removeLocationCheckbox = NSButton(checkboxWithTitle: "Remove Location Info", target: nil, action: nil)
    let keywordHierarchyCheckbox = NSButton(checkboxWithTitle: "Write Keywords as Lightroom Hierarchy", target: nil, action: nil)

    let watermarkCheckbox = NSButton(checkboxWithTitle: "Watermark:", target: nil, action: nil)
    let watermarkPopUp = NSPopUpButton()

    let afterExportPopUp = NSPopUpButton()
    let applicationLabel = NSTextField(labelWithString: "")
    let chooseApplicationButton = NSButton(title: "Choose…", target: nil, action: nil)

    let exportButton = NSButton(title: "Export", target: nil, action: nil)

    private var sizeFields: [NSTextField] { [widthField, heightField] }

    init(items: [ExportItem], settings: ExportSettings, presets: ExportPresets = .shared, watermarks: WatermarkPresets = .shared) {
        self.items = items
        self.settings = settings
        self.presets = presets
        self.watermarks = watermarks
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 820),
            styleMask: [.titled, .resizable], backing: .buffered, defer: true
        )
        window.title = items.count == 1 ? "Export 1 File" : "Export \(items.count.formatted()) Files"
        window.contentMinSize = NSSize(width: 800, height: 600)
        window.setAccessibilityIdentifier("exportDialog")
        super.init(window: window)
        window.delegate = self
        buildContent()
        presetList.expandItem(nil, expandChildren: true)
        updateControls()
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
        settings = preset.settings
        updateControls()
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

    // MARK: - Changes

    private func change(_ update: (inout ExportSettings) -> Void) {
        update(&settings)
        updateControls()
    }

    @objc private func controlChanged(_ sender: Any?) {
        change { settings in
            settings.destination = ExportSettings.Destination.allCases[max(0, destinationPopUp.indexOfSelectedItem)]
            settings.usesSubfolder = subfolderCheckbox.state == .on
            settings.subfolderName = subfolderField.stringValue
            settings.existingFiles = ExportSettings.ExistingFiles.allCases[max(0, existingFilesPopUp.indexOfSelectedItem)]

            settings.renames = renameCheckbox.state == .on
            settings.namingTemplate = ExportSettings.NamingTemplate.allCases[max(0, templatePopUp.indexOfSelectedItem)]
            settings.customText = customTextField.stringValue
            settings.startNumber = max(0, startNumberField.integerValue)
            settings.extensionCase = ExportSettings.ExtensionCase.allCases[max(0, extensionsPopUp.indexOfSelectedItem)]

            settings.format = ExportSettings.Format.allCases[max(0, formatPopUp.indexOfSelectedItem)]
            settings.limitsFileSize = limitSizeCheckbox.state == .on
            settings.fileSizeLimit = max(10, sizeLimitField.integerValue)
            settings.colorSpace = ExportSettings.ColorSpace.allCases[max(0, colorSpacePopUp.indexOfSelectedItem)]
            settings.bitDepth = bitDepthPopUp.indexOfSelectedItem == 1 ? 16 : 8
            settings.tiffCompression = ExportSettings.TIFFCompression.allCases[max(0, compressionPopUp.indexOfSelectedItem)]

            settings.resizes = resizeCheckbox.state == .on
            settings.resizeMode = ExportSettings.ResizeMode.allCases[max(0, resizeModePopUp.indexOfSelectedItem)]
            settings.doesNotEnlarge = dontEnlargeCheckbox.state == .on
            let first = max(0.01, widthField.doubleValue), second = max(0.01, heightField.doubleValue)
            switch settings.resizeMode {
            case .widthHeight, .dimensions: (settings.width, settings.height) = (first, second)
            case .longEdge, .shortEdge: settings.edge = first
            case .megapixels: settings.megapixels = first
            case .percentage: settings.percentage = first
            }
            settings.sizeUnit = ExportSettings.SizeUnit.allCases[max(0, sizeUnitPopUp.indexOfSelectedItem)]
            settings.resolution = max(1, resolutionField.doubleValue)
            settings.resolutionUnit = ExportSettings.ResolutionUnit.allCases[max(0, resolutionUnitPopUp.indexOfSelectedItem)]

            settings.sharpens = sharpenCheckbox.state == .on
            settings.sharpenMedium = ExportSettings.SharpenMedium.allCases[max(0, sharpenMediumPopUp.indexOfSelectedItem)]
            settings.sharpenAmount = ExportSettings.SharpenAmount.allCases[max(0, sharpenAmountPopUp.indexOfSelectedItem)]

            settings.metadata = ExportSettings.MetadataInclusion.allCases[max(0, metadataPopUp.indexOfSelectedItem)]
            settings.removesPersonInfo = removePersonCheckbox.state == .on
            settings.removesLocationInfo = removeLocationCheckbox.state == .on

            settings.watermarks = watermarkCheckbox.state == .on
            if let name = watermarkPopUp.selectedItem?.representedObject as? String { settings.watermarkName = name }

            settings.afterExport = ExportSettings.AfterExport.allCases[max(0, afterExportPopUp.indexOfSelectedItem)]
        }
        if settings.afterExport == .openInApplication, settings.applicationPath == nil {
            chooseApplication(nil)
        }
    }

    @objc private func chooseFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(filePath: settings.folderPath, directoryHint: .isDirectory)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.change {
                $0.folderPath = url.path(percentEncoded: false)
                $0.destination = .specificFolder
            }
        }
    }

    @objc private func chooseApplication(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL.applicationDirectory
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .OK, let url = panel.url {
                change { $0.applicationPath = url.path(percentEncoded: false) }
            } else if settings.applicationPath == nil {
                change { $0.afterExport = .nothing }
            }
        }
    }

    @objc private func editWatermarks(_ sender: Any?) {
        NSApp.sendAction(#selector(PixelLoupeActions.showWatermarkEditor(_:)), to: nil, from: self)
        updateControls()
    }

    func controlTextDidChange(_ notification: Notification) {
        // The example file name follows the custom text as it's typed.
        guard notification.object as? NSTextField === customTextField || notification.object as? NSTextField === startNumberField else { return }
        var preview = settings
        preview.customText = customTextField.stringValue
        preview.startNumber = startNumberField.integerValue
        updateExample(preview)
    }

    // MARK: - Updating

    /// Mirrors the settings in every control.
    func updateControls() {
        exportButton.isEnabled = !items.isEmpty

        destinationPopUp.selectItem(at: ExportSettings.Destination.allCases.firstIndex(of: settings.destination) ?? 0)
        folderLabel.stringValue = (settings.folderPath as NSString).abbreviatingWithTildeInPath
        let specific = settings.destination == .specificFolder
        folderLabel.textColor = specific ? .labelColor : .disabledControlTextColor
        chooseFolderButton.isEnabled = true
        subfolderCheckbox.state = settings.usesSubfolder ? .on : .off
        setText(subfolderField, settings.subfolderName)
        subfolderField.isEnabled = settings.usesSubfolder
        existingFilesPopUp.selectItem(at: ExportSettings.ExistingFiles.allCases.firstIndex(of: settings.existingFiles) ?? 0)

        renameCheckbox.state = settings.renames ? .on : .off
        templatePopUp.selectItem(at: ExportSettings.NamingTemplate.allCases.firstIndex(of: settings.namingTemplate) ?? 0)
        templatePopUp.isEnabled = settings.renames
        setText(customTextField, settings.customText)
        customTextField.isEnabled = settings.renames && settings.namingTemplate.usesCustomText
        setText(startNumberField, String(settings.startNumber))
        startNumberField.isEnabled = settings.renames && settings.namingTemplate.usesStartNumber
        extensionsPopUp.selectItem(at: ExportSettings.ExtensionCase.allCases.firstIndex(of: settings.extensionCase) ?? 0)
        updateExample(settings)

        let format = settings.format
        let rendered = format != .original
        formatPopUp.selectItem(at: ExportSettings.Format.allCases.firstIndex(of: format) ?? 0)
        qualityRow.value = settings.quality
        qualityRow.isEnabled = format.isLossy && !(format == .jpeg && settings.limitsFileSize)
        limitSizeCheckbox.state = settings.limitsFileSize ? .on : .off
        limitSizeCheckbox.isEnabled = format == .jpeg
        setText(sizeLimitField, String(settings.fileSizeLimit))
        sizeLimitField.isEnabled = format == .jpeg && settings.limitsFileSize
        colorSpacePopUp.selectItem(at: ExportSettings.ColorSpace.allCases.firstIndex(of: settings.colorSpace) ?? 0)
        colorSpacePopUp.isEnabled = rendered
        bitDepthPopUp.selectItem(at: settings.bitDepth == 16 ? 1 : 0)
        bitDepthPopUp.isEnabled = format.hasBitDepth
        compressionPopUp.selectItem(at: ExportSettings.TIFFCompression.allCases.firstIndex(of: settings.tiffCompression) ?? 0)
        compressionPopUp.isEnabled = format == .tiff

        resizeCheckbox.state = settings.resizes ? .on : .off
        resizeCheckbox.isEnabled = rendered
        let resizing = settings.resizes && rendered
        resizeModePopUp.selectItem(at: ExportSettings.ResizeMode.allCases.firstIndex(of: settings.resizeMode) ?? 0)
        dontEnlargeCheckbox.state = settings.doesNotEnlarge ? .on : .off
        for control in [resizeModePopUp, dontEnlargeCheckbox, widthField, heightField, sizeUnitPopUp] as [NSControl] {
            control.isEnabled = resizing
        }
        let twoValues = settings.resizeMode == .widthHeight || settings.resizeMode == .dimensions
        widthLabel.isHidden = !twoValues
        heightLabel.isHidden = !twoValues
        heightField.isHidden = !twoValues
        let usesUnit = ![.megapixels, .percentage].contains(settings.resizeMode)
        sizeUnitPopUp.isHidden = !usesUnit
        sizeSuffixLabel.isHidden = usesUnit
        sizeSuffixLabel.stringValue = settings.resizeMode == .megapixels ? "megapixels" : "%"
        let firstValue: Double = switch settings.resizeMode {
        case .widthHeight, .dimensions: settings.width
        case .longEdge, .shortEdge: settings.edge
        case .megapixels: settings.megapixels
        case .percentage: settings.percentage
        }
        setText(widthField, Self.number(firstValue))
        setText(heightField, Self.number(settings.height))
        sizeUnitPopUp.selectItem(at: ExportSettings.SizeUnit.allCases.firstIndex(of: settings.sizeUnit) ?? 0)
        setText(resolutionField, Self.number(settings.resolution))
        resolutionField.isEnabled = rendered
        resolutionUnitPopUp.selectItem(at: ExportSettings.ResolutionUnit.allCases.firstIndex(of: settings.resolutionUnit) ?? 0)
        resolutionUnitPopUp.isEnabled = rendered

        sharpenCheckbox.state = settings.sharpens ? .on : .off
        sharpenCheckbox.isEnabled = rendered
        sharpenMediumPopUp.selectItem(at: ExportSettings.SharpenMedium.allCases.firstIndex(of: settings.sharpenMedium) ?? 0)
        sharpenAmountPopUp.selectItem(at: ExportSettings.SharpenAmount.allCases.firstIndex(of: settings.sharpenAmount) ?? 0)
        sharpenMediumPopUp.isEnabled = settings.sharpens && rendered
        sharpenAmountPopUp.isEnabled = settings.sharpens && rendered

        metadataPopUp.selectItem(at: ExportSettings.MetadataInclusion.allCases.firstIndex(of: settings.metadata) ?? 0)
        metadataPopUp.isEnabled = rendered
        removePersonCheckbox.state = settings.removesPersonInfo ? .on : .off
        removeLocationCheckbox.state = settings.removesLocationInfo ? .on : .off
        removePersonCheckbox.isEnabled = rendered && settings.metadata.includesDescriptive
        removeLocationCheckbox.isEnabled = rendered && settings.metadata.includesDescriptive

        rebuildWatermarkMenu()
        watermarkCheckbox.state = settings.watermarks ? .on : .off
        watermarkCheckbox.isEnabled = rendered
        watermarkPopUp.isEnabled = settings.watermarks && rendered

        afterExportPopUp.selectItem(at: ExportSettings.AfterExport.allCases.firstIndex(of: settings.afterExport) ?? 0)
        applicationLabel.stringValue = settings.applicationPath.map { FileManager.default.displayName(atPath: $0) } ?? "Choose an application…"
        applicationLabel.textColor = settings.afterExport == .openInApplication ? .labelColor : .disabledControlTextColor
        chooseApplicationButton.isEnabled = settings.afterExport == .openInApplication
    }

    private func updateExample(_ settings: ExportSettings) {
        exampleLabel.stringValue = items.first.map {
            ExportNaming.fileName(for: $0, index: 0, total: items.count, settings: settings)
        } ?? ""
    }

    /// Sets a field's text unless it's being typed in.
    private func setText(_ field: NSTextField, _ text: String) {
        guard field.currentEditor() == nil, field.stringValue != text else { return }
        field.stringValue = text
    }

    private func rebuildWatermarkMenu() {
        let menu = NSMenu()
        for preset in watermarks.all {
            let item = NSMenuItem(title: preset.name, action: nil, keyEquivalent: "")
            item.representedObject = preset.name
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let edit = NSMenuItem(title: "Edit Watermarks…", action: #selector(editWatermarks(_:)), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
        watermarkPopUp.menu = menu
        if let item = menu.items.first(where: { $0.representedObject as? String == settings.watermarkName }) {
            watermarkPopUp.select(item)
        } else {
            watermarkPopUp.selectItem(at: 0)
        }
    }

    static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    // MARK: - Layout

    private func buildContent() {
        guard let contentView = window?.contentView else { return }
        exportToPopUp.addItem(withTitle: "Hard Drive")
        exportToPopUp.setAccessibilityIdentifier("exportToPopUp")
        let exportTo = NSStackView(views: [NSTextField(labelWithString: "Export To:"), exportToPopUp])

        // Presets.
        let presetsLabel = secondaryLabel("Preset:")
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
        let countLabel = secondaryLabel(window?.title ?? "")
        let sections = NSStackView(views: [
            section("Export Location", exportLocation()),
            section("File Naming", fileNaming()),
            section("Video", video()),
            section("File Settings", fileSettings()),
            section("Image Sizing", imageSizing()),
            section("Output Sharpening", outputSharpening()),
            section("Metadata", metadataSection()),
            section("Watermarking", watermarking()),
            section("Post-Processing", postProcessing()),
        ])
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
        let clip = ExportFlippedClipView()
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

    private func section(_ title: String, _ content: NSView) -> NSView {
        InspectorSectionView(title: title, content: content, stateKey: Self.sectionStateKey)
    }

    private func exportLocation() -> NSView {
        popUp(destinationPopUp, ExportSettings.Destination.allCases.map(\.title), id: "exportDestination")
        popUp(existingFilesPopUp, ExportSettings.ExistingFiles.allCases.map(\.title))
        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseFolder(_:))
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control(subfolderCheckbox)
        field(subfolderField)
        return grid([
            [label("Export To:"), destinationPopUp],
            [label("Folder:"), row(folderLabel, chooseFolderButton)],
            [subfolderCheckbox, subfolderField],
            [label("Existing Files:"), existingFilesPopUp],
        ])
    }

    private func fileNaming() -> NSView {
        control(renameCheckbox)
        popUp(templatePopUp, ExportSettings.NamingTemplate.allCases.map(\.title))
        popUp(extensionsPopUp, ExportSettings.ExtensionCase.allCases.map(\.title))
        field(customTextField)
        field(startNumberField, width: 70)
        exampleLabel.setAccessibilityIdentifier("exportExampleName")
        return grid([
            [renameCheckbox, templatePopUp],
            [label("Custom Text:"), row(customTextField, label("Start Number:"), startNumberField)],
            [label("Example:"), row(exampleLabel, spacer(), label("Extensions:"), extensionsPopUp)],
        ])
    }

    private func video() -> NSView {
        let include = NSButton(checkboxWithTitle: "Include Video Files", target: nil, action: nil)
        include.isEnabled = false
        let videoFormat = NSPopUpButton()
        videoFormat.isEnabled = false
        let quality = NSPopUpButton()
        quality.isEnabled = false
        let note = secondaryLabel("PixelLoupe doesn’t import video yet.")
        return grid([
            [NSGridCell.emptyContentView, include],
            [label("Video Format:"), videoFormat],
            [label("Quality:"), quality],
            [NSGridCell.emptyContentView, note],
        ])
    }

    private func fileSettings() -> NSView {
        popUp(formatPopUp, ExportSettings.Format.allCases.map(\.title), id: "exportFormat")
        popUp(colorSpacePopUp, ExportSettings.ColorSpace.allCases.map(\.title))
        popUp(bitDepthPopUp, ["8 bits/component", "16 bits/component"])
        popUp(compressionPopUp, ExportSettings.TIFFCompression.allCases.map(\.title))
        qualityRow.onChange = { [weak self] value in self?.change { $0.quality = value } }
        qualityRow.setAccessibilityIdentifier("exportQuality")
        control(limitSizeCheckbox)
        field(sizeLimitField, width: 70)
        return grid([
            [label("Image Format:"), formatPopUp],
            [label("Quality:"), row(qualityRow, limitSizeCheckbox, sizeLimitField, label("K"))],
            [label("Color Space:"), row(colorSpacePopUp, label("Bit Depth:"), bitDepthPopUp)],
            [label("Compression:"), compressionPopUp],
        ])
    }

    private func imageSizing() -> NSView {
        control(resizeCheckbox)
        control(dontEnlargeCheckbox)
        popUp(resizeModePopUp, ExportSettings.ResizeMode.allCases.map(\.title), id: "exportResizeMode")
        popUp(sizeUnitPopUp, ExportSettings.SizeUnit.allCases.map(\.title))
        popUp(resolutionUnitPopUp, ExportSettings.ResolutionUnit.allCases.map(\.title))
        field(widthField, width: 80)
        field(heightField, width: 80)
        field(resolutionField, width: 70)
        widthField.setAccessibilityIdentifier("exportWidth")
        return grid([
            [resizeCheckbox, row(resizeModePopUp, dontEnlargeCheckbox)],
            [NSGridCell.emptyContentView, row(widthLabel, widthField, heightLabel, heightField, sizeUnitPopUp, sizeSuffixLabel)],
            [label("Resolution:"), row(resolutionField, resolutionUnitPopUp)],
        ])
    }

    private func outputSharpening() -> NSView {
        control(sharpenCheckbox)
        popUp(sharpenMediumPopUp, ExportSettings.SharpenMedium.allCases.map(\.title))
        popUp(sharpenAmountPopUp, ExportSettings.SharpenAmount.allCases.map(\.title))
        return grid([[sharpenCheckbox, row(sharpenMediumPopUp, label("Amount:"), sharpenAmountPopUp)]])
    }

    private func metadataSection() -> NSView {
        popUp(metadataPopUp, ExportSettings.MetadataInclusion.allCases.map(\.title), id: "exportMetadata")
        control(removePersonCheckbox)
        control(removeLocationCheckbox)
        // PixelLoupe's keywords aren't hierarchical (yet).
        keywordHierarchyCheckbox.isEnabled = false
        return grid([
            [label("Include:"), metadataPopUp],
            [NSGridCell.emptyContentView, row(removePersonCheckbox, removeLocationCheckbox)],
            [NSGridCell.emptyContentView, keywordHierarchyCheckbox],
        ])
    }

    private func watermarking() -> NSView {
        control(watermarkCheckbox)
        watermarkPopUp.target = self
        watermarkPopUp.action = #selector(controlChanged(_:))
        watermarkPopUp.setAccessibilityIdentifier("exportWatermark")
        return grid([[watermarkCheckbox, watermarkPopUp]])
    }

    private func postProcessing() -> NSView {
        popUp(afterExportPopUp, ExportSettings.AfterExport.allCases.map(\.title), id: "exportAfterExport")
        chooseApplicationButton.target = self
        chooseApplicationButton.action = #selector(chooseApplication(_:))
        applicationLabel.lineBreakMode = .byTruncatingMiddle
        applicationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return grid([
            [label("After Export:"), afterExportPopUp],
            [label("Application:"), row(applicationLabel, chooseApplicationButton)],
        ])
    }

    // MARK: Builders

    private func popUp(_ popUp: NSPopUpButton, _ titles: [String], id: String? = nil) {
        popUp.removeAllItems()
        popUp.addItems(withTitles: titles)
        popUp.target = self
        popUp.action = #selector(controlChanged(_:))
        if let id { popUp.setAccessibilityIdentifier(id) }
    }

    private func control(_ button: NSButton) {
        button.target = self
        button.action = #selector(controlChanged(_:))
    }

    private func field(_ field: NSTextField, width: CGFloat? = nil) {
        field.target = self
        field.action = #selector(controlChanged(_:))
        field.delegate = self
        field.cell?.sendsActionOnEndEditing = true
        if let width { field.widthAnchor.constraint(equalToConstant: width).isActive = true }
    }

    private func grid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 140
        grid.column(at: 1).xPlacement = .leading
        return grid
    }

    private func row(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.alignment = .firstBaseline
        return stack
    }

    private func label(_ title: String) -> NSTextField {
        NSTextField(labelWithString: title)
    }

    private func secondaryLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
}

/// Keeps the settings scrolled from the top.
private final class ExportFlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
