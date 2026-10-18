import AppKit
import CoreData
import Testing
@testable import PixelLoupe

@Suite("View buttons") @MainActor
struct ViewModeControlTests {
    @Test func buttonsUseTheViewSymbolsAndKeys() {
        #expect(LibraryView.allCases.map(\.symbolName)
            == ["square.grid.3x3.square", "plus.magnifyingglass", "square.on.square", "square.grid.3x2.fill"])
        #expect(LibraryView.allCases.map(\.key) == ["G", "E", "C", "N"])
        #expect(LibraryView.allCases.map(\.command) == [.showLibrary, .enlarge, .compare, .survey])
        for view in LibraryView.allCases {
            #expect(NSImage(systemSymbolName: view.symbolName, accessibilityDescription: nil) != nil, "\(view.symbolName) exists")
        }
    }

    @Test func followsTheViewAndEnablesWhatCanShow() throws {
        let (store, ids, directory) = try makeSurveyStore()
        _ = (store, directory)
        let state = LibraryState()
        state.photoOrder = ids
        let control = ViewModeControl(state: state)
        #expect(control.selectedSegment == LibraryView.grid.rawValue)
        #expect(!control.isEnabled(forSegment: LibraryView.loupe.rawValue), "nothing selected")
        #expect(!control.isEnabled(forSegment: LibraryView.compare.rawValue))
        #expect(!control.isEnabled(forSegment: LibraryView.survey.rawValue))

        state.selectedPhotoIDs = [ids[0]]
        #expect(control.isEnabled(forSegment: LibraryView.loupe.rawValue))
        #expect(control.isEnabled(forSegment: LibraryView.compare.rawValue), "with the next photo")
        #expect(control.isEnabled(forSegment: LibraryView.survey.rawValue))

        state.presentation = .survey
        #expect(control.selectedSegment == LibraryView.survey.rawValue)
        state.presentation = .fullScreen
        #expect(control.selectedSegment == -1)
    }

    @Test func clickingAButtonSwitchesTheCatalogWindowsView() throws {
        let (store, ids, directory) = try makeSurveyStore()
        _ = directory
        let controller = CatalogWindowController(store: store)
        controller.showWindow(nil)
        defer { controller.close() }
        controller.state.photoOrder = ids
        controller.state.selectedPhotoIDs = [ids[0], ids[1]]
        let control = try #require(controller.window?.contentView?.descendants
            .compactMap { $0 as? ViewModeControl }.first { !$0.isHiddenOrHasHiddenAncestor })
        for (view, presentation) in [(LibraryView.survey, PhotoPresentation.survey), (.loupe, .loupe), (.grid, .grid), (.compare, .compare)] {
            control.selectedSegment = view.rawValue
            control.sendAction(control.action, to: control.target)
            #expect(controller.state.presentation == presentation, "\(view.title) shows \(presentation)")
        }
        #expect(controller.window?.contentView?.descendants.contains { $0.accessibilityIdentifier() == "photoCountLabel" } == false,
                "the photo count is only in the filmstrip")
    }
}
