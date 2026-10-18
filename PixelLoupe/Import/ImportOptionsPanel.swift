import AppKit
import Observation
import SwiftUI

/// The import window's choices that the right panel and the top bar edit together.
@Observable
final class ImportOptionsModel {
    var transfer: ImportTransfer { didSet { changed() } }
    var root: URL { didSet { changed() } }
    var usesSubfolder: Bool { didSet { changed() } }
    var subfolderName: String { didSet { changed() } }
    var layout: ImportFolderLayout { didSet { changed() } }
    /// Why Add can't be used for the current source (a memory card), or `nil` when it can.
    var addUnavailableReason: String? { didSet { if addUnavailableReason != oldValue { changed() } } }

    /// What the import will do: the chosen transfer, unless Add isn't available for this source, when
    /// it copies (without forgetting that Add was chosen, for the next source).
    var effectiveTransfer: ImportTransfer {
        addUnavailableReason == nil ? transfer : .copy
    }
    var destinationExpanded = true

    /// Called after any choice changes.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Called by Choose… to pick the destination folder.
    @ObservationIgnored var onChooseRoot: (() -> Void)?

    init(settings: ImportSettings) {
        transfer = settings.transfer
        root = settings.destination.root
        usesSubfolder = settings.destination.subfolder != nil
        subfolderName = settings.destination.subfolder ?? ""
        layout = settings.destination.layout
    }

    var settings: ImportSettings {
        ImportSettings(transfer: transfer, destination: destination)
    }

    var destination: ImportDestination {
        ImportDestination(root: root, subfolder: usesSubfolder ? subfolderName : nil, layout: layout)
    }

    private func changed() {
        onChange?()
    }
}

/// The right panel. File Handling, File Renaming and Apply During Import join Destination in later
/// parts of the import work (RAW-80, RAW-82).
struct ImportOptionsPanel: View {
    @Bindable var model: ImportOptionsModel

    var body: some View {
        Form {
            Section(isExpanded: $model.destinationExpanded) {
                LabeledContent("Folder") {
                    HStack(spacing: 6) {
                        Text(FileManager.default.displayName(atPath: model.root.path(percentEncoded: false)))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.root.path(percentEncoded: false))
                        Button("Choose…") { model.onChooseRoot?() }
                            .accessibilityIdentifier("importChooseDestination")
                    }
                }
                Toggle("Into Subfolder", isOn: $model.usesSubfolder)
                    // Switches follow Monochrome Mode, like the rest of the window. (Only switches: a tint
                    // on buttons and pop-ups would make them look disabled.)
                    .tint(AppSettings.shared.isMonochrome ? Color(nsColor: Accent.monochrome) : .accentColor)
                    .accessibilityIdentifier("importIntoSubfolder")
                TextField("Subfolder", text: $model.subfolderName, prompt: Text("Name"))
                    .disabled(!model.usesSubfolder)
                    .accessibilityIdentifier("importSubfolderName")
                Picker("Organize", selection: $model.layout) {
                    ForEach(ImportFolderLayout.allCases, id: \.self) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .accessibilityIdentifier("importOrganize")
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
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

/// The middle of the import window's top bar: Copy or Add, in the Library/Develop picker's style,
/// with what the choice does under it.
struct ImportTransferBar: View {
    @Bindable var model: ImportOptionsModel

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
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
            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("importTransfer")
    }
}
