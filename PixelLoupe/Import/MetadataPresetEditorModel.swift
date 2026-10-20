import Foundation
import Observation

/// What the metadata preset editor shows and changes: the saved presets, and the one being edited
/// (its name, each field's value and whether it's checked).
@Observable
final class MetadataPresetEditorModel {
    /// The saved presets, in the order they were made.
    private(set) var presets: [MetadataPreset]
    /// The preset being edited, or `nil` for a new one.
    private(set) var editingID: UUID?
    var name = ""
    /// What's typed in each field, checked or not.
    private(set) var values: [MetadataField.ID: String] = [:]
    private(set) var checked: Set<MetadataField.ID> = []
    /// Saves the presets (to preferences, through the import window's options).
    private let persist: ([MetadataPreset]) -> Void

    init(presets: [MetadataPreset], editing id: UUID?, persist: @escaping ([MetadataPreset]) -> Void) {
        self.presets = presets
        self.persist = persist
        if let preset = presets.first(where: { $0.id == id }) { load(preset) } else { startNew() }
    }

    var isNew: Bool { editingID == nil }

    /// The edited preset as it would be saved.
    var preset: MetadataPreset {
        var preset = MetadataPreset(id: editingID ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        for id in checked { preset[id] = values[id] ?? "" }
        return preset
    }

    /// Whether there's something to save: a new preset with a name, or a change to a saved one.
    var hasChanges: Bool {
        guard let editingID, let saved = presets.first(where: { $0.id == editingID }) else {
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !checked.isEmpty
        }
        return preset != saved
    }

    var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: Fields

    func value(_ id: MetadataField.ID) -> String { values[id] ?? "" }

    /// Typing in a field checks it, as in Lightroom.
    func setValue(_ value: String, for id: MetadataField.ID) {
        values[id] = value
        checked.insert(id)
    }

    func isChecked(_ id: MetadataField.ID) -> Bool { checked.contains(id) }

    func setChecked(_ isChecked: Bool, _ ids: [MetadataField.ID]) {
        if isChecked { checked.formUnion(ids) } else { checked.subtract(ids) }
    }

    static var allFields: [MetadataField.ID] { MetadataPreset.sections.flatMap { $0.fields.map(\.id) } }

    func checkAll() { checked = Set(Self.allFields) }

    func checkNone() { checked = [] }

    /// Checks the fields that have something typed in them, and only those.
    func checkFilled() {
        checked = Set(Self.allFields.filter { !value($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    // MARK: Presets

    func load(_ preset: MetadataPreset) {
        editingID = preset.id
        name = preset.name
        values = [:]
        checked = []
        for (key, value) in preset.fields {
            guard let id = MetadataField.ID(rawValue: key) else { continue }
            values[id] = value
            checked.insert(id)
        }
    }

    func startNew() {
        editingID = nil
        name = ""
        values = [:]
        checked = []
    }

    /// Saves the edited preset (a new one is added; a saved one is replaced, so renaming keeps its
    /// place) and returns it.
    @discardableResult
    func save() -> MetadataPreset? {
        guard canSave else { return nil }
        let preset = preset
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        persist(presets)
        load(preset)
        return preset
    }

    /// Deletes the edited preset and shows the next one (or a new one when none are left).
    func delete() {
        guard let editingID, let index = presets.firstIndex(where: { $0.id == editingID }) else { return }
        presets.remove(at: index)
        persist(presets)
        if presets.isEmpty { startNew() } else { load(presets[min(index, presets.count - 1)]) }
    }
}
