import AppKit

/// The Masking panel: the photo's masks, a picker to add a linear or radial gradient, a brush, or the
/// subject or background, and the selected mask's sliders (and the brush's, or the subject's edge). Every edit calls `onChange` (final ones
/// are saved and undoable).
final class MaskPanelViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var masks: [PhotoAdjustments.LocalAdjustment] = []
    private(set) var selectedID: UUID?

    var onChange: ((_ masks: [PhotoAdjustments.LocalAdjustment], _ isFinal: Bool, _ actionName: String) -> Void)?
    var onSelectionChange: ((UUID?) -> Void)?
    var onAdd: ((MaskKind) -> Void)?
    var onOverlayChange: ((Bool) -> Void)?
    var onBrushChange: ((MaskGeometry.BrushSettings) -> Void)?

    enum MaskKind: CaseIterable, Sendable {
        case linear, radial, brush, subject, background

        var title: String {
            switch self {
            case .linear: "Linear"
            case .radial: "Radial"
            case .brush: "Brush"
            case .subject: "Subject"
            case .background: "Background"
            }
        }

        var toolTip: String {
            switch self {
            case .linear: "Add a Linear Gradient (M)"
            case .radial: "Add a Radial Gradient (⇧M)"
            case .brush: "Add a Brush (K)"
            case .subject: "Select Subject"
            case .background: "Select Background"
            }
        }

        /// The kind a mask was added as (its first shape's).
        init?(_ mask: PhotoAdjustments.LocalAdjustment) {
            switch mask.components.first?.shape {
            case .linear?: self = .linear
            case .radial?: self = .radial
            case .brush?: self = .brush
            case .subject?: self = .subject
            case .background?: self = .background
            case nil: return nil
            }
        }
    }

    /// Whether the photo's subject has been found, for a Subject or Background mask.
    var subjectStatus = SubjectMatteStore.Status.finding {
        didSet { if subjectStatus != oldValue { refreshers.forEach { $0() } } }
    }

    /// What the next brush stroke is painted with (the Brush sliders, and [ ] ⇧[ ⇧] on the photo).
    var brush = MaskGeometry.BrushSettings() {
        didSet {
            guard brush != oldValue else { return }
            brushRefreshers.forEach { $0() }
            onBrushChange?(brush)
        }
    }

    var isEditingEnabled = true {
        didSet { setControlsEnabled(isEditingEnabled, in: view) }
    }

    private let kindPicker = AccentSegmentedControl()
    private let table = NSTableView()
    private let overlayCheckbox = NSButton(checkboxWithTitle: "Show Overlay (O)", target: nil, action: nil)
    private let kindLabel = NSTextField(labelWithString: "")
    private let invertSwitch = NSSwitch()
    private let sections = AdjustmentsPanelViewController(scope: .mask)
    private let detail = NSStackView()
    private var refreshers: [() -> Void] = []
    private var brushRefreshers: [() -> Void] = []
    private let brushControls = NSStackView()
    private let subjectControls = NSStackView()
    private var actionTargets: [ActionTarget] = []
    /// The targets for each row's checkbox and delete button (replaced whenever the rows are rebuilt).
    private var rowTargets: [UUID: ActionTarget] = [:]
    private var rowDeleteTargets: [UUID: ActionTarget] = [:]
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Add a linear (M) or radial (⇧M) gradient, a brush (K), or the subject or background, to adjust part of the photo.")

    private var selected: PhotoAdjustments.LocalAdjustment? { masks.first { $0.id == selectedID } }

    override func loadView() {
        let title = NSTextField(labelWithString: "MASKING")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor

        // One segment per kind of mask: clicking one adds that kind, and the selected mask's kind is the one
        // highlighted (in the accent color, or Monochrome Mode's).
        let kinds = MaskKind.allCases
        kindPicker.segmentCount = kinds.count
        for (index, kind) in kinds.enumerated() {
            kindPicker.setLabel(kind.title, forSegment: index)
            kindPicker.setToolTip(kind.toolTip, forSegment: index)
        }
        kindPicker.trackingMode = .selectOne
        kindPicker.controlSize = .small
        kindPicker.segmentDistribution = .fillProportionally
        kindPicker.setAccessibilityIdentifier("addMask")
        kindPicker.setAccessibilityLabel("Add Mask")
        let pickTarget = ActionTarget { [weak self] control in
            let index = (control as! NSSegmentedControl).selectedSegment
            guard kinds.indices.contains(index) else { return }
            self?.onAdd?(kinds[index])
        }
        kindPicker.target = pickTarget
        kindPicker.action = #selector(ActionTarget.fire(_:))
        actionTargets.append(pickTarget)
        Accent.apply(in: kindPicker)

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

        let stack = NSStackView(views: [title, kindPicker, overlayCheckbox, scroll, emptyLabel, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 20, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [kindPicker, scroll, detail] { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }

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
        buildHeader()

        let amount = SliderRow(title: "Amount", range: 0...1, defaultValue: 1, format: { String(format: "%.0f", $0 * 100) })
        amount.setAccessibilityIdentifier("slider.Mask.Amount")
        amount.slider.setAccessibilityIdentifier("slider.Mask.Amount")
        amount.onChange = { [weak self] value, isFinal in self?.edit("Mask Amount", isFinal: isFinal) { $0.amount = value } }
        refreshers.append { [weak self, weak amount] in amount?.value = self?.selected?.amount ?? 1 }
        detail.addArrangedSubview(amount)
        amount.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        buildBrushControls()
        buildSubjectControls()

        // The mask's own Develop sections (RAW-193), the Adjust panel's controls bound to the mask's settings.
        addChild(sections)
        sections.onChange = { [weak self] adjustments, isFinal, action in
            self?.edit(action, isFinal: isFinal) { $0.settings = PhotoAdjustments.LocalSettings(adjustments) }
        }
        refreshers.append { [weak self] in
            guard let self else { return }
            sections.display((selected?.settings ?? .init()).adjustments, asShotWhiteBalance: (0, 0), isRaw: false)
        }
        detail.addArrangedSubview(sections.view)
        sections.view.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
    }

    /// Size, Feather, Flow and Density for the next stroke, shown while a brush mask is selected.
    private func buildBrushControls() {
        let percent: (Double) -> String = { String(format: "%.0f", $0 * 100) }
        let defaults = MaskGeometry.BrushSettings()
        let rows: [(String, ClosedRange<Double>, WritableKeyPath<MaskGeometry.BrushSettings, Double>, (Double) -> String)] = [
            ("Size", MaskGeometry.BrushSettings.sizeRange, \.size, { String(format: "%.1f", $0 * 100) }),
            ("Feather", 0...1, \.feather, percent),
            ("Flow", 0...1, \.flow, percent),
            ("Density", 0...1, \.density, percent),
        ]
        brushControls.orientation = .vertical
        brushControls.alignment = .leading
        brushControls.spacing = 8
        brushControls.setAccessibilityIdentifier("brushControls")
        for (name, range, path, format) in rows {
            let row = SliderRow(title: name, range: range, defaultValue: defaults[keyPath: path], format: format)
            row.setAccessibilityIdentifier("slider.Brush.\(name)")
            row.slider.setAccessibilityIdentifier("slider.Brush.\(name)")
            // Only the next stroke changes, so there is nothing to undo.
            row.onChange = { [weak self] value, _ in self?.brush[keyPath: path] = value }
            brushRefreshers.append { [weak self, weak row] in row?.value = self?.brush[keyPath: path] ?? 0 }
            brushControls.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: brushControls.widthAnchor).isActive = true
        }
        // A line between the brush and the mask's Develop sliders below it.
        let separator = NSBox()
        separator.boxType = .separator
        separator.setAccessibilityIdentifier("brushSeparator")
        brushControls.setCustomSpacing(12, after: brushControls.arrangedSubviews.last!)
        brushControls.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: brushControls.widthAnchor).isActive = true
        brushRefreshers.forEach { $0() }
        refreshers.append { [weak self] in
            guard let self else { return }
            brushControls.isHidden = !(selected?.components.contains { if case .brush = $0.shape { true } else { false } } ?? false)
        }
        detail.addArrangedSubview(brushControls)
        detail.setCustomSpacing(12, after: brushControls)
        brushControls.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
    }

    /// Feather and Edge for a Subject or Background mask, and whether its subject has been found.
    private func buildSubjectControls() {
        subjectControls.orientation = .vertical
        subjectControls.alignment = .leading
        subjectControls.spacing = 8
        subjectControls.setAccessibilityIdentifier("subjectControls")

        let status = NSTextField(wrappingLabelWithString: "")
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.setAccessibilityIdentifier("subjectStatus")
        subjectControls.addArrangedSubview(status)

        let rows: [(String, ClosedRange<Double>, WritableKeyPath<PhotoAdjustments.SubjectSelection, Double>, Double, (Double) -> String)] = [
            ("Feather", 0...1, \.feather, PhotoAdjustments.SubjectSelection().feather, { String(format: "%.0f", $0 * 100) }),
            ("Edge", -1...1, \.edge, 0, MaskPanelViewController.signedPercent),
        ]
        var sliders: [SliderRow] = []
        for (name, range, path, defaultValue, format) in rows {
            let row = SliderRow(title: name, range: range, defaultValue: defaultValue, format: format)
            row.setAccessibilityIdentifier("slider.Subject.\(name)")
            row.slider.setAccessibilityIdentifier("slider.Subject.\(name)")
            row.onChange = { [weak self] value, isFinal in
                self?.edit("Mask \(name)", isFinal: isFinal) { mask in
                    for index in mask.components.indices {
                        switch mask.components[index].shape {
                        case .subject(var selection):
                            selection[keyPath: path] = value
                            mask.components[index].shape = .subject(selection)
                        case .background(var selection):
                            selection[keyPath: path] = value
                            mask.components[index].shape = .background(selection)
                        case .linear, .radial, .brush:
                            break
                        }
                    }
                }
            }
            refreshers.append { [weak self, weak row] in
                let selection = self?.selected?.components.lazy.compactMap(\.shape.subjectSelection).first
                row?.value = selection?[keyPath: path] ?? defaultValue
            }
            subjectControls.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: subjectControls.widthAnchor).isActive = true
            sliders.append(row)
        }
        let separator = NSBox()
        separator.boxType = .separator
        subjectControls.setCustomSpacing(12, after: sliders.last!)
        subjectControls.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: subjectControls.widthAnchor).isActive = true
        status.widthAnchor.constraint(equalTo: subjectControls.widthAnchor).isActive = true

        refreshers.append { [weak self] in
            guard let self else { return }
            let usesSubject = selected?.usesSubject ?? false
            subjectControls.isHidden = !usesSubject
            // Found: just the sliders. Not yet, or nothing found: say so (the sliders have nothing to work on).
            status.stringValue = switch subjectStatus {
            case .finding: "Finding the subject…"
            case .noSubject: "No subject found"
            case .found: ""
            }
            status.isHidden = subjectStatus == .found
            for slider in sliders { slider.isHidden = subjectStatus == .noSubject }
        }
        detail.addArrangedSubview(subjectControls)
        detail.setCustomSpacing(12, after: subjectControls)
        subjectControls.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
    }

    /// The mask's type on the left and the Invert switch on the right, above every mask's controls.
    private func buildHeader() {
        kindLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        kindLabel.setAccessibilityIdentifier("maskKind")
        kindLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        refreshers.append { [weak self] in
            // An imported Lightroom mask can mix shapes; it is named after its first.
            self?.kindLabel.stringValue = self?.selected?.components.first?.shape.title ?? ""
        }

        let invertLabel = NSTextField(labelWithString: "Invert")
        invertLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        invertSwitch.controlSize = .small
        invertSwitch.setAccessibilityLabel("Invert")
        invertSwitch.setAccessibilityIdentifier("maskInvert")
        let invertTarget = ActionTarget { [weak self] control in
            let on = (control as! NSSwitch).state == .on
            self?.edit("Invert Mask", isFinal: true) { mask in
                for index in mask.components.indices { mask.components[index].isInverted = on }
            }
        }
        invertSwitch.target = invertTarget
        invertSwitch.action = #selector(ActionTarget.fire(_:))
        actionTargets.append(invertTarget)
        refreshers.append { [weak self] in
            self?.invertSwitch.state = (self?.selected?.components.first?.isInverted ?? false) ? .on : .off
        }

        let header = NSStackView(views: [kindLabel, NSView(), invertLabel, invertSwitch])
        header.spacing = 6
        detail.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
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

    /// Deletes a mask; deleting the selected one selects the next (or the last).
    private func delete(_ id: UUID) {
        guard let index = masks.firstIndex(where: { $0.id == id }) else { return }
        masks.remove(at: index)
        if selectedID == id { selectedID = masks.indices.contains(index) ? masks[index].id : masks.last?.id }
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

    /// Takes masks edited elsewhere (moved on the preview) without rebuilding the panel, so its next
    /// slider edit starts from them instead of putting the old shapes back.
    func update(masks: [PhotoAdjustments.LocalAdjustment]) {
        self.masks = masks
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
        showSelectedKind()
        detail.isHidden = selected == nil
        emptyLabel.isHidden = !masks.isEmpty
        setControlsEnabled(isEditingEnabled, in: view)
    }

    /// Highlights the selected mask's kind in the picker (none without a selection).
    private func showSelectedKind() {
        let index = selected.flatMap(MaskKind.init).flatMap(MaskKind.allCases.firstIndex(of:)) ?? -1
        kindPicker.selectedSegment = index
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

        let delete = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Delete \(mask.name)")!,
                              target: nil, action: nil)
        delete.isBordered = false
        delete.symbolConfiguration = NSImage.SymbolConfiguration(paletteColors: [.white, .systemRed])
        delete.toolTip = "Delete \(mask.name)"
        delete.setAccessibilityIdentifier("deleteMask.\(row)")
        delete.isEnabled = isEditingEnabled
        let deleteTarget = ActionTarget { [weak self] _ in self?.delete(id) }
        delete.target = deleteTarget
        delete.action = #selector(ActionTarget.fire(_:))
        rowDeleteTargets[id] = deleteTarget

        checkbox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cell = NSStackView(views: [checkbox, NSView(), delete])
        cell.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 4)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, masks.indices.contains(table.selectedRow) else { return }
        let id = masks[table.selectedRow].id
        guard id != selectedID else { return }
        selectedID = id
        refreshers.forEach { $0() }
        showSelectedKind()
        detail.isHidden = false
        onSelectionChange?(id)
    }
}
