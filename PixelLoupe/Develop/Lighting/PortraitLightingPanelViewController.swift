import AppKit

/// The Portrait Lighting section of the Lighting panel (RAW-214): a switch, the effect, and its Intensity. The effect
/// applies only while the switch is on; turning it off keeps the effect and Intensity.
final class PortraitLightingPanelViewController: NSViewController {
    typealias PortraitLighting = PhotoAdjustments.PortraitLighting

    var onChange: (_ portraitLighting: PortraitLighting, _ isFinal: Bool, _ actionName: String) -> Void = { _, _, _ in }

    private(set) var portraitLighting = PortraitLighting()
    var isEditingEnabled = false {
        didSet { if isViewLoaded { update() } }
    }
    /// Whether the people in the photo have been found; nil with no photo.
    var peopleStatus: SubjectMatteStore.Status? {
        didSet { if isViewLoaded { updateStatus() } }
    }

    private let enableSwitch = NSSwitch()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let effectPopUp = NSPopUpButton()
    private lazy var intensityRow = SliderRow(title: "Intensity", range: 0...1, defaultValue: PortraitLighting().intensity,
                                              format: RimLightPanelViewController.percent)

    override func loadView() {
        let title = NSTextField(labelWithString: "Portrait Lighting")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        enableSwitch.controlSize = .small
        enableSwitch.target = self
        enableSwitch.action = #selector(enableChanged(_:))
        enableSwitch.setAccessibilityLabel("Portrait Lighting")
        enableSwitch.setAccessibilityIdentifier("portraitLightingEnabled")
        let titleRow = NSStackView(views: [title, NSView(), enableSwitch])
        titleRow.distribution = .fill

        let note = NSTextField(wrappingLabelWithString: "Studio lighting on the people in the photo.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityIdentifier("portraitLightingStatus")

        let effectLabel = NSTextField(labelWithString: "Effect")
        effectPopUp.controlSize = .small
        effectPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        effectPopUp.addItems(withTitles: PortraitLighting.Effect.allCases.map(\.title))
        effectPopUp.target = self
        effectPopUp.action = #selector(effectChanged(_:))
        effectPopUp.setAccessibilityLabel("Portrait Lighting effect")
        effectPopUp.setAccessibilityIdentifier("portraitLightingEffect")
        let effectRow = NSStackView(views: [effectLabel, NSView(), effectPopUp])
        effectRow.distribution = .fill

        intensityRow.toolTip = "How strong the effect is; for Stage, how dark the background goes"
        intensityRow.slider.setAccessibilityIdentifier("slider.PortraitLighting.Intensity")
        intensityRow.onChange = { [weak self] value, isFinal in self?.change(isFinal: isFinal, "Intensity") { $0.intensity = value } }

        let stack = NSStackView(views: [titleRow, note, statusLabel, effectRow, intensityRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 20, right: 14)
        stack.setCustomSpacing(4, after: titleRow)
        for view in [titleRow, note, statusLabel, effectRow, intensityRow] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        stack.setAccessibilityIdentifier("portraitLightingPanel")
        view = stack
        update()
    }

    func display(_ portraitLighting: PortraitLighting) {
        self.portraitLighting = portraitLighting
        if isViewLoaded { update() }
    }

    // MARK: - Showing

    private func update() {
        enableSwitch.state = portraitLighting.isEnabled ? .on : .off
        enableSwitch.isEnabled = isEditingEnabled
        let editable = isEditingEnabled && portraitLighting.isEnabled
        effectPopUp.selectItem(at: PortraitLighting.Effect.allCases.firstIndex(of: portraitLighting.effect) ?? 0)
        effectPopUp.isEnabled = editable
        intensityRow.value = portraitLighting.intensity
        intensityRow.slider.isEnabled = editable
        updateStatus()
    }

    private func updateStatus() {
        let text: String = switch peopleStatus {
        case .finding? where portraitLighting.isActive: "Finding people…"
        case .noSubject? where portraitLighting.isEnabled: "No person detected in this photo, so there's nothing to light."
        default: ""
        }
        statusLabel.stringValue = text
        statusLabel.isHidden = text.isEmpty
    }

    // MARK: - Editing

    /// Changes the settings and reports them.
    private func change(isFinal: Bool, _ actionName: String, _ edit: (inout PortraitLighting) -> Void) {
        var changed = portraitLighting
        edit(&changed)
        guard changed != portraitLighting || isFinal else { return }
        portraitLighting = changed
        onChange(changed, isFinal, actionName)
    }

    @objc private func enableChanged(_ sender: NSSwitch) {
        let on = sender.state == .on
        change(isFinal: true, on ? "Portrait Lighting On" : "Portrait Lighting Off") { $0.isEnabled = on }
        update()
    }

    @objc private func effectChanged(_ sender: NSPopUpButton) {
        let effects = PortraitLighting.Effect.allCases
        guard effects.indices.contains(sender.indexOfSelectedItem) else { return }
        let effect = effects[sender.indexOfSelectedItem]
        guard effect != portraitLighting.effect else { return }
        change(isFinal: true, "Portrait Lighting Effect") { $0.effect = effect }
        update()
    }
}
