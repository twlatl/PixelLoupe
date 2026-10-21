import AppKit
import Testing
@testable import PixelLoupe

@Suite("Library Filter presets")
struct FilterPresetTests {
    private func preset(_ name: String) throws -> FilterPreset {
        try #require(FilterPreset.builtIn.first { $0.name == name })
    }

    @Test func builtInPresetsSetTheirModesAndKeepTheRest() throws {
        var filter = LibraryFilter()
        filter.text.query = "canon"
        filter.apply(try preset("Flagged"))
        #expect(filter.modes == [.attribute] && filter.attributes.flags == [.picked])
        #expect(filter.text.query == "canon", "the Text mode is off but keeps its search")

        filter.apply(try preset("Exposure Info"))
        #expect(filter.modes == [.metadata])
        #expect(filter.metadata.columns.map(\.kind) == [.focalLength, .shutterSpeed, .aperture, .iso])
        #expect(filter.attributes.flags == [.picked], "Attribute is off but keeps its flags")

        filter.apply(try preset("Filters Off"))
        #expect(filter.modes.isEmpty && !filter.isFiltering)
    }

    @Test func theBarNamesThePresetTheFilterMatches() throws {
        let presets = FilterPresets(defaults: try #require(UserDefaults(suiteName: "FilterPresetTests.\(UUID())")))
        var filter = LibraryFilter()
        filter.text.query = "nikon"
        filter.modes = []
        #expect(presets.preset(matching: filter.criteria)?.name == "Filters Off", "what an off mode was set to doesn't count")
        filter.apply(try preset("Rated"))
        #expect(presets.preset(matching: filter.criteria)?.name == "Rated")
        filter.attributes.rating = 2
        #expect(presets.preset(matching: filter.criteria) == nil)
    }

    @Test func customPresetsSaveRenameAndDelete() throws {
        let suite = "FilterPresetTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let presets = FilterPresets(defaults: defaults)
        var criteria = LibraryFilter.Criteria()
        criteria.modes = [.text]
        criteria.text.query = "landscape"
        presets.save(criteria, as: "Landscapes")
        #expect(FilterPresets(defaults: defaults).custom == [FilterPreset(name: "Landscapes", criteria: criteria)], "saved in the preferences")
        #expect(presets.preset(matching: criteria)?.name == "Landscapes")

        criteria.text.query = "landscape sea"
        presets.save(criteria, as: "landscapes")
        #expect(presets.custom.count == 1 && presets.custom[0].criteria.text.query == "landscape sea", "the same name replaces it")

        presets.save(.init(), as: "Second")
        presets.rename("Second", to: "Landscapes")
        #expect(presets.custom.map(\.name) == ["Landscapes"], "renaming over another replaces it")
        presets.delete("Landscapes")
        #expect(presets.custom.isEmpty)
        #expect(presets.isBuiltIn("flagged") && !presets.isBuiltIn("Mine"))
    }

    @Test func theMenuAppliesPresetsAndOffersToManageTheCurrentOne() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.create(at: directory.url.appending(path: "P.pixelloupe", directoryHint: .isDirectory), info: Fixtures.referencedInfo)
        let controller = CatalogWindowController(store: store)
        defer { controller.close(); FilterPresets.shared.delete("Mine") }
        controller.showWindow(nil)
        let popUp = try #require(controller.window?.contentView?.descendants.first { $0.accessibilityIdentifier() == "filterPresets" } as? NSPopUpButton)
        let menu = try #require(popUp.menu)
        #expect(popUp.itemTitle(at: 0) == "Filters Off")

        menu.delegate?.menuNeedsUpdate?(menu)
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Flagged"))
        #expect(controller.state.filter.modes == [.attribute] && controller.state.filter.attributes.flags == [.picked])
        #expect(popUp.itemTitle(at: 0) == "Flagged")

        controller.state.filter.attributes.rating = 4
        #expect(popUp.itemTitle(at: 0) == "Custom Filter")
        FilterPresets.shared.save(controller.state.filter.criteria, as: "Mine")
        #expect(popUp.itemTitle(at: 0) == "Mine")
        menu.delegate?.menuNeedsUpdate?(menu)
        #expect(menu.items.map(\.title).contains("Delete Preset \u{201C}Mine\u{201D}"))
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Delete Preset \u{201C}Mine\u{201D}"))
        #expect(FilterPresets.shared.custom.isEmpty && popUp.itemTitle(at: 0) == "Custom Filter")
    }
}
