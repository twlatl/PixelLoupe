import Foundation
import Testing
@testable import PixelLoupe

/// Metadata presets shared by the import window and the Library (RAW-88).
@Suite(.serialized)
@MainActor
struct MetadataPresetTests {
    /// An empty preferences domain of its own (one for the suite, emptied for each test).
    private func defaults() -> UserDefaults {
        let suite = "net.pixegen.PixelLoupe.UnitTests.MetadataPresets"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    @Test func presetsSavedByTheImportWindowBeforeStillLoad() throws {
        // As RAW-80 (#71) saved them: creator, copyright, title and caption, where empty meant "leave it".
        let defaults = defaults()
        let id = UUID()
        let old = #"[{"id":"\#(id.uuidString)","name":"Me","creator":"Ted Lee","copyright":"© 2026 Ted Lee","title":"","caption":"  "}]"#
        defaults.set(Data(old.utf8), forKey: MetadataPreset.legacyKey)

        let presets = MetadataPreset.all(in: defaults)
        #expect(presets.count == 1)
        #expect(presets[0].id == id, "the import window's remembered choice still points at it")
        #expect(presets[0].name == "Me")
        #expect(presets[0].fields == ["creator": "Ted Lee", "copyright": "© 2026 Ted Lee"], "only the filled-in fields are checked")
        #expect(defaults.data(forKey: MetadataPreset.storageKey) != nil, "saved in the new form")
    }

    @Test func presetsSavedByTheLibraryBeforeStillLoad() {
        let defaults = defaults()
        defaults.set(["Studio": ["creator": "Ted", "city": "Boston", "bogus": "x"], "Agency": ["copyright": "©"]],
                     forKey: MetadataPreset.legacyKey)
        let presets = MetadataPreset.all(in: defaults)
        #expect(presets.map(\.name) == ["Agency", "Studio"])
        #expect(presets[1].fields == ["creator": "Ted", "city": "Boston"], "fields PixelLoupe doesn't know are dropped")
    }

    @Test func savingRenamingAndDeletingPresets() {
        let defaults = defaults()
        var persisted: [MetadataPreset] = []
        let persist: ([MetadataPreset]) -> Void = { persisted = $0; MetadataPreset.save($0, in: defaults) }

        // New…: a name and two fields.
        let editor = MetadataPresetEditorModel(presets: [], editing: nil, persist: persist)
        #expect(editor.isNew && !editor.canSave)
        editor.name = "Me"
        editor.setValue("Ted Lee", for: .creator)
        editor.setValue("© 2026 Ted Lee", for: .copyright)
        #expect(editor.isChecked(.creator), "typing in a field checks it")
        let me = try! #require(editor.save())
        #expect(!editor.isNew && !editor.hasChanges)
        #expect(MetadataPreset.all(in: defaults) == [me])

        // A second one, then rename the first: it keeps its place and ID.
        editor.startNew()
        editor.name = "Travel"
        editor.setValue("Paris", for: .city)
        let travel = try! #require(editor.save())
        editor.load(me)
        editor.name = "Ted"
        #expect(editor.hasChanges)
        editor.save()
        #expect(persisted.map(\.name) == ["Ted", "Travel"] && persisted[0].id == me.id)

        // Unchecking a field leaves it out of the preset, though it's still typed.
        editor.setChecked(false, [.copyright])
        #expect(editor.value(.copyright) == "© 2026 Ted Lee")
        editor.save()
        #expect(persisted[0].fields == ["creator": "Ted Lee"])

        // Delete shows the next preset.
        editor.delete()
        #expect(persisted.map(\.id) == [travel.id])
        #expect(editor.editingID == travel.id && editor.name == "Travel")
        editor.delete()
        #expect(persisted.isEmpty && editor.isNew)
    }

    @Test func checkAllNoneAndFilled() {
        let editor = MetadataPresetEditorModel(presets: [], editing: nil, persist: { _ in })
        editor.setValue("Ted", for: .creator)
        editor.setValue("", for: .city)
        editor.checkAll()
        #expect(editor.preset.fields.count == MetadataPresetEditorModel.allFields.count)
        editor.checkNone()
        #expect(editor.preset.fields.isEmpty)
        editor.checkFilled()
        #expect(editor.preset.fields == ["creator": "Ted"])
    }

    @Test func everyFieldInTheEditorCanBeStoredAndShown() {
        let fields = MetadataPresetEditorModel.allFields
        #expect(Set(fields).count == fields.count, "no field twice")
        #expect(fields.allSatisfy { MetadataField.field($0).isEditable })
    }

    @Test func theImportWindowForgetsADeletedChoice() {
        let saved = Defaults.store.object(forKey: MetadataPreset.storageKey)
        defer { Defaults.store.set(saved, forKey: MetadataPreset.storageKey) }
        let me = MetadataPreset(name: "Me", fields: [.creator: "Ted"])
        let model = ImportOptionsModel(settings: .defaults(for: Fixtures.referencedInfo))
        model.saveMetadataPresets([me])
        model.metadataPresetID = me.id
        #expect(model.extras.metadata == me)
        let editor = model.metadataEditor(forNew: false)
        #expect(editor.editingID == me.id, "Edit Presets… opens on the chosen preset")
        editor.delete()
        #expect(model.metadataPresetID == nil && model.metadataPresets.isEmpty)
    }
}
