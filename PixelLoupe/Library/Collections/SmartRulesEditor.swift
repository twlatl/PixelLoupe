import AppKit

/// The rule list of the Create Smart Collection dialog: one row per rule (field, operator, value),
/// with − and + buttons, like Lightroom's.
final class SmartRulesEditor: NSView {
    private(set) var rules: [SmartCollectionRules.Rule] = []
    private let stack = NSStackView()

    init(rules: [SmartCollectionRules.Rule]) {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        setAccessibilityIdentifier("smartRules")
        self.rules = rules.isEmpty ? [.default(for: .rating)] : rules
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, rule) in rules.enumerated() {
            let row = RuleRow(rule: rule, canRemove: rules.count > 1)
            row.onChange = { [weak self] rule in self?.rules[index] = rule }
            row.onAdd = { [weak self] in
                guard let self else { return }
                rules.insert(.default(for: .rating), at: index + 1)
                rebuild()
            }
            row.onRemove = { [weak self] in
                guard let self, rules.count > 1 else { return }
                rules.remove(at: index)
                rebuild()
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    /// The rows, for tests.
    var rows: [RuleRow] { stack.arrangedSubviews.compactMap { $0 as? RuleRow } }

    /// One rule.
    final class RuleRow: NSView {
        var onChange: (SmartCollectionRules.Rule) -> Void = { _ in }
        var onAdd: () -> Void = {}
        var onRemove: () -> Void = {}

        private(set) var rule: SmartCollectionRules.Rule
        let fieldPopUp = NSPopUpButton()
        let operatorPopUp = NSPopUpButton()
        private let valueArea = NSStackView()
        private let canRemove: Bool

        init(rule: SmartCollectionRules.Rule, canRemove: Bool) {
            self.rule = rule
            self.canRemove = canRemove
            super.init(frame: .zero)
            for field in SmartCollectionRules.Field.allCases {
                fieldPopUp.addItem(withTitle: field.title)
                fieldPopUp.lastItem?.representedObject = field.rawValue
            }
            fieldPopUp.target = self
            fieldPopUp.action = #selector(fieldChanged(_:))
            fieldPopUp.setAccessibilityLabel("Field")
            fieldPopUp.setAccessibilityIdentifier("ruleField")
            operatorPopUp.target = self
            operatorPopUp.action = #selector(operatorChanged(_:))
            operatorPopUp.setAccessibilityLabel("Comparison")
            operatorPopUp.setAccessibilityIdentifier("ruleOperator")
            valueArea.spacing = 6
            valueArea.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let remove = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove rule")!, target: self, action: #selector(removeRule(_:)))
            remove.bezelStyle = .push
            remove.controlSize = .small
            remove.isEnabled = canRemove
            remove.setAccessibilityIdentifier("ruleRemove")
            let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add rule")!, target: self, action: #selector(addRule(_:)))
            add.bezelStyle = .push
            add.controlSize = .small
            add.setAccessibilityIdentifier("ruleAdd")
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)

            let row = NSStackView(views: [fieldPopUp, operatorPopUp, valueArea, spacer, remove, add])
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: topAnchor),
                row.leadingAnchor.constraint(equalTo: leadingAnchor),
                row.trailingAnchor.constraint(equalTo: trailingAnchor),
                row.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            setAccessibilityElement(false)
            update()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        private func update() {
            fieldPopUp.selectItem(at: SmartCollectionRules.Field.allCases.firstIndex(of: rule.field) ?? 0)
            operatorPopUp.removeAllItems()
            for (index, group) in rule.field.operatorGroups.enumerated() {
                if index > 0 { operatorPopUp.menu?.addItem(.separator()) }
                for op in group {
                    operatorPopUp.addItem(withTitle: op.title(for: rule.field))
                    operatorPopUp.lastItem?.representedObject = op.rawValue
                }
            }
            if let item = operatorPopUp.itemArray.first(where: { ($0.representedObject as? String) == rule.operator.rawValue }) {
                operatorPopUp.select(item)
            }
            buildValueControls()
        }

        private func changed() {
            onChange(rule)
        }

        @objc private func fieldChanged(_ sender: NSPopUpButton) {
            guard let raw = sender.selectedItem?.representedObject as? String,
                  let field = SmartCollectionRules.Field(rawValue: raw), field != rule.field else { return }
            rule = .default(for: field)
            update()
            changed()
        }

        @objc private func operatorChanged(_ sender: NSPopUpButton) {
            guard let raw = sender.selectedItem?.representedObject as? String,
                  let op = SmartCollectionRules.Operator(rawValue: raw) else { return }
            let wasRelative = rule.operator == .inTheLast || rule.operator == .notInTheLast
            rule.operator = op
            let isRelative = op == .inTheLast || op == .notInTheLast
            // Dates switch between a day and a count.
            if rule.field.valueKind == .date, wasRelative != isRelative {
                rule.value = isRelative ? "1" : SmartCollectionRules.dayFormatter.string(from: Date())
                rule.value2 = ""
            }
            if op.takesSecondValue, rule.value2.isEmpty { rule.value2 = rule.value }
            buildValueControls()
            changed()
        }

        @objc private func addRule(_ sender: Any?) { onAdd() }
        @objc private func removeRule(_ sender: Any?) { onRemove() }

        // MARK: - Value controls

        private func buildValueControls() {
            valueArea.arrangedSubviews.forEach { $0.removeFromSuperview() }
            valueKeyPaths = [:]
            guard rule.operator.takesValue else { return }
            switch rule.field.valueKind {
            case .rating:
                valueArea.addArrangedSubview(ratingControl(\.value))
                if rule.operator.takesSecondValue {
                    valueArea.addArrangedSubview(NSTextField(labelWithString: "to"))
                    valueArea.addArrangedSubview(ratingControl(\.value2))
                }
            case .flag:
                valueArea.addArrangedSubview(popUp(PhotoFlag.allCases.map { ($0.ruleTitle, $0.ruleValue) }, \.value))
            case .fileType:
                valueArea.addArrangedSubview(popUp(SmartCollectionRules.fileTypes.map { ($0 == "Raw" ? "RAW" : $0, $0) }, \.value))
            case .bool:
                valueArea.addArrangedSubview(popUp([("true", "true"), ("false", "false")], \.value))
            case .colorLabel:
                valueArea.addArrangedSubview(popUp(ColorLabel.allCases.map { ($0.title, $0.ruleValue) }, \.value))
            case .number:
                valueArea.addArrangedSubview(numberField(\.value))
                if rule.operator.takesSecondValue {
                    valueArea.addArrangedSubview(NSTextField(labelWithString: "to"))
                    valueArea.addArrangedSubview(numberField(\.value2))
                }
            case .text:
                let field = NSTextField(string: rule.value)
                field.placeholderString = rule.field == .keywords ? "keywords" : rule.field.title.lowercased()
                field.target = self
                field.action = #selector(textChanged(_:))
                field.setAccessibilityIdentifier("ruleText")
                field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
                NotificationCenter.default.addObserver(self, selector: #selector(textDidChange(_:)), name: NSControl.textDidChangeNotification, object: field)
                valueArea.addArrangedSubview(field)
            case .date:
                if rule.operator == .inTheLast || rule.operator == .notInTheLast {
                    let count = NSTextField(string: rule.value)
                    count.formatter = { let f = NumberFormatter(); f.minimum = 0; f.maximumFractionDigits = 0; return f }()
                    count.widthAnchor.constraint(equalToConstant: 50).isActive = true
                    count.setAccessibilityIdentifier("ruleCount")
                    NotificationCenter.default.addObserver(self, selector: #selector(textDidChange(_:)), name: NSControl.textDidChangeNotification, object: count)
                    valueArea.addArrangedSubview(count)
                    let unit = NSPopUpButton()
                    for item in SmartCollectionRules.Unit.allCases {
                        unit.addItem(withTitle: item.rawValue)
                        unit.lastItem?.representedObject = item.rawValue
                    }
                    unit.selectItem(withTitle: rule.unit.rawValue)
                    unit.target = self
                    unit.action = #selector(unitChanged(_:))
                    unit.setAccessibilityIdentifier("ruleUnit")
                    valueArea.addArrangedSubview(unit)
                } else {
                    valueArea.addArrangedSubview(datePicker(\.value))
                    if rule.operator.takesSecondValue {
                        valueArea.addArrangedSubview(NSTextField(labelWithString: "to"))
                        valueArea.addArrangedSubview(datePicker(\.value2))
                    }
                }
            }
        }

        private var valueKeyPaths: [ObjectIdentifier: WritableKeyPath<SmartCollectionRules.Rule, String>] = [:]

        private func bind(_ control: NSControl, _ keyPath: WritableKeyPath<SmartCollectionRules.Rule, String>) {
            valueKeyPaths[ObjectIdentifier(control)] = keyPath
        }

        private func keyPath(of control: NSControl) -> WritableKeyPath<SmartCollectionRules.Rule, String> {
            valueKeyPaths[ObjectIdentifier(control)] ?? \.value
        }

        /// Stars, with Lightroom's dots for none.
        private func ratingControl(_ keyPath: WritableKeyPath<SmartCollectionRules.Rule, String>) -> NSLevelIndicator {
            let indicator = NSLevelIndicator()
            indicator.levelIndicatorStyle = .rating
            indicator.minValue = 0
            indicator.maxValue = 5
            indicator.isEditable = true
            indicator.placeholderVisibility = .always
            indicator.integerValue = Int(rule[keyPath: keyPath]) ?? 0
            indicator.target = self
            indicator.action = #selector(ratingChanged(_:))
            indicator.setAccessibilityLabel("Rating")
            indicator.setAccessibilityIdentifier("ruleRating")
            bind(indicator, keyPath)
            return indicator
        }

        private func numberField(_ keyPath: WritableKeyPath<SmartCollectionRules.Rule, String>) -> NSTextField {
            let field = NSTextField(string: rule[keyPath: keyPath])
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimum = 0
            formatter.maximumFractionDigits = 4
            formatter.usesGroupingSeparator = false
            field.formatter = formatter
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
            field.setAccessibilityLabel(rule.field.title)
            field.setAccessibilityIdentifier("ruleNumber")
            bind(field, keyPath)
            NotificationCenter.default.addObserver(self, selector: #selector(textDidChange(_:)), name: NSControl.textDidChangeNotification, object: field)
            return field
        }

        private func popUp(_ options: [(title: String, value: String)], _ keyPath: WritableKeyPath<SmartCollectionRules.Rule, String>) -> NSPopUpButton {
            let popUp = NSPopUpButton()
            for option in options {
                popUp.addItem(withTitle: option.title)
                popUp.lastItem?.representedObject = option.value
            }
            if let item = popUp.itemArray.first(where: { ($0.representedObject as? String) == rule[keyPath: keyPath] }) {
                popUp.select(item)
            }
            popUp.target = self
            popUp.action = #selector(choiceChanged(_:))
            popUp.setAccessibilityIdentifier("ruleChoice")
            bind(popUp, keyPath)
            return popUp
        }

        private func datePicker(_ keyPath: WritableKeyPath<SmartCollectionRules.Rule, String>) -> NSDatePicker {
            let picker = NSDatePicker()
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = .yearMonthDay
            if rule[keyPath: keyPath].isEmpty { rule[keyPath: keyPath] = SmartCollectionRules.dayFormatter.string(from: Date()) }
            picker.dateValue = SmartCollectionRules.dayFormatter.date(from: rule[keyPath: keyPath]) ?? Date()
            picker.target = self
            picker.action = #selector(dateChanged(_:))
            picker.setAccessibilityIdentifier("ruleDate")
            bind(picker, keyPath)
            return picker
        }

        @objc private func ratingChanged(_ sender: NSLevelIndicator) {
            rule[keyPath: keyPath(of: sender)] = String(sender.integerValue)
            changed()
        }

        @objc private func choiceChanged(_ sender: NSPopUpButton) {
            guard let value = sender.selectedItem?.representedObject as? String else { return }
            rule[keyPath: keyPath(of: sender)] = value
            changed()
        }

        @objc private func dateChanged(_ sender: NSDatePicker) {
            rule[keyPath: keyPath(of: sender)] = SmartCollectionRules.dayFormatter.string(from: sender.dateValue)
            changed()
        }

        @objc private func unitChanged(_ sender: NSPopUpButton) {
            guard let raw = sender.selectedItem?.representedObject as? String,
                  let unit = SmartCollectionRules.Unit(rawValue: raw) else { return }
            rule.unit = unit
            changed()
        }

        @objc private func textChanged(_ sender: NSTextField) {
            rule.value = sender.stringValue
            changed()
        }

        @objc private func textDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            rule[keyPath: keyPath(of: field)] = field.stringValue
            changed()
        }
    }
}
