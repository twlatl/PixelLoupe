import AppKit
import Observation
import SwiftUI

/// The import window's choices that the right panel and the top bar edit together.
@Observable
final class ImportOptionsModel {
    var transfer: ImportTransfer { didSet { changed() } }
    var root: URL { didSet { changed() } }
    var usesSubfolder: Bool { didSet { changed() } }
    var subfolderName: String {
        didSet {
            // Shoot Name follows the subfolder until it's typed.
            if !renaming.shootNameEdited { renaming.shootName = subfolderName }
            changed()
        }
    }
    var layout: ImportFolderLayout { didSet { changed() } }
    var organize: ImportOrganization { didSet { changed() } }
    /// Why Add can't be used for the current source (a memory card), or `nil` when it can.
    var addUnavailableReason: String? { didSet { if addUnavailableReason != oldValue { changed() } } }

    // File Handling
    /// Don't Import Suspected Duplicates (on by default).
    var skipsDuplicates: Bool { didSet { changed() } }
    /// Don't Import Rejected Images.
    var skipsRejected: Bool { didSet { changed() } }
    var makesSecondCopy: Bool { didSet { changed() } }
    var secondCopy: URL? { didSet { changed() } }
    var addsToCollection: Bool { didSet { changed() } }
    /// The collection to add to: an existing one, or `nil` for a new one named `newCollectionName`.
    var collectionID: UUID? { didSet { changed() } }
    var newCollectionName = "" { didSet { changed() } }

    // File Renaming
    var renaming: ImportRenaming { didSet { changed() } }
    /// The first checked file, for File Renaming's example.
    var exampleFile: (name: String, date: Date)?

    // Apply During Import
    var developPresetPath: String? { didSet { changed() } }
    var metadataPresetID: UUID? { didSet { changed() } }
    /// Not remembered: they're usually for one shoot.
    var keywords: [String] = [] { didSet { changed() } }

    // What the panel offers, filled in by the window.
    var collections: [(id: UUID, path: String)] = []
    var presetGroups: [(name: String, presets: [DevelopPreset])] = []
    var metadataPresets: [MetadataPreset] = MetadataPreset.all()
    var keywordSuggestions: [String] = []
    var duplicateCount = 0
    var rejectedCount = 0

    /// While photos import: the top bar's Copy / Add is disabled.
    var isLocked = false
    var fileHandlingExpanded = true
    var renamingExpanded = true
    var applyExpanded = true
    var destinationExpanded = true

    /// Called after any choice changes.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Called by Choose… to pick the destination folder.
    @ObservationIgnored var onChooseRoot: (() -> Void)?
    /// Called by Make a Second Copy's Choose… to pick its folder.
    @ObservationIgnored var onChooseSecondCopy: (() -> Void)?

    /// What the import will do: the chosen transfer, unless Add isn't available for this source, when
    /// it copies (without forgetting that Add was chosen, for the next source).
    var effectiveTransfer: ImportTransfer {
        addUnavailableReason == nil ? transfer : .copy
    }

    init(settings: ImportSettings) {
        transfer = settings.transfer
        root = settings.destination.root
        usesSubfolder = settings.destination.subfolder != nil
        subfolderName = settings.destination.subfolder ?? ""
        layout = settings.destination.layout
        organize = settings.destination.organize
        let handling = settings.handling ?? ImportHandling()
        skipsDuplicates = !handling.allowsDuplicates
        skipsRejected = handling.skipsRejected
        makesSecondCopy = handling.makesSecondCopy
        secondCopy = handling.secondCopy
        addsToCollection = handling.addsToCollection
        collectionID = handling.collectionID
        developPresetPath = handling.developPresetPath
        metadataPresetID = handling.metadataPresetID
        var renaming = handling.renaming ?? ImportRenaming()
        if !renaming.shootNameEdited { renaming.shootName = settings.destination.subfolder ?? "" }
        self.renaming = renaming
    }

    var settings: ImportSettings {
        ImportSettings(transfer: transfer, destination: destination, handling: ImportHandling(
            allowsDuplicates: !skipsDuplicates, skipsRejected: skipsRejected, makesSecondCopy: makesSecondCopy,
            secondCopy: secondCopy, addsToCollection: addsToCollection, collectionID: collectionID,
            developPresetPath: developPresetPath, metadataPresetID: metadataPresetID, renaming: renaming))
    }

    var destination: ImportDestination {
        ImportDestination(root: root, subfolder: usesSubfolder ? subfolderName : nil, layout: layout, organize: organize)
    }

    var developPreset: DevelopPreset? {
        guard let developPresetPath else { return nil }
        return presetGroups.lazy.flatMap(\.presets).first { $0.url.path(percentEncoded: false) == developPresetPath }
    }

    var metadataPreset: MetadataPreset? {
        metadataPresets.first { $0.id == metadataPresetID }
    }

    /// What the import does besides bringing files in.
    var extras: ImportExtras {
        var extras = ImportExtras()
        extras.allowsDuplicates = !skipsDuplicates
        extras.skipsRejected = skipsRejected
        extras.secondCopy = makesSecondCopy && effectiveTransfer == .copy ? secondCopy : nil
        extras.keywords = keywords
        extras.metadata = metadataPreset
        extras.developPreset = developPreset
        extras.renaming = renaming.isOn ? renaming : nil
        if addsToCollection {
            if let collectionID {
                extras.collection = .existing(collectionID)
            } else {
                // Left empty, it's named for the day: "Import 2026-10-15".
                let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                extras.collection = .new(name: name.isEmpty ? "Import \(Date().formatted(.iso8601.year().month().day()))" : name)
            }
        }
        return extras
    }

    /// Takes on a preset's choices (Copy or Add, File Handling, File Renaming, Apply During Import
    /// except keywords, and Destination).
    func apply(_ settings: ImportSettings) {
        // One change for the whole preset, not one per choice.
        isApplying = true
        defer {
            isApplying = false
            changed()
        }
        let handling = settings.handling ?? ImportHandling()
        transfer = settings.transfer
        root = settings.destination.root
        usesSubfolder = settings.destination.subfolder != nil
        subfolderName = settings.destination.subfolder ?? ""
        layout = settings.destination.layout
        organize = settings.destination.organize
        skipsDuplicates = !handling.allowsDuplicates
        skipsRejected = handling.skipsRejected
        makesSecondCopy = handling.makesSecondCopy
        secondCopy = handling.secondCopy
        addsToCollection = handling.addsToCollection
        collectionID = handling.collectionID
        developPresetPath = handling.developPresetPath
        metadataPresetID = handling.metadataPresetID
        renaming = handling.renaming ?? ImportRenaming()
    }

    /// File Renaming's example: the first checked file as it would be named.
    var renamingExample: String {
        let file = exampleFile ?? (name: "DSC00112.ARW", date: Date())
        return renaming.isOn ? renaming.name(for: file.name, date: file.date, index: 0) : file.name
    }

    /// Saves a new or edited metadata preset, choosing it.
    func saveMetadataPreset(_ preset: MetadataPreset) {
        if let index = metadataPresets.firstIndex(where: { $0.id == preset.id }) {
            metadataPresets[index] = preset
        } else {
            metadataPresets.append(preset)
        }
        MetadataPreset.save(metadataPresets)
        metadataPresetID = preset.id
    }

    func deleteMetadataPreset(_ preset: MetadataPreset) {
        metadataPresets.removeAll { $0.id == preset.id }
        MetadataPreset.save(metadataPresets)
        if metadataPresetID == preset.id { metadataPresetID = nil }
    }

    @ObservationIgnored private var isApplying = false

    private func changed() {
        guard !isApplying else { return }
        onChange?()
    }
}

/// The import window's right panel, as in RAW-76's mockups. (File Renaming joins it with RAW-82.)
struct ImportOptionsPanel: View {
    @Bindable var model: ImportOptionsModel
    @State private var editingMetadata: MetadataPreset?

    /// Switches follow Monochrome Mode, like the rest of the window. (Only switches: a tint on buttons
    /// and pop-ups would make them look disabled.)
    private var switchTint: Color {
        AppSettings.shared.isMonochrome ? Color(nsColor: Accent.monochrome) : .accentColor
    }

    var body: some View {
        Form {
            fileHandling
            fileRenaming
            applyDuringImport
            destination
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(item: $editingMetadata) { preset in
            MetadataPresetEditor(
                preset: preset, isNew: !model.metadataPresets.contains { $0.id == preset.id },
                onSave: { model.saveMetadataPreset($0) }, onDelete: { model.deleteMetadataPreset($0) })
        }
    }

    // MARK: File Handling

    private var fileHandling: some View {
        Section(isExpanded: $model.fileHandlingExpanded) {
            Toggle(isOn: $model.skipsDuplicates) {
                Text("Don't Import Suspected Duplicates")
                if model.duplicateCount > 0 {
                    Text(model.duplicateCount == 1 ? "1 photo already in library" : "\(model.duplicateCount) photos already in library")
                }
            }
            .tint(switchTint)
            .accessibilityIdentifier("importSkipsDuplicates")
            Toggle(isOn: $model.skipsRejected) {
                Text("Don't Import Rejected Images")
                if model.rejectedCount > 0 {
                    Text(model.rejectedCount == 1 ? "1 photo rated as rejected" : "\(model.rejectedCount) photos rated as rejected")
                }
            }
            .tint(switchTint)
            .accessibilityIdentifier("importSkipsRejected")
            Toggle("Make a Second Copy", isOn: $model.makesSecondCopy)
                .tint(switchTint)
                .disabled(model.effectiveTransfer == .add)
                .help(model.effectiveTransfer == .add ? "Only when copying" : "Also copies each photo to a backup folder")
                .accessibilityIdentifier("importSecondCopy")
            if model.makesSecondCopy, model.effectiveTransfer == .copy {
                folderRow("Copy To", url: model.secondCopy, placeholder: "Choose a folder") { model.onChooseSecondCopy?() }
                    .accessibilityIdentifier("importSecondCopyFolder")
            }
            Toggle("Add to Collection", isOn: $model.addsToCollection)
                .tint(switchTint)
                .accessibilityIdentifier("importAddsToCollection")
            if model.addsToCollection {
                Picker("Collection", selection: $model.collectionID) {
                    Text("New Collection").tag(UUID?.none)
                    if !model.collections.isEmpty { Divider() }
                    ForEach(model.collections, id: \.id) { collection in
                        Text(collection.path).tag(Optional(collection.id))
                    }
                }
                .accessibilityIdentifier("importCollection")
                if model.collectionID == nil {
                    TextField("Name", text: $model.newCollectionName, prompt: Text("Import \(Date().formatted(.iso8601.year().month().day()))"))
                        .accessibilityIdentifier("importNewCollectionName")
                }
            }
        } header: {
            Text("File Handling")
        }
    }

    // MARK: File Renaming

    private var fileRenaming: some View {
        Section(isExpanded: $model.renamingExpanded) {
            Toggle("Rename Files", isOn: $model.renaming.isOn)
                .tint(switchTint)
                .accessibilityIdentifier("importRenames")
            Group {
                Picker("Template", selection: $model.renaming.template) {
                    ForEach(ImportRenaming.Template.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("importRenameTemplate")
                TextField("Custom Text", text: $model.renaming.customText, prompt: Text("Custom name"))
                    .disabled(!model.renaming.template.usesCustomText)
                    .accessibilityIdentifier("importRenameCustomText")
                TextField("Shoot Name", text: Binding(
                    get: { model.renaming.shootName },
                    set: {
                        model.renaming.shootName = $0
                        model.renaming.shootNameEdited = true
                    }), prompt: Text("Shoot name"))
                    .disabled(!model.renaming.template.usesShootName)
                    .accessibilityIdentifier("importRenameShootName")
                TextField("Start Number", value: $model.renaming.startNumber, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .disabled(!model.renaming.template.usesSequence)
                    .accessibilityIdentifier("importRenameStartNumber")
                Picker("Extensions", selection: $model.renaming.extensionCase) {
                    ForEach(ImportRenaming.ExtensionCase.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("importRenameExtensions")
            }
            .disabled(!model.renaming.isOn)
            LabeledContent("Example") {
                Text(model.renamingExample)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("importRenameExample")
            }
            if model.effectiveTransfer == .add {
                Text("Add leaves photos where they are, so they keep their names.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("File Renaming")
        }
        .disabled(model.effectiveTransfer == .add)
    }

    // MARK: Apply During Import

    private var applyDuringImport: some View {
        Section(isExpanded: $model.applyExpanded) {
            Picker("Develop Settings", selection: $model.developPresetPath) {
                Text("None").tag(String?.none)
                ForEach(model.presetGroups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.presets) { preset in
                            Text(preset.name).tag(Optional(preset.url.path(percentEncoded: false)))
                        }
                    }
                }
            }
            .help("Applied to every photo it suits, as in Develop")
            .accessibilityIdentifier("importDevelopPreset")
            LabeledContent("Metadata") {
                HStack(spacing: 6) {
                    Picker("Metadata", selection: $model.metadataPresetID) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.metadataPresets) { preset in
                            Text(preset.name).tag(Optional(preset.id))
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("importMetadataPreset")
                    Menu {
                        Button("New Preset…") { editingMetadata = MetadataPreset(name: "") }
                        if let preset = model.metadataPreset {
                            Button("Edit “\(preset.name)”…") { editingMetadata = preset }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Metadata presets")
                    .accessibilityIdentifier("importMetadataPresetMenu")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Keywords")
                KeywordTokenField(keywords: $model.keywords, suggestions: model.keywordSuggestions)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("importKeywords")
            }
        } header: {
            Text("Apply During Import")
        }
    }

    // MARK: Destination

    private var destination: some View {
        Section(isExpanded: $model.destinationExpanded) {
            folderRow("Folder", url: model.root, placeholder: "") { model.onChooseRoot?() }
                .accessibilityIdentifier("importChooseDestination")
            Toggle("Into Subfolder", isOn: $model.usesSubfolder)
                .tint(switchTint)
                .accessibilityIdentifier("importIntoSubfolder")
            TextField("Subfolder", text: $model.subfolderName, prompt: Text("Name"))
                .disabled(!model.usesSubfolder)
                .accessibilityIdentifier("importSubfolderName")
            Picker("Organize", selection: $model.organize) {
                ForEach(ImportOrganization.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("importOrganize")
            Picker("Date Format", selection: $model.layout) {
                ForEach(ImportFolderLayout.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(model.organize != .byDate)
            .accessibilityIdentifier("importDateFormat")
            if model.effectiveTransfer == .add {
                Text("Add leaves photos where they are, so they aren't copied to a destination.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Destination")
        }
        .disabled(model.effectiveTransfer == .add)
    }

    private func folderRow(_ title: String, url: URL?, placeholder: String, choose: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(url.map { FileManager.default.displayName(atPath: $0.path(percentEncoded: false)) } ?? placeholder)
                    .foregroundStyle(url == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url?.path(percentEncoded: false) ?? "")
                Button("Choose…", action: choose)
            }
        }
    }
}

/// A token field for keywords, completing from the catalog's keywords as you type.
struct KeywordTokenField: NSViewRepresentable {
    @Binding var keywords: [String]
    var suggestions: [String]

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.placeholderString = "Add keywords"
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",\n")
        field.completionDelay = 0.1
        field.setAccessibilityLabel("Keywords")
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        let current = (field.objectValue as? [String]) ?? []
        if current != keywords { field.objectValue = keywords }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: KeywordTokenField

        init(parent: KeywordTokenField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            update(notification)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            update(notification)
        }

        private func update(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            let tokens = ((field.objectValue as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            let keywords = tokens.filter { !$0.isEmpty }.reduce(into: [String]()) { list, keyword in
                if !list.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) { list.append(keyword) }
            }
            if keywords != parent.keywords { parent.keywords = keywords }
        }

        func tokenField(
            _ tokenField: NSTokenField, completionsForSubstring substring: String, indexOfToken tokenIndex: Int,
            indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
        ) -> [Any]? {
            parent.suggestions.filter { $0.range(of: substring, options: [.caseInsensitive, .anchored]) != nil }.prefix(20).map { $0 }
        }
    }
}

/// Makes or edits a metadata preset (Apply During Import ▸ Metadata).
struct MetadataPresetEditor: View {
    @State var preset: MetadataPreset
    let isNew: Bool
    let onSave: (MetadataPreset) -> Void
    let onDelete: (MetadataPreset) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Metadata Preset" : "Edit Metadata Preset")
                .font(.headline)
            Form {
                TextField("Preset Name", text: $preset.name)
                    .accessibilityIdentifier("metadataPresetName")
                TextField("Creator", text: $preset.creator)
                TextField("Copyright", text: $preset.copyright, prompt: Text("© 2026 Your Name"))
                TextField("Title", text: $preset.title)
                TextField("Caption", text: $preset.caption, axis: .vertical)
                    .lineLimit(2...4)
            }
            Text("Empty fields are left as each photo has them.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                if !isNew {
                    Button("Delete Preset", role: .destructive) {
                        onDelete(preset)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") {
                    onSave(preset)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(preset.name.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("metadataPresetSave")
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// The middle of the import window's top bar: Copy or Add, in the Library/Develop picker's style,
/// with what the choice does under it. Add, where it isn't available (a card or a camera), still
/// takes a click, which says why.
struct ImportTransferBar: View {
    @Bindable var model: ImportOptionsModel

    var body: some View {
        VStack(spacing: 2) {
            CapsulePicker(
                options: ImportTransfer.allCases, selected: model.effectiveTransfer, title: \.title,
                identifier: { "importTransfer.\($0.rawValue)" }, onSelect: { model.transfer = $0 },
                unavailable: model.addUnavailableReason.map { [.add: $0] } ?? [:])
            Text(model.transfer == .add ? model.addUnavailableReason ?? model.effectiveTransfer.explanation
                                        : model.effectiveTransfer.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .disabled(model.isLocked)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("importTransfer")
    }
}
