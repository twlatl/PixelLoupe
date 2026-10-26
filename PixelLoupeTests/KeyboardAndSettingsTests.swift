import AppKit
import CoreData
import Testing
@testable import PixelLoupe

@Suite("Keyboard commands")
struct KeyCommandTests {
    private func event(_ characters: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        )!
    }

    @Test(arguments: [
        ("g", KeyCommand.showLibrary), ("G", .showLibrary), ("d", .showDevelop),
        ("0", .rating(0)), ("1", .rating(1)), ("5", .rating(5)),
        ("p", .flag(.picked)), ("x", .flag(.rejected)), ("u", .flag(.unflagged)),
        ("\r", .toggleEnlarge), ("f", .fullScreen), ("`", .toggleLoupe), ("e", .enlarge), ("c", .compare), ("r", .cropTool), ("j", .showClipping), ("=", .largerThumbnails), ("-", .smallerThumbnails),
    ])
    func characters(_ characters: String, expected: KeyCommand) {
        #expect(KeyCommand(event: event(characters)) == expected)
    }

    @Test func beforeAfterUsesLightroomKeys() {
        #expect(KeyCommand(event: event("y")) == .beforeAfter(.leftRight))
        #expect(KeyCommand(event: event("y", modifiers: .option)) == .beforeAfter(.topBottom))
        #expect(KeyCommand(event: event("\\")) == .beforeAfter(.beforeOnly))
        #expect(KeyCommand(event: event("Y", modifiers: .shift)) == .beforeAfter(.split))
        #expect(KeyCommand(event: event("y", modifiers: .command)) == nil)
    }

    @Test func deleteRemovesPhotos() {
        #expect(KeyCommand(event: event("\u{7f}", keyCode: 51)) == .removePhoto)
        #expect(KeyCommand(event: event("\u{7f}", keyCode: 51, modifiers: .command)) == nil, "⌘Delete is the menu's")
    }

    @Test func escapeAndArrows() {
        #expect(KeyCommand(event: event("\u{1b}", keyCode: 53)) == .exit)
        let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        #expect(KeyCommand(event: event(left, keyCode: 123, modifiers: [.numericPad, .function])) == .previous)
        #expect(KeyCommand(event: event(right, keyCode: 124, modifiers: [.numericPad, .function])) == .next)
    }

    @Test func ignoresModifiedAndUnknownKeys() {
        #expect(KeyCommand(event: event("g", modifiers: .command)) == nil)
        #expect(KeyCommand(event: event("f", modifiers: [.command, .control])) == nil, "⌃⌘F is the app's full screen")
        #expect(KeyCommand(event: event("d", modifiers: .option)) == nil)
        #expect(KeyCommand(event: event("m")) == .linearMask, "M adds a linear gradient mask")
        #expect(KeyCommand(event: event("z")) == .toggleZoom, "Z toggles zoom, as in Lightroom")
        #expect(KeyCommand(event: event("k")) == .brushMask, "K adds a brush mask, as in Lightroom")
        #expect(KeyCommand(event: event("l")) == nil)
        #expect(KeyCommand(event: event("a")) == nil)
    }
}

@Suite("Main menu")
struct MainMenuTests {
    private func item(_ action: Selector, in menuTitle: String, modifiers: NSEvent.ModifierFlags? = nil) throws -> NSMenuItem {
        let menu = try #require(MainMenu.make().items.first { $0.title == menuTitle }?.submenu)
        return try #require(menu.items.first { $0.action == action && (modifiers == nil || $0.keyEquivalentModifierMask == modifiers) })
    }

    @Test func lightroomShortcuts() throws {
        let revert = try item(#selector(PixelLoupeActions.revertToOriginal(_:)), in: "Photo")
        #expect(revert.keyEquivalent == "r" && revert.keyEquivalentModifierMask == [.command, .shift])
        let auto = try item(#selector(PixelLoupeActions.autoLight(_:)), in: "Photo")
        #expect(auto.keyEquivalent == "u" && auto.keyEquivalentModifierMask == .command)

        let library = try item(#selector(PixelLoupeActions.showLibrary(_:)), in: "View", modifiers: [.command, .option])
        #expect(library.keyEquivalent == "1" && library.isAlternate)
        let develop = try item(#selector(PixelLoupeActions.showDevelop(_:)), in: "View", modifiers: [.command, .option])
        #expect(develop.keyEquivalent == "2" && develop.isAlternate)
        #expect(try item(#selector(PixelLoupeActions.showLibrary(_:)), in: "View", modifiers: .command).keyEquivalent == "1")

        let larger = try item(#selector(PixelLoupeActions.increaseThumbnailSize(_:)), in: "View")
        #expect(larger.keyEquivalent.isEmpty, "= is a single-key shortcut, not a menu key equivalent")
    }

    @Test func rotateAndFlipUseLightroomShortcuts() throws {
        let left = try item(#selector(PixelLoupeActions.rotateLeft(_:)), in: "Photo")
        #expect(left.title == "Rotate Left (CCW)" && left.keyEquivalent == "[" && left.keyEquivalentModifierMask == .command)
        let right = try item(#selector(PixelLoupeActions.rotateRight(_:)), in: "Photo")
        #expect(right.title == "Rotate Right (CW)" && right.keyEquivalent == "]" && right.keyEquivalentModifierMask == .command)
        for action in [#selector(PixelLoupeActions.flipHorizontal(_:)), #selector(PixelLoupeActions.flipVertical(_:)),
                       #selector(PixelLoupeActions.resetToCameraOrientation(_:)), #selector(PixelLoupeActions.restoreOrientationFromMetadata(_:))] {
            _ = try item(action, in: "Photo")
        }
    }

    @Test func cropIsInTheViewMenuWithR() throws {
        let crop = try item(#selector(PixelLoupeActions.cropTool(_:)), in: "View")
        #expect(crop.keyEquivalent == "r" && crop.keyEquivalentModifierMask.isEmpty)
    }

    @Test func brushMaskIsInTheViewMenuWithK() throws {
        let brush = try item(#selector(PixelLoupeActions.addBrushMask(_:)), in: "View")
        #expect(brush.title == "Brush Mask" && brush.keyEquivalent == "k" && brush.keyEquivalentModifierMask.isEmpty)
    }

    @Test func addKeywordsIsCommandKAfterShowInFinder() throws {
        let menu = MainMenu.make()
        let photo = try #require(menu.items.first { $0.title == "Photo" }?.submenu)
        let titles = photo.items.map(\.title)
        let index = try #require(titles.firstIndex(of: "Add Keywords…"))
        #expect(titles[index - 1] == "Show in Finder")
        #expect(photo.items[index].keyEquivalent == "k" && photo.items[index].keyEquivalentModifierMask == .command)
        #expect(!titles.contains("Add Tag…"))
    }

    @Test func removeItemsUseLightroomShortcuts() throws {
        let delete = String(Character(UnicodeScalar(NSBackspaceCharacter)!))
        let expected: [(Selector, String, NSEvent.ModifierFlags)] = [
            (#selector(PixelLoupeActions.removePhoto(_:)), "Remove Photo…", []),
            (#selector(PixelLoupeActions.removeSelectedPhotos(_:)), "Remove Selected Photo…", [.shift]),
            (#selector(PixelLoupeActions.removeAndTrashPhotos(_:)), "Remove and Trash Photo…", [.option, .shift, .command]),
            (#selector(PixelLoupeActions.deleteRejectedPhotos(_:)), "Delete Rejected Photos…", [.command]),
        ]
        for (action, title, modifiers) in expected {
            let menuItem = try item(action, in: "Photo")
            #expect(menuItem.title == title)
            #expect(menuItem.keyEquivalent == delete && menuItem.keyEquivalentModifierMask == modifiers, "\(title)")
        }
    }

    @Test func showClippingIsInTheViewMenuWithJ() throws {
        let clipping = try item(#selector(PixelLoupeActions.showClipping(_:)), in: "View")
        #expect(clipping.title == "Show Clipping")
        #expect(clipping.keyEquivalent == "j" && clipping.keyEquivalentModifierMask.isEmpty)
    }

    @Test func beforeAfterIsInTheViewMenuWithLightroomKeys() throws {
        let view = try #require(MainMenu.make().items.first { $0.title == "View" }?.submenu)
        let menu = try #require(view.items.first { $0.title == "Before/After" }?.submenu)
        let items = menu.items.map { ($0.title, $0.keyEquivalent, $0.keyEquivalentModifierMask, $0.tag) }
        #expect(items.map(\.0) == ["Left/Right", "Top/Bottom", "Before Only", "Split Screen"])
        #expect(items.map(\.1) == ["y", "y", "\\", "y"])
        #expect(items.map(\.2) == [[], .option, [], .shift])
        #expect(items.map(\.3) == BeforeAfterView.allCases.map(\.rawValue))
        #expect(menu.items.allSatisfy { $0.action == #selector(PixelLoupeActions.showBeforeAfter(_:)) })
    }

    @Test func compareIsInTheViewMenuWithC() throws {
        let compare = try item(#selector(PixelLoupeActions.compare(_:)), in: "View")
        #expect(compare.keyEquivalent == "c" && compare.keyEquivalentModifierMask.isEmpty)
    }

    @Test func f6TogglesFilmstrip() throws {
        let toggle = try item(#selector(PixelLoupeActions.toggleFilmstrip(_:)), in: "View")
        #expect(toggle.keyEquivalent == String(Character(UnicodeScalar(NSF6FunctionKey)!)))
        #expect(toggle.keyEquivalentModifierMask.isEmpty)
    }

    @Test func controlCommandFTogglesFullScreen() throws {
        let menu = MainMenu.make()
        let view = try #require(menu.items.first { $0.title == "View" }?.submenu)
        let item = try #require(view.items.first { $0.action == #selector(NSWindow.toggleFullScreen(_:)) })
        #expect(item.keyEquivalent == "f")
        #expect(item.keyEquivalentModifierMask == [.command, .control])
    }
}

@Suite("Library state")
struct LibraryStateTests {
    @Test func stepsThroughPhotosInGridOrder() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url)
        let ids = (0..<3).map { _ in Photo(context: store.viewContext).objectID }
        let state = LibraryState()
        state.photoOrder = ids
        #expect(state.photoCount == 3)

        state.selectedPhotoIDs = [ids[0]]
        #expect(!state.stepSelection(by: -1), "already at the first photo")
        #expect(state.stepSelection(by: 1))
        #expect(state.selectedPhotoIDs == [ids[1]])
        #expect(state.stepSelection(by: 1))
        #expect(!state.stepSelection(by: 1), "already at the last photo")
        #expect(state.selectedPhotoIDs == [ids[2]])
    }
}

@Suite("Matte color", .serialized)
struct MatteTests {
    private let dark = NSAppearance(named: .darkAqua)!
    private let light = NSAppearance(named: .aqua)!

    private func white(_ color: (NSAppearance) -> NSColor, _ appearance: NSAppearance) -> CGFloat {
        color(appearance).usingColorSpace(.genericGamma22Gray)?.whiteComponent ?? -1
    }

    private func white(_ color: CGColor?) -> CGFloat {
        color.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.genericGamma22Gray)?.whiteComponent } ?? -1
    }

    @Test func followsThemeUntilSet() {
        let settings = AppSettings.shared
        let saved = settings.matte
        defer { settings.matte = saved }

        settings.matte = nil
        #expect(abs(white(GridColors.background(for:), dark) - 0.15) < 0.01, "85% in Dark Mode")
        #expect(abs(white(GridColors.background(for:), light) - 0.90) < 0.01, "10% in Light Mode")
        #expect(GridColors.contentAppearance() == nil)

        settings.matte = 0           // white
        #expect(white(GridColors.background(for:), dark) > 0.99)
        #expect(white(GridColors.cell(for:), dark) < white(GridColors.background(for:), dark), "cells darker on a light matte")
        #expect(GridColors.contentAppearance()?.name == .aqua)

        settings.matte = 1           // black
        #expect(white(GridColors.background(for:), light) < 0.01)
        #expect(white(GridColors.cell(for:), light) > white(GridColors.background(for:), light), "cells lighter on a dark matte")
        #expect(GridColors.contentAppearance()?.name == .darkAqua)
    }

    @Test("Switching between Light and Dark puts Matte Color back to the theme's 10% or 85% (RAW-152)")
    func appearanceSwitchResetsMatte() {
        let settings = AppSettings.shared
        let saved = settings.matte
        defer { settings.matte = saved }

        settings.effectiveAppearanceDidChange(light)
        settings.matte = 0.5
        settings.effectiveAppearanceDidChange(light)
        #expect(settings.matte == 0.5, "no switch, no reset")
        settings.effectiveAppearanceDidChange(dark)
        #expect(settings.matte == nil)
        #expect(abs(white(GridColors.background(for:), dark) - 0.15) < 0.01)

        settings.matte = 0.3
        settings.effectiveAppearanceDidChange(NSAppearance(named: .vibrantDark)!)
        #expect(settings.matte == 0.3, "still dark")
        settings.effectiveAppearanceDidChange(light)
        #expect(settings.matte == nil)
        #expect(abs(white(GridColors.background(for:), light) - 0.90) < 0.01)
    }

    @Test("Gray is Light Mode with a black matte, whatever appearance a view on the matte has (RAW-155)")
    func grayHasABlackMatte() {
        let settings = AppSettings.shared
        let (savedAppearance, savedMatte) = (settings.appearance, settings.matte)
        defer { settings.appearance = savedAppearance; settings.matte = savedMatte }

        settings.matte = nil
        settings.appearance = .gray
        #expect(NSApp.appearance?.name == .aqua)
        #expect(AppSettings.theme(for: light) == .gray)
        // The grid's matte view turns dark for its labels; it must still get Gray's matte.
        #expect(AppSettings.theme(for: dark) == .gray)
        #expect(white(GridColors.background(for:), light) < 0.01)
        #expect(white(GridColors.background(for:), dark) < 0.01)
        #expect(GridColors.contentAppearance()?.name == .darkAqua, "labels on the black matte are light")
        let grayBar = FilterBarBackground.stops(for: light)
        #expect(grayBar.first!.color.r < grayBar.last!.color.r, "lightens toward the grid")

        settings.appearance = .light
        #expect(grayBar.last!.color.r < FilterBarBackground.stops(for: light).first!.color.r, "Gray's bar is darker than Light's")
        #expect(abs(white(GridColors.background(for:), light) - 0.90) < 0.01)
        #expect(GridColors.contentAppearance() == nil)
    }

    @Test("Choosing Gray puts a custom matte back to black, and leaving it to the theme's (RAW-155)")
    func switchingToGrayResetsMatte() {
        let settings = AppSettings.shared
        let (savedAppearance, savedMatte) = (settings.appearance, settings.matte)
        defer { settings.appearance = savedAppearance; settings.matte = savedMatte }

        settings.appearance = .light
        settings.matte = 0.4
        settings.appearance = .gray      // same appearance to macOS, but a different theme
        #expect(settings.matte == nil)
        #expect(white(GridColors.background(for:), light) < 0.01)

        settings.matte = 0.6
        settings.appearance = .gray
        #expect(settings.matte == 0.6, "no switch, no reset")
        settings.appearance = .light
        #expect(settings.matte == nil)
    }

    @Test("Gray paints windows' chrome and puts it back, leaving windows with their own (RAW-155)")
    func grayPaintsWindowChrome() {
        let settings = AppSettings.shared
        let savedAppearance = settings.appearance
        defer { settings.appearance = savedAppearance }
        settings.appearance = .light

        let plain = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let black = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        black.backgroundColor = .black
        plain.isReleasedWhenClosed = false
        black.isReleasedWhenClosed = false
        defer { plain.close(); black.close() }

        settings.appearance = .gray
        GrayChrome.apply(to: plain)
        GrayChrome.apply(to: black)
        #expect(plain.backgroundColor == GrayChrome.color)
        #expect(plain.titlebarAppearsTransparent)
        #expect(black.backgroundColor == .black, "the full-screen viewer and slideshow stay black")

        settings.appearance = .light
        GrayChrome.apply(to: plain)
        #expect(plain.backgroundColor == .windowBackgroundColor)
        #expect(!plain.titlebarAppearsTransparent)
        #expect(black.backgroundColor == .black)
    }

    @Test("The filmstrip's header is chrome, not matte: gray in Gray (RAW-155)")
    func filmstripHeaderIsChrome() {
        let settings = AppSettings.shared
        let savedAppearance = settings.appearance
        defer { settings.appearance = savedAppearance }

        let bar = ChromeBackgroundView(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
        settings.appearance = .gray
        bar.updateLayer()
        #expect(abs(white(bar.layer?.backgroundColor) - white(GrayChrome.color.cgColor)) < 0.01)
        #expect(white(bar.layer?.backgroundColor) > 0.5, "not Gray's black matte")

        settings.appearance = .light
        bar.updateLayer()
        #expect(white(bar.layer?.backgroundColor) > white(GrayChrome.color.cgColor), "Light's window background")
    }

    /// Views on the matte must repaint when the setting changes, not only when the theme does.
    @Test func matteViewsRepaintWhenSettingChanges() {
        let settings = AppSettings.shared
        let saved = settings.matte
        defer { settings.matte = saved }

        let matte = MatteView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        let cell = PhotoGridCellView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        matte.addSubview(cell)

        settings.matte = 0.1
        matte.updateLayer()
        cell.updateLayer()
        #expect(abs(white(matte.layer?.backgroundColor) - 0.9) < 0.01)
        let lightCell = white(cell.layer?.backgroundColor)

        settings.matte = 0.9
        matte.updateLayer()
        cell.updateLayer()
        #expect(abs(white(matte.layer?.backgroundColor) - 0.1) < 0.01)
        #expect(white(cell.layer?.backgroundColor) < lightCell)
        #expect(matte.appearance?.name == .darkAqua)
    }
}

@Suite("Quitting")
@MainActor
struct QuitConfirmationTests {
    @Test func confirmingIsOnByDefaultAndInTheGeneralPane() throws {
        #expect(AppSettings.shared.confirmsQuit, "on until the user turns it off")
        let controller = SettingsWindowController()
        let tabs = try #require(controller.window?.contentViewController as? NSTabViewController)
        #expect(tabs.tabViewItems.map(\.label) == ["General", "Appearance", "Import", "Displays", "External Editing"], "General comes first")
    }

    @Test func theAlertMakesQuitTheDefault() {
        let alert = AppDelegate.quitAlert()
        #expect(alert.messageText == "Are you sure you want to quit?")
        #expect(alert.buttons.map(\.title) == ["Quit", "Cancel"])
        #expect(alert.buttons[0].keyEquivalent == "\r", "Return quits")
        #expect(alert.buttons[1].keyEquivalent == "\u{1b}", "Escape cancels")
        #expect(alert.showsSuppressionButton)
    }

    @Test func whenToAsk() {
        // Hosting tests never asks (it would block the run); the rest of the rule is checked directly.
        #expect(!AppDelegate.shouldAskBeforeQuitting(confirmsQuit: false, event: nil))
        let logout = NSAppleEventDescriptor(eventClass: kCoreEventClass, eventID: kAEQuitApplication, targetDescriptor: nil,
                                            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        logout.setAttribute(NSAppleEventDescriptor(enumCode: kAELogOut), forKeyword: kAEQuitReason)
        #expect(!AppDelegate.shouldAskBeforeQuitting(confirmsQuit: true, event: logout), "macOS asks on log out")
    }
}

@Suite("Window tabs")
@MainActor
struct WindowTabbingTests {
    /// AppKit adds View ▸ Show Tab Bar and Show All Tabs unless the app turns window tabbing off.
    @Test func windowTabbingIsOff() {
        #expect(!NSWindow.allowsAutomaticWindowTabbing)
    }
}
