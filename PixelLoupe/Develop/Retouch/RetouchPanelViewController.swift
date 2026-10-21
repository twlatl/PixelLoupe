import AppKit

/// The Spot Removal panel: Heal, Clone or Red Eye, the placed spots and the selected one's sliders.
final class RetouchPanelViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum Mode: Int, CaseIterable {
        case heal, clone, redEye

        var title: String {
            switch self {
            case .heal: "Heal"
            case .clone: "Clone"
            case .redEye: "Red Eye"
            }
        }
    }

    private(set) var spots: [PhotoAdjustments.Spot] = []
    private(set) var redEyes: [PhotoAdjustments.RedEyeSpot] = []
    private(set) var selectedID: UUID?
    private(set) var mode = Mode.heal

    var onChange: ((_ spots: [PhotoAdjustments.Spot], _ redEyes: [PhotoAdjustments.RedEyeSpot], _ isFinal: Bool, _ actionName: String) -> Void)?
    var onSelectionChange: ((UUID?) -> Void)?
    var onModeChange: ((Mode) -> Void)?
    var isEditingEnabled = true { didSet { setControlsEnabled(isEditingEnabled, in: view) } }

    private let picker = NSSegmentedControl(labels: Mode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let table = NSTableView()
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let detail = NSStackView()
    private var sizeRow: SliderRow?, featherRow: SliderRow?, opacityRow: SliderRow?
    private var actionTargets: [ActionTarget] = []
    /// The targets for each row's delete button (replaced whenever the rows are rebuilt).
    private var rowDeleteTargets: [UUID: ActionTarget] = [:]

    private struct Row { var id: UUID; var title: String }
    private var rows: [Row] {
        spots.enumerated().map { Row(id: $1.id, title: "\($1.kind.title) \($0 + 1)") }
            + redEyes.enumerated().map { Row(id: $1.id, title: "Red Eye \($0 + 1)") }
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "SPOT REMOVAL")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor

        picker.controlSize = .small
        picker.selectedSegment = mode.rawValue
        picker.setAccessibilityIdentifier("retouchMode")
        let pickTarget = ActionTarget { [weak self] control in
            guard let self, let mode = Mode(rawValue: (control as! NSSegmentedControl).selectedSegment) else { return }
            self.mode = mode
            updateHint()
            onModeChange?(mode)
        }
        picker.target = pickTarget
        picker.action = #selector(ActionTarget.fire(_:))
        actionTargets.append(pickTarget)

        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        updateHint()

        let column = NSTableColumn(identifier: .init("spot"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Spots")
        table.setAccessibilityIdentifier("spotList")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 86).isActive = true

        let size = SliderRow(title: "Size", range: RetouchOverlayView.radiusRange, defaultValue: 0.02, format: { String(format: "%.1f", $0 * 1000) })
        let feather = SliderRow(title: "Feather", range: 0...1, defaultValue: 0.5, format: { String(format: "%.0f", $0 * 100) })
        let opacity = SliderRow(title: "Opacity", range: 0...1, defaultValue: 1, format: { String(format: "%.0f", $0 * 100) })
        for (row, name) in [(size, "Size"), (feather, "Feather"), (opacity, "Opacity")] {
            row.setAccessibilityIdentifier("slider.Spot.\(name)")
            row.slider.setAccessibilityIdentifier("slider.Spot.\(name)")
        }
        size.onChange = { [weak self] value, isFinal in self?.editSelected("Spot Size", isFinal: isFinal, spot: { $0.radius = value }, eye: { $0.radius = value }) }
        feather.onChange = { [weak self] value, isFinal in self?.editSelected(self?.selectedIsEye == true ? "Red Eye Strength" : "Spot Feather", isFinal: isFinal, spot: { $0.feather = value }, eye: { $0.strength = value }) }
        opacity.onChange = { [weak self] value, isFinal in self?.editSelected(self?.selectedIsEye == true ? "Red Eye Darken" : "Spot Opacity", isFinal: isFinal, spot: { $0.opacity = value }, eye: { $0.darken = value }) }
        sizeRow = size; featherRow = feather; opacityRow = opacity

        let delete = NSButton(title: "Delete", target: nil, action: nil)
        delete.controlSize = .small
        delete.bezelStyle = .rounded
        delete.setAccessibilityIdentifier("deleteSpot")
        let clear = NSButton(title: "Clear All", target: nil, action: nil)
        clear.controlSize = .small
        clear.bezelStyle = .rounded
        clear.setAccessibilityIdentifier("clearSpots")
        let deleteTarget = ActionTarget { [weak self] _ in self?.deleteSelected() }
        let clearTarget = ActionTarget { [weak self] _ in self?.clearAll() }
        delete.target = deleteTarget; delete.action = #selector(ActionTarget.fire(_:))
        clear.target = clearTarget; clear.action = #selector(ActionTarget.fire(_:))
        actionTargets += [deleteTarget, clearTarget]
        let buttons = NSStackView(views: [delete, clear])
        buttons.spacing = 8

        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 8
        for row in [size, feather, opacity] as [NSView] { detail.addArrangedSubview(row) }
        detail.addArrangedSubview(buttons)
        for row in [size, feather, opacity] { row.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true }

        let stack = NSStackView(views: [title, picker, hint, scroll, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 20, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [scroll, detail] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
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
        outer.setAccessibilityIdentifier("retouchPanel")
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: outer.contentView.widthAnchor).isActive = true
        document.topAnchor.constraint(equalTo: outer.contentView.topAnchor).isActive = true
        view = outer
        refresh()
    }

    private func updateHint() {
        hint.stringValue = switch mode {
        case .heal: "Click a spot on the photo. Heal copies from nearby and matches the colors around it. Drag the spot or its source; scroll to resize."
        case .clone: "Click a spot on the photo. Clone copies from nearby as it is. Drag the spot or its source; scroll to resize."
        case .redEye: "Click an eye. Scroll to resize."
        }
    }

    // MARK: - Showing and editing

    private var selectedIsEye: Bool { redEyes.contains { $0.id == selectedID } }

    func display(spots: [PhotoAdjustments.Spot], redEyes: [PhotoAdjustments.RedEyeSpot], selecting id: UUID? = nil) {
        self.spots = spots
        self.redEyes = redEyes
        let known = Set(spots.map(\.id) + redEyes.map(\.id))
        if let id, known.contains(id) { selectedID = id } else if let current = selectedID, !known.contains(current) { selectedID = nil }
        refresh()
    }

    func select(_ id: UUID?) {
        selectedID = id
        refresh()
    }

    private func refresh() {
        guard isViewLoaded else { return }
        table.reloadData()
        if let index = rows.firstIndex(where: { $0.id == selectedID }) { table.selectRowIndexes([index], byExtendingSelection: false) } else { table.deselectAll(nil) }
        detail.isHidden = selectedID == nil
        if let spot = spots.first(where: { $0.id == selectedID }) {
            sizeRow?.value = spot.radius; featherRow?.value = spot.feather; opacityRow?.value = spot.opacity
            featherRow?.slider.setAccessibilityLabel("Feather"); opacityRow?.slider.setAccessibilityLabel("Opacity")
        } else if let eye = redEyes.first(where: { $0.id == selectedID }) {
            sizeRow?.value = eye.radius; featherRow?.value = eye.strength; opacityRow?.value = eye.darken
        }
        picker.selectedSegment = mode.rawValue
        setControlsEnabled(isEditingEnabled, in: view)
    }

    func setMode(_ mode: Mode) {
        self.mode = mode
        if isViewLoaded { picker.selectedSegment = mode.rawValue; updateHint() }
    }

    private func editSelected(
        _ action: String, isFinal: Bool, spot: (inout PhotoAdjustments.Spot) -> Void, eye: (inout PhotoAdjustments.RedEyeSpot) -> Void
    ) {
        if let index = spots.firstIndex(where: { $0.id == selectedID }) { spot(&spots[index]) }
        else if let index = redEyes.firstIndex(where: { $0.id == selectedID }) { eye(&redEyes[index]) }
        else { return }
        onChange?(spots, redEyes, isFinal, action)
    }

    private func deleteSelected() {
        guard let id = selectedID else { return }
        delete(id)
    }

    /// Deletes a spot or red eye; deleting the selected one clears the selection.
    private func delete(_ id: UUID) {
        spots.removeAll { $0.id == id }
        redEyes.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = nil
            onSelectionChange?(nil)
        }
        onChange?(spots, redEyes, true, "Delete Spot")
        refresh()
    }

    private func clearAll() {
        guard !spots.isEmpty || !redEyes.isEmpty else { return }
        spots = []
        redEyes = []
        selectedID = nil
        onSelectionChange?(nil)
        onChange?(spots, redEyes, true, "Clear Spots")
        refresh()
    }

    /// Deletes the selected spot (the Delete key); `false` when nothing is selected.
    @discardableResult
    func deleteSelectedSpot() -> Bool {
        guard selectedID != nil else { return false }
        deleteSelected()
        return true
    }

    private func setControlsEnabled(_ enabled: Bool, in view: NSView) {
        for subview in view.subviews {
            if let control = subview as? NSControl, control !== table { control.isEnabled = enabled }
            setControlsEnabled(enabled, in: subview)
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let label = NSTextField(labelWithString: item.title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let delete = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Delete \(item.title)")!,
                              target: nil, action: nil)
        delete.isBordered = false
        delete.symbolConfiguration = NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed])
        delete.toolTip = "Delete \(item.title)"
        delete.setAccessibilityIdentifier("deleteSpot.\(row)")
        delete.isEnabled = isEditingEnabled
        let id = item.id
        let deleteTarget = ActionTarget { [weak self] _ in self?.delete(id) }
        delete.target = deleteTarget
        delete.action = #selector(ActionTarget.fire(_:))
        rowDeleteTargets[id] = deleteTarget

        let cell = NSStackView(views: [label, NSView(), delete])
        cell.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 4)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, rows.indices.contains(table.selectedRow) else { return }
        let id = rows[table.selectedRow].id
        guard id != selectedID else { return }
        selectedID = id
        refresh()
        onSelectionChange?(id)
    }
}
