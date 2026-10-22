import AppKit

/// The Library's Assisted Culling Info panel (RAW-71): the target photo's verdict by the Assisted Culling panel's
/// criteria, what rejected it, and its scores.
final class CullingInfoPanelView: NSView {
    private(set) var values: [CullingInfo.Row: NSTextField] = [:]
    let noteLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        let rows: [[NSView]] = CullingInfo.Row.allCases.map { row in
            let title = NSTextField(labelWithString: row.rawValue)
            title.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            title.textColor = .secondaryLabelColor
            title.alignment = .right
            let value = NSTextField(wrappingLabelWithString: CullingInfo.none)
            value.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            value.isSelectable = true
            value.setAccessibilityLabel(row.rawValue)
            value.setAccessibilityIdentifier("cullingInfo.\(row)")
            values[row] = value
            return [title, value]
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 4
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 92

        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.setAccessibilityIdentifier("cullingInfoNote")

        let stack = NSStackView(views: [grid, noteLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            noteLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        show(CullingInfo())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ info: CullingInfo) {
        for (row, field) in values { field.stringValue = info[row] }
        let verdict = values[.verdict]
        switch info.verdict {
        case .select?:
            verdict?.textColor = .systemGreen
            verdict?.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        case .reject?:
            verdict?.textColor = .systemRed
            verdict?.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        case nil:
            verdict?.textColor = .labelColor
            verdict?.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        noteLabel.stringValue = info.note ?? ""
        noteLabel.isHidden = info.note == nil
    }
}
