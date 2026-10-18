import AppKit
import CoreData
import Testing
@testable import PixelLoupe

@Suite("Secondary display")
struct SecondaryDisplayTests {
    private let left = DisplayInfo(id: "L", name: "Studio Display", frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440))
    private let main = DisplayInfo(id: "M", name: "Built-in Retina Display", frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
    private let above = DisplayInfo(id: "A", name: "LG UltraFine", frame: CGRect(x: 0, y: 982, width: 1920, height: 1080))

    @Test func oneDisplayHasNoSecondary() {
        #expect(SecondaryDisplay.target(among: [main], preferred: "M", mainWindowDisplay: "M") == nil)
        #expect(SecondaryDisplay.target(among: [], preferred: nil, mainWindowDisplay: nil) == nil)
    }

    @Test func defaultsToTheFirstDisplayWithoutTheMainWindow() {
        #expect(SecondaryDisplay.target(among: [main, left], preferred: nil, mainWindowDisplay: "M") == left)
        #expect(SecondaryDisplay.target(among: [main, left], preferred: nil, mainWindowDisplay: "L") == main)
        #expect(SecondaryDisplay.target(among: [main, left], preferred: nil, mainWindowDisplay: nil) == main)
    }

    @Test func prefersTheChosenDisplayWhileItsConnected() {
        #expect(SecondaryDisplay.target(among: [main, left, above], preferred: "A", mainWindowDisplay: "M") == above)
        #expect(SecondaryDisplay.target(among: [main, left], preferred: "A", mainWindowDisplay: "M") == left,
                "an unplugged choice falls back to the default")
    }

    @Test func layoutKeepsTheArrangementAndProportions() throws {
        let frames = SecondaryDisplay.layout([main, left, above], in: CGSize(width: 520, height: 220), padding: 10)
        let m = try #require(frames["M"]), l = try #require(frames["L"]), a = try #require(frames["A"])
        // Left of the main display, sharing its bottom edge; the display above sits on top of it.
        #expect(l.maxX == m.minX)
        #expect(abs(l.maxY - m.maxY) < 0.001)
        #expect(abs(a.maxY - m.minY) < 0.001)
        #expect(abs(l.width / l.height - 2560 / 1440) < 0.001)
        // Fits the area, inside the padding.
        let union = [m, l, a].dropFirst().reduce(m) { $0.union($1) }
        #expect(union.minX >= 10 - 0.001 && union.maxX <= 510 + 0.001)
        #expect(union.minY >= 10 - 0.001 && union.maxY <= 210 + 0.001)
    }

    @Test func windowKeepsAFrameThatFitsOtherwiseFillsMostOfTheDisplay() {
        let visible = CGRect(x: -2560, y: 0, width: 2560, height: 1415)
        let inside = CGRect(x: -2000, y: 100, width: 1200, height: 800)
        #expect(SecondaryWindowController.frame(for: inside, on: visible) == inside)
        #expect(SecondaryWindowController.frame(for: .zero, on: visible) == CGRect(x: -2304, y: 142, width: 2048, height: 1132),
                "a window not placed yet fills most of the display")
        let elsewhere = CGRect(x: 100, y: 100, width: 1200, height: 800)
        #expect(SecondaryWindowController.frame(for: elsewhere, on: visible) == CGRect(x: -2304, y: 142, width: 2048, height: 1132))
    }

    @Test func settingsPersist() {
        let suite = "net.pixegen.PixelLoupe.SecondaryDisplayTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SecondaryDisplaySettings(defaults: defaults)
        #expect(settings.preferredDisplayID == nil && !settings.isShown && !settings.isFullScreen && settings.view == .grid)
        settings.preferredDisplayID = "L"
        settings.isShown = true
        settings.isFullScreen = true
        settings.view = .loupe
        let reloaded = SecondaryDisplaySettings(defaults: defaults)
        #expect(reloaded.preferredDisplayID == "L" && reloaded.isShown && reloaded.isFullScreen && reloaded.view == .loupe)
    }

    @Test func shiftKeysPickTheSecondaryView() {
        func event(_ characters: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
        }
        #expect(KeyCommand(event: event("G")) == .secondaryView(.grid))
        #expect(KeyCommand(event: event("E")) == .secondaryView(.loupe))
        #expect(KeyCommand(event: event("C")) == .secondaryView(.compare))
    }
}

@Suite("Displays settings") @MainActor
struct DisplaysSettingsTests {
    @Test func paneUsesTheDisplaySymbol() throws {
        let controller = SettingsWindowController()
        let tabs = try #require(controller.window?.contentViewController as? NSTabViewController)
        let displays = try #require(tabs.tabViewItems.first { $0.label == "Displays" })
        #expect(displays.image != nil)
        tabs.selectedTabViewItemIndex = try #require(tabs.tabViewItems.firstIndex(of: displays))
        #expect((displays.viewController?.view.fittingSize.width ?? 0) >= DisplaysSettingsView.arrangementSize.width)
    }
}

@Suite("Secondary Window menu") @MainActor
struct SecondaryWindowMenuTests {
    @Test func toolbarMenuMatchesTheMockup() {
        let menu = SecondaryDisplayMenu.make(header: true)
        #expect(menu.items.map(\.title) == [
            "Secondary Window:", "Show", "Full Screen", "Show Second Monitor Preview", "",
            "Grid", "Loupe – Normal", "Loupe – Live", "Loupe – Locked", "Compare", "Survey", "", "Slideshow",
        ])
        #expect(menu.items[0].isSectionHeader)
        let f11 = String(Character(UnicodeScalar(NSF11FunctionKey)!))
        #expect(menu.items[1].keyEquivalent == f11 && menu.items[1].keyEquivalentModifierMask == [.command])
        #expect(menu.items[2].keyEquivalent == f11 && menu.items[2].keyEquivalentModifierMask == [.command, .shift])
        #expect(menu.items[3].keyEquivalent.isEmpty)
        #expect(menu.items[5].keyEquivalent == "g" && menu.items[5].keyEquivalentModifierMask == [.shift])
        #expect(menu.items[6].keyEquivalent == "e" && menu.items[6].keyEquivalentModifierMask == [.shift])
        #expect(menu.items[7].keyEquivalent.isEmpty, "Loupe – Live has no shortcut, as in Lightroom")
        #expect(menu.items[8].keyEquivalent == "\r" && menu.items[8].keyEquivalentModifierMask == [.shift, .command])
        #expect(menu.items[9].keyEquivalent == "c" && menu.items[9].keyEquivalentModifierMask == [.shift])
        #expect(menu.items[10].keyEquivalent == "n" && menu.items[10].keyEquivalentModifierMask == [.shift])
        #expect(menu.items[12].keyEquivalent == "\r" && menu.items[12].keyEquivalentModifierMask == [.option, .shift, .command])
        #expect(menu.items[5].representedObject as? String == "grid")
    }

    @Test func windowMenuHasSecondaryDisplay() throws {
        let window = try #require(MainMenu.make().items.first { $0.title == "Window" }?.submenu)
        let secondary = try #require(window.items.first { $0.title == "Secondary Display" }?.submenu)
        #expect(secondary.items.first?.title == "Show", "no header in the Window menu")
        #expect(secondary.items.contains { $0.action == #selector(PixelLoupeActions.showSecondaryView(_:)) })
    }
}

@Suite("Secondary window") @MainActor
struct SecondaryWindowTests {
    private func makeStore() throws -> (CatalogStore, [NSManagedObjectID], TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        var photos: [Photo] = []
        for index in 0..<3 {
            let photo = Photo(context: store.viewContext)
            photo.id = UUID()
            photo.fileName = "IMG_\(index).jpg"
            photo.filePath = directory.url.appending(path: photo.fileName).path(percentEncoded: false)
            photo.fileType = "JPG"
            photo.captureDate = Date(timeIntervalSince1970: Double(index) * 60)
            photo.importDate = Date()
            photo.editDate = Date()
            photos.append(photo)
        }
        try store.viewContext.save()
        return (store, photos.map(\.objectID), directory)
    }

    @Test func followsTheMainWindowAndSelectsForIt() throws {
        let (store, ids, directory) = try makeStore()
        _ = directory
        let main = LibraryState()
        main.selectedPhotoIDs = [ids[0]]
        let controller = SecondaryWindowController(store: store, main: main, view: .grid)
        defer { controller.closeQuietly() }
        #expect(controller.state.selectedPhotoIDs == [ids[0]])

        main.filter.scope = .folder(path: "/Photos/Trip")
        #expect(controller.state.filter == main.filter)
        main.selectedPhotoIDs = [ids[1]]
        #expect(controller.state.selectedPhotoIDs == [ids[1]])

        controller.state.selectedPhotoIDs = [ids[2], ids[0]]
        #expect(main.selectedPhotoIDs == [ids[2], ids[0]], "selecting in the secondary window selects in the main window")
    }

    @Test func hasItsOwnThumbnailSize() throws {
        let (store, _, directory) = try makeStore()
        _ = directory
        let main = LibraryState()
        main.thumbnailSize = 200
        let controller = SecondaryWindowController(store: store, main: main, view: .grid)
        defer { controller.closeQuietly() }
        controller.state.thumbnailSize = 120
        #expect(main.thumbnailSize == 200)
        #expect(Defaults.store.double(forKey: SecondaryDisplaySettings.thumbnailSizeKey) == 120)
    }

    @Test func switchesBetweenGridAndLoupe() throws {
        let (store, ids, directory) = try makeStore()
        _ = directory
        let main = LibraryState()
        main.selectedPhotoIDs = [ids[1]]
        let controller = SecondaryWindowController(store: store, main: main, view: .grid)
        defer { controller.closeQuietly() }
        let content = try #require(controller.window?.contentViewController as? SecondaryContentViewController)
        #expect(content.current is GridViewController)
        controller.view = .loupe
        #expect(content.children.count == 1)
        #expect(content.current is SecondaryLoupeViewController)
        #expect(controller.shownPhotoID == ids[1])
        #expect(controller.window?.identifier?.rawValue == "secondaryWindow")
        let window = try #require(controller.window)
        #expect(window.contentRect(forFrameRect: window.frame).size == SecondaryContentViewController.initialSize,
                "the window keeps its size when it adopts its content")
        #expect(!window.isRestorable, "the app places it; macOS mustn't restore an old frame")
    }

    @Test func forwardsMenuCommandsToTheCatalogWindow() throws {
        let (store, _, directory) = try makeStore()
        _ = directory
        let controller = SecondaryWindowController(store: store, main: LibraryState(), view: .grid)
        defer { controller.closeQuietly() }
        final class Target: NSResponder {
            @objc func toggleSecondaryWindow(_ sender: Any?) {}
        }
        let target = Target()
        controller.actionTarget = target
        #expect(controller.supplementalTarget(forAction: #selector(PixelLoupeActions.toggleSecondaryWindow(_:)), sender: nil) as? Target === target)
        #expect(controller.supplementalTarget(forAction: #selector(PixelLoupeActions.compare(_:)), sender: nil) == nil)
    }
}

@Suite("Secondary window views") @MainActor
struct SecondaryWindowViewTests {
    private func makeWindow(view: SecondaryView = .grid, selected: [Int] = [0]) throws
        -> (SecondaryWindowController, LibraryState, [NSManagedObjectID], TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        var photos: [Photo] = []
        for index in 0..<4 {
            let photo = Photo(context: store.viewContext)
            photo.id = UUID()
            photo.fileName = "IMG_\(index).jpg"
            photo.filePath = directory.url.appending(path: photo.fileName).path(percentEncoded: false)
            photo.fileType = "JPG"
            photo.captureDate = Date(timeIntervalSince1970: Double(index) * 60)
            photo.importDate = Date()
            photo.editDate = Date()
            photos.append(photo)
        }
        try store.viewContext.save()
        let ids = photos.map(\.objectID)
        let main = LibraryState()
        main.photoOrder = ids
        main.selectedPhotoIDs = selected.map { ids[$0] }
        return (SecondaryWindowController(store: store, main: main, view: view), main, ids, directory)
    }

    @Test func liveLoupeFollowsThePointerInTheMainWindow() throws {
        let (controller, main, ids, directory) = try makeWindow()
        _ = directory
        defer { controller.closeQuietly() }
        #expect(!main.tracksHover, "the grid only tracks the pointer for Loupe – Live")
        controller.view = .liveLoupe
        #expect(main.tracksHover)
        #expect(controller.shownPhotoID == ids[0], "the active photo until the pointer is over one")
        main.hoveredPhotoID = ids[2]
        #expect(controller.shownPhotoID == ids[2])
        main.hoveredPhotoID = nil
        #expect(controller.shownPhotoID == ids[2], "moving off the photos keeps the last one")
        #expect(main.selectedPhotoIDs == [ids[0]], "hovering doesn't select")
        controller.view = .loupe
        #expect(!main.tracksHover)
        #expect(controller.shownPhotoID == ids[0])
    }

    @Test func lockedLoupeKeepsItsPhoto() throws {
        let (controller, main, ids, directory) = try makeWindow(view: .loupe, selected: [1])
        _ = directory
        defer { controller.closeQuietly() }
        controller.view = .lockedLoupe
        main.selectedPhotoIDs = [ids[3]]
        #expect(controller.shownPhotoID == ids[1])
        controller.view = .loupe
        #expect(controller.shownPhotoID == ids[3])
    }

    @Test func lockingFromLiveLocksThePhotoUnderThePointer() throws {
        let (controller, main, ids, directory) = try makeWindow(view: .liveLoupe)
        _ = directory
        defer { controller.closeQuietly() }
        main.hoveredPhotoID = ids[2]
        controller.view = .lockedLoupe
        main.hoveredPhotoID = ids[3]
        #expect(controller.shownPhotoID == ids[2])
        #expect(!main.tracksHover)
    }

    @Test func compareShowsTheSelectedPairAndDoneReturnsToTheGrid() throws {
        let (controller, main, ids, directory) = try makeWindow(selected: [0, 2])
        _ = directory
        defer { controller.closeQuietly() }
        var reported: SecondaryView?
        controller.onViewChange = { reported = $0 }
        #expect(controller.canCompare)
        controller.view = .compare
        #expect(controller.content.current is CompareViewController)
        #expect(controller.state.comparePhotos?.select == ids[0] && controller.state.comparePhotos?.candidate == ids[2])
        #expect(main.presentation == .grid, "the main window doesn't enter Compare")

        controller.state.presentation = .grid   // Compare's Done
        #expect(controller.view == .grid)
        #expect(reported == .grid)
        #expect(controller.content.current is GridViewController)
    }

    @Test func compareNeedsSomethingToCompare() throws {
        let (controller, _, _, directory) = try makeWindow(view: .loupe, selected: [])
        _ = directory
        defer { controller.closeQuietly() }
        #expect(!controller.canCompare)
        controller.view = .compare
        #expect(controller.view == .loupe)
    }

    @Test func opensInCompareOnlyWithAPair() throws {
        let (withPair, _, _, directory) = try makeWindow(view: .compare, selected: [0, 1])
        let (without, _, _, other) = try makeWindow(view: .compare, selected: [])
        _ = (directory, other)
        defer { withPair.closeQuietly(); without.closeQuietly() }
        #expect(withPair.view == .compare)
        #expect(without.view == .grid)
    }

    @Test func previewOnlyWhileFullScreen() throws {
        let (controller, _, _, directory) = try makeWindow()
        _ = directory
        defer { controller.closeQuietly() }
        controller.setPreviewShown(true, on: nil)
        #expect(!controller.isShowingPreview, "a windowed secondary window needs no preview")
    }

    @Test func previewPanelFloatsOverTheMainDisplay() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let preview = SecondaryPreviewController(store: store, state: LibraryState())
        defer { preview.close() }
        let panel = try #require(preview.window as? NSPanel)
        #expect(panel.isFloatingPanel)
        #expect(panel.title == "Second Monitor Preview")
        #expect(panel.contentViewController === preview.content)
        preview.content.mode = .loupe
        #expect(preview.content.current is SecondaryLoupeViewController)
        var closed = false
        preview.onClose = { closed = true }
        preview.close()
        #expect(closed)
    }
}

@Suite("Pointer tracking") @MainActor
struct PointerTrackingTests {
    @Test func collectionViewTracksThePointerOnlyWhenAsked() {
        let view = RangeSelectingCollectionView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.updateTrackingAreas()
        #expect(view.trackingAreas.isEmpty)
        view.onHover = { _ in }
        #expect(view.trackingAreas.count == 1)
        #expect(view.trackingAreas.first?.options.contains(.mouseMoved) == true)
        view.onHover = nil
        #expect(view.trackingAreas.isEmpty)
    }

    @Test func turningTrackingOffForgetsTheHoveredPhoto() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let photo = Photo(context: store.viewContext)
        let state = LibraryState()
        state.tracksHover = true
        state.hoveredPhotoID = photo.objectID
        state.tracksHover = false
        #expect(state.hoveredPhotoID == nil)
    }
}

@Suite("Secondary loupe zoom") @MainActor
struct SecondaryLoupeZoomTests {
    @Test(arguments: [
        (ZoomRatio.oneToOne, "100%"), (.threeToOne, "300%"), (.elevenToOne, "1100%"),
        (.oneToTwo, "50%"), (.oneToEight, "12.5%"), (.oneToSixteen, "6.25%"), (.oneToThree, "33.33%"),
    ])
    func ratiosReadAsPercentages(_ ratio: ZoomRatio, expected: String) {
        #expect(ZoomChoiceControl.percent(ratio) == expected)
    }

    @Test func offersTheNavigatorsChoices() throws {
        let state = LibraryState()
        let control = ZoomChoiceControl(state: state)
        #expect(control.segmentCount == 3)
        #expect(control.label(forSegment: 0) == "FIT")
        #expect(control.label(forSegment: 1) == "100%")
        #expect(control.label(forSegment: 2) == "300%", "Lightroom's menu starts at 3:1")
        #expect(control.selectedSegment == 0)
        let fits = try #require(control.menu(forSegment: 0)).items.map(\.title)
        #expect(fits == ["FIT", "FILL"])
        let ratios = try #require(control.menu(forSegment: 2)).items.map(\.title)
        #expect(ratios.count == ZoomRatio.menu.count)
        #expect(!ratios.contains("100%"), "1:1 has its own segment, as in the Navigator")
    }

    @Test func choicesSetTheZoom() throws {
        let state = LibraryState()
        let control = ZoomChoiceControl(state: state)
        control.selectedSegment = 1
        control.sendAction(control.action, to: control.target)
        #expect(state.zoom.isZoomed && state.zoom.ratio == .oneToOne)

        let fill = try #require(control.menu(forSegment: 0)?.items.first { $0.title == "FILL" })
        control.menu(forSegment: 0)?.performActionForItem(at: try #require(control.menu(forSegment: 0)?.index(of: fill)))
        #expect(!state.zoom.isZoomed && state.zoom.fit == .fill)
        #expect(control.label(forSegment: 0) == "FILL")
        #expect(control.selectedSegment == 0)

        let ratioMenu = try #require(control.menu(forSegment: 2))
        let eight = try #require(ratioMenu.items.firstIndex { $0.title == "800%" })
        ratioMenu.performActionForItem(at: eight)
        #expect(state.zoom.isZoomed && state.zoom.ratio == .eightToOne && state.zoom.menuRatio == .eightToOne)
        #expect(control.label(forSegment: 2) == "800%")
        #expect(control.selectedSegment == 2)

        // Z (or a click on the photo) changes the zoom too; the control follows.
        state.zoom.toggle()
        #expect(control.selectedSegment == 0)
    }

    @Test func barIsAlongTheBottomOfTheLoupe() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let host = SecondaryLoupeViewController(store: store, state: LibraryState())
        host.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        host.view.layoutSubtreeIfNeeded()
        let control = host.zoomControl.convert(host.zoomControl.bounds, to: host.view)
        #expect(control.minY < SecondaryLoupeViewController.barHeight, "at the bottom (unflipped)")
        #expect(control.maxX > 1100, "at the right")
        #expect(host.loupe.view.frame.minY == SecondaryLoupeViewController.barHeight, "the photo sits above the bar")
    }
}
