import SwiftUI

/// Makes and edits metadata presets (Apply During Import ▸ Metadata ▸ New… / Edit Presets…), laid
/// out like Lightroom's: sections of fields, each with a checkbox saying whether the preset sets it.
struct MetadataPresetEditor: View {
    @State var model: MetadataPresetEditorModel
    /// Called with the preset that was saved last (to choose it), when the sheet closes.
    let onClose: (MetadataPreset?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var collapsed: Set<String> = []
    @State private var lastSaved: MetadataPreset?
    /// A preset chosen in the Preset pop-up while there were unsaved changes.
    @State private var pendingChoice: Choice?
    @State private var isConfirmingDelete = false

    private enum Choice: Hashable {
        case preset(UUID)
        case new
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Preset Name:").gridColumnAlignment(.trailing)
                    TextField("Preset Name", text: $model.name, prompt: Text("Untitled Preset"))
                        .labelsHidden()
                        .accessibilityIdentifier("metadataPresetName")
                }
                GridRow {
                    Text("Preset:")
                    Picker("Preset", selection: choice) {
                        ForEach(model.presets) { preset in
                            Text(preset.name).tag(Choice.preset(preset.id))
                        }
                        if !model.presets.isEmpty { Divider() }
                        Text("New Preset").tag(Choice.new)
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("metadataPresetChoice")
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(MetadataPreset.sections) { section in
                        sectionView(section)
                        Divider()
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(.rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

            HStack {
                Button("Check All") { model.checkAll() }
                Button("Check None") { model.checkNone() }
                Button("Check Filled") { model.checkFilled() }
                Spacer()
                if !model.isNew {
                    Button("Delete Preset…", role: .destructive) { isConfirmingDelete = true }
                        .accessibilityIdentifier("metadataPresetDelete")
                }
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button(model.isNew ? "Create" : "Save") {
                    lastSaved = model.save()
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
                .accessibilityIdentifier("metadataPresetSave")
            }
        }
        .padding(16)
        .frame(width: 640, height: 720)
        .alert("Save changes to “\(model.name)”?", isPresented: isAskingToSave, presenting: pendingChoice) { choice in
            Button("Save") {
                lastSaved = model.save() ?? lastSaved
                show(choice)
            }
            .disabled(!model.canSave)
            Button("Don’t Save", role: .destructive) { show(choice) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your changes will be lost if you don’t save them.")
        }
        .alert("Delete the preset “\(model.name)”?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) { model.delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Photos it was applied to keep their metadata.")
        }
    }

    // MARK: Sections

    private func sectionView(_ section: MetadataPreset.Section) -> some View {
        let ids = section.fields.map(\.id)
        let isExpanded = !collapsed.contains(section.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button {
                    if isExpanded { collapsed.insert(section.id) } else { collapsed.remove(section.id) }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse \(section.title)" : "Expand \(section.title)")
                Toggle(sources: ids.map { id in checkedBinding(id) }, isOn: \.self) {
                    Text(section.title).bold()
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel("Apply \(section.title)")
            }
            if isExpanded {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                    ForEach(section.fields, id: \.id) { field in
                        GridRow {
                            Text(field.label)
                                .gridColumnAlignment(.trailing)
                                .frame(minWidth: 170, alignment: .trailing)
                            control(for: field.id, label: field.label)
                            Toggle(field.label, isOn: checkedBinding(field.id))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .accessibilityLabel("Apply \(field.label)")
                        }
                    }
                }
                .padding(.leading, 6)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func control(for id: MetadataField.ID, label: String) -> some View {
        let text = Binding { model.value(id) } set: { model.setValue($0, for: id) }
        switch MetadataField.field(id).kind {
        case .choice(let options):
            Picker(label, selection: text) {
                ForEach(options, id: \.self) { option in
                    Text(option.isEmpty ? "Unset" : option).tag(option)
                }
                if !options.contains(model.value(id)) { Text("").tag(model.value(id)) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("metadataPresetField.\(id.rawValue)")
        case .multiline(let lines):
            TextField(label, text: text, prompt: Text(""), axis: .vertical)
                .lineLimit(lines...lines + 2)
                .labelsHidden()
                .accessibilityIdentifier("metadataPresetField.\(id.rawValue)")
        default:
            TextField(label, text: text, prompt: Text(""))
                .labelsHidden()
                .accessibilityIdentifier("metadataPresetField.\(id.rawValue)")
        }
    }

    private func checkedBinding(_ id: MetadataField.ID) -> Binding<Bool> {
        Binding { model.isChecked(id) } set: { model.setChecked($0, [id]) }
    }

    // MARK: Switching and closing

    private var choice: Binding<Choice> {
        Binding {
            model.editingID.map(Choice.preset) ?? .new
        } set: { choice in
            if model.hasChanges { pendingChoice = choice } else { show(choice) }
        }
    }

    private var isAskingToSave: Binding<Bool> {
        Binding { pendingChoice != nil } set: { if !$0 { pendingChoice = nil } }
    }

    private func show(_ choice: Choice) {
        pendingChoice = nil
        switch choice {
        case .preset(let id):
            if let preset = model.presets.first(where: { $0.id == id }) { model.load(preset) }
        case .new:
            model.startNew()
        }
    }

    private func close() {
        onClose(lastSaved)
        dismiss()
    }
}
