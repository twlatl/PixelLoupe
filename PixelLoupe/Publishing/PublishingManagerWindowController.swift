import AppKit

/// Window ▸ Publishing Manager…, laid out like Lightroom's: the catalog's publish services on the left,
/// with Add and Remove, and the selected one's settings on the right in collapsible sections. Changes
/// are kept on Save and thrown away on Cancel (or closing the window).
final class PublishingManagerWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                                               NSTextFieldDelegate {
    private static let sectionStateKey = "PublishingManagerExpanded"
    /// The photo File Naming's example is named after.
    private static let exampleItem = ExportItem(source: URL(filePath: "/DSC00105.ARW"), adjustments: PhotoAdjustments(),
                                                metadata: PhotoMetadata(), keywords: [], rating: 0, captureDate: .now)

    let model: PublishingManagerModel
    let watermarks: WatermarkPresets
    /// Called when the window has closed, saved or not.
    var onClose: (() -> Void)?
    /// Asks whether to re-publish the photos of services whose changes no longer match them, and calls
    /// back with the IDs of those to re-publish (nil to go back to editing). Replaced in tests.
    lazy var askToRepublish: ([PublishingManagerModel.Draft], @escaping (Set<UUID>?) -> Void) -> Void = { [weak self] drafts, answer in
        self?.presentRepublishAlert(for: drafts, answer: answer)
    }

    // MARK: Controls

    let serviceList = NSTableView()
    let addButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let settingsScroll = NSScrollView()
    private let emptyLabel = FormLayout.secondaryLabel("Click Add to set up a publish service.")

    /// The selected service's form, rebuilt when the selection changes.
    private(set) var form: ExportSettingsForm?
    let descriptionField = NSTextField()
    let accountLabel = NSTextField(labelWithString: "")
    let titleSourcePopUp = NSPopUpButton()
    let titleUpdatePopUp = NSPopUpButton()
    let publicRadio = NSButton(radioButtonWithTitle: "Public", target: nil, action: nil)
    let privateRadio = NSButton(radioButtonWithTitle: "Private", target: nil, action: nil)
    let familyCheckbox = NSButton(checkboxWithTitle: "Family", target: nil, action: nil)
    let friendsCheckbox = NSButton(checkboxWithTitle: "Friends", target: nil, action: nil)
    let safetyPopUp = NSPopUpButton()
    let hiddenCheckbox = NSButton(checkboxWithTitle: "Hide from public site areas", target: nil, action: nil)
    let contentTypePopUp = NSPopUpButton()

    var selectedIndex: Int? {
        let row = serviceList.selectedRow
        return model.drafts.indices.contains(row) ? row : nil
    }

    init(model: PublishingManagerModel, watermarks: WatermarkPresets = .shared) {
        self.model = model
        self.watermarks = watermarks
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 780),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true
        )
        window.title = "Publishing Manager"
        window.contentMinSize = NSSize(width: 820, height: 560)
        window.setAccessibilityIdentifier("publishingManager")
        super.init(window: window)
        window.delegate = self
        buildContent()
        serviceList.reloadData()
        if !model.drafts.isEmpty { serviceList.selectRowIndexes([0], byExtendingSelection: false) }
        showSelectedService()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Finishing

    @objc func save(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        let changing = model.draftsChangingPublishedPhotos
        guard !changing.isEmpty else { return finish(saving: []) }
        askToRepublish(changing) { [weak self] republishing in
            if let republishing { self?.finish(saving: republishing) }
        }
    }

    @objc func cancel(_ sender: Any?) {
        close()
    }

    private func finish(saving republishing: Set<UUID>) {
        model.save(republishing: republishing)
        close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private func presentRepublishAlert(for drafts: [PublishingManagerModel.Draft], answer: @escaping (Set<UUID>?) -> Void) {
        guard let window else { return answer([]) }
        let alert = NSAlert()
        let count = drafts.reduce(0) { $0 + $1.publishedCount }
        alert.messageText = drafts.count == 1
            ? "Re-publish the photos already published to “\(drafts[0].displayName)”?"
            : "Re-publish the photos already published to these services?"
        alert.informativeText = "The new settings change how photos are published. Re-Publish All marks "
            + (count == 1 ? "the published photo" : "all \(count.formatted()) published photos")
            + " as modified, so the next Publish sends them again. Leave As Is uses the new settings only for photos published from now on."
        alert.addButton(withTitle: "Re-Publish All")
        alert.addButton(withTitle: "Leave As Is")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: answer(Set(drafts.map(\.id)))
            case .alertSecondButtonReturn: answer([])
            default: answer(nil)
            }
        }
    }

    // MARK: - Services

    /// Adds a service of the kind and selects it.
    func add(_ kind: PublishService.Kind) {
        window?.makeFirstResponder(nil)
        let index = model.add(kind)
        serviceList.reloadData()
        serviceList.selectRowIndexes([index], byExtendingSelection: false)
    }

    @objc private func addChosen(_ sender: NSMenuItem) {
        (sender.representedObject as? String).flatMap(PublishService.Kind.init(rawValue:)).map(add)
    }

    @objc func removeClicked(_ sender: Any?) {
        guard let index = selectedIndex else { return }
        let draft = model.drafts[index]
        guard draft.isSaved, let window else { return remove(at: index) }
        let alert = NSAlert()
        alert.messageText = "Remove the publish service “\(draft.displayName)”?"
        alert.informativeText = draft.publishedCount == 0
            ? "It’s removed when you click Save."
            : "PixelLoupe stops keeping track of its \(draft.publishedCount.formatted()) published "
                + (draft.publishedCount == 1 ? "photo" : "photos") + ". Nothing is removed from \(draft.kind.title). It’s removed when you click Save."
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.remove(at: index) }
        }
    }

    func remove(at index: Int) {
        model.remove(at: index)
        serviceList.reloadData()
        let next = min(index, model.drafts.count - 1)
        if next >= 0 { serviceList.selectRowIndexes([next], byExtendingSelection: false) } else { showSelectedService() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { model.drafts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ServiceCell.identifier, owner: self) as? ServiceCell ?? ServiceCell()
        cell.show(model.drafts[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showSelectedService()
    }

    private func reloadSelectedRow() {
        guard let index = selectedIndex else { return }
        serviceList.reloadData(forRowIndexes: [index], columnIndexes: [0])
    }

    // MARK: - Settings

    private func change(_ update: (inout PublishingManagerModel.Draft) -> Void) {
        guard let index = selectedIndex else { return }
        model.update(at: index, update)
        updateControls()
        reloadSelectedRow()
    }

    @objc private func controlChanged(_ sender: Any?) {
        change { draft in
            draft.name = descriptionField.stringValue
            draft.settings.titleSource = PublishSettings.TitleSource.allCases[max(0, titleSourcePopUp.indexOfSelectedItem)]
            draft.settings.titleUpdate = PublishSettings.TitleUpdate.allCases[max(0, titleUpdatePopUp.indexOfSelectedItem)]
            if sender as? NSButton === publicRadio || sender as? NSButton === privateRadio {
                draft.settings.isPublic = sender as? NSButton === publicRadio
            }
            draft.settings.isVisibleToFamily = familyCheckbox.state == .on
            draft.settings.isVisibleToFriends = friendsCheckbox.state == .on
            draft.settings.safety = PublishSettings.Safety.allCases[max(0, safetyPopUp.indexOfSelectedItem)]
            draft.settings.hidesFromPublicAreas = hiddenCheckbox.state == .on
            draft.settings.contentType = PublishSettings.ContentType.allCases[max(0, contentTypePopUp.indexOfSelectedItem)]
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        // The list follows the Description as it's typed.
        guard notification.object as? NSTextField === descriptionField, let index = selectedIndex else { return }
        model.update(at: index) { $0.name = descriptionField.stringValue }
        reloadSelectedRow()
    }

    /// Lays out the selected service's sections: those every service has, and those of its kind.
    private func showSelectedService() {
        window?.makeFirstResponder(nil)
        guard let index = selectedIndex else {
            form = nil
            settingsScroll.documentView = nil
            emptyLabel.isHidden = false
            removeButton.isEnabled = false
            return
        }
        emptyLabel.isHidden = true
        removeButton.isEnabled = true
        let draft = model.drafts[index]
        let form = ExportSettingsForm(settings: draft.settings.export, watermarks: watermarks)
        form.window = window
        form.example = (Self.exampleItem, 1)
        form.requiredFormat = draft.kind == .flickr ? .jpeg : nil
        form.onChange = { [weak self, weak form] in
            guard let form else { return }
            self?.change { $0.settings.export = form.settings }
        }
        self.form = form

        let key = Self.sectionStateKey
        var sections = [section("Publish Service", publishServiceSection())]
        switch draft.kind {
        case .hardDrive:
            sections.append(form.section(.publishLocation, stateKey: key))
        case .flickr:
            sections.append(section("Flickr Account", accountSection()))
            sections.append(section("Flickr Title", titleSection()))
        }
        sections += [.fileNaming, .video, .fileSettings, .imageSizing, .outputSharpening, .metadata, .watermarking]
            .map { form.section($0, stateKey: key) }
        if draft.kind == .flickr { sections.append(section("Privacy and Safety", privacySection())) }

        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 12, right: 16)
        for view in sections { view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        stack.translatesAutoresizingMaskIntoConstraints = false
        settingsScroll.documentView = stack
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalTo: settingsScroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: settingsScroll.contentView.topAnchor),
        ])
        updateControls()
    }

    /// Mirrors the selected service in the controls outside the export form.
    func updateControls() {
        guard let index = selectedIndex else { return }
        let draft = model.drafts[index]
        let settings = draft.settings
        if descriptionField.currentEditor() == nil { descriptionField.stringValue = draft.name }
        accountLabel.stringValue = draft.accountName.map { "Authorized as \($0)" } ?? "Not signed in. Signing in to Flickr is coming soon."
        titleSourcePopUp.selectItem(at: PublishSettings.TitleSource.allCases.firstIndex(of: settings.titleSource) ?? 0)
        titleUpdatePopUp.selectItem(at: PublishSettings.TitleUpdate.allCases.firstIndex(of: settings.titleUpdate) ?? 0)
        titleUpdatePopUp.isEnabled = settings.titleSource != .none
        publicRadio.state = settings.isPublic ? .on : .off
        privateRadio.state = settings.isPublic ? .off : .on
        familyCheckbox.state = settings.isVisibleToFamily ? .on : .off
        friendsCheckbox.state = settings.isVisibleToFriends ? .on : .off
        familyCheckbox.isEnabled = !settings.isPublic
        friendsCheckbox.isEnabled = !settings.isPublic
        safetyPopUp.selectItem(at: PublishSettings.Safety.allCases.firstIndex(of: settings.safety) ?? 0)
        hiddenCheckbox.state = settings.hidesFromPublicAreas ? .on : .off
        contentTypePopUp.selectItem(at: PublishSettings.ContentType.allCases.firstIndex(of: settings.contentType) ?? 0)
    }

    private func section(_ title: String, _ content: NSView) -> NSView {
        InspectorSectionView(title: title, content: content, stateKey: Self.sectionStateKey)
    }

    private func publishServiceSection() -> NSView {
        descriptionField.placeholderString = "Shown in the Library’s sidebar"
        descriptionField.target = self
        descriptionField.action = #selector(controlChanged(_:))
        descriptionField.delegate = self
        descriptionField.cell?.sendsActionOnEndEditing = true
        descriptionField.setAccessibilityIdentifier("publishServiceDescription")
        descriptionField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        return FormLayout.grid([[FormLayout.label("Description:"), descriptionField]])
    }

    private func accountSection() -> NSView {
        let buttons = ["Authorize", "Change Account", "Remove Authorization"].map { title in
            let button = NSButton(title: title, target: nil, action: nil)
            button.isEnabled = false
            return button
        }
        return FormLayout.grid([
            [NSGridCell.emptyContentView, accountLabel],
            [NSGridCell.emptyContentView, FormLayout.row(buttons)],
        ])
    }

    private func titleSection() -> NSView {
        popUp(titleSourcePopUp, PublishSettings.TitleSource.allCases.map(\.title))
        popUp(titleUpdatePopUp, PublishSettings.TitleUpdate.allCases.map(\.title))
        return FormLayout.grid([
            [FormLayout.label("Set Title Using:"), FormLayout.row([titleSourcePopUp, FormLayout.secondaryLabel("If empty, Filename will be used.")])],
            [FormLayout.label("When Updating Photos:"), titleUpdatePopUp],
        ])
    }

    private func privacySection() -> NSView {
        for button in [publicRadio, privateRadio, familyCheckbox, friendsCheckbox, hiddenCheckbox] {
            button.target = self
            button.action = #selector(controlChanged(_:))
        }
        popUp(safetyPopUp, PublishSettings.Safety.allCases.map(\.title))
        popUp(contentTypePopUp, PublishSettings.ContentType.allCases.map(\.title))
        return FormLayout.grid([
            [FormLayout.label("Privacy:"), FormLayout.row([privateRadio, familyCheckbox, friendsCheckbox])],
            [NSGridCell.emptyContentView, publicRadio],
            [FormLayout.label("Safety:"), safetyPopUp],
            [NSGridCell.emptyContentView, hiddenCheckbox],
            [FormLayout.label("Type:"), contentTypePopUp],
        ])
    }

    private func popUp(_ popUp: NSPopUpButton, _ titles: [String]) {
        popUp.removeAllItems()
        popUp.addItems(withTitles: titles)
        popUp.target = self
        popUp.action = #selector(controlChanged(_:))
    }

    // MARK: - Layout

    private func buildContent() {
        guard let contentView = window?.contentView else { return }
        let servicesLabel = FormLayout.secondaryLabel("Publish Services:")
        let settingsLabel = FormLayout.secondaryLabel("Settings:")

        let column = NSTableColumn(identifier: .init("Service"))
        serviceList.addTableColumn(column)
        serviceList.headerView = nil
        serviceList.style = .sourceList
        serviceList.rowHeight = 40
        serviceList.dataSource = self
        serviceList.delegate = self
        serviceList.setAccessibilityIdentifier("publishServiceList")
        let listScroll = NSScrollView()
        listScroll.documentView = serviceList
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .bezelBorder

        addButton.addItem(withTitle: "Add")
        for kind in PublishService.Kind.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(addChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.image = NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil)
            addButton.menu?.addItem(item)
        }
        addButton.setAccessibilityIdentifier("addPublishService")
        removeButton.target = self
        removeButton.action = #selector(removeClicked(_:))
        let listButtons = NSStackView(views: [addButton, removeButton])
        listButtons.distribution = .fillEqually

        settingsScroll.hasVerticalScroller = true
        settingsScroll.borderType = .bezelBorder
        settingsScroll.contentView = FlippedClipView()
        settingsScroll.drawsBackground = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.keyEquivalent = "\r"
        saveButton.setAccessibilityIdentifier("savePublishingManager")
        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.spacing = 12
        for button in [cancelButton, saveButton] { button.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true }

        for view in [servicesLabel, settingsLabel, listScroll, listButtons, settingsScroll, emptyLabel, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        let margin: CGFloat = 20
        NSLayoutConstraint.activate([
            servicesLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: margin),
            servicesLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: margin),
            listScroll.topAnchor.constraint(equalTo: servicesLabel.bottomAnchor, constant: 6),
            listScroll.leadingAnchor.constraint(equalTo: servicesLabel.leadingAnchor),
            listScroll.widthAnchor.constraint(equalToConstant: 230),
            listButtons.topAnchor.constraint(equalTo: listScroll.bottomAnchor, constant: 6),
            listButtons.leadingAnchor.constraint(equalTo: listScroll.leadingAnchor),
            listButtons.trailingAnchor.constraint(equalTo: listScroll.trailingAnchor),
            listButtons.bottomAnchor.constraint(equalTo: settingsScroll.bottomAnchor),

            settingsLabel.firstBaselineAnchor.constraint(equalTo: servicesLabel.firstBaselineAnchor),
            settingsLabel.leadingAnchor.constraint(equalTo: settingsScroll.leadingAnchor),
            settingsScroll.topAnchor.constraint(equalTo: listScroll.topAnchor),
            settingsScroll.leadingAnchor.constraint(equalTo: listScroll.trailingAnchor, constant: 16),
            settingsScroll.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),
            settingsScroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -20),
            emptyLabel.centerXAnchor.constraint(equalTo: settingsScroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: settingsScroll.centerYAnchor),

            buttons.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -margin),
            buttons.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -margin),
        ])
    }
}

/// A row of the service list: the service's icon, name, and where it publishes.
private final class ServiceCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("PublishService")
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        name.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let stack = NSStackView(views: [icon, text])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = name
        imageView = icon
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ draft: PublishingManagerModel.Draft) {
        icon.image = NSImage(systemSymbolName: draft.kind.symbolName, accessibilityDescription: draft.kind.title)
        name.stringValue = draft.displayName
        detail.stringValue = if !draft.isSaved {
            "(not saved)"
        } else {
            switch draft.kind {
            case .hardDrive: (draft.settings.export.folderPath as NSString).abbreviatingWithTildeInPath
            case .flickr: draft.accountName ?? "(not signed in)"
            }
        }
        setAccessibilityLabel("\(draft.displayName), \(detail.stringValue)")
    }
}
