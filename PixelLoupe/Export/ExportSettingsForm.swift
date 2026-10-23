import AppKit
import UniformTypeIdentifiers

/// The export settings' controls in Lightroom's collapsible sections, shared by the Export dialog and
/// the Publishing Manager: each asks for the sections it shows with `section(_:)`, and hears about
/// changes through `onChange`.
final class ExportSettingsForm: NSObject, NSTextFieldDelegate {
    enum Section: String {
        /// Export To, Folder, Subfolder and Existing Files (the Export dialog).
        case exportLocation = "Export Location"
        /// Folder and Subfolder only (a Hard Drive publish service, which always publishes to its folder).
        case publishLocation = "Publish Location"
        case fileNaming = "File Naming"
        case video = "Video"
        case fileSettings = "File Settings"
        case imageSizing = "Image Sizing"
        case outputSharpening = "Output Sharpening"
        case metadata = "Metadata"
        case watermarking = "Watermarking"
        case postProcessing = "Post-Processing"
    }

    let watermarks: WatermarkPresets
    /// The settings being edited.
    var settings: ExportSettings {
        didSet { updateControls() }
    }
    /// Called after the person changes a setting.
    var onChange: (() -> Void)?
    /// The photo File Naming's example is named after, and how many photos there are.
    var example: (item: ExportItem, total: Int)? {
        didSet { updateExample(settings) }
    }
    /// The format where the photos go only takes one (Flickr takes JPEGs): Image Format shows it, disabled.
    var requiredFormat: ExportSettings.Format? {
        didSet { updateControls() }
    }
    /// The window the folder and application choosers open on.
    weak var window: NSWindow?

    // MARK: Controls

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
    let keywordHierarchyCheckbox = NSButton(checkboxWithTitle: "Write Keywords as PixelLoupe Hierarchy", target: nil, action: nil)

    let watermarkCheckbox = NSButton(checkboxWithTitle: "Watermark:", target: nil, action: nil)
    let watermarkPopUp = NSPopUpButton()

    let afterExportPopUp = NSPopUpButton()
    let applicationLabel = NSTextField(labelWithString: "")
    let chooseApplicationButton = NSButton(title: "Choose…", target: nil, action: nil)

    init(settings: ExportSettings, watermarks: WatermarkPresets = .shared) {
        self.settings = settings
        self.watermarks = watermarks
        super.init()
    }

    /// A section, in a collapsible view whose state is remembered under `stateKey`. Ask for each one once.
    func section(_ section: Section, stateKey: String) -> NSView {
        let content: NSView = switch section {
        case .exportLocation: exportLocation()
        case .publishLocation: publishLocation()
        case .fileNaming: fileNaming()
        case .video: video()
        case .fileSettings: fileSettings()
        case .imageSizing: imageSizing()
        case .outputSharpening: outputSharpening()
        case .metadata: metadataSection()
        case .watermarking: watermarking()
        case .postProcessing: postProcessing()
        }
        updateControls()
        return InspectorSectionView(title: section.rawValue, content: content, stateKey: stateKey)
    }

    // MARK: - Changes

    private func change(_ update: (inout ExportSettings) -> Void) {
        update(&settings)
        onChange?()
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

            settings.format = requiredFormat ?? ExportSettings.Format.allCases[max(0, formatPopUp.indexOfSelectedItem)]
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
            settings.writesKeywordHierarchy = keywordHierarchyCheckbox.state == .on

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
        formatPopUp.isEnabled = requiredFormat == nil
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
        keywordHierarchyCheckbox.state = settings.writesKeywordHierarchy ? .on : .off
        keywordHierarchyCheckbox.isEnabled = rendered && settings.metadata.includesDescriptive

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
        exampleLabel.stringValue = example.map {
            ExportNaming.fileName(for: $0.item, index: 0, total: $0.total, settings: settings)
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

    // MARK: - Sections

    private func exportLocation() -> NSView {
        popUp(destinationPopUp, ExportSettings.Destination.allCases.map(\.title), id: "exportDestination")
        popUp(existingFilesPopUp, ExportSettings.ExistingFiles.allCases.map(\.title))
        folderRow()
        return grid([
            [label("Export To:"), destinationPopUp],
            [label("Folder:"), row(folderLabel, chooseFolderButton)],
            [subfolderCheckbox, subfolderField],
            [label("Existing Files:"), existingFilesPopUp],
        ])
    }

    private func publishLocation() -> NSView {
        folderRow()
        return grid([
            [label("Folder:"), row(folderLabel, chooseFolderButton)],
            [subfolderCheckbox, subfolderField],
        ])
    }

    private func folderRow() {
        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseFolder(_:))
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control(subfolderCheckbox)
        field(subfolderField)
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
        let note = secondaryLabel("Video files can’t be exported or published yet.")
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
        control(keywordHierarchyCheckbox)
        keywordHierarchyCheckbox.toolTip = "Also writes each keyword with its parents (Places|Ireland|Dublin), "
            + "which Lightroom and other apps read back as a keyword hierarchy. On Flickr, the tags are these paths."
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

    private func grid(_ rows: [[NSView]]) -> NSGridView { FormLayout.grid(rows) }
    private func row(_ views: NSView...) -> NSStackView { FormLayout.row(views) }
    private func label(_ title: String) -> NSTextField { FormLayout.label(title) }
    private func secondaryLabel(_ title: String) -> NSTextField { FormLayout.secondaryLabel(title) }
    private func spacer() -> NSView { FormLayout.spacer() }
}

/// Layout for forms laid out like Lightroom's Export dialog: a grid of trailing labels and their controls.
enum FormLayout {
    static func grid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 140
        grid.column(at: 1).xPlacement = .leading
        return grid
    }

    static func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.alignment = .firstBaseline
        return stack
    }

    static func label(_ title: String) -> NSTextField {
        NSTextField(labelWithString: title)
    }

    static func secondaryLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        return label
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
}

/// Keeps a scroll view's document pinned to the top.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
