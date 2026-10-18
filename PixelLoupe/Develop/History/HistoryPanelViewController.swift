import AppKit

/// The History and Snapshots panel: a photo's saved snapshots and its edit history, newest first.
/// Clicking a step or snapshot applies it; the next edit continues from there.
final class HistoryPanelViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    struct StepRow: Equatable {
        var id: UUID
        var name: String
        var date: Date
    }

    struct SnapshotRow: Equatable {
        var id: UUID
        var name: String
    }

    private(set) var steps: [StepRow] = []
    private(set) var snapshots: [SnapshotRow] = []
    private(set) var currentStepID: UUID?
    private(set) var selectedSnapshotID: UUID?

    var onSelectStep: ((UUID) -> Void)?
    var onSelectSnapshot: ((UUID) -> Void)?
    var onCreateSnapshot: (() -> Void)?
    var onUpdateSnapshot: ((UUID) -> Void)?
    var onDeleteSnapshot: ((UUID) -> Void)?
    var onRenameSnapshot: ((UUID, String) -> Void)?
    var onClearHistory: (() -> Void)?

    var isEditingEnabled = true { didSet { setControlsEnabled(isEditingEnabled, in: view) } }

    private let stepTable = NSTableView()
    private let snapshotTable = NSTableView()
    private let updateButton = NSButton(title: "Update", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private var actionTargets: [ActionTarget] = []
    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    override func loadView() {
        func heading(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }
        func makeScroll(_ table: NSTableView, height: CGFloat, identifier: String, label: String) -> NSScrollView {
            let column = NSTableColumn(identifier: .init(identifier))
            table.addTableColumn(column)
            table.headerView = nil
            table.rowHeight = 22
            table.dataSource = self
            table.delegate = self
            table.setAccessibilityIdentifier(identifier)
            table.setAccessibilityLabel(label)
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.borderType = .bezelBorder
            scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
            return scroll
        }
        let create = NSButton(title: "Create", target: nil, action: nil)
        for (button, identifier, tip) in [(create, "createSnapshot", "Create Snapshot (⌘N)"), (updateButton, "updateSnapshot", "Update the selected snapshot with the current settings"),
                                          (deleteButton, "deleteSnapshot", "Delete the selected snapshot")] {
            button.controlSize = .small
            button.bezelStyle = .rounded
            button.toolTip = tip
            button.setAccessibilityIdentifier(identifier)
        }
        let createTarget = ActionTarget { [weak self] _ in self?.onCreateSnapshot?() }
        let updateTarget = ActionTarget { [weak self] _ in if let id = self?.selectedSnapshotID { self?.onUpdateSnapshot?(id) } }
        let deleteTarget = ActionTarget { [weak self] _ in if let id = self?.selectedSnapshotID { self?.onDeleteSnapshot?(id) } }
        for (button, target) in [(create, createTarget), (updateButton, updateTarget), (deleteButton, deleteTarget)] {
            button.target = target
            button.action = #selector(ActionTarget.fire(_:))
            actionTargets.append(target)
        }
        let buttons = NSStackView(views: [create, updateButton, deleteButton])
        buttons.spacing = 8

        let menu = NSMenu()
        let clear = NSMenuItem(title: "Clear History", action: #selector(ActionTarget.fire(_:)), keyEquivalent: "")
        let clearTarget = ActionTarget { [weak self] _ in self?.onClearHistory?() }
        clear.target = clearTarget
        actionTargets.append(clearTarget)
        menu.addItem(clear)
        stepTable.menu = menu

        let snapshotScroll = makeScroll(snapshotTable, height: 84, identifier: "snapshotList", label: "Snapshots")
        let stepScroll = makeScroll(stepTable, height: 220, identifier: "historyList", label: "History")
        let stack = NSStackView(views: [heading("SNAPSHOTS"), snapshotScroll, buttons, heading("HISTORY"), stepScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 20, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for scroll in [snapshotScroll, stepScroll] { scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
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
        outer.setAccessibilityIdentifier("historyPanel")
        document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: outer.contentView.widthAnchor).isActive = true
        document.topAnchor.constraint(equalTo: outer.contentView.topAnchor).isActive = true
        view = outer
        refresh()
    }

    // MARK: - Showing

    /// `steps` oldest first; the panel lists them newest first.
    func display(steps: [StepRow], current: UUID?, snapshots: [SnapshotRow]) {
        self.steps = steps
        self.currentStepID = current ?? steps.last?.id
        self.snapshots = snapshots
        if !snapshots.contains(where: { $0.id == selectedSnapshotID }) { selectedSnapshotID = nil }
        refresh()
    }

    private func refresh() {
        guard isViewLoaded else { return }
        stepTable.reloadData()
        snapshotTable.reloadData()
        if let row = displayedSteps.firstIndex(where: { $0.id == currentStepID }) { stepTable.selectRowIndexes([row], byExtendingSelection: false) } else { stepTable.deselectAll(nil) }
        if let row = snapshots.firstIndex(where: { $0.id == selectedSnapshotID }) { snapshotTable.selectRowIndexes([row], byExtendingSelection: false) } else { snapshotTable.deselectAll(nil) }
        updateButton.isEnabled = isEditingEnabled && selectedSnapshotID != nil
        deleteButton.isEnabled = isEditingEnabled && selectedSnapshotID != nil
    }

    private var displayedSteps: [StepRow] { steps.reversed() }

    private func setControlsEnabled(_ enabled: Bool, in view: NSView) {
        for subview in view.subviews {
            if let control = subview as? NSControl, !(control is NSTableView) { control.isEnabled = enabled }
            setControlsEnabled(enabled, in: subview)
        }
        if isViewLoaded {
            updateButton.isEnabled = enabled && selectedSnapshotID != nil
            deleteButton.isEnabled = enabled && selectedSnapshotID != nil
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === stepTable ? steps.count : snapshots.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label: NSTextField
        if tableView === stepTable {
            let step = displayedSteps[row]
            label = NSTextField(labelWithString: "\(step.name)  ·  \(Self.timeFormat.string(from: step.date))")
            label.lineBreakMode = .byTruncatingTail
            label.setAccessibilityLabel(step.name)
        } else {
            label = NSTextField(string: snapshots[row].name)
            label.isEditable = true
            label.isBordered = false
            label.drawsBackground = false
            label.delegate = self
            label.tag = row
            label.setAccessibilityLabel("Snapshot \(snapshots[row].name)")
        }
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === stepTable {
            guard table.selectedRow >= 0, displayedSteps.indices.contains(table.selectedRow) else { return }
            let id = displayedSteps[table.selectedRow].id
            guard id != currentStepID else { return }
            currentStepID = id
            onSelectStep?(id)
        } else {
            guard table.selectedRow >= 0, snapshots.indices.contains(table.selectedRow) else { return }
            let id = snapshots[table.selectedRow].id
            selectedSnapshotID = id
            updateButton.isEnabled = isEditingEnabled
            deleteButton.isEnabled = isEditingEnabled
            onSelectSnapshot?(id)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, snapshots.indices.contains(field.tag) else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != snapshots[field.tag].name else { field.stringValue = snapshots[field.tag].name; return }
        onRenameSnapshot?(snapshots[field.tag].id, name)
    }
}
