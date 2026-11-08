import AppKit

/// The Remove panel (RAW-260), after Lightroom's: Remove, Heal or Clone; the brush's Size (and Feather for Heal
/// and Clone); Use Generative AI and Detect Objects for Remove; then the Selected card — before removing, the
/// detected area's Add / Subtract brush with Cancel and Remove; after, the spot's Fill, Opacity and Refresh —
/// and when spot pins show (Tool Overlay).
final class RemovePanelViewController: NSViewController {
    enum Mode: Int, CaseIterable {
        case remove, heal, clone

        var title: String {
            switch self {
            case .remove: "Remove"
            case .heal: "Heal"
            case .clone: "Clone"
            }
        }

        var symbol: String {
            switch self {
            case .remove: "eraser"
            case .heal: "bandage"
            case .clone: "square.on.square"
            }
        }

        var kind: PhotoAdjustments.Spot.Kind {
            switch self {
            case .remove: .remove
            case .heal: .heal
            case .clone: .clone
            }
        }
    }

    /// When spots' pins show on the photo.
    enum ToolOverlay: Int, CaseIterable {
        case always, selected, never

        var title: String {
            switch self {
            case .always: "Always"
            case .selected: "Selected"
            case .never: "Never"
            }
        }
    }

    /// An area painted with Detect Objects on, waiting for Remove or Cancel.
    enum Pending: Equatable {
        case detecting
        case ready(PhotoAdjustments.RemoveArea)
    }

    private(set) var mode: Mode
    /// The brush's radius as a fraction of the photo's long edge.
    private(set) var brushSize: Double
    /// Heal and Clone's feather, 0…1.
    private(set) var feather: Double
    private(set) var usesGenerativeAI: Bool
    private(set) var detectsObjects: Bool
    private(set) var toolOverlay: ToolOverlay
    /// Painting with the Selected card's Subtract.
    private(set) var subtracts = false
    private(set) var pending: Pending?
    private(set) var selected: PhotoAdjustments.Spot?

    var onModeChange: ((Mode) -> Void)?
    var onBrushChange: (() -> Void)?
    var onToolOverlayChange: ((ToolOverlay) -> Void)?
    var onSubtractChange: ((Bool) -> Void)?
    var onCommitPending: (() -> Void)?
    var onCancelPending: (() -> Void)?
    var onEditSelected: ((_ spot: PhotoAdjustments.Spot, _ isFinal: Bool, _ actionName: String) -> Void)?
    var onDeleteSelected: (() -> Void)?
    var onReset: (() -> Void)?
    var onClose: (() -> Void)?
    var isEditingEnabled = true { didSet { refresh() } }

    private let defaults: UserDefaults
    private let modePicker = NSSegmentedControl()
    private var sizeRow: SliderRow!
    private var featherRow: SliderRow!
    private let generativeCheckbox = NSButton(checkboxWithTitle: "Use generative AI", target: nil, action: nil)
    private let generativeStatus = NSTextField(wrappingLabelWithString: "")
    private let downloadButton = NSButton(title: "Download Model", target: nil, action: nil)
    private let detectCheckbox = NSButton(checkboxWithTitle: "Detect objects", target: nil, action: nil)
    private let removeOptions = NSStackView()
    private let card = CardView()
    private let cardTitle = NSTextField(labelWithString: "Selected")
    private let cardDelete = NSButton()
    private let pendingRows = NSStackView()
    private let maskPicker = NSSegmentedControl(labels: ["Add", "Subtract"], trackingMode: .selectOne, target: nil, action: nil)
    private let detectingLabel = NSTextField(labelWithString: "Detecting objects…")
    private let spotRows = NSStackView()
    private let fillPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private var opacityRow: SliderRow!
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let sourceHint = NSTextField(wrappingLabelWithString: "⌘-drag on the photo to choose a source of its own.")
    private let overlayPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private var actionTargets: [ActionTarget] = []
    private var modelObserver: NSObjectProtocol?
    var model: InpaintingModelStore = .shared

    private static let modeKey = "RemoveMode", sizeKey = "RemoveBrushSize", featherKey = "RemoveFeather"
    private static let generativeKey = "RemoveUsesGenerativeAI", detectKey = "RemoveDetectsObjects", overlayKey = "RemoveToolOverlay"
    /// Brush radii, as a fraction of the photo's long edge (the Size slider's range).
    static let sizeRange = 0.002...0.1

    init(defaults: UserDefaults = Defaults.store) {
        self.defaults = defaults
        mode = Mode(rawValue: defaults.integer(forKey: Self.modeKey)) ?? .remove
        brushSize = (defaults.object(forKey: Self.sizeKey) as? Double ?? 0.02).clamped(to: Self.sizeRange)
        feather = (defaults.object(forKey: Self.featherKey) as? Double ?? 0).clamped(to: 0...1)
        usesGenerativeAI = defaults.bool(forKey: Self.generativeKey)
        detectsObjects = defaults.object(forKey: Self.detectKey) as? Bool ?? true
        toolOverlay = ToolOverlay(rawValue: defaults.integer(forKey: Self.overlayKey)) ?? .always
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func target(_ handler: @escaping (NSControl) -> Void, for control: NSControl) {
        let target = ActionTarget { handler($0 as! NSControl) }
        control.target = target
        control.action = #selector(ActionTarget.fire(_:))
        actionTargets.append(target)
    }

    private func small(_ label: NSTextField) -> NSTextField {
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "REMOVE")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor

        // Mode: the three tools as icons, as in Lightroom.
        modePicker.segmentCount = Mode.allCases.count
        modePicker.trackingMode = .selectOne
        modePicker.controlSize = .regular
        for mode in Mode.allCases {
            modePicker.setImage(NSImage(systemSymbolName: mode.symbol, accessibilityDescription: mode.title), forSegment: mode.rawValue)
            modePicker.setToolTip(mode.title, forSegment: mode.rawValue)
            modePicker.setWidth(36, forSegment: mode.rawValue)
        }
        modePicker.setAccessibilityLabel("Mode")
        modePicker.setAccessibilityIdentifier("removeMode")
        target({ [weak self] control in
            guard let self, let mode = Mode(rawValue: (control as! NSSegmentedControl).selectedSegment) else { return }
            setMode(mode)
            onModeChange?(mode)
        }, for: modePicker)
        let modeRow = NSStackView(views: [small(NSTextField(labelWithString: "Mode:")), modePicker])

        sizeRow = SliderRow(title: "Size", range: Self.sizeRange, defaultValue: 0.02, format: { String(format: "%.0f", $0 * 1000) }, scale: .logarithmic(Self.sizeRange))
        sizeRow.slider.setAccessibilityIdentifier("slider.Remove.Size")
        sizeRow.onChange = { [weak self] value, _ in self?.setBrushSize(value) }
        featherRow = SliderRow(title: "Feather", range: 0...1, defaultValue: 0, format: { String(format: "%.0f", $0 * 100) })
        featherRow.slider.setAccessibilityIdentifier("slider.Remove.Feather")
        featherRow.onChange = { [weak self] value, _ in
            guard let self else { return }
            feather = value
            defaults.set(value, forKey: Self.featherKey)
            onBrushChange?()
        }

        for (checkbox, identifier) in [(generativeCheckbox, "removeGenerativeAI"), (detectCheckbox, "removeDetectObjects")] {
            checkbox.controlSize = .small
            checkbox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            checkbox.setAccessibilityIdentifier(identifier)
        }
        generativeCheckbox.toolTip = "Fill with an on-device generative model instead of the photo's own patches"
        target({ [weak self] control in
            guard let self else { return }
            usesGenerativeAI = (control as! NSButton).state == .on
            defaults.set(usesGenerativeAI, forKey: Self.generativeKey)
            if usesGenerativeAI { model.download() }
            refresh()
        }, for: generativeCheckbox)
        detectCheckbox.toolTip = "Paint roughly around something to select it"
        target({ [weak self] control in
            guard let self else { return }
            detectsObjects = (control as! NSButton).state == .on
            defaults.set(detectsObjects, forKey: Self.detectKey)
        }, for: detectCheckbox)
        downloadButton.controlSize = .small
        downloadButton.setAccessibilityIdentifier("removeDownloadModel")
        target({ [weak self] _ in self?.model.download() }, for: downloadButton)
        _ = small(generativeStatus)
        removeOptions.orientation = .vertical
        removeOptions.alignment = .leading
        removeOptions.spacing = 6
        for view in [generativeCheckbox, generativeStatus, downloadButton, detectCheckbox] { removeOptions.addArrangedSubview(view) }

        buildCard()

        overlayPopUp.controlSize = .small
        overlayPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        overlayPopUp.addItems(withTitles: ToolOverlay.allCases.map(\.title))
        overlayPopUp.setAccessibilityLabel("Tool Overlay")
        overlayPopUp.setAccessibilityIdentifier("removeToolOverlay")
        target({ [weak self] control in
            guard let self, let overlay = ToolOverlay(rawValue: (control as! NSPopUpButton).indexOfSelectedItem) else { return }
            toolOverlay = overlay
            defaults.set(overlay.rawValue, forKey: Self.overlayKey)
            onToolOverlayChange?(overlay)
        }, for: overlayPopUp)
        let overlayRow = NSStackView(views: [small(NSTextField(labelWithString: "Tool Overlay:")), overlayPopUp])

        let reset = NSButton(title: "Reset", target: nil, action: nil)
        let close = NSButton(title: "Close", target: nil, action: nil)
        for (button, identifier, tip) in [(reset, "removeReset", "Remove every spot"), (close, "removeClose", "Close the Remove tool")] {
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.setAccessibilityIdentifier(identifier)
            button.toolTip = tip
        }
        target({ [weak self] _ in self?.onReset?() }, for: reset)
        target({ [weak self] _ in self?.onClose?() }, for: close)
        let footer = NSStackView(views: [NSView(), reset, close])

        _ = small(hint)

        let stack = NSStackView(views: [title, modeRow, separator(), sizeRow, featherRow, removeOptions, card, separator(), overlayRow, separator(), footer, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 20, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in stack.arrangedSubviews where view !== title && view !== modeRow && view !== overlayRow {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        let document = FlippedView()
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor), stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        let outer = NSScrollView()
        outer.documentView = document
        outer.hasVerticalScroller = true
        outer.autohidesScrollers = true
        outer.drawsBackground = false
        outer.setAccessibilityIdentifier("removePanel")
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: outer.contentView.widthAnchor).isActive = true
        document.topAnchor.constraint(equalTo: outer.contentView.topAnchor).isActive = true
        view = outer

        modelObserver = NotificationCenter.default.addObserver(forName: InpaintingModelStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// The Selected card: an area waiting to be removed, or the selected spot.
    private func buildCard() {
        card.setAccessibilityIdentifier("removeSelectedCard")

        cardTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        cardDelete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete Spot")
        cardDelete.isBordered = false
        cardDelete.toolTip = "Delete the spot (Delete)"
        cardDelete.setAccessibilityIdentifier("removeDeleteSpot")
        target({ [weak self] _ in self?.onDeleteSelected?() }, for: cardDelete)
        let header = NSStackView(views: [cardTitle, NSView(), cardDelete])

        // Before removing: the detected area's brush.
        maskPicker.controlSize = .small
        maskPicker.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: nil), forSegment: 0)
        maskPicker.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: nil), forSegment: 1)
        maskPicker.setAccessibilityLabel("Mask")
        maskPicker.setAccessibilityIdentifier("removeMaskMode")
        target({ [weak self] control in
            guard let self else { return }
            subtracts = (control as! NSSegmentedControl).selectedSegment == 1
            onSubtractChange?(subtracts)
        }, for: maskPicker)
        let maskRow = NSStackView(views: [small(NSTextField(labelWithString: "Mask:")), maskPicker])
        _ = small(detectingLabel)
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        let remove = NSButton(title: "Remove", target: nil, action: nil)
        cancel.controlSize = .small
        remove.controlSize = .small
        remove.bezelColor = .controlAccentColor
        remove.keyEquivalent = "\r"
        cancel.setAccessibilityIdentifier("removeCancel")
        remove.setAccessibilityIdentifier("removeCommit")
        target({ [weak self] _ in self?.onCancelPending?() }, for: cancel)
        target({ [weak self] _ in self?.onCommitPending?() }, for: remove)
        let pendingButtons = NSStackView(views: [NSView(), cancel, remove])
        pendingRows.orientation = .vertical
        pendingRows.alignment = .leading
        pendingRows.spacing = 6
        for view in [detectingLabel, maskRow, pendingButtons] { pendingRows.addArrangedSubview(view) }
        pendingButtons.widthAnchor.constraint(equalTo: pendingRows.widthAnchor).isActive = true

        // After: the spot's settings.
        fillPopUp.controlSize = .small
        fillPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        fillPopUp.addItems(withTitles: Mode.allCases.map(\.title))
        fillPopUp.setAccessibilityLabel("Fill")
        fillPopUp.setAccessibilityIdentifier("removeFill")
        target({ [weak self] control in
            guard let self, var spot = selected, let mode = Mode(rawValue: (control as! NSPopUpButton).indexOfSelectedItem) else { return }
            spot.kind = mode.kind
            onEditSelected?(spot, true, "Spot Fill")
        }, for: fillPopUp)
        let fillRow = NSStackView(views: [small(NSTextField(labelWithString: "Fill:")), fillPopUp])
        opacityRow = SliderRow(title: "Opacity", range: 0...1, defaultValue: 1, format: { String(format: "%.0f", $0 * 100) })
        opacityRow.slider.setAccessibilityIdentifier("slider.Remove.Opacity")
        opacityRow.onChange = { [weak self] value, isFinal in
            guard let self, var spot = selected else { return }
            spot.opacity = value
            onEditSelected?(spot, isFinal, "Spot Opacity")
        }
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshButton.imagePosition = .imageLeading
        refreshButton.controlSize = .small
        refreshButton.toolTip = "Fill the spot another way"
        refreshButton.setAccessibilityIdentifier("removeRefresh")
        target({ [weak self] _ in
            guard let self, var spot = selected else { return }
            spot.seed = UInt64.random(in: 1...UInt64.max)
            onEditSelected?(spot, true, "Refresh Spot")
        }, for: refreshButton)
        _ = small(sourceHint)
        spotRows.orientation = .vertical
        spotRows.alignment = .leading
        spotRows.spacing = 6
        for view in [fillRow, opacityRow, refreshButton, sourceHint] as [NSView] { spotRows.addArrangedSubview(view) }
        for view in [opacityRow, sourceHint] as [NSView] { view.widthAnchor.constraint(equalTo: spotRows.widthAnchor).isActive = true }

        let content = NSStackView(views: [header, pendingRows, spotRows])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        for view in [header, pendingRows, spotRows] { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
        ])
    }

    // MARK: - Showing

    func setMode(_ mode: Mode) {
        self.mode = mode
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        refresh()
    }

    func setBrushSize(_ size: Double) {
        brushSize = size.clamped(to: Self.sizeRange)
        defaults.set(brushSize, forKey: Self.sizeKey)
        if isViewLoaded, abs(sizeRow.value - brushSize) > 1e-9 { sizeRow.value = brushSize }
        onBrushChange?()
    }

    func showPending(_ pending: Pending?) {
        self.pending = pending
        if pending == nil, subtracts {
            subtracts = false
            onSubtractChange?(false)
        }
        refresh()
    }

    func showSelected(_ spot: PhotoAdjustments.Spot?) {
        selected = spot
        refresh()
    }

    private func refresh() {
        guard isViewLoaded else { return }
        modePicker.selectedSegment = mode.rawValue
        sizeRow.value = brushSize
        featherRow.value = feather
        featherRow.isHidden = mode == .remove
        removeOptions.isHidden = mode != .remove
        generativeCheckbox.state = usesGenerativeAI ? .on : .off
        detectCheckbox.state = detectsObjects ? .on : .off
        let modelState = model.state
        switch modelState {
        case .unavailable:
            generativeStatus.stringValue = "The generative model isn't available in this version, so spots are filled from the photo."
        case .notDownloaded:
            generativeStatus.stringValue = "The generative model downloads the first time it's used."
        case .downloading(let progress):
            generativeStatus.stringValue = "Downloading the generative model… \(Int(progress * 100))%. Spots are filled from the photo until it's ready."
        case .ready:
            generativeStatus.stringValue = ""
        case .failed(let message):
            generativeStatus.stringValue = "The generative model couldn't be downloaded: \(message)"
        }
        generativeStatus.isHidden = !usesGenerativeAI || modelState == .ready
        downloadButton.isHidden = !usesGenerativeAI || !(modelState == .notDownloaded || { if case .failed = modelState { true } else { false } }())
        overlayPopUp.selectItem(at: toolOverlay.rawValue)

        // The Selected card.
        card.isHidden = pending == nil && selected == nil
        pendingRows.isHidden = pending == nil
        spotRows.isHidden = pending != nil || selected == nil
        cardDelete.isHidden = pending != nil || selected == nil
        detectingLabel.isHidden = pending != .detecting
        maskPicker.selectedSegment = subtracts ? 1 : 0
        maskPicker.isEnabled = pending != .detecting
        if let spot = selected, pending == nil {
            cardTitle.stringValue = "Selected"
            fillPopUp.selectItem(at: spot.kind == .remove ? 0 : spot.kind == .heal ? 1 : 2)
            opacityRow.value = spot.opacity
            refreshButton.isHidden = !spot.isFilled
            sourceHint.isHidden = spot.kind != .remove || spot.area == nil
        } else {
            cardTitle.stringValue = "Selected"
        }

        hint.stringValue = switch mode {
        case .remove where pending != nil: "Paint to add to the area (or subtract with Subtract), then click Remove (Return). Esc cancels."
        case .remove: detectsObjects
            ? "Paint roughly around something to select it. Scroll to resize the brush."
            : "Paint over what to remove. Scroll to resize the brush."
        case .heal: "Click or paint a spot. Heal copies from nearby and matches the colors around it."
        case .clone: "Click or paint a spot. Clone copies from nearby as it is."
        }
        setControlsEnabled(isEditingEnabled, in: view)
    }

    private func setControlsEnabled(_ enabled: Bool, in view: NSView) {
        for subview in view.subviews {
            if let control = subview as? NSControl { control.isEnabled = enabled && (control !== maskPicker || pending != .detecting) }
            setControlsEnabled(enabled, in: subview)
        }
    }

    /// For tests.
    var modePickerForTesting: NSSegmentedControl { modePicker }
    var cardForTesting: NSView { card }
}

/// The Selected card's rounded, lightly filled background, following the appearance.
private final class CardView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}
