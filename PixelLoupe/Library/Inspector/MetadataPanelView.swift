import AppKit

/// The fields of one metadata set, in a two-column grid like Lightroom's (labels right-aligned on
/// the left). Editable fields commit when editing ends; values that differ between the selected
/// photos show "‹mixed›".
final class MetadataPanelView: NSView, NSTextFieldDelegate {
    var onEdit: (_ field: MetadataField.ID, _ value: String) -> Void = { _, _ in }
    var onAction: (_ action: MetadataField.Action) -> Void = { _ in }

    private(set) var metadataSet = MetadataSet.all[0]
    private var controls: [MetadataField.ID: [NSControl]] = [:]
    private var actionButtons: [NSButton] = []
    private var content: NSView?
    private static let mixed = "‹mixed›"

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("metadataFields")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Building

    func show(_ set: MetadataSet) {
        metadataSet = set
        controls = [:]
        actionButtons = []
        content?.removeFromSuperview()
        let built = set.isLargeCaption ? buildLargeCaption(set) : buildGrid(set)
        built.translatesAutoresizingMaskIntoConstraints = false
        addSubview(built)
        NSLayoutConstraint.activate([
            built.topAnchor.constraint(equalTo: topAnchor),
            built.leadingAnchor.constraint(equalTo: leadingAnchor),
            built.trailingAnchor.constraint(equalTo: trailingAnchor),
            built.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        content = built
    }

    private func label(_ text: String, header: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = header ? .tertiaryLabelColor : .secondaryLabelColor
        label.alignment = header ? .left : .right
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func control(for field: MetadataField) -> NSControl {
        let control: NSControl
        switch field.kind {
        case .readOnly:
            let value = NSTextField(labelWithString: "")
            value.isSelectable = true
            value.lineBreakMode = .byTruncatingMiddle
            value.textColor = .labelColor
            control = value
        case .text, .multiline:
            // Focus only when clicked, never when the view changes around it.
            let value = ClickToFocusTextField()
            value.controlSize = .small
            value.delegate = self
            if case .multiline(let lines) = field.kind {
                value.usesSingleLineMode = false
                value.cell?.wraps = true
                value.cell?.isScrollable = false
                value.lineBreakMode = .byWordWrapping
                value.heightAnchor.constraint(equalToConstant: CGFloat(lines) * 15 + 6).isActive = true
            }
            control = value
        case .choice(let options):
            let popUp = NSPopUpButton()
            popUp.controlSize = .small
            popUp.addItems(withTitles: options.map { $0.isEmpty ? " " : $0 })
            popUp.target = self
            popUp.action = #selector(choiceChanged(_:))
            control = popUp
        }
        control.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        control.setAccessibilityLabel(field.label)
        control.setAccessibilityIdentifier("metadata.\(field.id.rawValue)")
        control.identifier = NSUserInterfaceItemIdentifier(field.id.rawValue)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controls[field.id, default: []].append(control)
        return control
    }

    private func valueCell(for field: MetadataField) -> NSView {
        let control = control(for: field)
        guard let action = field.action else { return control }
        let button = NSButton()
        button.image = NSImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = #selector(actionClicked(_:))
        button.tag = actionTag(action)
        let title = switch action {
        case .showFolder: "Show Folder in Library"
        case .revealInFinder: "Show in Finder"
        case .openMap: "Show on Map"
        }
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.setAccessibilityIdentifier("metadataAction.\(field.id.rawValue)")
        button.setContentHuggingPriority(.required, for: .horizontal)
        actionButtons.append(button)
        let row = NSStackView(views: [control, button])
        row.spacing = 4
        return row
    }

    private func actionTag(_ action: MetadataField.Action) -> Int {
        switch action {
        case .showFolder: 0
        case .revealInFinder: 1
        case .openMap: 2
        }
    }

    private func buildGrid(_ set: MetadataSet) -> NSView {
        let grid = NSGridView()
        grid.rowSpacing = 5
        grid.columnSpacing = 8
        for (index, group) in set.groups.enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                let row = grid.addRow(with: [line])
                row.mergeCells(in: NSRange(location: 0, length: 2))
                row.topPadding = 3
                row.bottomPadding = 3
            }
            if let title = group.title {
                grid.addRow(with: [NSGridCell.emptyContentView, label(title, header: true)])
            }
            for field in group.fields {
                let row = grid.addRow(with: [label(field.label), valueCell(for: field)])
                if case .multiline = field.kind { row.yPlacement = .top }
            }
        }
        if grid.numberOfColumns == 2 {
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 0).width = 112
            grid.column(at: 1).xPlacement = .fill
        }
        grid.rowAlignment = .firstBaseline
        return grid
    }

    /// Large Caption: big text boxes for the caption and copyright, labelled above.
    private func buildLargeCaption(_ set: MetadataSet) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        for field in set.groups.flatMap(\.fields) {
            let title = label(field.label)
            title.alignment = .left
            let box = control(for: field)
            if let text = box as? NSTextField {
                text.usesSingleLineMode = false
                text.cell?.wraps = true
                text.cell?.isScrollable = false
                text.heightAnchor.constraint(equalToConstant: field.id == .caption ? 300 : 44).isActive = true
            }
            stack.addArrangedSubview(title)
            stack.addArrangedSubview(box)
            box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            stack.setCustomSpacing(12, after: box)
        }
        return stack
    }

    // MARK: - Values

    /// Shows values; `value` returns nil for a field whose value differs between photos.
    func display(_ value: (MetadataField.ID) -> String?, isEditingEnabled: Bool) {
        for (id, fieldControls) in controls {
            let text = value(id)
            for control in fieldControls {
                switch control {
                case let popUp as NSPopUpButton:
                    if let text {
                        popUp.selectItem(withTitle: text.isEmpty ? " " : text)
                        if popUp.indexOfSelectedItem < 0 { popUp.selectItem(at: 0) }
                    } else {
                        popUp.select(nil)
                        popUp.setTitle(Self.mixed)
                    }
                case let field as NSTextField where field.isEditable:
                    // Don't disturb the field being typed in.
                    if field.currentEditor() == nil { field.stringValue = text ?? "" }
                    field.placeholderString = text == nil ? Self.mixed : nil
                default:
                    (control as? NSTextField)?.stringValue = text ?? Self.mixed
                }
                if control is NSPopUpButton || (control as? NSTextField)?.isEditable == true {
                    control.isEnabled = isEditingEnabled
                }
            }
        }
        actionButtons.forEach { $0.isEnabled = isEditingEnabled }
    }

    /// The control showing a field (the first, when a set shows it twice), for tests.
    func control(_ id: MetadataField.ID) -> NSControl? { controls[id]?.first }

    // MARK: - Editing

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let raw = field.identifier?.rawValue,
              let id = MetadataField.ID(rawValue: raw) else { return }
        // Return commits and leaves the field (so ⌘Z then undoes the edit, as in Lightroom).
        if (notification.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.return.rawValue {
            DispatchQueue.main.async { [weak field] in
                if field?.currentEditor() != nil { field?.window?.makeFirstResponder(nil) }
            }
        }
        // A mixed value left empty stays mixed.
        if field.stringValue.isEmpty, field.placeholderString == Self.mixed { return }
        onEdit(id, field.stringValue)
    }

    @objc private func choiceChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue, let id = MetadataField.ID(rawValue: raw),
              let title = sender.titleOfSelectedItem else { return }
        onEdit(id, title == " " ? "" : title)
    }

    @objc private func actionClicked(_ sender: NSButton) {
        let action: MetadataField.Action = switch sender.tag {
        case 0: .showFolder
        case 1: .revealInFinder
        default: .openMap
        }
        onAction(action)
    }
}
