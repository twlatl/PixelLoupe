import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings ▸ External Editing, laid out like Lightroom's Preferences ▸ External Editing: the
/// primary editor (⌘E), an additional editor (⌥⌘E) with presets, Stack With Original, and how the
/// copies are named.
struct ExternalEditingSettingsView: View {
    @Bindable private var preferences = ExternalEditingPreferences.shared
    @State private var presetAction: PresetAction?
    @State private var presetName = ""

    private enum PresetAction: Identifiable {
        case save, rename(String)

        var id: String {
            switch self {
            case .save: "save"
            case .rename(let name): "rename-\(name)"
            }
        }
    }

    var body: some View {
        Form {
            Section {
                ExternalEditorFields(settings: $preferences.primary, identifier: "primary")
            } header: {
                Text("Primary External Editor (⌘E)")
            }

            Section {
                presetRow
                ExternalEditorFields(settings: $preferences.additional, identifier: "additional")
            } header: {
                Text("Additional External Editor (⌥⌘E)")
            }

            Section {
                Toggle("Stack With Original", isOn: $preferences.stacksWithOriginal)
                    .accessibilityIdentifier("externalStackToggle")
            }

            Section {
                namingRows
            } header: {
                Text("Edit Externally File Naming")
            }
        }
        .formStyle(.grouped)
        // Full height: Settings shows it in a ScrollingSettingsPane, which scrolls it.
        .scrollDisabled(true)
        .frame(width: ScrollingSettingsPane.contentWidth)
        .fixedSize(horizontal: false, vertical: true)
        .alert(alertTitle, isPresented: Binding(get: { presetAction != nil }, set: { if !$0 { presetAction = nil } })) {
            TextField("Preset Name", text: $presetName)
            Button(presetAction.map { if case .save = $0 { "Save" } else { "Rename" } } ?? "Save") { finishPresetAction() }
                .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { presetAction = nil }
        }
    }

    private var alertTitle: String {
        switch presetAction {
        case .rename(let name): "Rename “\(name)”"
        default: "New Preset"
        }
    }

    // MARK: - Presets

    /// The preset the Additional settings match, or Custom; choosing one copies its settings.
    private var presetSelection: Binding<String> {
        Binding(
            get: { preferences.currentPreset?.name ?? "" },
            set: { preferences.applyPreset($0) }
        )
    }

    private var presetRow: some View {
        LabeledContent("Preset:") {
            HStack(spacing: 6) {
                Picker("Preset", selection: presetSelection) {
                    Text("Custom").tag("")
                    if !preferences.presets.isEmpty { Divider() }
                    ForEach(preferences.presets) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("externalPresetPicker")

                Menu {
                    Button("Save Current Settings as New Preset…") {
                        presetName = ""
                        presetAction = .save
                    }
                    if let current = preferences.currentPreset {
                        Button("Rename Preset “\(current.name)”…") {
                            presetName = current.name
                            presetAction = .rename(current.name)
                        }
                        Button("Delete Preset “\(current.name)”") { preferences.deletePreset(current.name) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Preset actions")
                .accessibilityIdentifier("externalPresetActions")
            }
        }
    }

    private func finishPresetAction() {
        switch presetAction {
        case .save: preferences.savePreset(named: presetName)
        case .rename(let name): preferences.renamePreset(name, to: presetName)
        case nil: break
        }
        presetAction = nil
    }

    // MARK: - Naming

    @ViewBuilder private var namingRows: some View {
        LabeledContent("Example:") {
            Text(preferences.naming.example(format: preferences.primary.format))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("externalNamingExample")
        }
        Picker("Template:", selection: $preferences.naming.template) {
            ForEach(ExportSettings.NamingTemplate.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .accessibilityIdentifier("externalNamingTemplate")
        TextField("Custom Text:", text: $preferences.naming.customText)
            .disabled(!preferences.naming.template.usesCustomText)
            .accessibilityIdentifier("externalNamingCustomText")
        TextField("Start Number:", value: $preferences.naming.startNumber, format: .number)
            .disabled(!preferences.naming.template.usesStartNumber)
            .accessibilityIdentifier("externalNamingStartNumber")
    }
}

/// An editor's application and file options, shared by Settings and the Edit Photo sheet.
struct ExternalEditorFields: View {
    @Binding var settings: ExternalEditorSettings
    /// Prefix for accessibility identifiers.
    let identifier: String
    var showsApplication = true

    var body: some View {
        if showsApplication {
            ExternalApplicationRow(path: $settings.applicationPath, identifier: identifier)
        }
        Picker("File Format:", selection: $settings.format) {
            ForEach(ExternalEditorSettings.Format.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .accessibilityIdentifier("\(identifier)FormatPicker")
        Picker("Color Space:", selection: $settings.colorSpace) {
            ForEach(ExportSettings.ColorSpace.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .accessibilityIdentifier("\(identifier)ColorSpacePicker")
        Picker("Bit Depth:", selection: $settings.bitDepth) {
            Text("8 bits/component").tag(8)
            Text("16 bits/component").tag(16)
        }
        .accessibilityIdentifier("\(identifier)BitDepthPicker")
        LabeledContent("Resolution:") {
            HStack(spacing: 6) {
                TextField("Resolution", value: $settings.resolution, format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .accessibilityLabel("Resolution")
                    .accessibilityIdentifier("\(identifier)ResolutionField")
                Text("pixels per inch").foregroundStyle(.secondary)
            }
        }
        Picker("Compression:", selection: $settings.compression) {
            ForEach(ExportSettings.TIFFCompression.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        // ImageIO writes PSD files uncompressed.
        .disabled(settings.format != .tiff)
        .accessibilityIdentifier("\(identifier)CompressionPicker")
    }
}

/// Application: the app's icon and name, or "Not specified", with Choose… and Clear.
struct ExternalApplicationRow: View {
    @Binding var path: String?
    let identifier: String

    var body: some View {
        LabeledContent("Application:") {
            HStack(spacing: 6) {
                if let path {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text(FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: ""))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("\(identifier)ApplicationName")
                } else {
                    Text("Not specified")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("\(identifier)ApplicationName")
                }
                Spacer(minLength: 8)
                Button("Choose…") {
                    ExternalApplicationChooser.choose(current: path) { path = $0 }
                }
                .accessibilityIdentifier("\(identifier)ChooseApplication")
                Button("Clear") { path = nil }
                    .disabled(path == nil)
                    .accessibilityIdentifier("\(identifier)ClearApplication")
            }
        }
    }
}

/// The open panel for picking an editor, starting in /Applications (as in Export's Post-Processing).
enum ExternalApplicationChooser {
    static func choose(current: String?, attachedTo window: NSWindow? = nil, completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.directoryURL = current.map { URL(filePath: $0).deletingLastPathComponent() } ?? URL.applicationDirectory
        panel.prompt = "Choose"
        panel.message = "Choose an application to edit photos in."
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { completion(url.path(percentEncoded: false)) }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }
}
