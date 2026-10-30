import AppKit

/// The Crop & Straighten panel, laid out like Lightroom's: aspect with a lock, Auto, angle with
/// the straighten tool, Constrain to Image, Tool Overlay, and Reset | Close.
final class CropPanelViewController: NSViewController {
    enum ToolOverlay: Int, CaseIterable {
        case auto, always, never

        var title: String {
            switch self {
            case .auto: "Auto"
            case .always: "Always"
            case .never: "Never"
            }
        }
    }

    private static let overlayKey = "CropToolOverlay"

    var onChange: (_ crop: PhotoAdjustments.Crop, _ isFinal: Bool) -> Void = { _, _ in }
    var onAspect: (CropAspect) -> Void = { _ in }
    var onAuto: () -> Void = {}
    var onReset: () -> Void = {}
    var onClose: () -> Void = {}
    var onStraightenTool: (Bool) -> Void = { _ in }
    var onOverlayChange: (ToolOverlay) -> Void = { _ in }

    private(set) var crop = PhotoAdjustments.Crop()
    private(set) var toolOverlay = ToolOverlay(rawValue: Defaults.store.integer(forKey: overlayKey)) ?? .auto

    private let aspectPopUp = NSPopUpButton()
    private let lockButton = NSButton()
    private let angleSlider = AdjustmentSlider(value: 0, minValue: CropGeometry.angleRange.lowerBound,
                                               maxValue: CropGeometry.angleRange.upperBound)
    private let angleValue = NSTextField(labelWithString: "0.00")
    private let straightenButton = NSButton()
    private let constrainCheckbox = NSButton(checkboxWithTitle: "Constrain to Image", target: nil, action: nil)
    private let overlayPopUp = NSPopUpButton()
    private let autoStatus = NSTextField(labelWithString: "")
    private var autoStatusGeneration = 0

    override func loadView() {
        func label(_ text: String, secondary: Bool = true) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = secondary ? .secondaryLabelColor : .labelColor
            return label
        }
        func spacer() -> NSView {
            let view = NSView()
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return view
        }
        func symbol(_ name: String, _ description: String) -> NSImageView {
            let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage())
            view.symbolConfiguration = .init(pointSize: 16, weight: .regular)
            view.contentTintColor = .secondaryLabelColor
            return view
        }

        let toolTitle = label("Crop & Straighten", secondary: false)
        toolTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let toolRow = NSStackView(views: [label("Tool:"), spacer(), toolTitle])

        aspectPopUp.controlSize = .small
        aspectPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        aspectPopUp.target = self
        aspectPopUp.action = #selector(aspectChosen(_:))
        aspectPopUp.setAccessibilityIdentifier("cropAspect")
        aspectPopUp.setAccessibilityLabel("Aspect")
        aspectPopUp.setContentHuggingPriority(.required, for: .horizontal)
        buildAspectMenu()

        lockButton.isBordered = false
        lockButton.bezelStyle = .toolbar
        lockButton.imagePosition = .imageOnly
        lockButton.target = self
        lockButton.action = #selector(toggleLock(_:))
        lockButton.setAccessibilityIdentifier("cropAspectLock")
        let aspectRow = NSStackView(views: [symbol("crop", "Aspect"), label("Aspect:"), spacer(), aspectPopUp, lockButton])

        let auto = NSButton(title: "Auto", target: self, action: #selector(auto(_:)))
        auto.controlSize = .small
        auto.toolTip = "Straighten the horizon automatically"
        auto.setAccessibilityIdentifier("cropAuto")
        autoStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        autoStatus.textColor = .secondaryLabelColor
        autoStatus.lineBreakMode = .byTruncatingTail
        autoStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        autoStatus.setAccessibilityIdentifier("cropAutoStatus")
        let autoRow = NSStackView(views: [autoStatus, spacer(), auto])

        straightenButton.setButtonType(.pushOnPushOff)
        straightenButton.bezelStyle = .toolbar
        straightenButton.isBordered = false
        straightenButton.imagePosition = .imageOnly
        straightenButton.image = NSImage(systemSymbolName: "ruler", accessibilityDescription: "Straighten tool")
        straightenButton.toolTip = "Straighten tool: drag along a line that should be level"
        straightenButton.target = self
        straightenButton.action = #selector(toggleStraighten(_:))
        straightenButton.setAccessibilityIdentifier("cropStraightenTool")

        angleSlider.controlSize = .small
        angleSlider.isContinuous = true
        angleSlider.target = self
        angleSlider.action = #selector(angleChanged(_:))
        angleSlider.setAccessibilityLabel("Angle")
        angleSlider.setAccessibilityIdentifier("cropAngle")
        angleSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        angleValue.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        angleValue.textColor = .secondaryLabelColor
        angleValue.alignment = .right
        angleValue.widthAnchor.constraint(equalToConstant: 44).isActive = true
        angleValue.setAccessibilityIdentifier("cropAngleValue")
        let resetAngle = NSClickGestureRecognizer(target: self, action: #selector(resetAngle(_:)))
        resetAngle.numberOfClicksRequired = 2
        let angleLabel = label("Angle")
        angleLabel.addGestureRecognizer(resetAngle)
        angleLabel.toolTip = "Double-click to reset"
        let angleRow = NSStackView(views: [straightenButton, angleLabel, angleSlider, angleValue])

        constrainCheckbox.controlSize = .small
        constrainCheckbox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        constrainCheckbox.target = self
        constrainCheckbox.action = #selector(constrainChanged(_:))
        constrainCheckbox.setAccessibilityIdentifier("cropConstrain")

        overlayPopUp.controlSize = .small
        overlayPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for overlay in ToolOverlay.allCases { overlayPopUp.addItem(withTitle: overlay.title) }
        overlayPopUp.selectItem(at: toolOverlay.rawValue)
        overlayPopUp.target = self
        overlayPopUp.action = #selector(overlayChanged(_:))
        overlayPopUp.setAccessibilityIdentifier("cropToolOverlay")
        overlayPopUp.setAccessibilityLabel("Tool Overlay")
        let overlayRow = NSStackView(views: [label("Tool Overlay:"), overlayPopUp, spacer()])

        let reset = NSButton(title: "Reset", target: self, action: #selector(reset(_:)))
        let close = NSButton(title: "Close", target: self, action: #selector(close(_:)))
        for button in [reset, close] {
            button.isBordered = false
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.contentTintColor = .secondaryLabelColor
        }
        reset.setAccessibilityIdentifier("cropReset")
        close.setAccessibilityIdentifier("cropClose")
        let divider = NSBox()
        divider.boxType = .separator
        divider.heightAnchor.constraint(equalToConstant: 12).isActive = true
        let footer = NSStackView(views: [spacer(), reset, divider, close])

        let stack = NSStackView(views: [toolRow, aspectRow, autoRow, angleRow, constrainCheckbox, overlayRow, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for row in [toolRow, aspectRow, autoRow, angleRow, overlayRow, footer] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        stack.setCustomSpacing(16, after: overlayRow)

        let container = NSView()
        container.setAccessibilityIdentifier("cropPanel")
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        view = container
        update()
    }

    private func buildAspectMenu() {
        let menu = NSMenu()
        menu.font = .menuFont(ofSize: NSFont.smallSystemFontSize)
        for entry in CropAspect.menu {
            guard let entry else { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            if let detail = entry.detail {
                // Lightroom shows the pixel size alongside screen ratios.
                item.attributedTitle = NSAttributedString(string: "\(entry.title)\t\(detail)", attributes: [
                    .paragraphStyle: { () -> NSParagraphStyle in
                        let style = NSMutableParagraphStyle()
                        style.tabStops = [NSTextTab(textAlignment: .right, location: 130)]
                        return style
                    }(),
                    // Same size as the plain items in this small pop-up's menu.
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                ])
            }
            item.representedObject = AspectBox(entry.aspect)
            menu.addItem(item)
        }
        let custom = NSMenuItem(title: "Enter Custom…", action: nil, keyEquivalent: "")
        custom.representedObject = AspectBox(nil)
        menu.addItem(custom)
        aspectPopUp.menu = menu
    }

    /// Shows `crop` in the controls.
    func display(_ crop: PhotoAdjustments.Crop) {
        self.crop = crop
        if isViewLoaded { update() }
    }

    /// Briefly explains an Auto that couldn't straighten the photo.
    func showAutoStatus(_ message: String) {
        autoStatus.stringValue = message
        autoStatusGeneration += 1
        let generation = autoStatusGeneration
        NSAccessibility.post(element: autoStatus, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, autoStatusGeneration == generation else { return }
            autoStatus.stringValue = ""
        }
    }

    func setStraightenToolActive(_ active: Bool) {
        straightenButton.state = active ? .on : .off
        straightenButton.contentTintColor = active ? Accent.color : nil
    }

    private func update() {
        let menu = aspectPopUp.menu?.items ?? []
        if let index = menu.firstIndex(where: { ($0.representedObject as? AspectBox)?.aspect == crop.aspect }) {
            aspectPopUp.selectItem(at: index)
        } else {
            // A custom ratio: show it as a temporary item.
            aspectPopUp.menu?.items.filter { ($0.representedObject as? AspectBox)?.isEntered == true }.forEach { aspectPopUp.menu?.removeItem($0) }
            let item = NSMenuItem(title: crop.aspect.title, action: nil, keyEquivalent: "")
            item.representedObject = AspectBox(crop.aspect, isEntered: true)
            aspectPopUp.menu?.insertItem(item, at: max(0, (aspectPopUp.menu?.items.count ?? 1) - 1))
            aspectPopUp.select(item)
        }
        lockButton.image = NSImage(
            systemSymbolName: crop.isAspectLocked ? "lock.fill" : "lock.open.fill",
            accessibilityDescription: crop.isAspectLocked ? "Aspect locked" : "Aspect unlocked"
        )
        lockButton.contentTintColor = crop.isAspectLocked ? Accent.color : .secondaryLabelColor
        lockButton.setAccessibilityValue(crop.isAspectLocked ? "locked" : "unlocked")
        lockButton.toolTip = crop.isAspectLocked ? "Unlock the aspect ratio" : "Lock the aspect ratio"
        angleSlider.doubleValue = crop.angle
        showAngle(crop.angle)
        constrainCheckbox.state = crop.constrainToImage ? .on : .off
    }

    // MARK: - Actions

    @objc private func aspectChosen(_ sender: NSPopUpButton) {
        guard let box = sender.selectedItem?.representedObject as? AspectBox else { return }
        if let aspect = box.aspect {
            onAspect(aspect)
        } else {
            enterCustomAspect()
        }
    }

    private func enterCustomAspect() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Enter Custom Aspect Ratio"
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let width = NSTextField(string: "3"), height = NSTextField(string: "2")
        for field in [width, height] { field.widthAnchor.constraint(equalToConstant: 60).isActive = true }
        let row = NSStackView(views: [width, NSTextField(labelWithString: "x"), height])
        row.frame = NSRect(x: 0, y: 0, width: 160, height: 24)
        alert.accessoryView = row
        alert.window.initialFirstResponder = width
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn, width.doubleValue > 0, height.doubleValue > 0 else {
                update()
                return
            }
            onAspect(.ratio(width: max(width.doubleValue, height.doubleValue), height: min(width.doubleValue, height.doubleValue)))
        }
    }

    @objc private func toggleLock(_ sender: Any?) {
        var crop = crop
        crop.isAspectLocked.toggle()
        if crop.isAspectLocked, crop.aspect == .custom { crop.aspect = .original }
        display(crop)
        onChange(crop, true)
    }

    @objc private func angleChanged(_ sender: NSSlider) {
        var crop = crop
        crop.angle = (sender.doubleValue * 100).rounded() / 100
        showAngle(crop.angle)
        self.crop = crop
        onChange(crop, isFinalControlEvent())
    }

    /// Shows the angle, bright when it's been changed from 0 (as `SliderRow` does).
    private func showAngle(_ angle: Double) {
        angleValue.stringValue = String(format: "%.2f", angle)
        angleValue.textColor = (angle * 100).rounded() == 0 ? .secondaryLabelColor : .labelColor
    }

    @objc private func resetAngle(_ sender: Any?) {
        var crop = crop
        crop.angle = 0
        display(crop)
        onChange(crop, true)
    }

    @objc private func constrainChanged(_ sender: NSButton) {
        var crop = crop
        crop.constrainToImage = sender.state == .on
        display(crop)
        onChange(crop, true)
    }

    @objc private func overlayChanged(_ sender: NSPopUpButton) {
        toolOverlay = ToolOverlay(rawValue: sender.indexOfSelectedItem) ?? .auto
        Defaults.store.set(toolOverlay.rawValue, forKey: Self.overlayKey)
        onOverlayChange(toolOverlay)
    }

    @objc private func toggleStraighten(_ sender: NSButton) {
        setStraightenToolActive(sender.state == .on)
        onStraightenTool(sender.state == .on)
    }

    @objc private func auto(_ sender: Any?) { onAuto() }
    @objc private func reset(_ sender: Any?) { onReset() }
    @objc private func close(_ sender: Any?) { onClose() }
}

/// Wraps an optional aspect for a menu item's `representedObject`.
private final class AspectBox: NSObject {
    let aspect: CropAspect?
    let isEntered: Bool

    init(_ aspect: CropAspect?, isEntered: Bool = false) {
        self.aspect = aspect
        self.isEntered = isEntered
    }
}
