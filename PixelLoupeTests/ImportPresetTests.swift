import AppKit
import Testing
@testable import PixelLoupe

/// The import window's Import Presets (RAW-83).
@Suite("Import presets", .serialized)
struct ImportPresetTests {
    private func settings(_ layout: ImportFolderLayout, renames: Bool = false) -> ImportSettings {
        ImportSettings(
            transfer: .copy, destination: .init(root: URL(filePath: "/Pictures"), subfolder: "Trip", layout: layout),
            handling: ImportHandling(skipsRejected: true, renaming: ImportRenaming(isOn: renames, template: .dateSequence)))
    }

    @Test func presetsAreSavedByNameAndChosenPerCatalog() throws {
        let defaults = try #require(UserDefaults(suiteName: "ImportPresetTests.store"))
        defer { defaults.removePersistentDomain(forName: "ImportPresetTests.store") }
        let b = ImportPreset(name: "Weddings", settings: settings(.date))
        let a = ImportPreset(name: "Travel", settings: settings(.yearAndDate))
        ImportPreset.save([b, a], in: defaults)
        #expect(ImportPreset.all(in: defaults).map(\.name) == ["Travel", "Weddings"])

        let catalog = URL(filePath: "/Catalogs/A.pixelloupe")
        ImportPreset.setChosen(a.id, for: catalog, in: defaults)
        #expect(ImportPreset.chosen(for: catalog, in: defaults) == a.id)
        #expect(ImportPreset.chosen(for: URL(filePath: "/Catalogs/B.pixelloupe"), in: defaults) == nil)
        ImportPreset.save([b], in: defaults)
        #expect(ImportPreset.chosen(for: catalog, in: defaults) == nil, "a deleted preset isn't chosen")
    }

    @Test func applyingAPresetIsOneChangeAndKeepsKeywords() {
        let model = ImportOptionsModel(settings: settings(.date))
        model.keywords = ["Family"]
        var changes = 0
        model.onChange = { changes += 1 }
        let preset = settings(.yearMonthDay, renames: true)
        model.apply(preset)
        #expect(changes == 1)
        #expect(model.settings == preset)
        #expect(model.keywords == ["Family"], "keywords aren't part of a preset")
    }

    @Test func windowMarksAnEditedPresetAndUpdatesIt() throws {
        let directory = try TemporaryDirectory()
        let info = Fixtures.managedInfo(storage: try directory.subdirectory("Storage"))
        let catalog = directory.url.appending(path: "Test.pixelloupe")
        let store = try CatalogStore.inMemory(info: info, packageURL: catalog)
        let preset = ImportPreset(name: "Travel", settings: settings(.yearAndDate))
        ImportPreset.save([preset])
        defer { ImportPreset.save([]) }

        let controller = ImportWindowController(service: ImportService(store: store), catalogURL: catalog, info: info)
        defer { controller.close() }
        let popUp = try #require(controller.window?.contentView?.descendant(identifier: "importPreset") as? NSPopUpButton)
        #expect(popUp.titleOfSelectedItem == "None")
        func click(_ title: String) throws {
            let item = try #require(popUp.menu?.items.first { $0.title.hasPrefix(title) })
            #expect(item.isEnabled, "\(title) is enabled")
            NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        }
        try click("Travel")
        #expect(popUp.titleOfSelectedItem == "Travel")
        #expect(ImportPreset.chosen(for: catalog) == preset.id)

        // Changing a choice marks it edited, and Update saves the change.
        let updateTitle = "Update Preset “Travel”"
        #expect(popUp.menu?.item(withTitle: updateTitle)?.isEnabled == false)
        let options = controller.options
        options.layout = .date
        #expect(popUp.titleOfSelectedItem == "Travel (edited)")
        try click(updateTitle)
        #expect(popUp.titleOfSelectedItem == "Travel")
        #expect(ImportPreset.all().first?.settings.destination.layout == .date)

        try click("None")
        #expect(ImportPreset.chosen(for: catalog) == nil)
    }
}

private extension NSView {
    func descendant(identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier { return self }
        for subview in subviews {
            if let match = subview.descendant(identifier: identifier) { return match }
        }
        return nil
    }
}
