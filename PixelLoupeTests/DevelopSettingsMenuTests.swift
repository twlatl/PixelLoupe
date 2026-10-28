import AppKit
import CoreData
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import PixelLoupe

@Suite("Develop Settings menu")
@MainActor
struct DevelopSettingsMenuTests {
    /// Settings with every part changed from its default.
    private static func everything() -> PhotoAdjustments {
        var a = PhotoAdjustments()
        a.light.exposure = 0.5
        a.light.contrast = 0.1
        a.light.highlights = -0.2
        a.light.shadows = 0.3
        a.light.whites = 0.1
        a.light.blackPoint = 0.05
        a.light.brilliance = 0.2
        a.light.brightness = 0.1
        a.color.global.hue = 0.3
        a.blackAndWhite.isEnabled = true
        a.redEye.isEnabled = true
        a.whiteBalance.temperature = 4800
        a.curves.isEnabled = false
        a.levels.inputBlack = 0.1
        a.definition.intensity = 0.4
        a.selectiveColor.isEnabled = false
        a.noiseReduction.amount = 0.3
        a.sharpen.intensity = 0.5
        a.vignette.strength = 0.4
        a.crop.angle = 3
        a.orientation.quarterTurns = 1
        a.lens.enableProfileCorrections = true
        a.presence.texture = 0.1
        a.presence.clarity = 0.2
        a.presence.dehaze = 0.1
        a.presence.vibrance = 0.3
        a.presence.saturation = -0.1
        a.effects.grain = 0.2
        a.transform.vertical = 0.1
        a.profile.amount = 0.5
        a.calibration.redHue = 0.2
        a.rimLight.isEnabled = true
        a.rimLight.lights = [.init()]
        a.masks = [.init(components: [.init(shape: .radial(.init(center: .init(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.2)))])]
        a.spots = [.init()]
        a.redEyes = [.init()]
        return a
    }

    @Test("The fixture changes every part of the settings (so the next test covers them all)")
    func fixtureCoversEverything() {
        let changed = Mirror(reflecting: Self.everything()).children
        let defaults = Dictionary(uniqueKeysWithValues: Mirror(reflecting: PhotoAdjustments()).children.map { ($0.label!, "\($0.value)") })
        for child in changed {
            #expect("\(child.value)" != defaults[child.label!], "\(child.label!) is left at its default")
        }
    }

    @Test("Every setting together copies everything; each group lists settings once")
    func everySettingCopiesEverything() {
        let source = Self.everything()
        #expect(DevelopSetting.apply(Set(DevelopSetting.allCases), from: source, to: PhotoAdjustments()) == source)
        let listed = DevelopSetting.groups.flatMap(\.settings)
        #expect(listed.count == DevelopSetting.allCases.count && Set(listed) == Set(DevelopSetting.allCases))
    }

    @Test("Only the chosen settings are copied; what belongs to the photo stays by default")
    func copiesOnlyChosenSettings() {
        let source = Self.everything()
        var target = PhotoAdjustments()
        target.crop.angle = -2
        target.light.isEnabled = false
        let exposureOnly = DevelopSetting.apply([.exposure], from: source, to: target)
        #expect(exposureOnly.light.exposure == 0.5 && exposureOnly.light.contrast == 0 && exposureOnly.light.isEnabled)
        #expect(exposureOnly.whiteBalance == target.whiteBalance && exposureOnly.crop.angle == -2)

        let defaults = DevelopSetting.apply(DevelopSetting.defaultSelection, from: source, to: target)
        #expect(defaults.crop == target.crop && defaults.orientation == target.orientation)
        #expect(defaults.masks.isEmpty && defaults.spots.isEmpty && defaults.redEyes.isEmpty && !defaults.redEye.isEnabled)
        #expect(defaults.light == source.light && defaults.whiteBalance == source.whiteBalance && defaults.lens == source.lens)

        // Paste applies what Copy Settings chose.
        let pasted = SettingsClipboard.applied(.settings(source, from: "A.jpg", only: [.whiteBalance, .crop]), to: target, isRaw: true)
        #expect(pasted.whiteBalance == source.whiteBalance && pasted.crop == source.crop && pasted.light == target.light)
    }

    @Test("The dialog's checkboxes: groups switch their settings, Check All / None")
    func dialogModel() {
        let model = DevelopSettingsDialogModel(purpose: .sync(photoCount: 3))
        #expect(model.title == "Synchronize Settings" && model.actionTitle == "Synchronize")
        #expect(model.message.contains("3 other selected photos"))
        let basic = DevelopSetting.groups[1]
        #expect(model.isOn(basic).wrappedValue)
        model.isOn(.contrast).wrappedValue = false
        #expect(!model.isOn(basic).wrappedValue)
        model.isOn(basic).wrappedValue = true
        #expect(model.selection.isSuperset(of: basic.settings))
        model.checkNone()
        #expect(model.selection.isEmpty)
        model.checkAll()
        #expect(model.selection == Set(DevelopSetting.allCases))
        #expect(!DevelopSettingsDialogModel(purpose: .copy).selection.contains(.masking))
    }

    @Test("Empty masks are found and deleted")
    func emptyMasks() {
        var adjustments = Self.everything()
        #expect(!adjustments.hasEmptyMasks)
        adjustments.masks.append(.init(name: "Empty"))
        #expect(adjustments.hasEmptyMasks)
        adjustments.deleteEmptyMasks()
        #expect(adjustments.masks.count == 1 && !adjustments.hasEmptyMasks)
    }

    // MARK: - Auto

    @Test("Auto tones: a dull, flat photo gets whites, deeper blacks and color; a lively one is left alone")
    func autoTones() {
        let flat = AutoDevelop.autoTones(.init(darkest: 0.2, brightest: 0.7, saturation: 0.05))
        #expect(flat.whites > 0.5 && flat.blackPoint > 0.3 && flat.vibrance > 0.2 && flat.saturation > 0)
        let lively = AutoDevelop.autoTones(.init(darkest: 0.03, brightest: 0.96, saturation: 0.45))
        #expect(lively.whites == 0 && lively.blackPoint == 0 && lively.vibrance == 0 && lively.saturation < 0)
    }

    @Test("Tone statistics read the ends of the histogram and the midtones' color")
    func toneStatistics() throws {
        // 1,000 gray pixels from dark to light, the middle ones tinted.
        var pixels: [UInt8] = []
        for index in 0..<1000 {
            let value = UInt8(20 + index * 200 / 1000)
            pixels += index > 400 && index < 600 ? [value, value / 2, value / 2, 255] : [value, value, value, 255]
        }
        let statistics = try #require(AutoDevelop.toneStatistics(rgba: pixels))
        #expect(statistics.darkest < 0.1 && statistics.brightest > 0.8)
        #expect(statistics.saturation > 0.05 && statistics.saturation < 0.5)
    }

    /// A photo with a warm cast: neutral gray under orange light.
    private func writeWarmJPEG(to url: URL, red: CGFloat = 0.6, green: CGFloat = 0.5, blue: CGFloat = 0.38) throws {
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test("Auto White Balance cools a warm photo; Auto Settings brightens a dark one")
    func autoOnFiles() async throws {
        let directory = try TemporaryDirectory()
        let warm = directory.url.appending(path: "warm.jpg")
        try writeWarmJPEG(to: warm)
        let whiteBalance = try #require(await AutoDevelop.whiteBalance(for: .init(original: warm), adjustments: .init()))
        #expect((whiteBalance.temperature ?? 6500) < 6500 && whiteBalance.preset == "Auto")

        let dark = directory.url.appending(path: "dark.jpg")
        try writeWarmJPEG(to: dark, red: 0.08, green: 0.08, blue: 0.08)
        let settings = try #require(await AutoDevelop.settings(for: .init(original: dark), adjustments: .init()))
        #expect(settings.light.exposure > 0)
        #expect(await AutoDevelop.settings(for: .init(original: directory.url.appending(path: "gone.jpg")), adjustments: .init()) == nil)
    }

    // MARK: - In the window

    private func makeWindow() throws -> (CatalogWindowController, [NSManagedObjectID], TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        for index in 0..<3 {
            let photo = Photo(context: store.viewContext)
            photo.id = UUID()
            photo.fileName = "IMG_\(index).jpg"
            photo.filePath = directory.url.appending(path: photo.fileName).path(percentEncoded: false)
            photo.fileType = "JPG"
            photo.captureDate = Date(timeIntervalSince1970: Double(index) * 60)
            photo.importDate = Date()
            photo.editDate = Date()
        }
        try store.viewContext.save()
        let controller = CatalogWindowController(store: store)
        controller.showWindow(nil)
        controller.window?.layoutIfNeeded()
        return (controller, controller.state.photoOrder, directory)
    }

    private func photo(_ id: NSManagedObjectID, in controller: CatalogWindowController) throws -> Photo {
        try #require(controller.store.viewContext.existingObject(with: id) as? Photo)
    }

    @Test("The grid's context menu has Develop Settings after Add to Collection, with Lightroom's items")
    func contextMenu() throws {
        let (controller, order, directory) = try makeWindow()
        defer { controller.close(); _ = directory }
        controller.state.selectedPhotoIDs = [order[0]]
        let menu = controller.rootViewController.main.library.grid.contextMenu(clickedPhoto: order[0])
        let titles = menu.items.map(\.title)
        let add = try #require(titles.firstIndex(of: "Add to Collection"))
        #expect(titles[add + 1] == "Develop Settings")
        let submenu = try #require(menu.items[add + 1].submenu)
        #expect(submenu.items.filter { !$0.isSeparatorItem }.map(\.title) == [
            "Reset", "Copy Settings…", "Paste Settings", "Sync Settings…", "Delete All Empty Masks",
            "Auto White Balance", "Auto Settings", "Convert to Black & White",
        ])
        func enabled(_ title: String) -> Bool {
            controller.validateUserInterfaceItem(submenu.item(withTitle: title)!)
        }
        #expect(!enabled("Sync Settings…"), "needs two photos")
        #expect(!enabled("Delete All Empty Masks"), "no empty masks")
        #expect(enabled("Copy Settings…") && enabled("Auto Settings") && enabled("Convert to Black & White"))
        controller.state.selectedPhotoIDs = [order[0], order[1]]
        #expect(enabled("Sync Settings…"))
        #expect(submenu.item(withTitle: "Sync Settings…")?.representedObject as? NSManagedObjectID == order[0])
    }

    @Test("Sync Settings copies the chosen settings from the clicked photo to the others, as one undo step")
    func syncSettings() throws {
        let (controller, order, directory) = try makeWindow()
        defer { controller.close(); _ = directory }
        try photo(order[1], in: controller).adjustments = Self.everything()
        try controller.store.viewContext.save()
        // Setting up isn't part of what's undone below.
        controller.store.viewContext.undoManager?.removeAllActions()
        controller.state.selectedPhotoIDs = order
        let item = NSMenuItem(title: "Sync Settings…", action: #selector(CatalogWindowController.syncDevelopSettings(_:)), keyEquivalent: "")
        item.representedObject = order[1]
        controller.syncDevelopSettings(item)
        let dialog = try #require(controller.lastDevelopSettingsDialog)
        #expect(dialog.purpose == .sync(photoCount: 2))
        dialog.checkNone()
        dialog.selection = [.whiteBalance, .exposure]
        dialog.onFinish?(dialog.selection)

        for id in [order[0], order[2]] {
            let synced = try photo(id, in: controller)
            #expect(synced.adjustments.whiteBalance.temperature == 4800 && synced.adjustments.light.exposure == 0.5)
            #expect(synced.adjustments.light.contrast == 0 && synced.adjustments.crop == .init())
            #expect(synced.historySteps.count == 2, "Original, then Sync Settings")
        }
        #expect(controller.store.viewContext.undoManager?.undoActionName == "Sync Settings")
        controller.store.viewContext.undoManager?.undo()
        #expect(try photo(order[0], in: controller).adjustments == .init())
    }

    @Test("Copy Settings… copies only what's checked")
    func copySettingsChoosing() throws {
        let (controller, order, directory) = try makeWindow()
        defer { controller.close(); _ = directory }
        try photo(order[0], in: controller).adjustments = Self.everything()
        controller.state.selectedPhotoIDs = [order[0]]
        controller.copySettingsChoosing(nil)
        let dialog = try #require(controller.lastDevelopSettingsDialog)
        #expect(dialog.purpose == .copy && dialog.selection == DevelopSetting.defaultSelection)
        // Not finished here: SettingsClipboard is shared by tests running in parallel, so the
        // copy itself is covered through `SettingsClipboard.applied` above.
        dialog.onFinish?(nil)
    }

    @Test("Delete All Empty Masks and Convert to Black & White change the selected photos")
    func oneStepChanges() throws {
        let (controller, order, directory) = try makeWindow()
        defer { controller.close(); _ = directory }
        var withEmpty = Self.everything()
        withEmpty.masks.append(.init(name: "Empty"))
        try photo(order[0], in: controller).adjustments = withEmpty
        controller.state.selectedPhotoIDs = [order[0], order[1]]
        #expect(controller.selectionHasEmptyMasks)
        controller.deleteEmptyMasks(nil)
        #expect(try photo(order[0], in: controller).adjustments.masks.count == 1)
        #expect(try photo(order[1], in: controller).historySteps.isEmpty, "a photo with nothing to delete is untouched")

        controller.convertToBlackAndWhite(nil)
        #expect(try photo(order[1], in: controller).adjustments.blackAndWhite == PhotoAdjustments.autoBlackAndWhite)
        #expect(controller.store.viewContext.undoManager?.undoActionName == "Convert to Black & White")
    }
}
