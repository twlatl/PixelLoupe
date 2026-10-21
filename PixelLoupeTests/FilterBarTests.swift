import AppKit
import CoreData
import Testing
@testable import PixelLoupe

@Suite("Library Filter modes")
struct FilterModeTests {
    @Test func aClickShowsJustThatModeAndShiftClickCombines() {
        typealias Mode = LibraryFilter.Mode
        #expect(Mode.modes(afterClicking: .text, in: [], extending: false) == [.text])
        #expect(Mode.modes(afterClicking: .attribute, in: [.text, .metadata], extending: false) == [.attribute])
        #expect(Mode.modes(afterClicking: .text, in: [.text], extending: false) == [], "clicking the only mode turns it off")
        #expect(Mode.modes(afterClicking: .text, in: [.text, .attribute], extending: false) == [.text])
        #expect(Mode.modes(afterClicking: .metadata, in: [.text], extending: true) == [.text, .metadata])
        #expect(Mode.modes(afterClicking: .text, in: [.text, .metadata], extending: true) == [.metadata])
        #expect(Mode.modes(afterClicking: nil, in: [.text, .attribute], extending: false) == [], "None")
        #expect(Mode.modes(afterClicking: nil, in: [.text], extending: true) == [])
    }

    @Test func settingCriteriaTurnsTheirModeOn() {
        var filter = LibraryFilter()
        filter.attributes.rating = 3
        #expect(filter.modes == [.attribute])
        filter.text.query = "canon"
        filter.metadata.tags = ["Family"]
        #expect(filter.modes == [.text, .attribute, .metadata])

        // Clearing doesn't turn a mode on, or off.
        filter.modes = []
        filter.attributes = .init()
        filter.text.query = "  "
        #expect(filter.modes.isEmpty)
    }

    @Test func aModeThatsOffKeepsItsCriteriaButDoesntFilter() {
        var filter = LibraryFilter()
        filter.attributes.rating = 3
        #expect(filter.isFiltering)
        filter.modes.remove(.attribute)
        #expect(!filter.isFiltering)
        #expect(filter.predicate == filter.scopePredicate)
        #expect(filter.attributes.rating == 3, "the criteria stay for when the mode comes back")
        filter.modes.insert(.attribute)
        #expect(filter.isFiltering)
    }

    @Test func anActiveModeWithNothingSetDoesntFilter() {
        var filter = LibraryFilter()
        filter.modes = [.text, .attribute, .metadata]
        #expect(!filter.isFiltering)
        #expect(filter.predicate?.predicateFormat == "isHiddenInStack == 0")
    }

    @Test func restoringCriteriaKeepsTheirModesExactly() {
        var saved = LibraryFilter.Criteria()
        saved.attributes.flags = [.picked]
        saved.text.query = "nikon"
        saved.modes = [.text]
        var filter = LibraryFilter()
        filter.criteria = saved
        #expect(filter.modes == [.text], "the Attribute criteria don't turn their mode on")
        #expect(filter.criteria == saved)
    }

    @Test func theCatalogSavesTheFilterBar() throws {
        var state = CatalogViewState()
        var criteria = LibraryFilter.Criteria()
        criteria.modes = [.attribute, .metadata]
        criteria.attributes = .init(rating: 2, ratingComparison: .atMost, flags: [.rejected], colorLabels: [.red, .none])
        criteria.text.query = "24-70"
        criteria.metadata.tags = ["Places > Ireland"]
        state.filterCriteria = criteria
        state.isFilterBarVisible = false

        let data = try PropertyListEncoder().encode(state)
        let decoded = try PropertyListDecoder().decode(CatalogViewState.self, from: data)
        #expect(decoded.filterCriteria == criteria)
        #expect(!decoded.isFilterBarVisible)

        // Saved before the filter bar was: shown, with nothing set.
        let old = try PropertyListEncoder().encode(["folderPath": "/Photos"])
        let older = try PropertyListDecoder().decode(CatalogViewState.self, from: old)
        #expect(older.filterCriteria == nil && older.isFilterBarVisible && older.folderPath == "/Photos")
    }
}

@Suite("Library Filter bar")
struct FilterBarWindowTests {
    let directory: TemporaryDirectory
    let packageURL: URL

    init() throws {
        directory = try TemporaryDirectory()
        packageURL = directory.url.appending(path: "Filter.pixelloupe", directoryHint: .isDirectory)
        let store = try CatalogStore.create(at: packageURL, info: Fixtures.referencedInfo)
        let context = store.viewContext
        for (name, rating) in [("a.jpg", 5), ("b.jpg", 3), ("c.jpg", 0)] {
            let photo = Photo(context: context)
            photo.id = UUID()
            photo.fileName = name
            photo.filePath = "/Photos/" + name
            photo.fileType = "JPG"
            photo.rating = Int16(rating)
            photo.cameraMake = "Canon"
            photo.captureDate = .now
            photo.importDate = .now
            photo.editDate = .now
        }
        try context.save()
    }

    private func row(_ mode: LibraryFilter.Mode, in window: NSWindow?) -> NSView? {
        window?.contentView?.descendants.first { $0.accessibilityIdentifier() == "filterRow.\(mode.rawValue)" }
    }

    private func view(_ identifier: String, in window: NSWindow?) -> NSView? {
        window?.contentView?.descendants.first { $0.accessibilityIdentifier() == identifier }
    }

    @Test func backslashHidesTheBarInLibraryAndKeepsTheFilter() throws {
        let controller = CatalogWindowController(store: try CatalogStore.open(at: packageURL))
        defer { controller.close() }
        controller.showWindow(nil)
        let state = controller.state
        let bar = try #require(view("libraryFilter", in: controller.window))
        #expect(state.isFilterBarVisible && !bar.isHidden)

        state.filter.attributes.rating = 3
        #expect(state.photoCount == 2)
        #expect(controller.perform(.beforeAfter(.beforeOnly)), "\\ toggles the bar in Library")
        #expect(!state.isFilterBarVisible && bar.isHidden)
        #expect(state.photoCount == 2, "the hidden bar still filters")
        #expect(state.beforeAfter == nil)

        let info = try #require(view("filmstripInfo", in: controller.window) as? NSTextField)
        #expect(info.stringValue.contains("2 of 3 photos"))
        let filtered = try #require(view("filmstripFiltered", in: controller.window) as? NSButton)
        #expect(!filtered.isHidden)
        filtered.performClick(nil)
        #expect(state.isFilterBarVisible && !bar.isHidden, "the filmstrip's filter icon shows the bar")

        state.filter.modes = []
        #expect(info.stringValue.contains("3 photos") && !info.stringValue.contains(" of "))
        #expect(filtered.isHidden)
    }

    @Test func backslashIsBeforeOnlyInDevelop() throws {
        let controller = CatalogWindowController(store: try CatalogStore.open(at: packageURL))
        defer { controller.close() }
        controller.showWindow(nil)
        let state = controller.state
        state.selectedPhotoIDs = [try #require(state.photoOrder.first)]
        #expect(controller.perform(.showDevelop))
        #expect(controller.perform(.beforeAfter(.beforeOnly)))
        #expect(state.beforeAfter == .beforeOnly && state.isFilterBarVisible)
    }

    @Test func theMenuGivesBackslashToTheCurrentModule() throws {
        let controller = CatalogWindowController(store: try CatalogStore.open(at: packageURL))
        defer { controller.close() }
        controller.showWindow(nil)
        controller.state.selectedPhotoIDs = [try #require(controller.state.photoOrder.first)]
        let view = try #require(MainMenu.make().items.first { $0.title == "View" }?.submenu)
        let filterBar = try #require(view.items.first { $0.action == #selector(PixelLoupeActions.toggleFilterBar(_:)) })
        let beforeOnly = try #require(view.items.first { $0.title == "Before/After" }?.submenu?.items
            .first { $0.tag == BeforeAfterView.beforeOnly.rawValue })

        #expect(controller.validateUserInterfaceItem(filterBar))
        #expect(!controller.validateUserInterfaceItem(beforeOnly))
        #expect(filterBar.title == "Hide Filter Bar" && filterBar.keyEquivalent == "\\" && beforeOnly.keyEquivalent.isEmpty)

        _ = controller.perform(.showDevelop)
        #expect(!controller.validateUserInterfaceItem(filterBar))
        #expect(controller.validateUserInterfaceItem(beforeOnly))
        #expect(filterBar.keyEquivalent.isEmpty && beforeOnly.keyEquivalent == "\\")
    }

    @Test func modeRowsFollowTheModes() throws {
        let controller = CatalogWindowController(store: try CatalogStore.open(at: packageURL))
        defer { controller.close() }
        controller.showWindow(nil)
        let state = controller.state
        let window = controller.window
        #expect(LibraryFilter.Mode.allCases.allSatisfy { row($0, in: window)?.isHidden == true }, "None to start")
        let modes = try #require(view("filterModes", in: window) as? NSSegmentedControl)
        #expect(modes.isSelected(forSegment: 3), "None is selected")

        state.filter.modes = [.text, .metadata]
        #expect(row(.text, in: window)?.isHidden == false && row(.metadata, in: window)?.isHidden == false)
        #expect(row(.attribute, in: window)?.isHidden == true)
        #expect(modes.isSelected(forSegment: 0) && !modes.isSelected(forSegment: 1) && modes.isSelected(forSegment: 2))
        #expect(!modes.isSelected(forSegment: 3))

        // Each row's × clears just its criteria.
        state.filter.text.query = "canon"
        state.filter.attributes.rating = 5
        let clear = try #require(view("clearFilter.text", in: window) as? NSButton)
        clear.performClick(nil)
        #expect(state.filter.text.query.isEmpty && state.filter.attributes.rating == 5)
        #expect(state.filter.modes == [.text, .attribute, .metadata], "the mode stays on")
    }

    @Test func commandFShowsTheTextModeAndFocusesIt() throws {
        let controller = CatalogWindowController(store: try CatalogStore.open(at: packageURL))
        defer { controller.close() }
        controller.showWindow(nil)
        let state = controller.state
        state.isFilterBarVisible = false
        state.filter.modes = [.attribute]
        controller.rootViewController.main.library.focusSearch(nil)
        #expect(state.isFilterBarVisible)
        #expect(state.filter.modes == [.text, .attribute])
        let search = try #require(view("metadataSearch", in: controller.window) as? NSSearchField)
        #expect(controller.window?.firstResponder === search.currentEditor())
    }

    @Test func theBarAndItsCriteriaAreRestoredWhenTheCatalogReopens() throws {
        do {
            let controller = CatalogWindowController(store: try CatalogStore.open(at: packageURL))
            controller.showWindow(nil)
            controller.state.filter.attributes.rating = 5
            controller.state.filter.text.query = "canon"
            controller.state.filter.modes.remove(.text)
            controller.state.isFilterBarVisible = false
            controller.close()
        }
        let controller = CatalogWindowController(store: try CatalogStore.open(at: packageURL))
        defer { controller.close() }
        controller.showWindow(nil)
        #expect(!controller.state.isFilterBarVisible)
        #expect(controller.state.filter.modes == [.attribute])
        #expect(controller.state.filter.attributes.rating == 5 && controller.state.filter.text.query == "canon")
        #expect(controller.state.photoCount == 1)
    }
}
