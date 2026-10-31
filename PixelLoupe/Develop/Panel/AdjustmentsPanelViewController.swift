import AppKit

/// The Develop module's Adjust panel: twelve collapsible sections of controls bound to a
/// `PhotoAdjustments` value.
///
/// Every edit calls `onChange`. Intermediate changes (slider drags) only update the preview;
/// final ones (mouse up, buttons, keyboard) are saved and recorded for undo by the owner.
///
/// The Masking panel uses it too, for a mask's own sections (`Scope.mask`): just those a mask applies, without
/// the panel's header or scrolling, and with a relative Temp and Tint in place of the photo's white balance.
final class AdjustmentsPanelViewController: NSViewController {
    typealias Adjustments = PhotoAdjustments

    enum Scope {
        /// The photo's settings: the Adjust panel.
        case photo
        /// A mask's (``PhotoAdjustments/LocalSettings/adjustments``).
        case mask
    }

    let scope: Scope

    init(scope: Scope = .photo) {
        self.scope = scope
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// What sets a mask's sections apart: in their identifiers, action names and remembered open state.
    private var scopeName: String { scope == .mask ? "Mask." : "" }

    private(set) var adjustments = Adjustments()
    private var asShotWhiteBalance: (temperature: Double, tint: Double) = (6500, 0)
    /// Whether the photo is a RAW file: its White Balance pop-up lists the light sources.
    private(set) var isRaw = true

    var onChange: ((_ adjustments: Adjustments, _ isFinal: Bool, _ actionName: String) -> Void)?
    /// Called while a profile or white balance is highlighted in its menu, with the settings it would give the
    /// photo (to preview it without applying), and with `nil` when the menu closes.
    var onPreview: ((Adjustments?) -> Void)?
    var autoLight: (() -> Adjustments.Light?)?
    /// The photo's automatic white balance (temperature, tint), or `nil` when it can't be worked out.
    var autoWhiteBalance: (() -> (temperature: Double, tint: Double)?)?
    /// The white balance eyedropper was switched on or off.
    var onPickWhiteBalance: ((Bool) -> Void)?
    /// Transform's Upright ▸ Level: the controller measures the photo and calls back with the rotation.
    var onUprightLevel: (() -> Void)?
    /// A Color Grading wheel's eye was switched: the preview should leave out these wheels (render-time only).
    var onMuteWheels: ((Set<ColorGradingTab>) -> Void)?
    /// Option-dragging the Masking slider asks for the mask to be shown in the preview.
    var onSharpenMaskPreview: ((Bool) -> Void)?

    private let stack = NSStackView()
    private let resetAllButton = NSButton(title: "Revert to Original", target: nil, action: nil)
    private var refreshers: [() -> Void] = []
    private var sectionStates: [() -> Void] = []
    private var selectedSelectiveColor = Adjustments.SelectiveColorRange.red
    private var curveChannel = Adjustments.CurveChannel.rgb
    private var curveParametric = false
    private var mixerTab = 3
    private var mixerSection: AdjustmentSectionView?
    private var actionTargets: [ActionTarget] = []
    private var temperatureRow: SliderRow?
    private var tintRow: SliderRow?
    private let whiteBalancePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let whiteBalanceEyedropper = NSButton()
    /// Shows the Color Grading tab picked app-wide (`ColorGradingTab.current`).
    private var showColorGradingTab: (() -> Void)?
    /// Color Grading wheels hidden from the preview by their eye buttons.
    private(set) var mutedWheels: Set<ColorGradingTab> = []
    private var eyeButtons: [(tab: ColorGradingTab, button: NSButton)] = []
    /// The Shadows, Midtones and Highlights tabs' wheel strips, which slide between those tabs.
    private var colorCarousels: [ColorGradingTab: ColorWheelCarouselView] = [:]

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        if scope == .mask {
            // Inside the Masking panel, which scrolls and has its own header.
            view = stack
            buildSections()
            refresh()
            return
        }
        let title = NSTextField(labelWithString: "ADJUST")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor

        resetAllButton.controlSize = .small
        resetAllButton.target = self
        resetAllButton.action = #selector(resetAll(_:))
        resetAllButton.setAccessibilityIdentifier("revertToOriginal")

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [title, headerSpacer, resetAllButton])

        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 20, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true

        let document = FlippedView()
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
        scrollView.setAccessibilityIdentifier("adjustPanel")
        document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true
        document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor).isActive = true
        view = scrollView

        buildSections()
        refresh()
    }

    /// Shows the settings for a newly selected photo.
    func display(_ adjustments: Adjustments, asShotWhiteBalance: (temperature: Double, tint: Double), isRaw: Bool = true) {
        self.adjustments = adjustments
        self.asShotWhiteBalance = asShotWhiteBalance
        if isRaw != self.isRaw {
            self.isRaw = isRaw
            fillWhiteBalancePopUp()
        }
        temperatureRow?.defaultValue = asShotWhiteBalance.temperature
        tintRow?.defaultValue = asShotWhiteBalance.tint
        refresh()
    }

    var isEditingEnabled = true {
        didSet {
            setControlsEnabled(isEditingEnabled, in: stack)
            stack.alphaValue = isEditingEnabled ? 1 : 0.5
        }
    }

    // MARK: - Editing

    private func change(_ section: String, isFinal: Bool, _ mutate: (inout Adjustments) -> Void) {
        mutate(&adjustments)
        updateSectionStates()
        onChange?(adjustments, isFinal, scope == .mask ? "Adjust Mask \(section)" : "Adjust \(section)")
    }

    private func refresh() {
        refreshers.forEach { $0() }
        updateSectionStates()
    }

    private func updateSectionStates() {
        sectionStates.forEach { $0() }
        resetAllButton.isEnabled = isEditingEnabled && !adjustments.isDefault
    }

    /// Light ▸ Auto (also ⌘U, Lightroom's Auto Tone shortcut).
    func applyAutoLight() {
        guard isEditingEnabled, let light = autoLight?() else { return }
        change("Light", isFinal: true) { $0.light = light }
        refresh()
    }

    @objc private func resetAll(_ sender: Any?) {
        adjustments = Adjustments()
        refresh()
        onChange?(adjustments, true, "Revert to Original")
    }

    private func setControlsEnabled(_ enabled: Bool, in view: NSView) {
        for subview in view.subviews {
            if let control = subview as? NSControl { control.isEnabled = enabled }
            setControlsEnabled(enabled, in: subview)
        }
    }

    // MARK: - Building

    /// Adds a section whose on/off switch is `enabled` and whose defaults are `defaultValue`.
    private func addSection<Section: Equatable>(
        _ title: String,
        symbol: String,
        keyPath: WritableKeyPath<Adjustments, Section>,
        enabled: WritableKeyPath<Section, Bool>,
        defaultValue: Section,
        isApplied: @escaping (Adjustments) -> Bool,
        hasAuto: Bool = false,
        expanded: Bool = false
    ) -> AdjustmentSectionView {
        let section = AdjustmentSectionView(
            // Under a mask only Light starts open; the others are a click away.
            title: title, symbolName: symbol, hasAuto: hasAuto && scope == .photo,
            expandedByDefault: scope == .mask ? keyPath as AnyKeyPath == \Adjustments.light : expanded, scope: scopeName
        )
        stack.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true

        let isModified: (Adjustments) -> Bool = { $0[keyPath: keyPath] != defaultValue }
        sectionStates.append { [weak self, weak section] in
            guard let self, let section else { return }
            section.setState(isModified: isModified(adjustments), isApplied: isApplied(adjustments))
        }
        section.onReset = { [weak self] in
            self?.change(title, isFinal: true) { $0[keyPath: keyPath] = defaultValue }
            self?.refresh()
        }
        section.onToggle = { [weak self] in
            self?.change(title, isFinal: true) { $0[keyPath: keyPath][keyPath: enabled].toggle() }
        }
        return section
    }

    /// Adds a slider bound to a value inside a section; editing it turns the section on.
    @discardableResult
    private func addSlider<Section>(
        to section: AdjustmentSectionView,
        _ sectionTitle: String,
        _ title: String,
        keyPath: WritableKeyPath<Adjustments, Section>,
        enabled: WritableKeyPath<Section, Bool>,
        range: ClosedRange<Double>,
        defaultValue: Double = 0,
        format: @escaping (Double) -> String = SliderRow.signed,
        scale: SliderScale = .linear,
        trackColors: [NSColor]? = nil,
        placed: Bool = true,
        get: @escaping (Adjustments) -> Double,
        set: @escaping (inout Adjustments, Double) -> Void
    ) -> SliderRow {
        let row = SliderRow(title: title, range: range, defaultValue: defaultValue, format: format, scale: scale, trackColors: trackColors)
        row.setAccessibilityIdentifier("slider.\(scopeName)\(sectionTitle).\(title)")
        row.slider.setAccessibilityIdentifier("slider.\(scopeName)\(sectionTitle).\(title)")
        if placed { section.addControl(row) }
        row.onChange = { [weak self] value, isFinal in
            self?.change(sectionTitle, isFinal: isFinal) {
                set(&$0, value)
                $0[keyPath: keyPath][keyPath: enabled] = true
            }
        }
        refreshers.append { [weak self, weak row] in
            guard let self, let row else { return }
            row.value = get(adjustments)
        }
        return row
    }

    private func buildSections() {
        if scope == .mask {
            // What a mask can apply, in the Adjust panel's order.
            buildMaskWhiteBalance()
            buildLight()
            buildPresence()
            buildColor()
            buildBlackAndWhite()
            buildCurves()
            buildLevels()
            buildDefinition()
            buildSelectiveColor()
            buildNoiseReduction()
            buildSharpen()
            buildEffects()
            return
        }
        buildProfile()
        // First among the tone and color controls, as at the top of Lightroom's Basic panel.
        buildWhiteBalance()
        buildLight()
        buildPresence()
        buildColor()
        buildBlackAndWhite()
        buildRedEye()
        buildCurves()
        buildLevels()
        buildDefinition()
        buildSelectiveColor()
        buildNoiseReduction()
        buildSharpen()
        buildVignette()
        buildEffects()
        buildTransform()
        buildCalibration()
    }

    /// The Profile pop-up (PixelLoupe's own looks) and its Amount.
    private func buildProfile() {
        let title = "Profile"
        let section = addSection(
            title, symbol: "camera.filters", keyPath: \.profile, enabled: \.isEnabled, defaultValue: .init(),
            isApplied: { $0.profile.isActive }
        )
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.controlSize = .small
        popUp.setAccessibilityLabel("Profile")
        popUp.setAccessibilityIdentifier("profilePopUp")
        let target = ActionTarget { [weak self] control in
            let kinds = Adjustments.Profile.Kind.allCases
            let index = (control as! NSPopUpButton).indexOfSelectedItem
            guard kinds.indices.contains(index) else { return }
            self?.chooseProfile(kind: kinds[index], adobe: nil)
        }
        popUp.target = target
        popUp.action = #selector(ActionTarget.fire(_:))
        actionTargets.append(target)
        profilePopUp = popUp
        section.addControl(popUp)
        refreshers.append { [weak self] in self?.rebuildProfileMenu() }
        addSlider(to: section, title, "Amount", keyPath: \.profile, enabled: \.isEnabled, range: 0...2, defaultValue: 1,
                  format: { String(format: "%.0f", $0 * 100) },
                  get: { $0.profile.amount }, set: { $0.profile.amount = $1 })
        NotificationCenter.default.addObserver(
            self, selector: #selector(profilesDidChange(_:)), name: AdobeProfileLibrary.didChangeNotification, object: nil
        )
    }

    private weak var profilePopUp: NSPopUpButton?
    private var profileTargets: [ActionTarget] = []
    /// Where Adobe profiles come from (tests use their own).
    var profiles: AdobeProfileLibrary = .shared
    /// The photo's camera: camera-matching profiles are listed for it only.
    var cameraModel: String? { didSet { if cameraModel != oldValue { rebuildProfileMenu() } } }

    @objc private func profilesDidChange(_ notification: Notification) {
        rebuildProfileMenu()
    }

    /// PixelLoupe's own looks first (always at the same places), then the imported Adobe profiles by
    /// group, and the current Adobe profile shown selected at the end.
    private func rebuildProfileMenu() {
        guard let popUp = profilePopUp else { return }
        let profile = adjustments.profile
        let menu = NSMenu()
        menu.delegate = profilePreview
        for kind in Adjustments.Profile.Kind.allCases {
            menu.addItem(withTitle: kind.title, action: nil, keyEquivalent: "").representedObject = ProfileChoice(kind: kind, adobe: nil)
        }
        profileTargets = []
        let entries = profiles.allEntries.filter { $0.cameraModel.isEmpty || AdobeProfile.normalized($0.cameraModel) == cameraModel.map(AdobeProfile.normalized) }
        if !entries.isEmpty {
            menu.addItem(.separator())
            let groups = Dictionary(grouping: entries) { $0.cameraModel.isEmpty ? $0.group : "Camera Matching" }
            for group in groups.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
                let item = NSMenuItem(title: group, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: group)
                submenu.delegate = profilePreview
                for entry in groups[group] ?? [] {
                    let choice = NSMenuItem(title: entry.name, action: #selector(ActionTarget.fire(_:)), keyEquivalent: "")
                    choice.representedObject = ProfileChoice(kind: .standard, adobe: entry)
                    let target = ActionTarget { [weak self] _ in self?.chooseProfile(kind: .standard, adobe: entry) }
                    choice.target = target
                    choice.state = entry.id == profile.adobeID ? .on : .off
                    profileTargets.append(target)
                    submenu.addItem(choice)
                }
                item.submenu = submenu
                menu.addItem(item)
            }
        }
        var selected = Adjustments.Profile.Kind.allCases.firstIndex(of: profile.kind) ?? 0
        if let id = profile.adobeID {
            menu.addItem(.separator())
            menu.addItem(withTitle: profiles.entry(id: id)?.name ?? profile.importedName ?? "Adobe Profile", action: nil, keyEquivalent: "")
            selected = menu.items.count - 1
        }
        popUp.menu = menu
        popUp.selectItem(at: selected)
        popUp.toolTip = profile.adobeID != nil
            ? "Adobe profile, rendered from its own tables"
            : profile.importedName.map { "Imported from Lightroom as “\($0)”" } ?? "PixelLoupe’s own looks; they approximate Adobe’s profiles"
    }

    /// A choice in the Profile menu.
    final class ProfileChoice: NSObject {
        let kind: Adjustments.Profile.Kind
        let adobe: AdobeProfileLibrary.Entry?
        init(kind: Adjustments.Profile.Kind, adobe: AdobeProfileLibrary.Entry?) {
            self.kind = kind
            self.adobe = adobe
        }
    }

    /// Previews the highlighted profile as the pointer (or arrow keys) moves through the Profile menu
    /// and its groups, as Lightroom's profile browser does; closing the menu ends the preview.
    final class ProfilePreview: NSObject, NSMenuDelegate {
        weak var panel: AdjustmentsPanelViewController?
        private var openMenus = 0

        func menuWillOpen(_ menu: NSMenu) { openMenus += 1 }

        func menuDidClose(_ menu: NSMenu) {
            openMenus = max(0, openMenus - 1)
            // Moving from a group back to the top menu closes the group only.
            if openMenus == 0 { panel?.previewProfile(nil) }
        }

        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            // A group's own row (its submenu opening) keeps the current preview.
            guard let choice = item?.representedObject as? ProfileChoice else { return }
            panel?.previewProfile(choice)
        }
    }

    private lazy var profilePreview: ProfilePreview = {
        let preview = ProfilePreview()
        preview.panel = self
        return preview
    }()

    /// Shows `choice` on the photo without applying it (`nil` ends the preview).
    func previewProfile(_ choice: ProfileChoice?) {
        guard let choice else {
            onPreview?(nil)
            return
        }
        onPreview?(withProfile(kind: choice.kind, adobe: choice.adobe, in: adjustments))
    }

    /// A PixelLoupe look (`adobe` nil) or an imported Adobe profile. A B&W profile makes the photo black
    /// and white; leaving one for a color profile turns black and white off again, as in Lightroom.
    private func chooseProfile(kind: Adjustments.Profile.Kind, adobe: AdobeProfileLibrary.Entry?) {
        onPreview?(nil)
        let chosen = withProfile(kind: kind, adobe: adobe, in: adjustments)
        change("Profile", isFinal: true) { $0 = chosen }
        refresh()
    }

    private func withProfile(kind: Adjustments.Profile.Kind, adobe: AdobeProfileLibrary.Entry?, in current: Adjustments) -> Adjustments {
        let wasMonochrome = current.profile.adobeID.flatMap { profiles.entry(id: $0) }?.isMonochrome ?? false
        var adjustments = current
        adjustments.profile.kind = kind
        adjustments.profile.adobeID = adobe?.id
        adjustments.profile.importedName = adobe?.name
        adjustments.profile.isEnabled = true
        if adobe?.isMonochrome == true {
            adjustments.blackAndWhite.isEnabled = true
            adjustments.blackAndWhite.intensity = 1
        } else if wasMonochrome {
            adjustments.blackAndWhite.isEnabled = false
        }
        return adjustments
    }

    private func buildLight() {
        let title = "Light"
        let section = addSection(
            title, symbol: "sun.max", keyPath: \.light, enabled: \.isEnabled, defaultValue: .init(),
            isApplied: { $0.light.isActive }, hasAuto: true, expanded: true
        )
        section.onAuto = { [weak self] in self?.applyAutoLight() }
        let sliders: [(String, ClosedRange<Double>, WritableKeyPath<Adjustments.Light, Double>)] = [
            ("Exposure", -5...5, \.exposure),
            ("Brilliance", -1...1, \.brilliance),
            ("Highlights", -1...1, \.highlights),
            ("Shadows", -1...1, \.shadows),
            ("Whites", -1...1, \.whites),
            ("Brightness", -1...1, \.brightness),
            ("Contrast", -1...1, \.contrast),
            ("Black Point", -1...1, \.blackPoint),
        ]
        for (name, range, valuePath) in sliders {
            addSlider(
                to: section, title, name, keyPath: \.light, enabled: \.isEnabled, range: range,
                get: { $0.light[keyPath: valuePath] }, set: { $0.light[keyPath: valuePath] = $1 }
            )
        }
    }

    /// Color Grading, as in Lightroom: a picker at the top shows the three tonal wheels together (All) or one wheel
    /// large with its sliders, with a dot under each wheel that's set. The picked tab is shared app-wide.
    private func buildColor() {
        let title = "Color Grading"
        let section = addSection(
            title, symbol: "circle.hexagongrid.circle", keyPath: \.color, enabled: \.isEnabled, defaultValue: .init(),
            isApplied: { $0.color.isActive }, expanded: true
        )
        let tabs = ColorGradingTab.allCases
        let picker = NSSegmentedControl(images: tabs.map(\.image), trackingMode: .selectOne, target: nil, action: nil)
        picker.segmentDistribution = .fillEqually
        for tab in tabs {
            picker.setWidth(32, forSegment: tab.rawValue)
            picker.setToolTip(tab.title, forSegment: tab.rawValue)
        }
        picker.setAccessibilityLabel("Color Grading wheels")
        picker.setAccessibilityIdentifier("\(scopeName)colorGradingTab")
        let dots = SegmentDotsView()
        dots.setAccessibilityElement(false)
        let pickerColumn = NSStackView(views: [picker, dots])
        pickerColumn.orientation = .vertical
        pickerColumn.alignment = .centerX
        pickerColumn.spacing = 2
        dots.widthAnchor.constraint(equalTo: picker.widthAnchor).isActive = true
        section.addControl(pickerColumn)

        // All: Midtones on top, Shadows and Highlights under it.
        let lower = NSStackView(views: [
            colorWheelColumn(.shadows, title: title), colorWheelColumn(.highlights, title: title),
        ])
        lower.distribution = .fillEqually
        let allPage = NSStackView(views: [colorWheelColumn(.midtones, title: title), lower])
        allPage.orientation = .vertical
        allPage.alignment = .centerX
        allPage.spacing = 10
        section.addControl(allPage)
        lower.widthAnchor.constraint(equalTo: allPage.widthAnchor).isActive = true

        var pages: [ColorGradingTab: NSView] = [.all: allPage]
        for tab in tabs {
            guard let wheel = tab.wheel else { continue }
            let page = colorWheelPage(tab, wheel, title: title, section: section)
            section.addControl(page)
            pages[tab] = page
        }

        // Blending and Balance shape the tonal wheels, so they follow All, Shadows, Midtones and Highlights.
        let separator = NSBox()
        separator.boxType = .separator
        section.addControl(separator)
        let blending = addSlider(
            to: section, title, "Blending", keyPath: \.color, enabled: \.isEnabled, range: 0...1, defaultValue: 0.5,
            format: Self.percent, get: { $0.color.blending }, set: { $0.color.blending = $1 }
        )
        let balance = addSlider(
            to: section, title, "Balance", keyPath: \.color, enabled: \.isEnabled, range: -1...1,
            format: Self.signedPercent, get: { $0.color.balance }, set: { $0.color.balance = $1 }
        )

        var shown: ColorGradingTab?
        let show = { [weak self, weak picker, weak separator, weak blending, weak balance] in
            let current = ColorGradingTab.current
            picker?.selectedSegment = current.rawValue
            for (tab, page) in pages { page.isHidden = tab != current }
            for view in [separator, blending, balance] as [NSView?] { view?.isHidden = !current.showsBlending }
            // Between tonal tabs the wheels slide over, from where the new tab's wheel was peeking in.
            defer { shown = current }
            guard let previous = shown, previous != current, let from = previous.carouselIndex, let to = current.carouselIndex,
                  let carousel = self?.colorCarousels[current]
            else { return }
            carousel.scrollPosition = CGFloat(from)
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                carousel.scrollPosition = CGFloat(to)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = ColorWheelCarouselView.slideDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    carousel.animator().scrollPosition = CGFloat(to)
                }
            }
        }
        let pickerTarget = ActionTarget { control in
            guard let tab = ColorGradingTab(rawValue: (control as! NSSegmentedControl).selectedSegment) else { return }
            ColorGradingTab.current = tab
            show()
        }
        picker.target = pickerTarget
        picker.action = #selector(ActionTarget.fire(_:))
        actionTargets.append(pickerTarget)
        showColorGradingTab = show
        refreshers.append(show)
        NotificationCenter.default.addObserver(
            self, selector: #selector(colorGradingTabDidChange(_:)), name: ColorGradingTab.didChangeNotification, object: nil
        )
        sectionStates.append { [weak self, weak dots] in
            guard let self else { return }
            dots?.marked = tabs.map { $0.isMarked(in: adjustments.color) }
        }
    }

    /// Another panel (the photo's or a mask's) picked a Color Grading tab.
    @objc private func colorGradingTabDidChange(_ notification: Notification) {
        showColorGradingTab?()
    }

    /// One wheel large, with its name above and its Hue, Saturation and Luminance below in Lightroom's units.
    private func colorWheelPage(
        _ tab: ColorGradingTab, _ wheelPath: WritableKeyPath<Adjustments.ColorGrading, Adjustments.ColorWheel>,
        title: String, section: AdjustmentSectionView
    ) -> NSView {
        let label = NSTextField(labelWithString: tab.title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        let wheel = colorWheel(tab.title, wheelPath, title: title)
        wheel.setAccessibilityIdentifier("colorWheel.\(scopeName)\(tab.title).single")

        func row(
            _ name: String, range: ClosedRange<Double>, format: @escaping (Double) -> String, trackColors: [NSColor],
            _ valuePath: WritableKeyPath<Adjustments.ColorWheel, Double>
        ) -> SliderRow {
            let row = addSlider(
                to: section, title, name, keyPath: \.color, enabled: \.isEnabled, range: range, format: format,
                trackColors: trackColors, placed: false,
                get: { $0.color[keyPath: wheelPath][keyPath: valuePath] },
                set: { $0.color[keyPath: wheelPath][keyPath: valuePath] = $1 }
            )
            row.setAccessibilityIdentifier("slider.\(scopeName)\(title).\(tab.title).\(name)")
            row.slider.setAccessibilityIdentifier("slider.\(scopeName)\(title).\(tab.title).\(name)")
            row.slider.setAccessibilityLabel("\(tab.title) \(name.lowercased())")
            return row
        }
        let hue = row("Hue", range: 0...1, format: Self.degrees, trackColors: Self.hueColors, \.hue)
        let saturation = row("Saturation", range: 0...1, format: Self.percent, trackColors: [.gray, .gray], \.amount)
        let luminance = row("Luminance", range: -1...1, format: Self.signedPercent, trackColors: [.black, .white], \.luminance)

        // The wheel and the sliders edit the same values, so each follows the other as it changes.
        sectionStates.append { [weak self, weak wheel, weak hue, weak saturation, weak luminance] in
            guard let self else { return }
            let value = adjustments.color[keyPath: wheelPath]
            wheel?.hue = value.hue
            wheel?.amount = value.amount
            hue?.value = value.hue
            saturation?.value = value.amount
            luminance?.value = value.luminance
            if let slider = saturation?.slider, let cell = slider.cell as? GradientSliderCell {
                let full = Self.wheelColor(hue: value.hue)
                if cell.colors.last != full {
                    cell.colors = [.gray, full]
                    slider.needsDisplay = true
                }
            }
        }

        // The eye sits at the wheel's lower right.
        let eye = eyeButton(tab)
        let wheelArea: NSView
        if let index = tab.carouselIndex {
            // A tonal wheel: its neighbours peek in at the edges, and clicking one shows its tab.
            let wheels = ColorGradingTab.carousel.map { other -> ColorWheelView in
                guard other != tab, let otherPath = other.wheel else { return wheel }
                let peek = ColorWheelView()
                peek.setAccessibilityLabel("Show \(other.title)")
                peek.setAccessibilityIdentifier("colorWheelPeek.\(scopeName)\(tab.title).\(other.title)")
                peek.toolTip = other.title
                sectionStates.append { [weak self, weak peek] in
                    guard let self else { return }
                    peek?.hue = adjustments.color[keyPath: otherPath].hue
                    peek?.amount = adjustments.color[keyPath: otherPath].amount
                }
                return peek
            }
            let carousel = ColorWheelCarouselView(wheels: wheels, index: index, accessory: eye)
            carousel.onSelect = { [weak self] index in
                ColorGradingTab.current = ColorGradingTab.carousel[index]
                self?.showColorGradingTab?()
            }
            colorCarousels[tab] = carousel
            wheelArea = carousel
        } else {
            // Global, on its own; an empty space left of the wheel balances the eye so the wheel stays centered.
            let balance = NSView()
            let wheelRow = NSStackView(views: [balance, wheel, eye])
            wheelRow.alignment = .bottom
            wheelRow.spacing = 4
            balance.widthAnchor.constraint(equalTo: eye.widthAnchor).isActive = true
            wheelArea = wheelRow
        }

        let page = NSStackView(views: [label, wheelArea, hue, saturation, luminance])
        page.orientation = .vertical
        page.alignment = .centerX
        page.spacing = 8
        page.setCustomSpacing(12, after: wheelArea)
        if wheelArea is ColorWheelCarouselView {
            wheelArea.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true
            wheelArea.heightAnchor.constraint(equalTo: page.widthAnchor, multiplier: 0.62).isActive = true
        } else {
            wheel.widthAnchor.constraint(equalTo: page.widthAnchor, multiplier: 0.62).isActive = true
            wheel.heightAnchor.constraint(equalTo: wheel.widthAnchor).isActive = true
        }
        for row in [hue, saturation, luminance] { row.widthAnchor.constraint(equalTo: page.widthAnchor).isActive = true }
        return page
    }

    /// A color wheel that tints `wheelPath`.
    private func colorWheel(
        _ name: String, _ wheelPath: WritableKeyPath<Adjustments.ColorGrading, Adjustments.ColorWheel>, title: String
    ) -> ColorWheelView {
        let wheel = ColorWheelView()
        wheel.setAccessibilityLabel("\(name) color")
        wheel.onChange = { [weak self] hue, amount, isFinal in
            self?.change(title, isFinal: isFinal) {
                $0.color[keyPath: wheelPath].hue = hue
                $0.color[keyPath: wheelPath].amount = amount
                $0.color.isEnabled = true
            }
        }
        return wheel
    }

    /// The full-strength color at `hue` (0…1), as the wheel draws its rim.
    nonisolated static func wheelColor(hue: Double) -> NSColor {
        let (r, g, b) = ColorLUT.Transform.hsvToRGB(h: hue * 360, s: 0.85, v: 0.9)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// The Hue slider's track: around the wheel from red back to red.
    static let hueColors: [NSColor] = stride(from: 0.0, through: 1, by: 1.0 / 6).map { wheelColor(hue: $0) }

    /// One color wheel with its name above and its luminance slider and eye below (the All tab). While the pointer is
    /// over the wheel, the name gives way to its values, as in Lightroom.
    private func colorWheelColumn(_ tab: ColorGradingTab, title: String) -> NSView {
        let name = tab.title
        guard let wheelPath = tab.wheel else { preconditionFailure("All has no wheel of its own") }
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        let wheel = colorWheel(name, wheelPath, title: title)
        wheel.setAccessibilityIdentifier("colorWheel.\(scopeName)\(name)")
        let luminance = AdjustmentSlider(value: 0, minValue: -1, maxValue: 1)
        luminance.controlSize = .mini
        luminance.isContinuous = true
        luminance.setAccessibilityLabel("\(name) luminance")
        luminance.toolTip = "\(name) luminance"
        let target = ActionTarget { [weak self] slider in
            self?.change(title, isFinal: isFinalControlEvent()) {
                $0.color[keyPath: wheelPath].luminance = (slider as! NSSlider).doubleValue
                $0.color.isEnabled = true
            }
        }
        luminance.target = target
        luminance.action = #selector(ActionTarget.fire(_:))
        actionTargets.append(target)

        let showLabel = { [weak self, weak wheel, weak label] in
            guard let self, let wheel else { return }
            label?.stringValue = wheel.isHighlighted ? ColorGradingTab.readout(adjustments.color[keyPath: wheelPath]) : name
        }
        wheel.onHighlight = { _ in showLabel() }

        // Follows edits made on the wheel's own tab too.
        sectionStates.append { [weak self, weak wheel, weak luminance] in
            guard let self else { return }
            let value = adjustments.color[keyPath: wheelPath]
            wheel?.hue = value.hue
            wheel?.amount = value.amount
            luminance?.doubleValue = value.luminance
            showLabel()
        }
        let lower = NSStackView(views: [luminance, eyeButton(tab)])
        lower.spacing = 2
        let column = NSStackView(views: [label, wheel, lower])
        column.orientation = .vertical
        column.spacing = 4
        wheel.widthAnchor.constraint(equalToConstant: 96).isActive = true
        wheel.heightAnchor.constraint(equalTo: wheel.widthAnchor).isActive = true
        lower.widthAnchor.constraint(equalTo: wheel.widthAnchor).isActive = true
        return column
    }

    // MARK: Muted wheels

    /// Shows or hides one wheel's effect in the preview: a before and after for that wheel, never saved or undone.
    private func eyeButton(_ tab: ColorGradingTab) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.setButtonType(.toggle)
        button.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        button.alternateImage = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Preview without \(tab.title)"
        button.setAccessibilityLabel("Hide \(tab.title) in preview")
        button.setAccessibilityIdentifier("colorGradingEye.\(scopeName)\(tab.title)")
        button.setContentHuggingPriority(.required, for: .horizontal)
        let target = ActionTarget { [weak self] control in
            guard let self else { return }
            if (control as! NSButton).state == .on { mutedWheels.insert(tab) } else { mutedWheels.remove(tab) }
            showMutedWheels()
            onMuteWheels?(mutedWheels)
        }
        button.target = target
        button.action = #selector(ActionTarget.fire(_:))
        actionTargets.append(target)
        eyeButtons.append((tab, button))
        return button
    }

    private func showMutedWheels() {
        for (tab, button) in eyeButtons {
            button.state = mutedWheels.contains(tab) ? .on : .off
            button.contentTintColor = mutedWheels.contains(tab) ? .controlAccentColor : .secondaryLabelColor
        }
    }

    /// Shows every wheel again, without telling `onMuteWheels` (the owner is starting afresh, on another photo).
    func clearMutedWheels() {
        guard !mutedWheels.isEmpty else { return }
        mutedWheels = []
        showMutedWheels()
    }

    private func buildBlackAndWhite() {
        let title = "Black & White"
        let section = addSection(
            title, symbol: "circle.lefthalf.filled", keyPath: \.blackAndWhite, enabled: \.isEnabled,
            defaultValue: .init(), isApplied: { $0.blackAndWhite.isActive }, hasAuto: true
        )
        section.onAuto = { [weak self] in
            self?.change(title, isFinal: true) { $0.blackAndWhite = .init(isEnabled: true, tone: 0.2) }
            self?.refresh()
        }
        addSlider(to: section, title, "Intensity", keyPath: \.blackAndWhite, enabled: \.isEnabled, range: 0...1,
                  defaultValue: 1, format: SliderRow.unsigned,
                  get: { $0.blackAndWhite.intensity }, set: { $0.blackAndWhite.intensity = $1 })
        addSlider(to: section, title, "Neutrals", keyPath: \.blackAndWhite, enabled: \.isEnabled, range: -1...1,
                  get: { $0.blackAndWhite.neutrals }, set: { $0.blackAndWhite.neutrals = $1 })
        addSlider(to: section, title, "Tone", keyPath: \.blackAndWhite, enabled: \.isEnabled, range: -1...1,
                  get: { $0.blackAndWhite.tone }, set: { $0.blackAndWhite.tone = $1 })
        // The mix: how bright each color comes out. Replaces the color mixer while black and white is on.
        let mixTitle = NSTextField(labelWithString: "Mix")
        mixTitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        mixTitle.textColor = .secondaryLabelColor
        section.addControl(mixTitle)
        for range in Adjustments.SelectiveColorRange.allCases {
            addSlider(
                to: section, title, range.title, keyPath: \.blackAndWhite, enabled: \.isEnabled, range: -1...1,
                get: { $0.blackAndWhite[range] }, set: { $0.blackAndWhite[range] = $1 }
            )
        }
    }

    private func buildRedEye() {
        let title = "Red-Eye"
        let section = addSection(
            title, symbol: "eye.slash", keyPath: \.redEye, enabled: \.isEnabled, defaultValue: .init(),
            isApplied: { $0.redEye.isActive }
        )
        let checkbox = NSButton(checkboxWithTitle: "Automatically fix red-eye", target: nil, action: nil)
        checkbox.setAccessibilityIdentifier("redEyeCheckbox")
        let target = ActionTarget { [weak self] button in
            self?.change(title, isFinal: true) { $0.redEye.isEnabled = (button as! NSButton).state == .on }
        }
        checkbox.target = target
        checkbox.action = #selector(ActionTarget.fire(_:))
        actionTargets.append(target)
        refreshers.append { [weak self, weak checkbox] in
            guard let self else { return }
            checkbox?.state = adjustments.redEye.isEnabled ? .on : .off
        }
        sectionStates.append { [weak self, weak checkbox] in
            guard let self else { return }
            checkbox?.state = adjustments.redEye.isEnabled ? .on : .off
        }
        let note = NSTextField(wrappingLabelWithString: "Detects faces and removes red-eye from flash photos.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        section.addControl(checkbox)
        section.addControl(note)
    }

    /// Texture, Clarity, Dehaze, Vibrance and Saturation: Lightroom's Presence group.
    private func buildPresence() {
        let title = "Presence"
        let section = addSection(
            title, symbol: "circle.lefthalf.filled.righthalf.striped.horizontal", keyPath: \.presence, enabled: \.isEnabled,
            defaultValue: .init(), isApplied: { $0.presence.isActive }
        )
        let sliders: [(String, WritableKeyPath<Adjustments.Presence, Double>)] = [
            ("Texture", \.texture), ("Clarity", \.clarity), ("Dehaze", \.dehaze),
            ("Vibrance", \.vibrance), ("Saturation", \.saturation),
        ]
        for (name, valuePath) in sliders {
            addSlider(
                to: section, title, name, keyPath: \.presence, enabled: \.isEnabled, range: -1...1,
                get: { $0.presence[keyPath: valuePath] }, set: { $0.presence[keyPath: valuePath] = $1 }
            )
        }
    }

    private func buildWhiteBalance() {
        let title = "White Balance"
        let section = addSection(
            title, symbol: "thermometer.medium", keyPath: \.whiteBalance, enabled: \.isEnabled, defaultValue: .init(),
            isApplied: { $0.whiteBalance.isActive }, expanded: true
        )
        addWhiteBalancePicker(to: section)
        temperatureRow = addSlider(
            to: section, title, "Temp", keyPath: \.whiteBalance, enabled: \.isEnabled,
            range: WhiteBalanceEstimator.temperatureRange, defaultValue: 6500, format: Self.temperatureText,
            scale: .logarithmic(WhiteBalanceEstimator.temperatureRange), trackColors: Self.temperatureColors,
            get: { [weak self] in $0.whiteBalance.temperature ?? self?.asShotWhiteBalance.temperature ?? 6500 },
            set: { [weak self] adjustments, value in
                let asShot = self?.asShotWhiteBalance.temperature ?? 6500
                adjustments.whiteBalance.temperature = abs(value - asShot) < 1 ? nil : value.rounded()
                adjustments.whiteBalance.preset = nil
            }
        )
        tintRow = addSlider(
            to: section, title, "Tint", keyPath: \.whiteBalance, enabled: \.isEnabled, range: WhiteBalanceEstimator.tintRange,
            format: Self.tintText, trackColors: Self.tintColors,
            get: { [weak self] in $0.whiteBalance.tint ?? self?.asShotWhiteBalance.tint ?? 0 },
            set: { [weak self] adjustments, value in
                let asShot = self?.asShotWhiteBalance.tint ?? 0
                adjustments.whiteBalance.tint = abs(value - asShot) < 0.5 ? nil : value.rounded()
                adjustments.whiteBalance.preset = nil
            }
        )
    }

    /// "6,000", as Lightroom shows the temperature.
    /// A mask's white balance: warmer or cooler and magenta or green than the photo's, -1…1.
    private func buildMaskWhiteBalance() {
        let title = "White Balance"
        let section = addSection(
            title, symbol: "thermometer.medium", keyPath: \.whiteBalance, enabled: \.isEnabled, defaultValue: .init(),
            isApplied: { $0.whiteBalance.isActive }
        )
        addSlider(to: section, title, "Temp", keyPath: \.whiteBalance, enabled: \.isEnabled, range: -1...1,
                  trackColors: Self.temperatureColors,
                  get: { $0.whiteBalance.temperature ?? 0 }, set: { $0.whiteBalance.temperature = $1 == 0 ? nil : $1 })
        addSlider(to: section, title, "Tint", keyPath: \.whiteBalance, enabled: \.isEnabled, range: -1...1,
                  trackColors: Self.tintColors,
                  get: { $0.whiteBalance.tint ?? 0 }, set: { $0.whiteBalance.tint = $1 == 0 ? nil : $1 })
    }

    nonisolated static func temperatureText(_ value: Double) -> String {
        Int(value.rounded()).formatted()
    }

    /// "+22", "−22" or "0".
    nonisolated static func tintText(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded)" : rounded < 0 ? "\u{2212}\(-rounded)" : "0"
    }

    /// The tracks: blue to yellow (cooler to warmer), green to magenta.
    static let temperatureColors: [NSColor] = [
        NSColor(srgbRed: 0.35, green: 0.45, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.85, green: 0.85, blue: 0.8, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.85, blue: 0.25, alpha: 1),
    ]
    static let tintColors: [NSColor] = [
        NSColor(srgbRed: 0.3, green: 0.8, blue: 0.35, alpha: 1), NSColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1),
        NSColor(srgbRed: 0.85, green: 0.3, blue: 0.85, alpha: 1),
    ]

    /// The pop-up's choices: RAW files have the light sources; other files only As Shot, Auto and
    /// Custom, as in Lightroom.
    var whiteBalanceChoices: [String] {
        typealias WB = Adjustments.WhiteBalance
        return [WB.asShotName, WB.autoName] + (isRaw ? WB.presets.map(\.name) : []) + [WB.customName]
    }

    /// The pop-up's title for the photo's white balance: a light source on a non-RAW photo (from a
    /// preset or import) is Custom there.
    var whiteBalanceTitle: String {
        let name = adjustments.whiteBalance.displayName
        return whiteBalanceChoices.contains(name) ? name : Adjustments.WhiteBalance.customName
    }

    private func fillWhiteBalancePopUp() {
        whiteBalancePopUp.removeAllItems()
        whiteBalancePopUp.addItems(withTitles: whiteBalanceChoices)
        whiteBalancePopUp.selectItem(withTitle: whiteBalanceTitle)
    }

    /// The eyedropper (W) at the left, then "WB:" and the pop-up, as in Lightroom.
    private func addWhiteBalancePicker(to section: AdjustmentSectionView) {
        fillWhiteBalancePopUp()
        whiteBalancePopUp.controlSize = .small
        whiteBalancePopUp.setAccessibilityLabel("White balance")
        whiteBalancePopUp.setAccessibilityIdentifier("whiteBalancePreset")
        let target = ActionTarget { [weak self] popUp in
            self?.selectWhiteBalance(named: (popUp as! NSPopUpButton).titleOfSelectedItem ?? "")
        }
        whiteBalancePopUp.target = target
        whiteBalancePopUp.action = #selector(ActionTarget.fire(_:))
        whiteBalancePopUp.menu?.delegate = whiteBalancePreview
        actionTargets.append(target)

        whiteBalanceEyedropper.image = NSImage(systemSymbolName: "eyedropper", accessibilityDescription: "White balance selector")?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        whiteBalanceEyedropper.setButtonType(.pushOnPushOff)
        whiteBalanceEyedropper.isBordered = false
        whiteBalanceEyedropper.bezelStyle = .toolbar
        whiteBalanceEyedropper.imagePosition = .imageOnly
        whiteBalanceEyedropper.toolTip = "White Balance Selector (W): click something that should be neutral"
        whiteBalanceEyedropper.setAccessibilityLabel("White balance selector")
        whiteBalanceEyedropper.setAccessibilityIdentifier("whiteBalanceEyedropper")
        let pickTarget = ActionTarget { [weak self] button in
            guard let self else { return }
            let on = (button as! NSButton).state == .on
            whiteBalanceEyedropper.contentTintColor = on ? Accent.color : nil
            onPickWhiteBalance?(on)
        }
        whiteBalanceEyedropper.target = pickTarget
        whiteBalanceEyedropper.action = #selector(ActionTarget.fire(_:))
        actionTargets.append(pickTarget)

        let label = NSTextField(labelWithString: "WB:")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [whiteBalanceEyedropper, spacer, label, whiteBalancePopUp])
        row.spacing = 6
        section.addControl(row)
        refreshers.append { [weak self] in
            guard let self else { return }
            whiteBalancePopUp.selectItem(withTitle: whiteBalanceTitle)
        }
    }

    private func selectWhiteBalance(named name: String) {
        onPreview?(nil)
        guard isEditingEnabled else { return refresh() }
        defer { menuAutoWhiteBalance = nil }
        guard let whiteBalance = whiteBalance(named: name) else {
            if name == Adjustments.WhiteBalance.autoName { NSSound.beep() }
            return refresh()
        }
        change("White Balance", isFinal: true) { $0.whiteBalance = whiteBalance }
        refresh()
    }

    /// Auto's estimate, taken when the pop-up opens: it measures the photo on screen, which shows
    /// whichever white balance is being previewed once the pointer moves.
    private var menuAutoWhiteBalance: (temperature: Double, tint: Double)??

    /// The white balance a choice in the pop-up gives the photo; `nil` when Auto can't be worked out.
    private func whiteBalance(named name: String) -> Adjustments.WhiteBalance? {
        typealias WB = Adjustments.WhiteBalance
        var whiteBalance = adjustments.whiteBalance
        switch name {
        case WB.asShotName:
            return .init(isEnabled: whiteBalance.isEnabled)
        case WB.autoName:
            guard let estimate = menuAutoWhiteBalance ?? autoWhiteBalance?() else { return nil }
            return .init(isEnabled: true, temperature: estimate.temperature, tint: estimate.tint, preset: WB.autoName)
        case WB.customName:
            // Keeps the values; just no longer a preset.
            if whiteBalance.isActive { whiteBalance.preset = nil }
            return whiteBalance
        default:
            guard let preset = WB.presets.first(where: { $0.name == name }) else { return nil }
            return .init(isEnabled: true, temperature: preset.temperature, tint: preset.tint, preset: preset.name)
        }
    }

    /// Previews the highlighted white balance as the pointer (or arrow keys) moves through the pop-up,
    /// as the Profile menu does; closing the menu ends the preview.
    final class WhiteBalancePreview: NSObject, NSMenuDelegate {
        weak var panel: AdjustmentsPanelViewController?

        func menuWillOpen(_ menu: NSMenu) { panel?.menuAutoWhiteBalance = panel?.autoWhiteBalance?() }

        func menuDidClose(_ menu: NSMenu) { panel?.previewWhiteBalance(named: nil) }

        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            guard let item else { return }
            panel?.previewWhiteBalance(named: item.title)
        }
    }

    private lazy var whiteBalancePreview: WhiteBalancePreview = {
        let preview = WhiteBalancePreview()
        preview.panel = self
        return preview
    }()

    /// Shows the white balance named `name` on the photo without applying it (`nil` ends the preview).
    func previewWhiteBalance(named name: String?) {
        guard let name, let whiteBalance = whiteBalance(named: name) else {
            onPreview?(nil)
            return
        }
        var previewed = adjustments
        previewed.whiteBalance = whiteBalance
        onPreview?(previewed)
    }

    /// Sets the white balance to a temperature and tint, as one undoable edit.
    func applyWhiteBalance(temperature: Double, tint: Double, preset: String?) {
        guard isEditingEnabled else { return }
        change("White Balance", isFinal: true) {
            $0.whiteBalance = .init(isEnabled: true, temperature: temperature, tint: tint, preset: preset)
        }
        refresh()
    }

    /// Switches the eyedropper off (after a pick, or when leaving the panel).
    func endWhiteBalancePicking() {
        whiteBalanceEyedropper.state = .off
        whiteBalanceEyedropper.contentTintColor = nil
    }

    /// W: switches the eyedropper on or off.
    func toggleWhiteBalancePicking() {
        guard isEditingEnabled else { return }
        whiteBalanceEyedropper.state = whiteBalanceEyedropper.state == .on ? .off : .on
        whiteBalanceEyedropper.contentTintColor = whiteBalanceEyedropper.state == .on ? Accent.color : nil
        onPickWhiteBalance?(whiteBalanceEyedropper.state == .on)
    }

    /// The temperature and tint the sliders show: the photo's own when As Shot.
    var currentWhiteBalance: (temperature: Double, tint: Double) {
        (adjustments.whiteBalance.temperature ?? asShotWhiteBalance.temperature, adjustments.whiteBalance.tint ?? asShotWhiteBalance.tint)
    }

    private func buildCurves() {
        let title = "Curves"
        let section = addSection(
            title, symbol: "point.bottomleft.forward.to.point.topright.scurvepath", keyPath: \.curves,
            enabled: \.isEnabled, defaultValue: .init(), isApplied: { $0.curves.isActive }
        )
        // Parametric, then the point curve and its red, green and blue channels (as Lightroom orders them).
        let modes: [(title: String, label: String, channel: Adjustments.CurveChannel?)] = [
            ("Parametric", "Parametric curve", nil), ("Point", "Point curve", .rgb),
            ("R", "Red curve", .red), ("G", "Green curve", .green), ("B", "Blue curve", .blue),
        ]
        let picker = NSSegmentedControl(labels: modes.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        picker.controlSize = .small
        for (index, mode) in modes.enumerated() { picker.setToolTip(mode.label, forSegment: index) }
        picker.selectedSegment = 1
        picker.setAccessibilityIdentifier("curveChannel")
        let editor = CurveEditorView()
        editor.setAccessibilityIdentifier("curveEditor")

        // The four region sliders, shown with the parametric curve.
        let regions: [(String, WritableKeyPath<ParametricCurve, Double>)] = [
            ("Highlights", \.highlights), ("Lights", \.lights), ("Darks", \.darks), ("Shadows", \.shadows),
        ]
        var regionRows: [SliderRow] = []
        for (name, valuePath) in regions {
            let row = addSlider(
                to: section, title, name, keyPath: \.curves, enabled: \.isEnabled, range: -1...1,
                get: { $0.curves.parametric[keyPath: valuePath] }, set: { $0.curves.parametric[keyPath: valuePath] = $1 }
            )
            row.setAccessibilityIdentifier("slider.Curves.\(name)")
            regionRows.append(row)
        }

        let showMode = { [weak self, weak editor] in
            guard let self, let editor else { return }
            editor.isParametric = curveParametric
            editor.channel = curveChannel
            editor.curve = adjustments.curves[curveChannel]
            editor.parametric = adjustments.curves.parametric
            for row in regionRows { row.isHidden = !curveParametric }
            picker.selectedSegment = curveParametric ? 0 : modes.firstIndex { $0.channel == curveChannel } ?? 1
        }
        let target = ActionTarget { [weak self] control in
            guard let self else { return }
            let mode = modes[(control as! NSSegmentedControl).selectedSegment]
            curveParametric = mode.channel == nil
            if let channel = mode.channel { curveChannel = channel }
            showMode()
        }
        picker.target = target
        picker.action = #selector(ActionTarget.fire(_:))
        actionTargets.append(target)

        editor.onChange = { [weak self] curve, isFinal in
            guard let self else { return }
            let channel = curveChannel
            change(title, isFinal: isFinal) {
                $0.curves[channel] = curve
                $0.curves.isEnabled = true
            }
        }
        editor.onParametricChange = { [weak self] parametric, isFinal in
            guard let self else { return }
            change(title, isFinal: isFinal) {
                $0.curves.parametric = parametric
                $0.curves.isEnabled = true
            }
            refresh()
        }
        refreshers.append(showMode)
        // The editor and picker go above the sliders addSlider already put in the section.
        section.insertControl(picker, at: 0)
        section.insertControl(editor, at: 1)
        showMode()
    }

    private func buildLevels() {
        let title = "Levels"
        let section = addSection(
            title, symbol: "chart.bar.xaxis", keyPath: \.levels, enabled: \.isEnabled, defaultValue: .init(),
            isApplied: { $0.levels.isActive }
        )
        let rows: [(String, Double, WritableKeyPath<Adjustments.Levels, Double>)] = [
            ("Input Black", 0, \.inputBlack),
            ("Input White", 1, \.inputWhite),
            ("Output Black", 0, \.outputBlack),
            ("Output White", 1, \.outputWhite),
        ]
        for (name, defaultValue, valuePath) in rows {
            addSlider(
                to: section, title, name, keyPath: \.levels, enabled: \.isEnabled, range: 0...1,
                defaultValue: defaultValue, format: SliderRow.unsigned,
                get: { $0.levels[keyPath: valuePath] }, set: { $0.levels[keyPath: valuePath] = $1 }
            )
        }
        // Midtones slider: -1…1 maps to gamma ¼…4.
        let midtones = addSlider(
            to: section, title, "Midtones", keyPath: \.levels, enabled: \.isEnabled, range: -1...1,
            get: { log($0.levels.gamma) / log(4) },
            set: { $0.levels.gamma = abs($1) < 0.005 ? 1 : pow(4, $1) }
        )
        section.contentStack.removeArrangedSubview(midtones)
        section.contentStack.insertArrangedSubview(midtones, at: 2)
    }

    private func buildDefinition() {
        let title = "Definition"
        let section = addSection(
            title, symbol: "triangle.lefthalf.filled", keyPath: \.definition, enabled: \.isEnabled, defaultValue: .init(),
            isApplied: { $0.definition.isActive }
        )
        addSlider(to: section, title, "Intensity", keyPath: \.definition, enabled: \.isEnabled, range: 0...1,
                  format: SliderRow.unsigned,
                  get: { $0.definition.intensity }, set: { $0.definition.intensity = $1 })
    }

    /// The Color Mixer: Hue, Saturation and Luminance tabs with a slider per color, or All, which
    /// picks a color and shows its three sliders together.
    private func buildSelectiveColor() {
        let title = "Color Mixer"
        let section = addSection(
            title, symbol: "paintpalette", keyPath: \.selectiveColor, enabled: \.isEnabled, defaultValue: .init(),
            isApplied: { $0.selectiveColor.isActive }
        )
        mixerSection = section
        let ranges = Adjustments.SelectiveColorRange.allCases
        let attributes: [(name: String, path: WritableKeyPath<Adjustments.SelectiveColorAdjustment, Double>)] = [
            ("Hue", \.hue), ("Saturation", \.saturation), ("Luminance", \.luminance),
        ]

        let tabs = NSSegmentedControl(
            labels: attributes.map(\.name) + ["All"], trackingMode: .selectOne, target: nil, action: nil)
        tabs.controlSize = .small
        tabs.selectedSegment = mixerTab
        tabs.setAccessibilityIdentifier("colorMixerTab")
        section.addControl(tabs)

        // All: swatches to pick a color, then that color's three sliders.
        var swatches: [SwatchButton] = []
        for range in ranges {
            let (r, g, b) = ColorLUT.Transform.hsvToRGB(h: range.hue, s: 0.85, v: 0.95)
            let swatch = SwatchButton(color: NSColor(srgbRed: r, green: g, blue: b, alpha: 1))
            swatch.setAccessibilityLabel(range.title)
            swatch.setAccessibilityIdentifier("swatch.\(range.title)")
            swatch.toolTip = range.title
            swatches.append(swatch)
        }
        let swatchRow = NSStackView(views: swatches)
        swatchRow.distribution = .equalSpacing
        section.addControl(swatchRow)

        var allRows: [SliderRow] = []
        for (name, valuePath) in attributes.map({ ($0.name, $0.path) }) {
            allRows.append(addSlider(
                to: section, title, name, keyPath: \.selectiveColor, enabled: \.isEnabled, range: -1...1,
                get: { [weak self] in $0.selectiveColor[self?.selectedSelectiveColor ?? .red][keyPath: valuePath] },
                set: { [weak self] adjustments, value in
                    adjustments.selectiveColor[self?.selectedSelectiveColor ?? .red][keyPath: valuePath] = value
                }
            ))
        }

        // Hue, Saturation, Luminance: all eight colors at once.
        var tabRows: [[SliderRow]] = []
        for attribute in attributes {
            var rows: [SliderRow] = []
            for range in ranges {
                let row = addSlider(
                    to: section, title, range.title, keyPath: \.selectiveColor, enabled: \.isEnabled, range: -1...1,
                    get: { $0.selectiveColor[range][keyPath: attribute.path] },
                    set: { $0.selectiveColor[range][keyPath: attribute.path] = $1 }
                )
                row.setAccessibilityIdentifier("slider.\(title).\(attribute.name).\(range.title)")
                row.slider.setAccessibilityIdentifier("slider.\(title).\(attribute.name).\(range.title)")
                rows.append(row)
            }
            tabRows.append(rows)
        }

        let showTab = { [weak self, weak tabs] in
            guard let self, let tabs else { return }
            tabs.selectedSegment = mixerTab
            let showsAll = mixerTab == attributes.count
            swatchRow.isHidden = !showsAll
            for row in allRows { row.isHidden = !showsAll }
            for (index, rows) in tabRows.enumerated() { for row in rows { row.isHidden = mixerTab != index } }
        }
        let tabTarget = ActionTarget { [weak self] control in
            self?.mixerTab = (control as! NSSegmentedControl).selectedSegment
            showTab()
        }
        tabs.target = tabTarget
        tabs.action = #selector(ActionTarget.fire(_:))
        actionTargets.append(tabTarget)
        refreshers.append(showTab)

        for (index, swatch) in swatches.enumerated() {
            swatch.onSelect = { [weak self] in
                guard let self else { return }
                selectedSelectiveColor = ranges[index]
                refresh()
            }
        }
        refreshers.append { [weak self] in
            guard let self else { return }
            for (index, swatch) in swatches.enumerated() {
                swatch.isSelected = ranges[index] == selectedSelectiveColor
                swatch.isModified = !adjustments.selectiveColor[ranges[index]].isIdentity
            }
        }
        sectionStates.append { [weak self] in
            guard let self else { return }
            for (index, swatch) in swatches.enumerated() {
                swatch.isModified = !adjustments.selectiveColor[ranges[index]].isIdentity
            }
            // The B&W mix takes the mixer's place while black and white is on.
            mixerSection?.isHidden = adjustments.blackAndWhite.isActive
        }
    }

    /// Slider text on Lightroom's scales: 0…100 or -100…+100.
    nonisolated static func percent(_ value: Double) -> String { String(format: "%.0f", value * 100) }
    /// A hue, 0…1 around the wheel, in degrees as Lightroom shows it.
    nonisolated static func degrees(_ value: Double) -> String { String(format: "%.0f", value * 360) }
    nonisolated static func signedPercent(_ value: Double) -> String {
        let rounded = (value * 100).rounded()
        return rounded == 0 ? "0" : String(format: "%+.0f", rounded)
    }

    private func buildNoiseReduction() {
        let title = "Noise Reduction"
        let section = addSection(
            title, symbol: "circle.dotted.circle", keyPath: \.noiseReduction, enabled: \.isEnabled, defaultValue: .init(),
            isApplied: { $0.noiseReduction.isActive }
        )
        addSlider(to: section, title, "Amount", keyPath: \.noiseReduction, enabled: \.isEnabled, range: 0...1,
                  format: Self.percent,
                  get: { $0.noiseReduction.amount }, set: { $0.noiseReduction.amount = $1 })
        addSlider(to: section, title, "Color", keyPath: \.noiseReduction, enabled: \.isEnabled, range: 0...1,
                  format: Self.percent,
                  get: { $0.noiseReduction.color }, set: { $0.noiseReduction.color = $1 })
        addSlider(to: section, title, "Detail", keyPath: \.noiseReduction, enabled: \.isEnabled, range: 0...1,
                  defaultValue: 0.5, format: Self.percent,
                  get: { $0.noiseReduction.detail }, set: { $0.noiseReduction.detail = $1 })
            .toolTip = "How much fine detail noise reduction keeps (not used on RAW files, whose engine has no such control)"
    }

    private func buildSharpen() {
        let title = "Sharpen"
        let section = addSection(
            title, symbol: "righttriangle.fill", keyPath: \.sharpen, enabled: \.isEnabled, defaultValue: .init(),
            isApplied: { $0.sharpen.isActive }
        )
        addSlider(to: section, title, "Amount", keyPath: \.sharpen, enabled: \.isEnabled, range: 0...1,
                  format: { String(format: "%.0f", $0 * 150) },
                  get: { $0.sharpen.intensity }, set: { $0.sharpen.intensity = $1 })
        addSlider(to: section, title, "Radius", keyPath: \.sharpen, enabled: \.isEnabled,
                  range: Adjustments.Sharpen.radiusRange, defaultValue: 1, format: { String(format: "%.1f", $0) },
                  get: { $0.sharpen.radius }, set: { $0.sharpen.radius = $1 })
        addSlider(to: section, title, "Detail", keyPath: \.sharpen, enabled: \.isEnabled, range: 0...1,
                  defaultValue: 0.25, format: Self.percent,
                  get: { $0.sharpen.detail }, set: { $0.sharpen.detail = $1 })
        let masking = addSlider(
            to: section, title, "Masking", keyPath: \.sharpen, enabled: \.isEnabled, range: 0...1, format: Self.percent,
            get: { $0.sharpen.masking }, set: { $0.sharpen.masking = $1 })
        // The preview shows the photo's own sharpening mask, so not under a mask.
        if scope == .photo { masking.toolTip = "Hold Option while dragging to see the mask: white is sharpened" }
        // Option-drag shows the mask in the preview.
        let change = masking.onChange
        masking.onChange = { [weak self] value, isFinal in
            change?(value, isFinal)
            self?.onSharpenMaskPreview?(!isFinal && NSEvent.modifierFlags.contains(.option))
        }
    }

    private func buildVignette() {
        let title = "Post-Crop Vignette"
        let section = addSection(
            title, symbol: "circle.circle", keyPath: \.vignette, enabled: \.isEnabled, defaultValue: .init(),
            isApplied: { $0.vignette.isActive }
        )
        let styles = Adjustments.Vignette.Style.allCases
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: styles.map(\.title))
        popUp.controlSize = .small
        popUp.setAccessibilityLabel("Vignette style")
        popUp.setAccessibilityIdentifier("vignetteStyle")
        let target = ActionTarget { [weak self] control in
            let style = styles[(control as! NSPopUpButton).indexOfSelectedItem]
            self?.change(title, isFinal: true) {
                $0.vignette.style = style
                $0.vignette.isEnabled = true
            }
        }
        popUp.target = target
        popUp.action = #selector(ActionTarget.fire(_:))
        actionTargets.append(target)
        section.addControl(popUp)
        refreshers.append { [weak self, weak popUp] in
            guard let self else { return }
            popUp?.selectItem(at: styles.firstIndex(of: adjustments.vignette.style) ?? 0)
        }

        addSlider(to: section, title, "Amount", keyPath: \.vignette, enabled: \.isEnabled, range: -1...1,
                  format: Self.signedPercent,
                  get: { -$0.vignette.strength }, set: { $0.vignette.strength = -$1 })
            .toolTip = "Negative darkens, positive lightens"
        addSlider(to: section, title, "Midpoint", keyPath: \.vignette, enabled: \.isEnabled, range: 0...1,
                  defaultValue: 0.5, format: Self.percent,
                  get: { $0.vignette.radius }, set: { $0.vignette.radius = $1 })
        addSlider(to: section, title, "Roundness", keyPath: \.vignette, enabled: \.isEnabled, range: -1...1,
                  format: Self.signedPercent,
                  get: { $0.vignette.roundness }, set: { $0.vignette.roundness = $1 })
        addSlider(to: section, title, "Feather", keyPath: \.vignette, enabled: \.isEnabled, range: 0...1,
                  defaultValue: 0.5, format: Self.percent,
                  get: { $0.vignette.softness }, set: { $0.vignette.softness = $1 })
        addSlider(to: section, title, "Highlights", keyPath: \.vignette, enabled: \.isEnabled, range: 0...1,
                  format: Self.percent,
                  get: { $0.vignette.highlightContrast }, set: { $0.vignette.highlightContrast = $1 })
            .toolTip = "Highlight Priority only: how much bright areas keep their brightness"
    }

    /// Perspective correction: Upright and the manual sliders.
    private func buildTransform() {
        let title = "Transform"
        let section = addSection(
            title, symbol: "perspective", keyPath: \.transform, enabled: \.isEnabled, defaultValue: .init(),
            isApplied: { $0.transform.isActive }
        )
        // Upright. Level works; the rest need analysis PixelLoupe doesn't have yet, and an imported
        // Upright shows here as the mode Lightroom had.
        let modes = Adjustments.Transform.Upright.allCases
        let picker = NSSegmentedControl(labels: modes.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
        picker.controlSize = .small
        picker.setAccessibilityIdentifier("uprightMode")
        for (index, mode) in modes.enumerated() {
            let available = mode == .off || mode == .level
            picker.setEnabled(available, forSegment: index)
            picker.setToolTip(available ? "Upright: \(mode.title)" : "Upright \(mode.title) isn't available yet", forSegment: index)
        }
        let target = ActionTarget { [weak self] control in
            guard let self else { return }
            let mode = modes[(control as! NSSegmentedControl).selectedSegment]
            switch mode {
            case .off:
                change(title, isFinal: true) {
                    $0.transform = .init(isEnabled: $0.transform.isEnabled, constrainCrop: $0.transform.constrainCrop)
                }
                refresh()
            case .level:
                refresh()   // back to the current mode until the measurement comes back
                onUprightLevel?()
            default:
                refresh()
            }
        }
        picker.target = target
        picker.action = #selector(ActionTarget.fire(_:))
        actionTargets.append(target)
        section.addControl(picker)
        refreshers.append { [weak self, weak picker] in
            guard let self else { return }
            picker?.selectedSegment = modes.firstIndex(of: adjustments.transform.upright) ?? 0
        }

        let sliders: [(String, ClosedRange<Double>, Double, WritableKeyPath<Adjustments.Transform, Double>, (Double) -> String)] = [
            ("Vertical", -1...1, 0, \.vertical, Self.signedPercent),
            ("Horizontal", -1...1, 0, \.horizontal, Self.signedPercent),
            ("Rotate", -10...10, 0, \.rotate, { String(format: "%+.1f°", $0) }),
            ("Aspect", -1...1, 0, \.aspect, Self.signedPercent),
            ("Scale", 0.5...1.5, 1, \.scale, { String(format: "%.0f%%", $0 * 100) }),
            ("X Offset", -1...1, 0, \.offsetX, Self.signedPercent),
            ("Y Offset", -1...1, 0, \.offsetY, Self.signedPercent),
        ]
        for (name, range, defaultValue, valuePath, format) in sliders {
            addSlider(
                to: section, title, name, keyPath: \.transform, enabled: \.isEnabled, range: range, defaultValue: defaultValue,
                format: format,
                get: { $0.transform[keyPath: valuePath] },
                set: {
                    $0.transform[keyPath: valuePath] = $1
                    // A hand-made transform is no longer the Upright Lightroom chose.
                    $0.transform.upright = .off
                    $0.transform.uprightMatrix = nil
                }
            )
        }

        let constrain = NSButton(checkboxWithTitle: "Constrain Crop", target: nil, action: nil)
        constrain.setAccessibilityIdentifier("transformConstrainCrop")
        let constrainTarget = ActionTarget { [weak self] button in
            self?.change(title, isFinal: true) { $0.transform.constrainCrop = (button as! NSButton).state == .on }
        }
        constrain.target = constrainTarget
        constrain.action = #selector(ActionTarget.fire(_:))
        actionTargets.append(constrainTarget)
        refreshers.append { [weak self, weak constrain] in
            guard let self else { return }
            constrain?.state = adjustments.transform.constrainCrop ? .on : .off
        }
        section.addControl(constrain)
    }

    /// Camera calibration: primaries' hue and saturation, and the shadow tint.
    private func buildCalibration() {
        let title = "Calibration"
        let section = addSection(
            title, symbol: "slider.horizontal.below.rectangle", keyPath: \.calibration, enabled: \.isEnabled,
            defaultValue: .init(), isApplied: { $0.calibration.isActive }
        )
        let sliders: [(String, WritableKeyPath<Adjustments.Calibration, Double>)] = [
            ("Shadows Tint", \.shadowTint),
            ("Red Hue", \.redHue), ("Red Saturation", \.redSaturation),
            ("Green Hue", \.greenHue), ("Green Saturation", \.greenSaturation),
            ("Blue Hue", \.blueHue), ("Blue Saturation", \.blueSaturation),
        ]
        for (name, valuePath) in sliders {
            addSlider(
                to: section, title, name, keyPath: \.calibration, enabled: \.isEnabled, range: -1...1, format: Self.signedPercent,
                get: { $0.calibration[keyPath: valuePath] }, set: { $0.calibration[keyPath: valuePath] = $1 }
            )
        }
    }

    /// Applies Upright ▸ Level's measured rotation (degrees) as one undoable edit.
    func applyUprightLevel(rotation: Double) {
        guard isEditingEnabled else { return }
        change("Transform", isFinal: true) {
            $0.transform.rotate = (rotation * 10).rounded() / 10
            $0.transform.upright = .level
            $0.transform.isEnabled = true
        }
        refresh()
    }

    /// Grain (and, later, other finishing effects).
    private func buildEffects() {
        let title = "Effects"
        let section = addSection(
            title, symbol: "sparkles", keyPath: \.effects, enabled: \.isEnabled, defaultValue: .init(),
            isApplied: { $0.effects.isActive }
        )
        addSlider(to: section, title, "Grain Amount", keyPath: \.effects, enabled: \.isEnabled, range: 0...1,
                  format: Self.percent,
                  get: { $0.effects.grain },
                  set: { adjustments, value in
                      adjustments.effects.grain = value
                      // The first grain gives the photo its own pattern.
                      if value > 0, adjustments.effects.grainSeed == 0 { adjustments.effects.grainSeed = Int.random(in: 1...1_000_000) }
                  })
        addSlider(to: section, title, "Grain Size", keyPath: \.effects, enabled: \.isEnabled, range: 0...1,
                  defaultValue: 0.25, format: Self.percent,
                  get: { $0.effects.grainSize }, set: { $0.effects.grainSize = $1 })
        addSlider(to: section, title, "Grain Roughness", keyPath: \.effects, enabled: \.isEnabled, range: 0...1,
                  defaultValue: 0.5, format: Self.percent,
                  get: { $0.effects.grainRoughness }, set: { $0.effects.grainRoughness = $1 })
    }
}

/// Routes a control's action to a closure.
final class ActionTarget: NSObject {
    private let handler: (Any) -> Void

    init(_ handler: @escaping (Any) -> Void) {
        self.handler = handler
    }

    /// Not `perform(_:)`: `#selector(ActionTarget.perform(_:))` resolves to `NSObject.perform(_:)`
    /// (`performSelector:`), so the control would call that instead and this would never run.
    @objc func fire(_ sender: Any) {
        handler(sender)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A round color swatch used to pick a Selective Color range. A dot marks ranges with changes.
final class SwatchButton: NSView {
    var isSelected = false { didSet { needsDisplay = true } }
    var isModified = false { didSet { needsDisplay = true } }
    var onSelect: (() -> Void)?
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 4, dy: 4)
        color.setFill()
        NSBezierPath(ovalIn: circle).fill()
        if isSelected {
            Accent.color.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 2
            ring.stroke()
        }
        if isModified {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: CGRect(x: bounds.midX - 2, y: bounds.midY - 2, width: 4, height: 4)).fill()
        }
        setAccessibilityValue(isSelected ? 1 : 0)
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }
}
