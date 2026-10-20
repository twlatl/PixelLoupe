import AppKit

/// The lens profiles the panel's Make, Model and Profile menus offer (lenses that fit the camera).
nonisolated struct LensCatalog: Sendable, Equatable {
    var makers: [String] = []
    /// Lens models by maker.
    var models: [String: [String]] = [:]
    /// Calibration titles by "maker\tmodel".
    var variants: [String: [String]] = [:]

    init() {}

    init(lenses: [LensFunDatabase.Lens]) {
        for lens in lenses {
            if models[lens.maker] == nil { makers.append(lens.maker) }
            if !(models[lens.maker]?.contains(lens.model) ?? false) { models[lens.maker, default: []].append(lens.model) }
            variants[Self.key(lens.maker, lens.model), default: []].append(lens.variantTitle)
        }
        makers.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        for maker in makers { models[maker]?.sort { $0.localizedStandardCompare($1) == .orderedAscending } }
    }

    static func key(_ maker: String, _ model: String) -> String { "\(maker)\t\(model)" }
}

/// Lightroom's Lens Corrections panel: Profile (Remove Chromatic Aberration, profile corrections
/// from the camera's built-in profile or LensFun, with amounts) and Manual (distortion, defringe,
/// vignetting).
final class LensPanelViewController: NSViewController {
    typealias Lens = PhotoAdjustments.LensCorrections

    enum ProfileStatus: Equatable {
        /// No photo, or it hasn't loaded.
        case unavailable
        /// The database is loading or a profile is being matched.
        case searching
        /// The camera has its own profile, used instead of LensFun's.
        case builtIn
        case matched
        case noMatch
    }

    var onChange: (_ lens: Lens, _ isFinal: Bool, _ actionName: String) -> Void = { _, _, _ in }
    /// A profile was picked from the menus.
    var onSelectProfile: (_ maker: String, _ model: String, _ variant: String) -> Void = { _, _, _ in }
    /// The defringe eyedropper was switched on or off.
    var onPickFringe: (Bool) -> Void = { _ in }

    private(set) var lens = Lens()
    private(set) var status = ProfileStatus.unavailable
    private(set) var catalog = LensCatalog()
    /// The camera's RAW files always apply their built-in profile.
    private(set) var builtInAlwaysOn = false
    private(set) var onSmartPreview = false
    var isEditingEnabled = false {
        didSet { update() }
    }

    private static let tabKey = "LensCorrectionsTab"
    private let tabs = NSSegmentedControl(labels: ["Profile", "Manual"], trackingMode: .selectOne, target: nil, action: nil)
    private let profileView = NSStackView()
    private let manualView = NSStackView()

    private let removeCACheckbox = NSButton(checkboxWithTitle: "Remove Chromatic Aberration", target: nil, action: nil)
    private let enableProfileCheckbox = NSButton(checkboxWithTitle: "Enable Profile Corrections", target: nil, action: nil)
    private let setupPopUp = NSPopUpButton()
    private let makePopUp = NSPopUpButton()
    private let modelPopUp = NSPopUpButton()
    private let variantPopUp = NSPopUpButton()
    private let distortionAmount = SliderRow(title: "Distortion", range: 0...200, defaultValue: 100, format: LensPanelViewController.integer)
    private let vignettingAmount = SliderRow(title: "Vignetting", range: 0...200, defaultValue: 100, format: LensPanelViewController.integer)
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    private let manualDistortion = SliderRow(title: "Amount", range: -100...100, format: LensPanelViewController.integer)
    private let constrainCheckbox = NSButton(checkboxWithTitle: "Constrain Crop", target: nil, action: nil)
    private let eyedropper = NSButton()
    private let purpleAmount = SliderRow(title: "Purple Amount", range: 0...20, format: LensPanelViewController.integer)
    private let purpleHue = HueRangeSlider(colors: [.systemBlue, .systemPurple, .systemPink, .systemOrange], title: "Purple Hue")
    private let purpleHueValue = NSTextField(labelWithString: "")
    private let greenAmount = SliderRow(title: "Green Amount", range: 0...20, format: LensPanelViewController.integer)
    private let greenHue = HueRangeSlider(colors: [.systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue], title: "Green Hue")
    private let greenHueValue = NSTextField(labelWithString: "")
    private let manualVignetting = SliderRow(title: "Amount", range: -100...100, format: LensPanelViewController.integer)
    private let midpoint = SliderRow(title: "Midpoint", range: 0...100, defaultValue: 50, format: LensPanelViewController.integer)

    nonisolated static func integer(_ value: Double) -> String { String(Int(value.rounded())) }

    override func loadView() {
        tabs.segmentStyle = .automatic
        tabs.controlSize = .small
        tabs.target = self
        tabs.action = #selector(tabChanged(_:))
        tabs.selectedSegment = Defaults.store.integer(forKey: Self.tabKey) == 1 ? 1 : 0
        tabs.setAccessibilityIdentifier("lensTabs")

        let title = NSTextField(labelWithString: "Lens Corrections")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

        buildProfileView()
        buildManualView()

        let stack = NSStackView(views: [title, tabs, profileView, manualView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 20, right: 14)
        stack.setCustomSpacing(8, after: title)
        for view in [tabs, profileView, manualView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }

        let document = FlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        let scrollView = NSScrollView()
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.setAccessibilityIdentifier("lensPanel")
        document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true
        document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor).isActive = true
        view = scrollView
        showTab()
        update()
    }

    // MARK: - Building

    private func label(_ text: String, header: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = header ? .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold) : .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = header ? .labelColor : .secondaryLabelColor
        return label
    }

    private func configure(_ checkbox: NSButton, identifier: String) {
        checkbox.controlSize = .small
        checkbox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        checkbox.target = self
        checkbox.action = #selector(checkboxChanged(_:))
        checkbox.setAccessibilityIdentifier(identifier)
    }

    private func popUpRow(_ title: String, _ popUp: NSPopUpButton, identifier: String) -> NSView {
        popUp.controlSize = .small
        popUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        popUp.target = self
        popUp.action = #selector(popUpChanged(_:))
        popUp.setAccessibilityLabel(title)
        popUp.setAccessibilityIdentifier(identifier)
        popUp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let title = label(title)
        title.alignment = .right
        title.widthAnchor.constraint(equalToConstant: 46).isActive = true
        return NSStackView(views: [title, popUp])
    }

    private func buildProfileView() {
        configure(removeCACheckbox, identifier: "lensRemoveCA")
        configure(enableProfileCheckbox, identifier: "lensEnableProfile")
        for setup in Lens.ProfileSetup.allCases { setupPopUp.addItem(withTitle: setup == .auto ? "Auto" : "Custom") }
        let setupRow = popUpRow("Setup", setupPopUp, identifier: "lensSetup")
        let makeRow = popUpRow("Make", makePopUp, identifier: "lensMake")
        let modelRow = popUpRow("Model", modelPopUp, identifier: "lensModel")
        let variantRow = popUpRow("Profile", variantPopUp, identifier: "lensProfile")

        distortionAmount.setAccessibilityIdentifier("lensDistortionAmount")
        distortionAmount.slider.setAccessibilityIdentifier("lensDistortionAmount")
        distortionAmount.onChange = { [weak self] value, isFinal in
            self?.change(isFinal: isFinal) { $0.distortionAmount = value / 100 }
        }
        vignettingAmount.setAccessibilityIdentifier("lensVignettingAmount")
        vignettingAmount.slider.setAccessibilityIdentifier("lensVignettingAmount")
        vignettingAmount.onChange = { [weak self] value, isFinal in
            self?.change(isFinal: isFinal) { $0.vignettingAmount = value / 100 }
        }

        statusIcon.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        statusIcon.contentTintColor = .secondaryLabelColor
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityIdentifier("lensStatus")
        let statusRow = NSStackView(views: [statusIcon, statusLabel])
        statusRow.alignment = .top

        let rows: [NSView] = [
            removeCACheckbox, enableProfileCheckbox, setupRow,
            label("Lens Profile", header: true), makeRow, modelRow, variantRow,
            label("Amount", header: true), distortionAmount, vignettingAmount, statusRow,
        ]
        profileView.orientation = .vertical
        profileView.alignment = .leading
        profileView.spacing = 8
        for row in rows {
            profileView.addArrangedSubview(row)
            if !(row is NSButton) { row.widthAnchor.constraint(equalTo: profileView.widthAnchor).isActive = true }
        }
        profileView.setCustomSpacing(12, after: setupRow)
        profileView.setCustomSpacing(12, after: variantRow)
        profileView.setCustomSpacing(14, after: vignettingAmount)
    }

    private func hueRow(_ slider: HueRangeSlider, value: NSTextField, title: String, identifier: String) -> NSView {
        let titleLabel = label(title)
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        let header = NSStackView(views: [titleLabel, NSView(), value])
        slider.setAccessibilityIdentifier(identifier)
        let row = NSStackView(views: [header, slider])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        header.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        slider.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        return row
    }

    private func buildManualView() {
        manualDistortion.setAccessibilityIdentifier("lensManualDistortion")
        manualDistortion.slider.setAccessibilityIdentifier("lensManualDistortion")
        manualDistortion.onChange = { [weak self] value, isFinal in
            self?.change(isFinal: isFinal) { $0.manualDistortion = value / 100 }
        }
        configure(constrainCheckbox, identifier: "lensConstrainCrop")

        eyedropper.image = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: "Fringe color selector")
        eyedropper.setButtonType(.pushOnPushOff)
        eyedropper.isBordered = false
        eyedropper.bezelStyle = .toolbar
        eyedropper.imagePosition = .imageOnly
        eyedropper.toolTip = "Fringe color selector: click a purple or green fringe on the photo"
        eyedropper.target = self
        eyedropper.action = #selector(toggleEyedropper(_:))
        eyedropper.setAccessibilityIdentifier("lensFringePicker")
        let defringeHeader = NSStackView(views: [label("Defringe", header: true), NSView(), eyedropper])

        purpleAmount.setAccessibilityIdentifier("lensPurpleAmount")
        purpleAmount.slider.setAccessibilityIdentifier("lensPurpleAmount")
        purpleAmount.onChange = { [weak self] value, isFinal in
            self?.change(isFinal: isFinal) { $0.purpleAmount = value / 20 }
        }
        greenAmount.setAccessibilityIdentifier("lensGreenAmount")
        greenAmount.slider.setAccessibilityIdentifier("lensGreenAmount")
        greenAmount.onChange = { [weak self] value, isFinal in
            self?.change(isFinal: isFinal) { $0.greenAmount = value / 20 }
        }
        purpleHue.onChange = { [weak self] lower, upper, isFinal in
            self?.change(isFinal: isFinal) { $0.purpleHue = .init(lower: lower, upper: upper) }
        }
        greenHue.onChange = { [weak self] lower, upper, isFinal in
            self?.change(isFinal: isFinal) { $0.greenHue = .init(lower: lower, upper: upper) }
        }

        manualVignetting.setAccessibilityIdentifier("lensManualVignetting")
        manualVignetting.slider.setAccessibilityIdentifier("lensManualVignetting")
        manualVignetting.onChange = { [weak self] value, isFinal in
            self?.change(isFinal: isFinal) { $0.manualVignetting = value / 100 }
        }
        midpoint.setAccessibilityIdentifier("lensVignettingMidpoint")
        midpoint.slider.setAccessibilityIdentifier("lensVignettingMidpoint")
        midpoint.onChange = { [weak self] value, isFinal in
            self?.change(isFinal: isFinal) { $0.vignettingMidpoint = value / 100 }
        }

        let distortionHeader = label("Distortion", header: true)
        let vignettingHeader = label("Vignetting", header: true)
        let rows: [NSView] = [
            distortionHeader, manualDistortion, constrainCheckbox,
            defringeHeader, purpleAmount, hueRow(purpleHue, value: purpleHueValue, title: "Purple Hue", identifier: "lensPurpleHue"),
            greenAmount, hueRow(greenHue, value: greenHueValue, title: "Green Hue", identifier: "lensGreenHue"),
            vignettingHeader, manualVignetting, midpoint,
        ]
        manualView.orientation = .vertical
        manualView.alignment = .leading
        manualView.spacing = 8
        for row in rows {
            manualView.addArrangedSubview(row)
            if !(row is NSButton), !(row is NSTextField) { row.widthAnchor.constraint(equalTo: manualView.widthAnchor).isActive = true }
        }
        manualView.setCustomSpacing(16, after: constrainCheckbox)
        manualView.setCustomSpacing(16, after: manualView.arrangedSubviews[7])
    }

    // MARK: - Display

    /// Shows a photo's settings and what's known about its profile. `onSmartPreview`: the photo is
    /// drawn from its Smart Preview, whose pixels have the built-in profile or not whatever the
    /// setting (`builtInAlwaysOn` says which).
    func display(_ lens: Lens, status: ProfileStatus, catalog: LensCatalog, builtInAlwaysOn: Bool = false, onSmartPreview: Bool = false) {
        self.lens = lens
        self.status = status
        self.catalog = catalog
        self.builtInAlwaysOn = builtInAlwaysOn
        self.onSmartPreview = onSmartPreview
        if isViewLoaded { update() }
    }

    /// Switches the eyedropper off (after a pick, or when leaving the panel).
    func endFringePicking() {
        eyedropper.state = .off
        eyedropper.contentTintColor = nil
    }

    private func update() {
        guard isViewLoaded else { return }
        let builtIn = status == .builtIn
        let profileEditable = isEditingEnabled && lens.enableProfileCorrections && !builtIn

        removeCACheckbox.state = lens.removeChromaticAberration ? .on : .off
        let builtInApplied = builtIn && (lens.enableProfileCorrections || builtInAlwaysOn)
        enableProfileCheckbox.state = lens.enableProfileCorrections || builtInApplied ? .on : .off
        removeCACheckbox.isEnabled = isEditingEnabled
        // A camera that always applies its built-in profile can't turn it off.
        enableProfileCheckbox.isEnabled = isEditingEnabled && !(builtIn && builtInAlwaysOn)

        setupPopUp.selectItem(at: lens.setup == .auto ? 0 : 1)
        setupPopUp.isEnabled = profileEditable

        if builtIn {
            for popUp in [makePopUp, modelPopUp, variantPopUp] {
                popUp.removeAllItems()
                popUp.addItem(withTitle: "Built-in")
                popUp.isEnabled = false
            }
        } else {
            let maker = lens.profile?.maker
            let model = lens.profile?.model
            fill(makePopUp, catalog.makers, selected: maker)
            fill(modelPopUp, maker.flatMap { catalog.models[$0] } ?? [], selected: model)
            fill(variantPopUp, maker.flatMap { m in model.flatMap { catalog.variants[LensCatalog.key(m, $0)] } } ?? [],
                 selected: lens.profile?.variant)
            for popUp in [makePopUp, modelPopUp, variantPopUp] { popUp.isEnabled = profileEditable && !catalog.makers.isEmpty }
        }

        distortionAmount.value = lens.distortionAmount * 100
        vignettingAmount.value = lens.vignettingAmount * 100
        distortionAmount.slider.isEnabled = profileEditable && !(lens.profile?.distortion.isEmpty ?? true)
        vignettingAmount.slider.isEnabled = profileEditable && !(lens.profile?.vignetting.isEmpty ?? true)

        let message: String? = switch status {
        case .unavailable: nil
        case .searching: "Looking for a lens profile…"
        case .builtIn where onSmartPreview && !builtInAlwaysOn:
            lens.enableProfileCorrections ? "The Built-in Lens Profile is applied to the original only." : nil
        case .builtIn: builtInApplied ? "Built-in Lens Profile applied." : nil
        case .matched where !lens.enableProfileCorrections: nil
        case .matched: lens.profile.map { "LensFun profile applied: \($0.title)." }
        case .noMatch where lens.enableProfileCorrections: "Unable to locate a matching lens profile automatically."
        case .noMatch: nil
        }
        statusLabel.stringValue = message ?? ""
        statusIcon.isHidden = message == nil

        manualDistortion.value = lens.manualDistortion * 100
        constrainCheckbox.state = lens.constrainCrop ? .on : .off
        purpleAmount.value = lens.purpleAmount * 20
        greenAmount.value = lens.greenAmount * 20
        purpleHue.lower = lens.purpleHue.lower
        purpleHue.upper = lens.purpleHue.upper
        greenHue.lower = lens.greenHue.lower
        greenHue.upper = lens.greenHue.upper
        purpleHueValue.stringValue = "\(Int((lens.purpleHue.lower * 100).rounded())) / \(Int((lens.purpleHue.upper * 100).rounded()))"
        greenHueValue.stringValue = "\(Int((lens.greenHue.lower * 100).rounded())) / \(Int((lens.greenHue.upper * 100).rounded()))"
        manualVignetting.value = lens.manualVignetting * 100
        midpoint.value = lens.vignettingMidpoint * 100

        for control in [manualDistortion.slider, constrainCheckbox, eyedropper, purpleAmount.slider, greenAmount.slider,
                        purpleHue, greenHue, manualVignetting.slider] as [NSControl] {
            control.isEnabled = isEditingEnabled
        }
        // Like Lightroom, Midpoint only matters once there's vignetting to place.
        midpoint.slider.isEnabled = isEditingEnabled && lens.manualVignetting != 0
    }

    private func fill(_ popUp: NSPopUpButton, _ titles: [String], selected: String?) {
        let current = popUp.itemTitles
        if current != titles {
            popUp.removeAllItems()
            popUp.addItems(withTitles: titles)
        }
        if let selected, titles.contains(selected) {
            popUp.selectItem(withTitle: selected)
        } else {
            popUp.select(nil)
            popUp.setTitle(titles.isEmpty ? "None" : "Choose…")
        }
    }

    // MARK: - Actions

    private func change(isFinal: Bool, actionName: String = "Lens Corrections", _ mutate: (inout Lens) -> Void) {
        mutate(&lens)
        update()
        onChange(lens, isFinal, actionName)
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        Defaults.store.set(sender.selectedSegment, forKey: Self.tabKey)
        showTab()
    }

    private func showTab() {
        profileView.isHidden = tabs.selectedSegment != 0
        manualView.isHidden = tabs.selectedSegment != 1
        if tabs.selectedSegment != 1, eyedropper.state == .on {
            endFringePicking()
            onPickFringe(false)
        }
    }

    @objc private func checkboxChanged(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender {
        case removeCACheckbox: change(isFinal: true) { $0.removeChromaticAberration = on }
        case enableProfileCheckbox: change(isFinal: true) { $0.enableProfileCorrections = on }
        case constrainCheckbox: change(isFinal: true) { $0.constrainCrop = on }
        default: break
        }
    }

    @objc private func popUpChanged(_ sender: NSPopUpButton) {
        switch sender {
        case setupPopUp:
            change(isFinal: true) { $0.setup = sender.indexOfSelectedItem == 0 ? .auto : .custom }
        case makePopUp:
            // A new maker: its first lens.
            guard let maker = sender.titleOfSelectedItem, let model = catalog.models[maker]?.first else { return }
            selectProfile(maker, model)
        case modelPopUp:
            guard let maker = lens.profile?.maker ?? makePopUp.titleOfSelectedItem, let model = sender.titleOfSelectedItem else { return }
            selectProfile(maker, model)
        case variantPopUp:
            guard let profile = lens.profile, let variant = sender.titleOfSelectedItem else { return }
            onSelectProfile(profile.maker, profile.model, variant)
        default:
            break
        }
    }

    private func selectProfile(_ maker: String, _ model: String) {
        let variant = catalog.variants[LensCatalog.key(maker, model)]?.first ?? ""
        onSelectProfile(maker, model, variant)
    }

    @objc private func toggleEyedropper(_ sender: NSButton) {
        let on = sender.state == .on
        sender.contentTintColor = on ? Accent.color : nil
        onPickFringe(on)
    }
}
