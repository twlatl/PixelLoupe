import AppKit
import CoreData

/// The Library's right sidebar: Histogram (not editable), Keywords and Metadata, for the selected
/// photos.
final class LibraryInspectorViewController: NSViewController {
    enum Target: Int {
        /// Metadata edits go to the target (first selected) photo.
        case targetPhoto
        /// Metadata edits go to every selected photo.
        case selectedPhotos
    }

    private let store: CatalogStore
    private let state: LibraryState
    private lazy var editing = PhotoEditing(store: store)

    let histogram = HistogramView()
    let keywordField = KeywordField()
    private lazy var keywordsSection = InspectorSectionView(title: "Keywords", content: keywordField)
    private(set) lazy var keywordList = KeywordListView(store: store)
    private lazy var keywordListSection = InspectorSectionView(title: "Keyword List", content: keywordList)
    let metadataPanel = MetadataPanelView()
    let setPopUp = NSPopUpButton()
    let presetPopUp = NSPopUpButton()
    let targetControl = NSSegmentedControl(labels: ["Target Photo", "Selected Photos"], trackingMode: .selectOne, target: nil, action: nil)

    private static let setKey = "LibraryMetadataSet"
    private static let targetKey = "LibraryMetadataTarget"
    static let presetsKey = "MetadataPresets"

    /// Metadata of the shown photos, by object ID (read from files off the main thread).
    private var fileMetadata: [NSManagedObjectID: FileMetadata] = [:]
    private var loadTask: Task<Void, Never>?
    private var histogramTask: Task<Void, Never>?
    /// The photos whose metadata is read when several are selected (enough to tell what's mixed).
    static let maximumComparedPhotos = 200

    var target: Target {
        get { Target(rawValue: targetControl.selectedSegment) ?? .selectedPhotos }
        set { targetControl.selectedSegment = newValue.rawValue }
    }

    init(store: CatalogStore, state: LibraryState) {
        self.store = store
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Building

    override func loadView() {
        histogram.showsClippingIndicators = false
        histogram.isEditingEnabled = false

        keywordField.onAdd = { [weak self] names in self?.addKeywords(names) }
        keywordField.onRemove = { [weak self] name in self?.removeKeyword(name) }
        keywordList.onAssign = { [weak self] id, on in self?.assignKeyword(id, on: on) }
        keywordList.onShowPhotos = { [weak self] pathKey in self?.showPhotos(withKeyword: pathKey) }
        keywordList.onCommand = { [weak self] command, id in self?.perform(command, on: id) }

        for set in MetadataSet.all { setPopUp.addItem(withTitle: set.title) }
        setPopUp.controlSize = .small
        setPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        setPopUp.selectItem(withTitle: Defaults.store.string(forKey: Self.setKey) ?? "Default")
        if setPopUp.indexOfSelectedItem < 0 { setPopUp.selectItem(at: 0) }
        setPopUp.target = self
        setPopUp.action = #selector(setChanged(_:))
        setPopUp.setAccessibilityLabel("Metadata set")
        setPopUp.setAccessibilityIdentifier("metadataSet")

        presetPopUp.controlSize = .small
        presetPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        presetPopUp.target = self
        presetPopUp.action = #selector(presetChosen(_:))
        presetPopUp.setAccessibilityLabel("Metadata preset")
        presetPopUp.setAccessibilityIdentifier("metadataPreset")
        presetPopUp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buildPresetMenu()
        let presetTitle = NSTextField(labelWithString: "Preset")
        presetTitle.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        presetTitle.textColor = .secondaryLabelColor
        let presetRow = NSStackView(views: [presetTitle, presetPopUp])

        targetControl.controlSize = .small
        targetControl.selectedSegment = Defaults.store.object(forKey: Self.targetKey) as? Int ?? Target.selectedPhotos.rawValue
        targetControl.target = self
        targetControl.action = #selector(targetChanged(_:))
        targetControl.setAccessibilityIdentifier("metadataTarget")

        metadataPanel.onEdit = { [weak self] id, value in self?.edit(id, value) }
        metadataPanel.onAction = { [weak self] action in self?.perform(action) }
        metadataPanel.show(MetadataSet.named(setPopUp.titleOfSelectedItem ?? "Default"))

        let metadataContent = NSStackView(views: [presetRow, targetControl, metadataPanel])
        metadataContent.orientation = .vertical
        metadataContent.alignment = .centerX
        metadataContent.spacing = 10
        for view in [presetRow, metadataPanel] {
            view.widthAnchor.constraint(equalTo: metadataContent.widthAnchor).isActive = true
        }

        let sections = [
            InspectorSectionView(title: "Histogram", content: histogram),
            keywordsSection,
            keywordListSection,
            InspectorSectionView(title: "Metadata", accessory: setPopUp, content: metadataContent),
        ]
        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 20, right: 14)
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }

        let document = FlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        let scrollView = NSScrollView()
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.setAccessibilityIdentifier("libraryInspector")
        document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true
        document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor).isActive = true
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        state.addObserver(self) { [weak self] change in
            if change == .selection { self?.selectionChanged() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(contextObjectsDidChange(_:)),
            name: .NSManagedObjectContextObjectsDidChange, object: store.viewContext
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(thumbnailDidUpdate(_:)),
            name: ThumbnailStore.didUpdateNotification, object: store.thumbnails
        )
        keywordList.reload()
        selectionChanged()
    }

    // MARK: - Photos

    private var selectedPhotos: [Photo] { editing.photos(state.selectedPhotoIDs) }

    /// The photos metadata edits go to.
    private var editTargets: [NSManagedObjectID] {
        target == .targetPhoto ? Array(state.selectedPhotoIDs.prefix(1)) : state.selectedPhotoIDs
    }

    /// The photos whose values are shown: the target photo, or (up to a limit) all selected.
    private var shownPhotos: [Photo] {
        let photos = selectedPhotos
        return target == .targetPhoto ? Array(photos.prefix(1)) : Array(photos.prefix(Self.maximumComparedPhotos))
    }

    private func selectionChanged() {
        updateHistogram()
        updateKeywords()
        keywordList.updateMembership(for: selectedPhotos)
        loadFileMetadata()
    }

    @objc private func contextObjectsDidChange(_ notification: Notification) {
        let ids = Set(state.selectedPhotoIDs)
        let changed = [NSUpdatedObjectsKey, NSRefreshedObjectsKey, NSInsertedObjectsKey, NSDeletedObjectsKey].contains { key in
            (notification.userInfo?[key] as? Set<NSManagedObject>)?.contains { ids.contains($0.objectID) || $0 is Tag } ?? false
        }
        // The keyword tree and its counts follow edits to keywords and to which photos have them.
        let keywordsChanged = [NSUpdatedObjectsKey, NSInsertedObjectsKey, NSDeletedObjectsKey, NSRefreshedObjectsKey].contains { key in
            (notification.userInfo?[key] as? Set<NSManagedObject>)?.contains { $0 is Tag } ?? false
        }
        if keywordsChanged { scheduleKeywordListReload() }
        guard changed else { return }
        updateKeywords()
        updateMetadata()
    }

    private var keywordListReloadScheduled = false

    /// Rebuilds the Keyword List shortly after the last change (counts are one query, but edits come in bursts).
    private func scheduleKeywordListReload() {
        guard !keywordListReloadScheduled else { return }
        keywordListReloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            keywordListReloadScheduled = false
            keywordList.reload()
            keywordList.updateMembership(for: selectedPhotos)
        }
    }

    @objc private func thumbnailDidUpdate(_ notification: Notification) {
        guard let id = notification.userInfo?["id"] as? UUID, selectedPhotos.first?.id == id else { return }
        updateHistogram()
    }

    // MARK: - Histogram

    /// From the photo's thumbnail, which already shows its edits (fast, no decoding).
    private func updateHistogram() {
        histogramTask?.cancel()
        guard let photo = selectedPhotos.first else {
            histogram.histogram = nil
            histogram.shootingInfo = ShootingInfo()
            return
        }
        let thumbnails = store.thumbnails, id = photo.id, url = photo.fileURL
        histogramTask = Task { [weak self] in
            let image = await thumbnails.image(for: id)
            let result = await Self.histogram(of: image.map { HistogramCalculator.Input(image: CIImage(cgImage: $0)) }, url: url)
            guard let self, !Task.isCancelled else { return }
            histogram.histogram = result.histogram
            histogram.shootingInfo = result.info
        }
    }

    @concurrent
    nonisolated private static func histogram(of input: HistogramCalculator.Input?, url: URL) async -> (histogram: Histogram?, info: ShootingInfo) {
        (input.flatMap { HistogramCalculator.histogram(of: $0.image) }, ShootingInfo.read(from: url))
    }

    // MARK: - Keywords

    private func updateKeywords() {
        let photos = selectedPhotos
        keywordField.isEnabled = !photos.isEmpty
        var counts: [String: Int] = [:]
        var shown: [String: Tag] = [:]
        for photo in photos {
            for tag in photo.tags {
                counts[tag.pathKey, default: 0] += 1
                shown[tag.pathKey] = tag
            }
        }
        keywordField.keywords = counts.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { KeywordField.Keyword(name: shown[$0]!.name, path: shown[$0]!.displayPath, isOnAll: counts[$0] == photos.count) }
    }

    /// Photo ▸ Add Keywords (⌘K): opens the Keywords panel and puts the cursor in it.
    func focusKeywords() {
        keywordsSection.expand()
        view.layoutSubtreeIfNeeded()
        keywordField.scrollToVisible(keywordField.bounds)
        keywordField.focus()
    }

    /// Chooses among keywords that share a name, when a typed name could mean any of them. Replaced
    /// in tests; by default a pop-up menu of the paths (or `nil` if dismissed).
    var chooseKeyword: ([Tag]) -> Tag? = { options in
        let menu = NSMenu(title: "Choose Keyword")
        menu.addItem(withTitle: "“\(options[0].name)” is in several places:", action: nil, keyEquivalent: "").isEnabled = false
        for (index, tag) in options.enumerated() {
            let item = NSMenuItem(title: tag.displayPath, action: nil, keyEquivalent: "")
            item.tag = index
            menu.addItem(item)
        }
        guard let window = NSApp.keyWindow, let view = window.firstResponder as? NSView ?? window.contentView else { return nil }
        let chosen = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height), in: view)
        return chosen ? options[menu.highlightedItem?.tag ?? 0] : nil
    }

    /// Adds typed keywords to the selected photos: `A > B > C` makes that path, a plain name uses the
    /// one keyword with that name (asking when there are several), and a new name makes a top-level keyword.
    func addKeywords(_ texts: [String]) {
        let context = store.viewContext
        var tags: [Tag] = []
        for text in texts {
            switch Tag.resolve(text, in: context) {
            case .tag(let tag)?: tags.append(tag)
            case .ambiguous(let options)?: if let chosen = chooseKeyword(options) { tags.append(chosen) }
            case nil: break
            }
        }
        guard !tags.isEmpty else { return }
        editing.edit(state.selectedPhotoIDs, actionName: tags.count == 1 ? "Add Keyword" : "Add Keywords") { photo in
            for tag in tags { photo.tags.insert(tag) }
        }
        updateKeywords()
    }

    /// Removes a keyword (by its path, or its name when that's unambiguous) from the selected photos.
    func removeKeyword(_ path: String) {
        editing.edit(state.selectedPhotoIDs, actionName: "Remove Keyword") { photo in
            for tag in photo.tags where tag.displayPath.caseInsensitiveCompare(path) == .orderedSame { photo.tags.remove(tag) }
        }
        updateKeywords()
    }

    // MARK: - Keyword List

    /// A checkbox in the Keyword List: puts the keyword on, or takes it off, the selected photos.
    func assignKeyword(_ id: NSManagedObjectID, on: Bool) {
        guard let tag = try? store.viewContext.existingObject(with: id) as? Tag else { return }
        editing.edit(state.selectedPhotoIDs, actionName: on ? "Add Keyword" : "Remove Keyword") { photo in
            if on { photo.tags.insert(tag) } else { photo.tags.remove(tag) }
        }
        updateKeywords()
        keywordList.updateMembership(for: selectedPhotos)
    }

    /// The arrow beside a keyword's count: shows its photos (and those of keywords below it).
    func showPhotos(withKeyword pathKey: String) {
        state.presentation = .grid
        var filter = state.filter
        filter.scope = .allPhotos
        filter.tags = [pathKey]
        state.filter = filter
    }

    private func perform(_ command: KeywordListView.Command, on id: NSManagedObjectID?) {
        let tag = id.flatMap { try? store.viewContext.existingObject(with: $0) as? Tag }
        let keywords = KeywordEditing(store: store)
        func report(_ error: Error) {
            if let window = view.window { NSAlert(error: error).beginSheetModal(for: window) } else { NSAlert(error: error).runModal() }
        }
        switch command {
        case .create:
            guard let name = promptForName(title: tag.map { "Create Keyword Inside “\($0.name)”" } ?? "Create Keyword", value: "", button: "Create") else { return }
            do { try keywords.create(named: name, in: tag) } catch { report(error) }
        case .rename:
            guard let tag, let name = promptForName(title: "Rename Keyword", value: tag.name, button: "Rename") else { return }
            do { try keywords.rename(tag, to: name) } catch { report(error) }
        case .delete:
            guard let tag else { return }
            let alert = NSAlert()
            alert.messageText = "Delete the keyword “\(tag.name)”?"
            let inside = tag.children.count
            alert.informativeText = (inside > 0 ? "The \(inside) keyword\(inside == 1 ? "" : "s") inside it will be deleted too. " : "")
                + "Photos keep their other keywords. You can undo this."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            alert.buttons[0].hasDestructiveAction = true
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            keywords.delete(tag)
        case .edit:
            guard let tag else { return }
            editKeyword(tag, using: keywords)
        }
    }

    private func promptForName(title: String, value: String, button: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.setAccessibilityLabel("Keyword name")
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// Synonyms and export options, like Lightroom's Edit Keyword Tag dialog.
    private func editKeyword(_ tag: Tag, using keywords: KeywordEditing) {
        let alert = NSAlert()
        alert.messageText = "Edit Keyword “\(tag.name)”"
        let synonymsLabel = NSTextField(labelWithString: "Synonyms (one per line)")
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 260, height: 70))
        text.string = tag.synonyms.joined(separator: "\n")
        text.isRichText = false
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 70))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let onExport = NSButton(checkboxWithTitle: "Include on Export", target: nil, action: nil)
        let parents = NSButton(checkboxWithTitle: "Export Containing Keywords", target: nil, action: nil)
        let synonyms = NSButton(checkboxWithTitle: "Export Synonyms", target: nil, action: nil)
        let person = NSButton(checkboxWithTitle: "This keyword is a person", target: nil, action: nil)
        for (box, on) in [(onExport, tag.includeOnExport), (parents, tag.includeParents), (synonyms, tag.includeSynonyms), (person, tag.isPerson)] {
            box.state = on ? .on : .off
        }
        let stack = NSStackView(views: [synonymsLabel, scroll, onExport, parents, synonyms, person])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 190)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        keywords.update(
            tag, synonyms: text.string.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            includeOnExport: onExport.state == .on, includeParents: parents.state == .on, includeSynonyms: synonyms.state == .on,
            isPerson: person.state == .on)
    }

    // MARK: - Metadata

    private func loadFileMetadata() {
        loadTask?.cancel()
        let photos = shownPhotos
        let needed = photos.filter { fileMetadata[$0.objectID] == nil }.map { ($0.objectID, $0.fileURL) }
        updateMetadata()
        guard !needed.isEmpty else { return }
        loadTask = Task { [weak self] in
            let loaded = await Self.read(needed.map(\.1))
            guard let self, !Task.isCancelled else { return }
            for ((id, _), metadata) in zip(needed, loaded) { fileMetadata[id] = metadata }
            // Keep the cache to roughly what's shown.
            if fileMetadata.count > Self.maximumComparedPhotos * 4 {
                let keep = Set(state.selectedPhotoIDs.prefix(Self.maximumComparedPhotos))
                fileMetadata = fileMetadata.filter { keep.contains($0.key) }
            }
            updateMetadata()
        }
    }

    @concurrent
    nonisolated private static func read(_ urls: [URL]) async -> [FileMetadata] {
        urls.map { FileMetadata.read(from: $0) }
    }

    /// What's shown for each shown photo.
    private var shownValues: [MetadataValues] {
        shownPhotos.map { MetadataValues(info: .init(photo: $0), file: fileMetadata[$0.objectID] ?? FileMetadata()) }
    }

    private func updateMetadata() {
        let values = shownValues
        metadataPanel.display({ MetadataValues.common($0, of: values) }, isEditingEnabled: !values.isEmpty)
    }

    func edit(_ id: MetadataField.ID, _ value: String) {
        let targets = editTargets
        if id == .label {
            editing.setColorLabel(ColorLabel.allCases.first { $0.title == value } ?? .none, for: targets)
            updateMetadata()
            return
        }
        // Only photos whose shown value changes.
        let changing = editing.photos(targets).filter { photo in
            MetadataValues(info: .init(photo: photo), file: fileMetadata[photo.objectID] ?? FileMetadata()).value(id) != value
        }
        guard !changing.isEmpty else { return }
        editing.edit(changing.map(\.objectID), actionName: "Edit \(MetadataField.field(id).label)") { photo in
            var metadata = photo.metadata
            metadata[id] = value
            photo.metadata = metadata
        }
        updateMetadata()
    }

    @objc private func setChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem else { return }
        Defaults.store.set(title, forKey: Self.setKey)
        metadataPanel.show(MetadataSet.named(title))
        updateMetadata()
    }

    @objc private func targetChanged(_ sender: NSSegmentedControl) {
        Defaults.store.set(sender.selectedSegment, forKey: Self.targetKey)
        loadFileMetadata()
    }

    private func perform(_ action: MetadataField.Action) {
        guard let photo = selectedPhotos.first else { return }
        switch action {
        case .showFolder:
            if let path = photo.folder?.path {
                state.presentation = .grid
                state.filter.scope = .folder(path: path)
            }
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([photo.fileURL])
        case .openMap:
            guard let coordinate = fileMetadata[photo.objectID]?.coordinate,
                  let url = URL(string: "maps://?ll=\(coordinate.latitude),\(coordinate.longitude)&q=\(photo.fileName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
            else { NSSound.beep(); return }
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Presets

    /// Saved metadata presets: name → field values. App-wide, like Lightroom's.
    static var presets: [String: [String: String]] {
        get { Defaults.store.dictionary(forKey: presetsKey) as? [String: [String: String]] ?? [:] }
        set { Defaults.store.set(newValue, forKey: presetsKey) }
    }

    private func buildPresetMenu() {
        presetPopUp.removeAllItems()
        presetPopUp.addItem(withTitle: "None")
        let names = Self.presets.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for name in names {
            presetPopUp.addItem(withTitle: name)
            presetPopUp.lastItem?.representedObject = name
        }
        presetPopUp.menu?.addItem(.separator())
        presetPopUp.addItem(withTitle: "Save Current Settings as New Preset…")
        presetPopUp.lastItem?.tag = 1
        if !names.isEmpty {
            let delete = NSMenu(title: "Delete Preset")
            for name in names {
                let item = delete.addItem(withTitle: name, action: #selector(deletePreset(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
            }
            let deleteItem = NSMenuItem(title: "Delete Preset", action: nil, keyEquivalent: "")
            deleteItem.submenu = delete
            presetPopUp.menu?.addItem(deleteItem)
        }
        presetPopUp.selectItem(at: 0)
    }

    @objc private func presetChosen(_ sender: NSPopUpButton) {
        defer { presetPopUp.selectItem(at: 0) }
        if sender.selectedItem?.tag == 1 {
            savePreset()
        } else if let name = sender.selectedItem?.representedObject as? String {
            applyPreset(named: name)
        }
    }

    /// Sets every field the preset has on the photos edits go to.
    func applyPreset(named name: String) {
        guard let values = Self.presets[name], !values.isEmpty else { return }
        editing.edit(editTargets, actionName: "Apply Metadata Preset") { photo in
            var metadata = photo.metadata
            for (key, value) in values { metadata.values[key] = value }
            photo.metadata = metadata
        }
        updateMetadata()
    }

    /// The target photo's editable fields that have values.
    func currentPresetValues() -> [String: String] {
        guard let photo = selectedPhotos.first else { return [:] }
        let values = MetadataValues(info: .init(photo: photo), file: fileMetadata[photo.objectID] ?? FileMetadata())
        var result: [String: String] = [:]
        for field in MetadataField.all.values where field.isEditable {
            let value = values.value(field.id)
            if !value.isEmpty { result[field.id.rawValue] = value }
        }
        return result
    }

    private func savePreset() {
        guard let window = view.window else { return }
        let values = currentPresetValues()
        guard !values.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "There’s no metadata to save."
            alert.informativeText = "Fill in fields such as Title, Caption or Copyright first."
            alert.beginSheetModal(for: window)
            return
        }
        let alert = NSAlert()
        alert.messageText = "New Metadata Preset"
        alert.informativeText = "Saves the \(values.count) filled-in field\(values.count == 1 ? "" : "s") of the target photo."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Preset name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !name.isEmpty else { return }
            Self.presets[name] = values
            self?.buildPresetMenu()
        }
    }

    @objc private func deletePreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Self.presets[name] = nil
        buildPresetMenu()
    }
}
