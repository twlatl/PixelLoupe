import AppKit

/// The Rim Light panel (RAW-203), from Pixegen's Filter ▸ Rim Light: a switch, Glow, and up to three lights, each with a
/// color, Angle, Strength, Width and Choke. Turning it on with no lights adds one; Add Light puts the next one across
/// from the last.
final class RimLightPanelViewController: NSViewController {
    typealias RimLight = PhotoAdjustments.RimLight

    var onChange: (_ rimLight: RimLight, _ isFinal: Bool, _ actionName: String) -> Void = { _, _, _ in }

    private(set) var rimLight = RimLight()
    var isEditingEnabled = false {
        didSet { if isViewLoaded { update() } }
    }
    /// Whether the photo's subject has been found (Rim Light lights its edges); nil with no photo.
    var subjectStatus: SubjectMatteStore.Status? {
        didSet { if isViewLoaded { updateStatus() } }
    }

    private let enableSwitch = NSSwitch()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var glowRow = SliderRow(title: "Glow", range: 0...1, defaultValue: RimLight().glow, format: Self.percent)
    private let lightsStack = NSStackView()
    private let addButton = NSButton(title: "Add Light", target: nil, action: nil)
    /// The controls for each light, in order.
    private var lightControls: [LightControls] = []

    nonisolated static func percent(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
    nonisolated static func degrees(_ value: Double) -> String { String(format: "%.0f°", value) }

    override func loadView() {
        let title = NSTextField(labelWithString: "Rim Light")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        enableSwitch.controlSize = .small
        enableSwitch.target = self
        enableSwitch.action = #selector(enableChanged(_:))
        enableSwitch.setAccessibilityLabel("Rim Light")
        enableSwitch.setAccessibilityIdentifier("rimLightEnabled")
        let titleRow = NSStackView(views: [title, NSView(), enableSwitch])
        titleRow.distribution = .fill

        let note = NSTextField(wrappingLabelWithString: "Colored lights behind the subject that catch its edges.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityIdentifier("rimLightStatus")

        glowRow.toolTip = "How much of the lights glows in the air around the subject"
        glowRow.slider.setAccessibilityIdentifier("slider.RimLight.Glow")
        glowRow.onChange = { [weak self] value, isFinal in self?.change(isFinal: isFinal, "Glow") { $0.glow = value } }

        lightsStack.orientation = .vertical
        lightsStack.alignment = .leading
        lightsStack.spacing = 14

        addButton.bezelStyle = .push
        addButton.controlSize = .small
        addButton.target = self
        addButton.action = #selector(addLight(_:))
        addButton.setAccessibilityIdentifier("rimLightAdd")

        let stack = NSStackView(views: [titleRow, note, statusLabel, glowRow, lightsStack, addButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 20, right: 14)
        stack.setCustomSpacing(4, after: titleRow)
        for view in [titleRow, note, statusLabel, glowRow, lightsStack] {
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
        scrollView.setAccessibilityIdentifier("rimLightPanel")
        document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true
        document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor).isActive = true
        view = scrollView
        update()
    }

    func display(_ rimLight: RimLight) {
        self.rimLight = rimLight
        if isViewLoaded { update() }
    }

    // MARK: - Showing

    private func update() {
        enableSwitch.state = rimLight.isEnabled ? .on : .off
        enableSwitch.isEnabled = isEditingEnabled
        let editable = isEditingEnabled && rimLight.isEnabled
        glowRow.value = rimLight.glow
        glowRow.slider.isEnabled = editable
        // Rebuilt only when lights come or go, so a control being dragged stays put.
        if lightControls.map(\.id) != rimLight.lights.map(\.id) {
            for controls in lightControls { controls.view.removeFromSuperview() }
            lightControls = rimLight.lights.enumerated().map { index, light in
                let controls = LightControls(light: light, number: index + 1, canRemove: rimLight.lights.count > 1, owner: self)
                lightsStack.addArrangedSubview(controls.view)
                controls.view.widthAnchor.constraint(equalTo: lightsStack.widthAnchor).isActive = true
                return controls
            }
        }
        for (controls, light) in zip(lightControls, rimLight.lights) { controls.show(light, isEnabled: editable) }
        addButton.isEnabled = editable && rimLight.lights.count < RimLight.maximumLights
        addButton.isHidden = rimLight.lights.count >= RimLight.maximumLights
        updateStatus()
    }

    private func updateStatus() {
        let text: String = switch subjectStatus {
        case .finding? where rimLight.isActive: "Finding the subject…"
        case .noSubject? where rimLight.isEnabled: "No subject found in this photo, so there's nothing to light."
        default: ""
        }
        statusLabel.stringValue = text
        statusLabel.isHidden = text.isEmpty
    }

    // MARK: - Editing

    /// Changes the settings and reports them.
    fileprivate func change(isFinal: Bool, _ actionName: String, _ edit: (inout RimLight) -> Void) {
        var changed = rimLight
        edit(&changed)
        guard changed != rimLight || isFinal else { return }
        rimLight = changed
        onChange(changed, isFinal, actionName)
    }

    fileprivate func changeLight(_ id: UUID, isFinal: Bool, _ actionName: String, _ edit: (inout RimLight.Light) -> Void) {
        change(isFinal: isFinal, actionName) { rimLight in
            guard let index = rimLight.lights.firstIndex(where: { $0.id == id }) else { return }
            edit(&rimLight.lights[index])
        }
    }

    @objc private func enableChanged(_ sender: NSSwitch) {
        let on = sender.state == .on
        change(isFinal: true, on ? "Rim Light On" : "Rim Light Off") { rimLight in
            rimLight.isEnabled = on
            if on, rimLight.lights.isEmpty { rimLight.lights = [RimLight.Light()] }
        }
        update()
    }

    @objc private func addLight(_ sender: Any?) {
        guard rimLight.lights.count < RimLight.maximumLights else { return }
        change(isFinal: true, "Add Light") { $0.lights.append($0.nextLight) }
        update()
    }

    fileprivate func removeLight(_ id: UUID) {
        guard rimLight.lights.count > 1 else { return }
        change(isFinal: true, "Remove Light") { $0.lights.removeAll { $0.id == id } }
        update()
    }
}

/// One light's controls: its number, color well and remove button, then Angle, Strength, Width and Choke.
@MainActor
private final class LightControls: NSObject {
    let id: UUID
    let view = NSStackView()
    private let color = NSColorWell(style: .minimal)
    private let rows: [(row: SliderRow, keyPath: WritableKeyPath<PhotoAdjustments.RimLight.Light, Double>)]
    private weak var owner: RimLightPanelViewController?

    init(light: PhotoAdjustments.RimLight.Light, number: Int, canRemove: Bool, owner: RimLightPanelViewController) {
        id = light.id
        self.owner = owner
        let defaults = PhotoAdjustments.RimLight.Light()
        let percent = RimLightPanelViewController.percent
        rows = [
            (SliderRow(title: "Angle", range: -180...180, defaultValue: defaults.angle, format: RimLightPanelViewController.degrees), \.angle),
            (SliderRow(title: "Strength", range: 0...1, defaultValue: defaults.strength, format: percent), \.strength),
            (SliderRow(title: "Width", range: 0...1, defaultValue: defaults.width, format: percent), \.width),
            (SliderRow(title: "Choke", range: 0...1, defaultValue: defaults.choke, format: percent), \.choke),
        ]
        super.init()

        let title = NSTextField(labelWithString: "Light \(number)")
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        color.target = self
        color.action = #selector(colorChanged(_:))
        color.setAccessibilityLabel("Light \(number) color")
        color.setAccessibilityIdentifier("rimLight.\(number).color")
        color.widthAnchor.constraint(equalToConstant: 38).isActive = true
        var header: [NSView] = [title, NSView(), color]
        if canRemove {
            let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove Light \(number)")!,
                                  target: self, action: #selector(removeClicked(_:)))
            remove.isBordered = false
            remove.toolTip = "Remove this light"
            remove.setAccessibilityIdentifier("rimLight.\(number).remove")
            header.append(remove)
        }
        let headerRow = NSStackView(views: header)
        headerRow.distribution = .fill

        let tips = ["Where the light comes from: 90° is from above", "How bright the light is",
                    "How far in from the edges it reaches", "How hard its inner edge is, rather than feathered"]
        for ((row, keyPath), tip) in zip(rows, tips) {
            row.toolTip = tip
            row.slider.setAccessibilityIdentifier("slider.RimLight.\(number).\(row.slider.accessibilityLabel() ?? "")")
            let name = row.slider.accessibilityLabel() ?? ""
            row.onChange = { [weak self] value, isFinal in
                guard let self else { return }
                self.owner?.changeLight(self.id, isFinal: isFinal, name) { $0[keyPath: keyPath] = value }
            }
        }
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 8
        for subview in [headerRow] + rows.map(\.row) {
            view.addArrangedSubview(subview)
            subview.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("Light \(number)")
    }

    func show(_ light: PhotoAdjustments.RimLight.Light, isEnabled: Bool) {
        for (row, keyPath) in rows {
            row.value = light[keyPath: keyPath]
            row.slider.isEnabled = isEnabled
        }
        let shown = NSColor(srgbRed: light.red, green: light.green, blue: light.blue, alpha: 1)
        if color.color != shown { color.color = shown }
        color.isEnabled = isEnabled
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard let srgb = sender.color.usingColorSpace(.sRGB) else { return }
        owner?.changeLight(id, isFinal: isFinalControlEvent(), "Light Color") {
            $0.red = Double(srgb.redComponent).clamped(to: 0...1)
            $0.green = Double(srgb.greenComponent).clamped(to: 0...1)
            $0.blue = Double(srgb.blueComponent).clamped(to: 0...1)
        }
    }

    @objc private func removeClicked(_ sender: Any?) {
        owner?.removeLight(id)
    }
}
