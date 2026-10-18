import AppKit
import CoreData
import UniformTypeIdentifiers

/// A photo the Watermark Editor previews: the file and its Develop settings.
struct WatermarkPreviewPhoto: Sendable {
    let url: URL
    let adjustments: PhotoAdjustments
}

/// The photos the Watermark Editor's ◀ ▶ step through, read one at a time as they're shown.
struct WatermarkPreviewSource {
    var count: Int
    /// Where the preview starts.
    var startIndex = 0
    var photo: (Int) -> WatermarkPreviewPhoto?

    init(count: Int, startIndex: Int = 0, photo: @escaping (Int) -> WatermarkPreviewPhoto?) {
        self.count = count
        self.startIndex = startIndex
        self.photo = photo
    }

    init(_ photos: [WatermarkPreviewPhoto]) {
        self.init(count: photos.count) { photos.indices.contains($0) ? photos[$0] : nil }
    }
}

extension CatalogWindowController {
    /// What the Watermark Editor previews: with several photos selected, those; otherwise every photo
    /// in the grid, in its order, starting at the selected one, so ◀ ▶ move through the gallery.
    var watermarkPreviews: WatermarkPreviewSource {
        let selected = state.selectedPhotoIDs
        let order = state.photoOrder
        let ids: [NSManagedObjectID]
        var start = 0
        if selected.count > 1 {
            ids = order.filter(selected.contains)
        } else {
            ids = order
            if let first = selected.first { start = order.firstIndex(of: first) ?? 0 }
        }
        let context = store.viewContext
        return WatermarkPreviewSource(count: ids.count, startIndex: start) { index in
            guard ids.indices.contains(index), let photo = try? context.existingObject(with: ids[index]) as? Photo else { return nil }
            return WatermarkPreviewPhoto(url: photo.fileURL, adjustments: photo.adjustments)
        }
    }
}

/// PixelLoupe ▸ Edit Watermarks…, laid out like Lightroom's Watermark Editor: presets and a preview
/// of the selected photos on the left, the watermark's options on the right. Save keeps the
/// watermark as a preset (asking for a name when it's new or edited); Cancel discards changes.
final class WatermarkEditorWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSMenuDelegate {
    private static let lastPresetKey = "WatermarkEditorPreset"
    private static let sectionStateKey = "WatermarkEditorExpanded"
    private static let previewPixels: CGFloat = 1400

    let presets: WatermarkPresets
    private let previews: WatermarkPreviewSource
    private(set) var previewIndex = 0
    var onClose: (() -> Void)?

    /// The watermark being edited.
    private(set) var settings: WatermarkSettings {
        didSet { if settings != oldValue { settingsChanged() } }
    }
    /// The preset the settings came from (nil for Custom).
    private(set) var presetName: String?

    /// Whether the settings differ from the preset they came from.
    var isEdited: Bool {
        guard let presetName else { return false }
        return presets.preset(named: presetName)?.settings != settings
    }

    /// The preset pop-up's title: "Custom", the preset's name, or "Name (edited)".
    var presetTitle: String {
        guard let presetName else { return "Custom" }
        return isEdited ? "\(presetName) (edited)" : presetName
    }

    // MARK: Controls

    let presetPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    let previewStepper = NSSegmentedControl()
    let textStyleButton = NSButton(radioButtonWithTitle: "Text", target: nil, action: nil)
    let graphicStyleButton = NSButton(radioButtonWithTitle: "Graphic", target: nil, action: nil)
    let previewView = NSImageView()
    let textView = NSTextView()

    let imageLabel = NSTextField(wrappingLabelWithString: "")
    let chooseImageButton = NSButton(title: "Choose…", target: nil, action: nil)
    let fontPopUp = NSPopUpButton()
    /// Draws each family in the Font menu in its own typeface, as the Mac's Font menus do.
    let fontMenuStyler = FontMenuStyler()
    let facePopUp = NSPopUpButton()
    let alignmentControl = NSSegmentedControl()
    let colorWell = NSColorWell(style: .minimal)
    let shadowCheckbox = NSButton(checkboxWithTitle: "Shadow", target: nil, action: nil)
    let shadowOpacity = WatermarkValueRow(range: 0...100)
    let shadowOffset = WatermarkValueRow(range: 0...100)
    let shadowRadius = WatermarkValueRow(range: 0...100)
    let shadowAngle = WatermarkValueRow(range: -180...180)

    let opacityRow = WatermarkValueRow(range: 0...100)
    let proportionalButton = NSButton(radioButtonWithTitle: "Proportional", target: nil, action: nil)
    let proportionalSize = WatermarkValueRow(range: 1...100)
    let fitButton = NSButton(radioButtonWithTitle: "Fit", target: nil, action: nil)
    let fillButton = NSButton(radioButtonWithTitle: "Fill", target: nil, action: nil)
    let horizontalInset = WatermarkValueRow(range: 0...50)
    let verticalInset = WatermarkValueRow(range: 0...50)
    private(set) var anchorButtons: [WatermarkSettings.Anchor: NSButton] = [:]
    let rotateLeftButton = NSButton()
    let rotateRightButton = NSButton()

    private var textSections: [NSView] = []
    private var baseImage: CIImage?
    private var previewTask: Task<Void, Never>?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    convenience init(presets: WatermarkPresets = .shared, previews: [WatermarkPreviewPhoto]) {
        self.init(presets: presets, source: WatermarkPreviewSource(previews))
    }

    init(presets: WatermarkPresets = .shared, source previews: WatermarkPreviewSource) {
        self.presets = presets
        self.previews = previews
        previewIndex = previews.count > 0 ? min(max(previews.startIndex, 0), previews.count - 1) : 0
        let last = Defaults.store.string(forKey: Self.lastPresetKey).flatMap(presets.preset(named:)) ?? presets.all.first
        presetName = last?.name
        settings = last?.settings ?? WatermarkSettings()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 960),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true
        )
        window.title = "Watermark Editor"
        window.contentMinSize = NSSize(width: 760, height: 720)
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("watermarkEditor")
        super.init(window: window)
        window.delegate = self
        buildContent()
        window.center()
        updateControls()
        loadPreviewPhoto()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Presets

    /// Loads a preset's settings.
    func choosePreset(named name: String) {
        guard let preset = presets.preset(named: name) else { return }
        presetName = preset.name
        settings = preset.settings
        updateControls()
    }

    /// Saves the current settings under a new (or replaced) name, and makes it the preset shown.
    func saveAsNewPreset(named name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        try presets.save(WatermarkPreset(name: name, settings: settings))
        presetName = name
        updateControls()
    }

    /// Save: keeps an unchanged preset as is, otherwise asks for a name, then closes.
    @objc func save(_ sender: Any?) {
        if let presetName, !isEdited {
            finish(rememberingPreset: presetName)
            return
        }
        askForName(title: "New Preset", defaultName: presetName ?? "Untitled") { [weak self] name in
            guard let self else { return }
            do {
                try saveAsNewPreset(named: name)
                finish(rememberingPreset: self.presetName)
            } catch {
                presentError(error)
            }
        }
    }

    @objc func cancel(_ sender: Any?) {
        window?.close()
    }

    private func finish(rememberingPreset name: String?) {
        if let name { Defaults.store.set(name, forKey: Self.lastPresetKey) }
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        previewTask?.cancel()
        onClose?()
    }

    private func rebuildPresetMenu() {
        let menu = NSMenu()
        menu.delegate = self
        // A pull-down's first item is its title.
        menu.addItem(withTitle: presetTitle, action: nil, keyEquivalent: "")
        for preset in presets.all {
            let item = NSMenuItem(title: preset.name, action: #selector(presetChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.name
            item.state = preset.name == presetName ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("Save Current Settings as New Preset…", #selector(saveCurrentAsNewPreset(_:)))
        add("Restore Default Presets", #selector(restoreDefaultPresets(_:)))
        if let presetName {
            menu.addItem(.separator())
            add("Delete preset “\(presetName)”…", #selector(deletePreset(_:)))
            add("Rename preset “\(presetName)”…", #selector(renamePreset(_:)))
            add("Update preset “\(presetName)”", #selector(updatePreset(_:)), enabled: isEdited)
        }
        presetPopUp.menu = menu
    }

    @objc private func presetChosen(_ sender: NSMenuItem) {
        (sender.representedObject as? String).map(choosePreset(named:))
    }

    @objc private func saveCurrentAsNewPreset(_ sender: Any?) {
        askForName(title: "New Preset", defaultName: "Untitled") { [weak self] name in
            do { try self?.saveAsNewPreset(named: name) } catch { self?.presentError(error) }
        }
    }

    @objc private func restoreDefaultPresets(_ sender: Any?) {
        presets.restoreDefaults()
        rebuildPresetMenu()
    }

    @objc private func deletePreset(_ sender: Any?) {
        guard let presetName, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the watermark preset “\(presetName)”?"
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            presets.delete(named: presetName)
            self.presetName = nil   // the settings stay, as Custom
            updateControls()
        }
    }

    @objc private func renamePreset(_ sender: Any?) {
        guard let presetName else { return }
        askForName(title: "Rename Preset", defaultName: presetName) { [weak self] name in
            guard let self else { return }
            do {
                try presets.rename(presetName, to: name)
                self.presetName = name
                updateControls()
            } catch {
                presentError(error)
            }
        }
    }

    @objc private func updatePreset(_ sender: Any?) {
        guard let presetName else { return }
        do { try saveAsNewPreset(named: presetName) } catch { presentError(error) }
    }

    /// Asks for a preset name in a sheet, confirming before replacing another preset.
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
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            guard name != presetName, presets.preset(named: name) != nil else {
                completion(name)
                return
            }
            let replace = NSAlert()
            replace.messageText = "A preset named “\(name)” already exists. Replace it?"
            replace.addButton(withTitle: "Replace")
            replace.addButton(withTitle: "Cancel")
            replace.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { completion(name) }
            }
        }
    }

    // MARK: - Changes

    private func change(_ update: (inout WatermarkSettings) -> Void) {
        var copy = settings
        update(&copy)
        settings = copy
    }

    private func settingsChanged() {
        rebuildPresetMenu()
        updatePreview()
    }

    @objc private func styleChanged(_ sender: NSButton) {
        change { $0.style = sender === graphicStyleButton ? .graphic : .text }
        updateControls()
    }

    @objc private func chooseImage(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.message = "Choose a PNG or JPG image for the watermark."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let name = try presets.importImage(from: url)
                change { $0.imageName = name; $0.style = .graphic }
                updateControls()
            } catch {
                presentError(error)
            }
        }
    }

    @objc private func fontChanged(_ sender: Any?) {
        guard let family = fontPopUp.titleOfSelectedItem else { return }
        let faces = Self.faces(of: family)
        change {
            $0.fontFamily = family
            if !faces.contains($0.fontFace) { $0.fontFace = faces.first { $0 == "Regular" } ?? faces.first ?? "Regular" }
        }
        updateControls()
    }

    @objc private func faceChanged(_ sender: Any?) {
        guard let face = facePopUp.titleOfSelectedItem else { return }
        change { $0.fontFace = face }
    }

    @objc private func alignmentChanged(_ sender: Any?) {
        let alignment = WatermarkSettings.Alignment.allCases[max(0, alignmentControl.selectedSegment)]
        change { $0.alignment = alignment }
    }

    @objc private func colorChanged(_ sender: Any?) {
        change { $0.color = WatermarkSettings.Color(colorWell.color) }
    }

    @objc private func shadowToggled(_ sender: Any?) {
        change { $0.shadow.isEnabled = shadowCheckbox.state == .on }
        updateControls()
    }

    @objc private func sizeChanged(_ sender: NSButton) {
        change { $0.size = sender === fitButton ? .fit : sender === fillButton ? .fill : .proportional }
        updateControls()
    }

    @objc private func anchorChanged(_ sender: NSButton) {
        guard let anchor = anchorButtons.first(where: { $0.value === sender })?.key else { return }
        change { $0.anchor = anchor }
        updateControls()
    }

    @objc private func rotate(_ sender: NSButton) {
        change { $0.quarterTurns = ($0.quarterTurns + (sender === rotateLeftButton ? 1 : 3)) % 4 }
    }

    @objc private func stepPreview(_ sender: NSSegmentedControl) {
        stepPreview(by: sender.selectedSegment == 0 ? -1 : 1)
    }

    /// ◀ ▶: the previous or next selected photo, wrapping around.
    func stepPreview(by step: Int) {
        guard previews.count > 1 else { return }
        previewIndex = (previewIndex + step + previews.count) % previews.count
        loadPreviewPhoto()
    }

    func textDidChange(_ notification: Notification) {
        change { $0.text = textView.string }
    }

    /// Mirrors the settings in every control.
    private func updateControls() {
        let isText = settings.style == .text
        textStyleButton.state = isText ? .on : .off
        graphicStyleButton.state = isText ? .off : .on
        textSections.forEach { setEnabled(isText, in: $0) }
        textView.isEditable = isText
        textView.textColor = isText ? .labelColor : .disabledControlTextColor
        if textView.string != settings.text { textView.string = settings.text }
        imageLabel.stringValue = settings.imageName == nil ? "Please choose a PNG or JPG image" : "Image chosen"

        if fontPopUp.itemTitles.contains(settings.fontFamily) {
            fontPopUp.selectItem(withTitle: settings.fontFamily)
        }
        facePopUp.removeAllItems()
        facePopUp.addItems(withTitles: Self.faces(of: settings.fontFamily))
        facePopUp.selectItem(withTitle: settings.fontFace)
        alignmentControl.selectedSegment = WatermarkSettings.Alignment.allCases.firstIndex(of: settings.alignment) ?? 0
        colorWell.color = settings.color.nsColor
        shadowCheckbox.state = settings.shadow.isEnabled ? .on : .off
        shadowOpacity.value = settings.shadow.opacity
        shadowOffset.value = settings.shadow.offset
        shadowRadius.value = settings.shadow.radius
        shadowAngle.value = settings.shadow.angle
        if isText {
            for row in [shadowOpacity, shadowOffset, shadowRadius, shadowAngle] { row.isEnabled = settings.shadow.isEnabled }
        }

        opacityRow.value = settings.opacity
        proportionalButton.state = settings.size == .proportional ? .on : .off
        fitButton.state = settings.size == .fit ? .on : .off
        fillButton.state = settings.size == .fill ? .on : .off
        proportionalSize.value = settings.proportionalSize
        proportionalSize.isEnabled = settings.size == .proportional
        horizontalInset.value = settings.horizontalInset
        verticalInset.value = settings.verticalInset
        for (anchor, button) in anchorButtons { button.state = anchor == settings.anchor ? .on : .off }

        previewStepper.isEnabled = previews.count > 1
        rebuildPresetMenu()
        updatePreview()
    }

    private func setEnabled(_ enabled: Bool, in view: NSView) {
        if let control = view as? NSControl { control.isEnabled = enabled }
        if let row = view as? WatermarkValueRow { row.isEnabled = enabled; return }
        view.subviews.forEach { setEnabled(enabled, in: $0) }
    }

    static func faces(of family: String) -> [String] {
        (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { $0[1] as? String }
    }

    // MARK: - Preview

    /// Renders the photo being previewed (with its edits) once; the watermark is drawn over it
    /// on every change.
    private func loadPreviewPhoto() {
        previewTask?.cancel()
        guard previewIndex < previews.count, let photo = previews.photo(previewIndex) else {
            baseImage = Self.samplePhoto()
            updatePreview()
            return
        }
        previewTask = Task { [weak self] in
            let rendered = await PhotoRenderer.render(photo.url, adjustments: photo.adjustments, maxPixels: Self.previewPixels)
            guard let self, !Task.isCancelled else { return }
            baseImage = rendered.map { CIImage(cgImage: $0.image) } ?? Self.samplePhoto()
            updatePreview()
        }
    }

    private func updatePreview() {
        guard let baseImage else { return }
        let imageURL = settings.imageName.map(presets.imageURL(named:))
        let image = WatermarkRenderer.apply(settings, imageURL: imageURL, to: baseImage)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent, format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.displayP3)) else { return }
        previewView.image = NSImage(cgImage: cgImage, size: image.extent.size)
    }

    /// A stand-in photo (sky over a field) when no photos are selected.
    static func samplePhoto() -> CIImage {
        let sky = CIImage(color: CIColor(red: 0.45, green: 0.62, blue: 0.82)).cropped(to: CGRect(x: 0, y: 360, width: 1200, height: 440))
        let field = CIImage(color: CIColor(red: 0.36, green: 0.48, blue: 0.27)).cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 360))
        return sky.composited(over: field)
    }

    // MARK: - Layout

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        // Left: presets, preview, text.
        presetPopUp.setAccessibilityIdentifier("watermarkPresetPopUp")
        presetPopUp.menu?.delegate = self
        previewView.imageScaling = .scaleProportionallyUpOrDown
        // The photo fits whatever room the preview has; it never sizes the window.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            previewView.setContentCompressionResistancePriority(.defaultLow, for: orientation)
            previewView.setContentHuggingPriority(.defaultLow, for: orientation)
        }
        previewView.setAccessibilityIdentifier("watermarkPreview")
        let previewBox = NSView()
        previewBox.wantsLayer = true
        previewBox.layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        previewBox.layer?.borderColor = NSColor.separatorColor.cgColor
        previewBox.layer?.borderWidth = 1
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(previewView)

        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize + 2)
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.setAccessibilityIdentifier("watermarkText")
        textView.setAccessibilityLabel("Watermark text")
        let textScroll = NSScrollView()
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true

        // Right: preview stepping, style, options.
        previewStepper.segmentStyle = .separated
        previewStepper.trackingMode = .momentary
        previewStepper.segmentCount = 2
        previewStepper.setImage(NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous Photo"), forSegment: 0)
        previewStepper.setImage(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next Photo"), forSegment: 1)
        previewStepper.target = self
        previewStepper.action = #selector(stepPreview(_:))
        previewStepper.setAccessibilityIdentifier("watermarkPreviewStepper")
        for button in [textStyleButton, graphicStyleButton] {
            button.target = self
            button.action = #selector(styleChanged(_:))
        }
        let styleRow = NSStackView(views: [NSTextField(labelWithString: "Watermark Style:"), textStyleButton, graphicStyleButton])
        styleRow.spacing = 10
        let topRight = NSStackView(views: [previewStepper, spacer(), styleRow])

        let sections = NSStackView(views: [
            InspectorSectionView(title: "Image Options", content: imageOptions(), stateKey: Self.sectionStateKey),
            InspectorSectionView(title: "Text Options", content: textOptions(), stateKey: Self.sectionStateKey),
            InspectorSectionView(title: "Watermark Effects", content: effects(), stateKey: Self.sectionStateKey),
        ])
        sections.orientation = .vertical
        sections.alignment = .leading
        sections.spacing = 12
        sections.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 12, right: 16)
        for view in sections.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: sections.widthAnchor, constant: -28).isActive = true
        }
        let optionsScroll = NSScrollView()
        optionsScroll.drawsBackground = false
        optionsScroll.hasVerticalScroller = true
        optionsScroll.autohidesScrollers = true
        let clip = FlippedClipView()
        clip.drawsBackground = false
        optionsScroll.contentView = clip
        optionsScroll.documentView = sections
        sections.translatesAutoresizingMaskIntoConstraints = false

        // Bottom: Cancel and Save.
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        saveButton.keyEquivalent = "\r"
        saveButton.setAccessibilityIdentifier("watermarkSaveButton")
        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.spacing = 12
        for button in [cancelButton, saveButton] { button.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true }

        for view in [presetPopUp, previewBox, textScroll, topRight, optionsScroll, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        let margin: CGFloat = 20
        NSLayoutConstraint.activate([
            presetPopUp.topAnchor.constraint(equalTo: contentView.topAnchor, constant: margin),
            presetPopUp.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            presetPopUp.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor),

            previewBox.topAnchor.constraint(equalTo: presetPopUp.bottomAnchor, constant: 14),
            previewBox.leadingAnchor.constraint(equalTo: presetPopUp.leadingAnchor),
            previewBox.trailingAnchor.constraint(equalTo: optionsScroll.leadingAnchor, constant: -margin),
            previewView.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 24),
            previewView.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 24),
            previewView.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -24),
            previewView.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: -24),

            textScroll.topAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: 14),
            textScroll.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor),
            textScroll.heightAnchor.constraint(equalToConstant: 72),
            textScroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -16),

            topRight.centerYAnchor.constraint(equalTo: presetPopUp.centerYAnchor),
            topRight.leadingAnchor.constraint(equalTo: optionsScroll.leadingAnchor),
            topRight.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),

            optionsScroll.topAnchor.constraint(equalTo: previewBox.topAnchor),
            optionsScroll.widthAnchor.constraint(equalToConstant: 360),
            optionsScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin + 12),
            optionsScroll.bottomAnchor.constraint(equalTo: textScroll.bottomAnchor),
            sections.widthAnchor.constraint(equalTo: optionsScroll.contentView.widthAnchor),
            sections.topAnchor.constraint(equalTo: optionsScroll.contentView.topAnchor),

            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -margin),
        ])
    }

    private func imageOptions() -> NSView {
        chooseImageButton.target = self
        chooseImageButton.action = #selector(chooseImage(_:))
        imageLabel.alignment = .center
        imageLabel.textColor = .secondaryLabelColor
        let row = NSStackView(views: [imageLabel, chooseImageButton])
        row.spacing = 12
        imageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func textOptions() -> NSView {
        fontPopUp.addItems(withTitles: NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        })
        fontPopUp.menu?.delegate = fontMenuStyler
        fontPopUp.target = self
        fontPopUp.action = #selector(fontChanged(_:))
        fontPopUp.setAccessibilityIdentifier("watermarkFont")
        facePopUp.target = self
        facePopUp.action = #selector(faceChanged(_:))
        facePopUp.setAccessibilityIdentifier("watermarkFontStyle")

        alignmentControl.segmentCount = 3
        alignmentControl.trackingMode = .selectOne
        for (index, (symbol, label)) in [("text.alignleft", "Left"), ("text.aligncenter", "Center"), ("text.alignright", "Right")].enumerated() {
            alignmentControl.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: label), forSegment: index)
        }
        alignmentControl.target = self
        alignmentControl.action = #selector(alignmentChanged(_:))
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.setAccessibilityLabel("Text Color")
        shadowCheckbox.target = self
        shadowCheckbox.action = #selector(shadowToggled(_:))
        shadowCheckbox.setAccessibilityIdentifier("watermarkShadow")

        bind(shadowOpacity) { $0.shadow.opacity = $1 }
        bind(shadowOffset) { $0.shadow.offset = $1 }
        bind(shadowRadius) { $0.shadow.radius = $1 }
        bind(shadowAngle) { $0.shadow.angle = $1 }

        let grid = NSGridView(views: [
            [label("Font:"), fontPopUp],
            [label("Style:"), facePopUp],
            [label("Align:"), alignmentControl],
            [label("Color:"), colorWell],
            [separator(), NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, shadowCheckbox],
            [label("Opacity:"), shadowOpacity],
            [label("Offset:"), shadowOffset],
            [label("Radius:"), shadowRadius],
            [label("Angle:"), shadowAngle],
        ])
        styleGrid(grid)
        grid.row(at: 4).mergeCells(in: NSRange(location: 0, length: 2))
        // The color well and alignment buttons keep their own size.
        for row in [2, 3] { grid.cell(atColumnIndex: 1, rowIndex: row).xPlacement = .leading }
        colorWell.widthAnchor.constraint(equalToConstant: 48).isActive = true
        grid.row(at: 3).rowAlignment = .none
        grid.row(at: 3).yPlacement = .center
        textSections.append(grid)
        return grid
    }

    private func effects() -> NSView {
        bind(opacityRow) { $0.opacity = $1 }
        bind(proportionalSize) { $0.proportionalSize = $1 }
        bind(horizontalInset) { $0.horizontalInset = $1 }
        bind(verticalInset) { $0.verticalInset = $1 }
        for button in [proportionalButton, fitButton, fillButton] {
            button.target = self
            button.action = #selector(sizeChanged(_:))
        }

        // Anchor: a 3 × 3 grid of radio buttons.
        let anchorGrid = NSGridView(numberOfColumns: 3, rows: 0)
        anchorGrid.rowSpacing = 2
        anchorGrid.columnSpacing = 2
        for row in WatermarkSettings.Anchor.allCases.chunked(3) {
            anchorGrid.addRow(with: row.map { anchor in
                let button = NSButton(radioButtonWithTitle: "", target: self, action: #selector(anchorChanged(_:)))
                button.setAccessibilityLabel("Anchor \(anchor.rawValue)")
                button.setAccessibilityIdentifier("watermarkAnchor.\(anchor.rawValue)")
                anchorButtons[anchor] = button
                return button
            })
        }
        for (button, symbol, label) in [(rotateRightButton, "rotate.right", "Rotate Clockwise"), (rotateLeftButton, "rotate.left", "Rotate Counterclockwise")] {
            button.bezelStyle = .push
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.imagePosition = .imageOnly
            button.toolTip = label
            button.target = self
            button.action = #selector(rotate(_:))
        }
        let rotate = NSStackView(views: [label("Rotate:"), rotateRightButton, rotateLeftButton])
        rotate.spacing = 6
        let anchorAndRotate = NSStackView(views: [anchorGrid, spacer(), rotate])
        anchorAndRotate.alignment = .top

        let insetLabel = NSTextField(labelWithString: "Inset")
        let grid = NSGridView(views: [
            [label("Opacity:"), opacityRow],
            [separator(), NSGridCell.emptyContentView],
            [label("Size:"), proportionalButton],
            [NSGridCell.emptyContentView, proportionalSize],
            [NSGridCell.emptyContentView, fitButton],
            [NSGridCell.emptyContentView, fillButton],
            [separator(), NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, insetLabel],
            [label("Horizontal:"), horizontalInset],
            [label("Vertical:"), verticalInset],
            [separator(), NSGridCell.emptyContentView],
            [label("Anchor:"), anchorAndRotate],
        ])
        styleGrid(grid)
        for row in [1, 6, 10] { grid.row(at: row).mergeCells(in: NSRange(location: 0, length: 2)) }
        grid.row(at: 11).yPlacement = .top
        return grid
    }

    /// Wires a value row to a setting.
    private func bind(_ row: WatermarkValueRow, _ update: @escaping (inout WatermarkSettings, Double) -> Void) {
        row.onChange = { [weak self] value in self?.change { update(&$0, value) } }
    }

    private func styleGrid(_ grid: NSGridView) {
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        // Same label column in every section, so the controls line up.
        grid.column(at: 0).width = 84
        grid.rowAlignment = .firstBaseline
        grid.column(at: 1).xPlacement = .fill
    }

    private func label(_ title: String) -> NSTextField {
        NSTextField(labelWithString: title)
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
}

/// A slider with an editable number beside it, as in Lightroom's Watermark Editor.
final class WatermarkValueRow: NSView, NSTextFieldDelegate {
    let slider = NSSlider()
    let field = NSTextField()
    var onChange: ((Double) -> Void)?

    var value: Double {
        get { slider.doubleValue }
        set {
            slider.doubleValue = newValue
            field.doubleValue = newValue.rounded()
        }
    }

    var isEnabled: Bool = true {
        didSet {
            slider.isEnabled = isEnabled
            field.isEnabled = isEnabled
        }
    }

    init(range: ClosedRange<Double>) {
        super.init(frame: .zero)
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        let formatter = NumberFormatter()
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        formatter.maximumFractionDigits = 0
        field.formatter = formatter
        field.alignment = .right
        field.delegate = self
        field.target = self
        field.action = #selector(fieldChanged(_:))
        for view in [slider, field] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: leadingAnchor),
            slider.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.widthAnchor.constraint(equalToConstant: 56),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var firstBaselineOffsetFromTop: CGFloat { field.firstBaselineOffsetFromTop }

    @objc private func sliderChanged(_ sender: NSSlider) {
        field.doubleValue = sender.doubleValue.rounded()
        onChange?(sender.doubleValue.rounded())
    }

    @objc private func fieldChanged(_ sender: NSTextField) {
        let clamped = sender.doubleValue.clamped(to: slider.minValue...slider.maxValue)
        value = clamped
        onChange?(clamped)
    }
}

/// Keeps a scroll view's document pinned to the top.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

private extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

/// Shows each font family in a font menu in that family's own typeface. Done when the menu first
/// opens, so opening the editor doesn't load hundreds of fonts.
final class FontMenuStyler: NSObject, NSMenuDelegate {
    private(set) var isStyled = false

    func menuWillOpen(_ menu: NSMenu) { style(menu) }

    func style(_ menu: NSMenu) {
        guard !isStyled else { return }
        isStyled = true
        let size = NSFont.systemFontSize
        for item in menu.items where !item.isSeparatorItem {
            guard let font = NSFontManager.shared.font(withFamily: item.title, traits: [], weight: 5, size: size) else { continue }
            item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: font])
        }
    }
}
