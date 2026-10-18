import AppKit

/// Lightroom's Create Collection / Create Smart Collection / Create Collection Set dialog (and Edit
/// Smart Collection), shown as a sheet.
final class CollectionDialog: NSViewController {
    struct Result: Equatable {
        var name: String
        var parentID: UUID?
        var includeSelectedPhotos: Bool
        var setAsTarget: Bool
        var rules: SmartCollectionRules
    }

    let kind: PhotoCollection.Kind
    private let isEditing: Bool
    private let sets: [(id: UUID, path: String)]
    private let hasSelection: Bool
    var onFinish: (Result?) -> Void = { _ in }

    let nameField = NSTextField()
    let insideSetCheckbox = NSButton(checkboxWithTitle: "Inside a Collection Set", target: nil, action: nil)
    let setPopUp = NSPopUpButton()
    let includeSelectedCheckbox = NSButton(checkboxWithTitle: "Include selected photos", target: nil, action: nil)
    let targetCheckbox = NSButton(checkboxWithTitle: "Set as target collection", target: nil, action: nil)
    let matchPopUp = NSPopUpButton()
    private var existingGroups: [SmartCollectionRules] = []
    private(set) var rulesEditor: SmartRulesEditor?

    /// `parentID`: the set to put it in; `rules` and `name` when editing a smart collection.
    init(kind: PhotoCollection.Kind, sets: [(id: UUID, path: String)], parentID: UUID?, hasSelection: Bool,
         name: String? = nil, rules: SmartCollectionRules? = nil) {
        self.kind = kind
        self.sets = sets
        self.hasSelection = hasSelection
        isEditing = rules != nil
        super.init(nibName: nil, bundle: nil)
        let defaultName = switch kind {
        case .collection: "Collection"
        case .smart: "Smart Collection"
        case .set: "Collection Set"
        }
        nameField.stringValue = name ?? defaultName
        nameField.placeholderString = defaultName
        for set in sets {
            setPopUp.addItem(withTitle: set.path)
            setPopUp.lastItem?.representedObject = set.id
        }
        if let parentID, let index = sets.firstIndex(where: { $0.id == parentID }) {
            insideSetCheckbox.state = .on
            setPopUp.selectItem(at: index)
        }
        includeSelectedCheckbox.state = hasSelection ? .on : .off
        for match in SmartCollectionRules.Match.allCases { matchPopUp.addItem(withTitle: match.title) }
        matchPopUp.selectItem(withTitle: (rules ?? SmartCollectionRules()).match.title)
        // Nested groups (from a Lightroom import) aren't edited here; they are kept as they are.
        existingGroups = rules?.groups ?? []
        if kind == .smart { rulesEditor = SmartRulesEditor(rules: (rules ?? SmartCollectionRules()).rules) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var title_: String {
        switch kind {
        case .collection: "Create Collection"
        case .smart: isEditing ? "Edit Smart Collection" : "Create Smart Collection"
        case .set: "Create Collection Set"
        }
    }

    override func loadView() {
        let heading = NSTextField(labelWithString: title_)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        nameField.setAccessibilityLabel("Name")
        nameField.setAccessibilityIdentifier("collectionName")
        let nameRow = NSStackView(views: [NSTextField(labelWithString: "Name:"), nameField])

        insideSetCheckbox.target = self
        insideSetCheckbox.action = #selector(insideSetChanged(_:))
        insideSetCheckbox.isEnabled = !sets.isEmpty
        insideSetCheckbox.setAccessibilityIdentifier("collectionInsideSet")
        setPopUp.setAccessibilityLabel("Collection set")
        setPopUp.setAccessibilityIdentifier("collectionSetPopUp")
        let location = box("Location", [insideSetCheckbox, setPopUp])

        var sections: [NSView] = [heading, nameRow, location]
        switch kind {
        case .collection:
            includeSelectedCheckbox.isEnabled = hasSelection
            includeSelectedCheckbox.setAccessibilityIdentifier("collectionIncludeSelected")
            targetCheckbox.setAccessibilityIdentifier("collectionSetTarget")
            sections.append(box("Options", [includeSelectedCheckbox, targetCheckbox]))
        case .smart:
            matchPopUp.setAccessibilityIdentifier("collectionMatch")
            let matchRow = NSStackView(views: [NSTextField(labelWithString: "Match"), matchPopUp,
                                               NSTextField(labelWithString: "of the following rules:")])
            sections.append(matchRow)
            if let rulesEditor {
                let scroll = NSScrollView()
                scroll.hasVerticalScroller = true
                scroll.autohidesScrollers = true
                scroll.borderType = .bezelBorder
                let document = FlippedView()
                rulesEditor.translatesAutoresizingMaskIntoConstraints = false
                document.addSubview(rulesEditor)
                document.translatesAutoresizingMaskIntoConstraints = false
                scroll.documentView = document
                NSLayoutConstraint.activate([
                    rulesEditor.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
                    rulesEditor.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
                    rulesEditor.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
                    rulesEditor.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
                    document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                    document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                    scroll.heightAnchor.constraint(equalToConstant: 260),
                ])
                sections.append(scroll)
            }
        case .set:
            break
        }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let create = NSButton(title: isEditing ? "Save" : "Create", target: self, action: #selector(create(_:)))
        create.keyEquivalent = "\r"
        create.setAccessibilityIdentifier("collectionCreate")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, create])
        sections.append(buttons)

        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in sections where view !== heading {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: kind == .smart ? 760 : 460).isActive = true
        view = stack
        update()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
        nameField.selectText(nil)
    }

    private func box(_ title: String, _ views: [NSView]) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        let content = NSStackView(views: views)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        for view in views where view is NSPopUpButton {
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48).isActive = true
        }
        // A rounded, tinted group that sizes to its content (NSBox doesn't, under Auto Layout).
        let group = GroupBackground()
        content.translatesAutoresizingMaskIntoConstraints = false
        group.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: group.topAnchor),
            content.leadingAnchor.constraint(equalTo: group.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: group.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: group.bottomAnchor),
        ])
        let stack = NSStackView(views: [label, group])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func update() {
        setPopUp.isEnabled = insideSetCheckbox.state == .on && !sets.isEmpty
    }

    @objc private func insideSetChanged(_ sender: Any?) { update() }

    /// What the dialog says now.
    var result: Result {
        let match = SmartCollectionRules.Match.allCases[max(0, min(matchPopUp.indexOfSelectedItem, SmartCollectionRules.Match.allCases.count - 1))]
        var rules = SmartCollectionRules(match: match, rules: rulesEditor?.rules ?? [], groups: existingGroups)
        if kind != .smart { rules = SmartCollectionRules() }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(
            name: name.isEmpty ? nameField.placeholderString ?? "Collection" : name,
            parentID: insideSetCheckbox.state == .on ? setPopUp.selectedItem?.representedObject as? UUID : nil,
            includeSelectedPhotos: kind == .collection && includeSelectedCheckbox.state == .on,
            setAsTarget: kind == .collection && targetCheckbox.state == .on,
            rules: rules
        )
    }

    @objc func create(_ sender: Any?) {
        // Commit a text field being edited first.
        view.window?.makeFirstResponder(nil)
        let result = result
        dismiss(nil)
        onFinish(result)
    }

    @objc func cancel(_ sender: Any?) {
        dismiss(nil)
        onFinish(nil)
    }
}

/// The tinted, rounded background of a dialog group ("Location", "Options").
private final class GroupBackground: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
    }
}
