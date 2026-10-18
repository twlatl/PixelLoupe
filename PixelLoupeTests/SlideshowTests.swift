import AppKit
import CoreData
import Testing
@testable import PixelLoupe

@Suite("Slideshow playlist")
struct SlideshowPlaylistTests {
    let order = ["a", "b", "c", "d"]

    @Test func severalSelectedPlayOnlyThoseFromTheActiveOne() {
        let playlist = SlideshowPlaylist.make(selection: ["c", "a"], order: order)
        #expect(playlist?.photos == ["a", "c"], "in grid order")
        #expect(playlist?.start == 1, "starting at the active photo")
    }

    @Test func oneOrNoneSelectedPlaysTheWholeGrid() {
        #expect(SlideshowPlaylist.make(selection: ["c"], order: order).map { [$0.photos.joined(), "\($0.start)"] } == ["abcd", "2"])
        #expect(SlideshowPlaylist.make(selection: [String](), order: order)?.start == 0)
        #expect(SlideshowPlaylist.make(selection: [String](), order: []) == nil)
    }

    @Test func steppingWrapsAround() {
        #expect(SlideshowPlaylist.index(after: 3, by: 1, count: 4) == 0)
        #expect(SlideshowPlaylist.index(after: 0, by: -1, count: 4) == 3)
        #expect(SlideshowPlaylist.index(after: 1, by: 1, count: 4) == 2)
    }
}

@Suite("Slideshow") @MainActor
struct SlideshowTests {
    @Test func playsStepsPausesAndStops() throws {
        let (store, ids, directory) = try makeSurveyStore()
        _ = directory
        let controller = CatalogWindowController(store: store)
        controller.showWindow(nil)
        defer { controller.close() }
        controller.state.photoOrder = ids
        controller.state.selectedPhotoIDs = [ids[2]]
        let presentationOptions = NSApp.presentationOptions

        controller.impromptuSlideshow(nil)
        let slideshow = try #require(controller.slideshowController)
        defer { slideshow.stop() }
        #expect(slideshow.photos == ids)
        #expect(slideshow.currentPhotoID == ids[2], "starts at the selected photo")
        #expect(slideshow.window?.isVisible == true)
        #expect(slideshow.window?.frame == controller.window?.screen?.frame, "covers the main window's display")

        slideshow.advance()
        #expect(slideshow.currentPhotoID == ids[3])
        slideshow.step(by: 1)
        #expect(slideshow.currentPhotoID == ids[0], "wraps around")
        slideshow.step(by: -1)
        #expect(slideshow.currentPhotoID == ids[3])
        slideshow.togglePause()
        #expect(slideshow.isPaused)
        #expect(controller.state.selectedPhotoIDs == [ids[2]], "playing doesn't change the selection")

        let item = NSMenuItem(title: "", action: #selector(CatalogWindowController.impromptuSlideshow(_:)), keyEquivalent: "")
        #expect(controller.validateUserInterfaceItem(item))
        #expect(item.title == "Stop Slideshow")

        controller.impromptuSlideshow(nil)
        #expect(controller.slideshowController == nil)
        #expect(slideshow.window?.isVisible == false)
        #expect(NSApp.presentationOptions == presentationOptions, "the menu bar and Dock come back")
        #expect(controller.validateUserInterfaceItem(item))
        #expect(item.title == "Impromptu Slideshow")
    }

    @Test func menusHaveLightroomsShortcuts() throws {
        let menu = SecondaryDisplayMenu.make(header: false)
        let secondary = try #require(menu.items.first { $0.action == #selector(PixelLoupeActions.toggleSecondarySlideshow(_:)) })
        #expect(secondary.keyEquivalent == "\r" && secondary.keyEquivalentModifierMask == [.option, .shift, .command])
        let main = try #require(MainMenu.make().items.compactMap(\.submenu)
            .flatMap(\.items).first { $0.action == #selector(PixelLoupeActions.impromptuSlideshow(_:)) })
        #expect(main.keyEquivalent == "\r" && main.keyEquivalentModifierMask == [.command])
    }

    @Test func nothingToPlayInAnEmptyFolder() throws {
        let (store, _, directory) = try makeSurveyStore(0)
        _ = directory
        let controller = CatalogWindowController(store: store)
        defer { controller.close() }
        controller.state.photoOrder = []
        controller.impromptuSlideshow(nil)
        #expect(controller.slideshowController == nil)
    }
}
