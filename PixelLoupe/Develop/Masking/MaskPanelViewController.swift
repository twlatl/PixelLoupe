import AppKit

/// The Masking panel: the photo's masks, buttons to add a linear or radial gradient, and the
/// selected mask's sliders. Every edit calls `onChange` (final ones are saved and undoable).
final class MaskPanelViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var masks: [PhotoAdjustments.LocalAdjustment] = []
    private(set) var selectedID: UUID?

    var onChange: ((_ masks: [PhotoAdjustments.LocalAdjustment], _ isFinal: Bool, _ actionName: String) -> Void)?
    var onSelectionChange: ((UUID?) -> Void)?
    var onAdd: ((MaskKind) -> Void)?
    var onOverlayChange: ((Bool) -> Void)?

    enum MaskKind: Sendable { case linear, radial }

    var isEditingEnabled = true {
        didSet { setControlsEnabled(isEditingEnabled, in: view) }
    }

    private let table = NSTableView()
    private let overlayCheckbox = NSButton(checkboxWithTitle: "Show Overlay (O)", target: nil, action: nil)
    private let invertCheckbox = NSButton(checkboxWithTitle: "Invert", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private var sliderRows: [SliderRow] = []
    private let detail = NSStackView()
    private var refreshers: [() -> Void] = []
    private var actionTargets: [ActionTarget] = []
    /// The target for each row's checkbox (replaced whenever the rows are rebuilt).
    private var rowTargets: [UUID: ActionTarget] = [:]
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Add a linear (M) or radial (⇧M) gradient to adjust part of the photo.")

    private var selected: PhotoAdjustments.LocalAdjustment? { masks.first { $0.id == selectedID } }

    override func loadView() {
        let title = NSTextField(labelWithString: "MASKING")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor

        let linear = NSButton(title: "Linear", target: nil, action: nil)
        let radial = NSButton(title: "Radial", target: nil, action: nil)
        for (button, kind, identifier, tip) in [(linear, MaskKind.linear, "addLinearMask", "Linear Gradient (M)"), (radial, .radial, "addRadialMask", "Radial Gradient (⇧M)")] {
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.toolTip = tip
            button.setAccessibilityIdentifier(identifier)
            let target = ActionTarget { [weak self] _ in self?.onAdd?(kind) }
            button.target = target
            button.action = #selector(ActionTarget.fire(_:))
            actionTargets.append(target)
        }
        let buttons = NSStackView(views: [linear, radial])
        buttons.spacing = 8

        overlayCheckbox.controlSize = .small
        overlayCheckbox.setAccessibilityIdentifier("maskOverlayCheckbox")
        let overlayTarget = ActionTarget { [weak self] button in self?.onOverlayChange?((button as! NSButton).state == .on) }
        overlayCheckbox.target = overlayTarget
        overlayCheckbox.action = #selector(ActionTarget.fire(_:))
        actionTargets.append(overlayTarget)

        let column = NSTableColumn(identifier: .init("mask"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("Masks")
        table.setAccessibilityIdentifier("maskList")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 96).isActive = true

        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        emptyLabel.textColor = .secondaryLabelColor

        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 8
        buildDetail()

        let stack = NSStackView(views: [title, buttons, overlayCheckbox, scroll, emptyLabel, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 20, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [scroll, detail] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }

        let document = FlippedView()
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        let outer = NSScrollView()
        outer.documentView = document
        outer.hasVerticalScroller = true
        outer.autohidesScrollers = true
        outer.drawsBackground = false
        outer.setAccessibilityIdentifier("maskPanel")
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: outer.contentView.widthAnchor).isActive = true
        document.topAnchor.constraint(equalTo: outer.contentView.topAnchor).isActive = true
        view = outer
        refresh()
    }

    // MARK: - Detail

    private func buildDetail() {
        let sliders: [(String, ClosedRange<Double>, WritableKeyPath<PhotoAdjustments.LocalSettings, Double>, (Double) -> String)] = [
            ("Exposure", -5...5, \.exposure, { String(format: "%+.2f", $0) }),
            ("Contrast", -1...1, \.contrast, MaskPanelViewController.signedPercent),
            ("Highlights", -1...1, \.highlights, MaskPanelViewController.signedPercent),
            ("Shadows", -1...1, \.shadows, MaskPanelViewController.signedPercent),
            ("Whites", -1...1, \.whites, MaskPanelViewController.signedPercent),
            ("Blacks", -1...1, \.blacks, MaskPanelViewController.signedPercent),
            ("Temp", -1...1, \.temperature, MaskPanelViewController.signedPercent),
            ("Tint", -1...1, \.tint, MaskPanelViewController.signedPercent),
            ("Saturation", -1...1, \.saturation, MaskPanelViewController.signedPercent),
            ("Clarity", -1...1, \.clarity, MaskPanelViewController.signedPercent),
            ("Texture", -1...1, \.texture, MaskPanelViewController.signedPercent),
            ("Dehaze", -1...1, \.dehaze, MaskPanelViewController.signedPercent),
        ]
        let amount = SliderRow(title: "Amount", range: 0...1, defaultValue: 1, format: { String(format: "%.0f", $0 * 100) })
        amount.setAccessibilityIdentifier("slider.Mask.Amount")
        amount.slider.setAccessibilityIdentifier("slider.Mask.Amount")
        amount.onChange = { [weak self] value, isFinal in self?.edit("Mask Amount", isFinal: isFinal) { $0.amount = value } }
        refreshers.append { [weak self, weak amount] in amount?.value = self?.selected?.amount ?? 1 }
        detail.addArrangedSubview(amount)
        sliderRows.append(amount)

        for (name, range, path, format) in sliders {
            let row = SliderRow(title: name, range: range, defaultValue: 0, format: format)
            row.setAccessibilityIdentifier("slider.Mask.\(name)")
            row.slider.setAccessibilityIdentifier("slider.Mask.\(name)")
            row.onChange = { [weak self] value, isFinal in
                self?.edit("Adjust Mask \(name)", isFinal: isFinal) { $0.settings[keyPath: path] = value }
            }
            refreshers.append { [weak self, weak row] in row?.value = self?.selected?.settings[keyPath: path] ?? 0 }
            detail.addArrangedSubview(row)
            sliderRows.append(row)
        }

        invertCheckbox.controlSize = .small
        invertCheckbox.setAccessibilityIdentifier("maskInvert")
        let invertTarget = ActionTarget { [weak self] button in
            let on = (button as! NSButton).state == .on
            self?.edit("Invert Mask", isFinal: true) { mask in
                for index in mask.components.indices { mask.components[index].isInverted = on }
            }
        }
        invertCheckbox.target = invertTarget
        invertCheckbox.action = #selector(ActionTarget.fire(_:))
        actionTargets.append(invertTarget)
        refreshers.append { [weak self] in
            self?.invertCheckbox.state = (self?.selected?.components.first?.isInverted ?? false) ? .on : .off
        }
        detail.addArrangedSubview(invertCheckbox)

        deleteButton.controlSize = .small
        deleteButton.bezelStyle = .rounded
        deleteButton.setAccessibilityIdentifier("deleteMask")
        let deleteTarget = ActionTarget { [weak self] _ in self?.deleteSelected() }
        deleteButton.target = deleteTarget
        deleteButton.action = #selector(ActionTarget.fire(_:))
        actionTargets.append(deleteTarget)
        detail.addArrangedSubview(deleteButton)
        for row in sliderRows { row.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true }
    }

    nonisolated private static func signedPercent(_ value: Double) -> String {
        let rounded = (value * 100).rounded()
        return rounded == 0 ? "0" : String(format: "%+.0f", rounded)
    }

    private func edit(_ action: String, isFinal: Bool, _ change: (inout PhotoAdjustments.LocalAdjustment) -> Void) {
        guard let index = masks.firstIndex(where: { $0.id == selectedID }) else { return }
        change(&masks[index])
        reloadRowOnly(index)
        onChange?(masks, isFinal, action)
    }

    private func deleteSelected() {
        guard let index = masks.firstIndex(where: { $0.id == selectedID }) else { return }
        masks.remove(at: index)
        selectedID = masks.indices.contains(index) ? masks[index].id : masks.last?.id
        onSelectionChange?(selectedID)
        onChange?(masks, true, "Delete Mask")
        refresh()
    }

    // MARK: - Showing

    /// Shows the photo's masks, keeping the selection if it is still there.
    func display(masks: [PhotoAdjustments.LocalAdjustment], selecting id: UUID? = nil) {
        self.masks = masks
        if let id, masks.contains(where: { $0.id == id }) {
            selectedID = id
        } else if !masks.contains(where: { $0.id == selectedID }) {
            selectedID = masks.first?.id
        }
        refresh()
    }

    func select(_ id: UUID?) {
        selectedID = id
        refresh()
    }

    private func refresh() {
        guard isViewLoaded else { return }
        table.reloadData()
        if let index = masks.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        refreshers.forEach { $0() }
        detail.isHidden = selected == nil
        emptyLabel.isHidden = !masks.isEmpty
        setControlsEnabled(isEditingEnabled, in: view)
    }

    private func reloadRowOnly(_ index: Int) {
        table.reloadData(forRowIndexes: [index], columnIndexes: [0])
        table.selectRowIndexes([index], byExtendingSelection: false)
    }

    var overlayVisible: Bool {
        get { overlayCheckbox.state == .on }
        set { overlayCheckbox.state = newValue ? .on : .off }
    }

    private func setControlsEnabled(_ enabled: Bool, in view: NSView) {
        for subview in view.subviews {
            if let control = subview as? NSControl, control !== table { control.isEnabled = enabled }
            setControlsEnabled(enabled, in: subview)
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { masks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let mask = masks[row]
        let checkbox = NSButton(checkboxWithTitle: mask.name, target: nil, action: nil)
        checkbox.state = mask.isEnabled ? .on : .off
        checkbox.controlSize = .small
        checkbox.setAccessibilityLabel("\(mask.name), \(mask.isEnabled ? "on" : "off")")
        let id = mask.id
        let target = ActionTarget { [weak self] button in
            self?.selectedID = id
            self?.edit("Mask On/Off", isFinal: true) { $0.isEnabled = (button as! NSButton).state == .on }
            self?.onSelectionChange?(id)
        }
        checkbox.target = target
        checkbox.action = #selector(ActionTarget.fire(_:))
        rowTargets[id] = target
        return checkbox
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, masks.indices.contains(table.selectedRow) else { return }
        let id = masks[table.selectedRow].id
        guard id != selectedID else { return }
        selectedID = id
        refreshers.forEach { $0() }
        detail.isHidden = false
        onSelectionChange?(id)
    }
}
