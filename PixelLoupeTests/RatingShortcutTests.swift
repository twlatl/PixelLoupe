import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Rating and flag shortcuts")
@MainActor
struct RatingShortcutTests {
    @Test func theMenusShowTheKeys() throws {
        let photo = try #require(MainMenu.make().items.first { $0.submenu?.title == "Photo" }?.submenu)
        let rating = try #require(photo.items.first { $0.title == "Set Rating" }?.submenu)
        let keyed = rating.items.filter { !$0.isSeparatorItem }
        #expect(keyed.map(\.title) == ["None", "★", "★★", "★★★", "★★★★", "★★★★★", "Decrease Rating", "Increase Rating"])
        #expect(keyed.map(\.keyEquivalent) == ["0", "1", "2", "3", "4", "5", "[", "]"])
        #expect(keyed.allSatisfy { $0.keyEquivalentModifierMask.isEmpty }, "single keys, as in Lightroom")
        #expect(rating.items[6].isSeparatorItem, "Decrease and Increase sit right below the stars")
        let flag = try #require(photo.items.first { $0.title == "Set Flag" }?.submenu)
        #expect(flag.items.map(\.title) == ["Flagged", "Unflagged", "Rejected"])
        #expect(flag.items.map(\.keyEquivalent) == ["p", "u", "x"])
    }

    @Test func theRightClickMenuShowsThemToo() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let photo = Photo(context: store.viewContext)
        photo.id = UUID()
        photo.fileName = "IMG.jpg"
        photo.captureDate = Date()
        photo.importDate = Date()
        photo.editDate = Date()
        photo.rating = 2
        try store.viewContext.save()
        let controller = CatalogWindowController(store: store)
        controller.showWindow(nil)
        defer { controller.close() }
        controller.state.selectedPhotoIDs = [photo.objectID]
        let grid = controller.rootViewController.main.library.grid
        let menu = grid.contextMenu()
        let rating = try #require(menu.items.first { $0.title == "Rating" }?.submenu)
        #expect(rating.items.filter { !$0.isSeparatorItem }.map(\.keyEquivalent) == ["0", "1", "2", "3", "4", "5", "[", "]"])
        #expect(rating.items.first { $0.title == "★★" }?.state == .on)
        let flags = menu.items.filter { $0.action == #selector(GridViewController.setFlagFromMenu(_:)) }
        #expect(flags.map(\.title) == ["Flagged", "Unflagged", "Rejected"] && flags.map(\.keyEquivalent) == ["p", "u", "x"])

        // Increase Rating from the right-click menu.
        let increase = try #require(rating.items.first { $0.title == "Increase Rating" })
        #expect(grid.validateMenuItem(increase))
        _ = (increase.target as AnyObject).perform(increase.action, with: increase)
        #expect(photo.rating == 3)
    }

    @Test func bracketsStepEachPhotosRating() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        var photos: [Photo] = []
        for (index, stars) in [0, 3, 5].enumerated() {
            let photo = Photo(context: store.viewContext)
            photo.id = UUID()
            photo.fileName = "IMG_\(index).jpg"
            photo.captureDate = Date(timeIntervalSince1970: Double(index))
            photo.importDate = Date()
            photo.editDate = Date()
            photo.rating = Int16(stars)
            photos.append(photo)
        }
        try store.viewContext.save()
        let controller = CatalogWindowController(store: store)
        controller.showWindow(nil)
        defer { controller.close() }
        func press(_ key: String) -> Bool {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
            return KeyCommand(event: event).map { controller.perform($0) } ?? false
        }
        #expect(KeyCommand.adjustRating(1) != KeyCommand.adjustRating(-1))
        controller.state.selectedPhotoIDs = []
        #expect(!press("]"), "nothing selected: the key isn't taken")

        controller.state.selectedPhotoIDs = photos.map(\.objectID)
        #expect(press("]"))
        #expect(photos.map(\.rating) == [1, 4, 5], "each photo up one star, no higher than five")
        #expect(press("["))
        #expect(press("["))
        #expect(photos.map(\.rating) == [0, 2, 3], "and down, no lower than none")
        #expect(store.viewContext.undoManager?.undoActionName == "Decrease Rating")

        // P, U and X still flag.
        #expect(press("p"))
        #expect(photos.allSatisfy { $0.photoFlag == .picked })
        #expect(press("x"))
        #expect(photos.allSatisfy { $0.photoFlag == .rejected })
        #expect(press("u"))
        #expect(photos.allSatisfy { $0.photoFlag == .unflagged })
    }
}
