import AppKit
import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Watermark presets")
@MainActor
struct WatermarkPresetTests {
    @Test func theDefaultTextIsJustTheCopyrightSign() {
        #expect(WatermarkSettings().text == "©", "no name is filled in from the Mac's account")
    }

    @Test func presetsSaveRenameDeleteAndRestore() throws {
        let directory = try TemporaryDirectory()
        Defaults.store.removeObject(forKey: "HiddenDefaultWatermarks")
        let presets = WatermarkPresets(directory: directory.url)
        #expect(presets.all.map(\.name) == ["Simple Copyright Watermark"], "Lightroom's built-in preset")

        var settings = WatermarkSettings()
        settings.text = "© Studio"
        settings.anchor = .bottomRight
        try presets.save(WatermarkPreset(name: "Studio", settings: settings))
        #expect(presets.all.map(\.name) == ["Simple Copyright Watermark", "Studio"])
        #expect(presets.preset(named: "Studio")?.settings == settings)
        #expect(FileManager.default.fileExists(atPath: directory.url.appending(path: "Studio.rlwatermark").path(percentEncoded: false)))

        try presets.rename("Studio", to: "Studio Mark")
        #expect(presets.all.map(\.name) == ["Simple Copyright Watermark", "Studio Mark"])

        presets.delete(named: "Simple Copyright Watermark")
        #expect(presets.all.map(\.name) == ["Studio Mark"], "deleting the built-in hides it")
        presets.restoreDefaults()
        #expect(presets.all.map(\.name) == ["Simple Copyright Watermark", "Studio Mark"])
        presets.delete(named: "Studio Mark")
        #expect(presets.all.map(\.name) == ["Simple Copyright Watermark"])
    }

    @Test func presetsFromOlderVersionsKeepDefaultsForNewOptions() throws {
        let json = #"{"text": "© Old", "anchor": "topRight", "opacity": 50}"#
        let settings = try JSONDecoder().decode(WatermarkSettings.self, from: Data(json.utf8))
        #expect(settings.text == "© Old")
        #expect(settings.anchor == .topRight)
        #expect(settings.opacity == 50)
        #expect(settings.shadow == WatermarkSettings.Shadow())
        #expect(settings.size == .proportional)
    }

    @Test func graphicImagesAreCopiedIntoThePresetsFolder() throws {
        let directory = try TemporaryDirectory()
        let presets = WatermarkPresets(directory: directory.url.appending(path: "Watermarks"))
        let logo = try Fixtures.writeJPEG(to: directory.url.appending(path: "Logo.jpg"))
        let name = try presets.importImage(from: logo)
        #expect(name.hasSuffix(".jpg"))
        #expect(FileManager.default.fileExists(atPath: presets.imageURL(named: name).path(percentEncoded: false)))
    }
}

@Suite("Drawing watermarks")
struct WatermarkRendererTests {
    private let photoSize = CGSize(width: 1200, height: 800)

    private func placement(_ update: (inout WatermarkSettings) -> Void) throws -> WatermarkRenderer.Placement {
        var settings = WatermarkSettings()
        settings.text = "© Example Studio"
        update(&settings)
        return try #require(WatermarkRenderer.placement(settings, imageURL: nil, photoSize: photoSize))
    }

    @Test func proportionalSizeIsAShareOfThePhotosWidth() throws {
        let frame = try placement { $0.proportionalSize = 25 }.frame
        #expect(abs(frame.width - 300) <= 2)
        #expect(frame.origin == .zero, "bottom-left with no inset")
    }

    @Test func anchorsAndInsetsPlaceTheWatermark() throws {
        let topRight = try placement { $0.anchor = .topRight; $0.horizontalInset = 5; $0.verticalInset = 10 }.frame
        #expect(abs(topRight.maxX - (1200 - 60)) <= 1)
        #expect(abs(topRight.maxY - (800 - 80)) <= 1)
        let center = try placement { $0.anchor = .center; $0.horizontalInset = 20 }.frame
        #expect(abs(center.midX - 600) <= 1 && abs(center.midY - 400) <= 1, "insets don't move a centered watermark")
    }

    @Test func fitAndFillScaleToThePhoto() throws {
        // Text metrics don't scale exactly linearly, so allow 1%.
        let fit = try placement { $0.size = .fit }.frame
        #expect(fit.width <= 1212 && fit.height <= 808)
        #expect(abs(fit.width - 1200) <= 12 || abs(fit.height - 800) <= 8, "as large as fits")
        let fill = try placement { $0.size = .fill }.frame
        #expect(fill.width >= 1188 && fill.height >= 792, "covers the photo")
        #expect(abs(fill.width - 1200) <= 12 || abs(fill.height - 800) <= 8)
    }

    @Test func aQuarterTurnSwapsItsShape() throws {
        let upright = try placement { $0.proportionalSize = 20 }.frame
        let turned = try placement { $0.proportionalSize = 20; $0.quarterTurns = 1 }.frame
        #expect(upright.width > upright.height)
        #expect(turned.height > turned.width)
        #expect(abs(turned.width - 240) <= 2, "the turned watermark is still 20% of the photo's width")
    }

    @Test func emptyTextDrawsNothing() {
        var settings = WatermarkSettings()
        settings.text = "  "
        #expect(WatermarkRenderer.placement(settings, imageURL: nil, photoSize: photoSize) == nil)
        settings.style = .graphic
        #expect(WatermarkRenderer.placement(settings, imageURL: nil, photoSize: photoSize) == nil, "no image chosen")
    }

    @Test func theWatermarkIsDrawnOverThePhotoAtItsOpacity() throws {
        let photo = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: photoSize))
        func brightest(_ opacity: Double) throws -> Double {
            var settings = WatermarkSettings()
            settings.text = "████"
            settings.size = .fit
            settings.anchor = .center
            settings.shadow.isEnabled = false
            settings.opacity = opacity
            let image = WatermarkRenderer.apply(settings, imageURL: nil, to: photo)
            #expect(image.extent == photo.extent)
            let context = CIContext()
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(image.cropped(to: CGRect(x: 600, y: 400, width: 1, height: 1)), toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: 600, y: 400, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return Double(pixel[0]) / 255
        }
        #expect(try brightest(100) > 0.95, "white text over black")
        // Core Image blends in linear light: half-opaque white over black is about 0.73 in sRGB.
        #expect(abs(try brightest(50) - 0.73) < 0.08)
        #expect(try brightest(0) < 0.02)
    }

    @Test func graphicWatermarksDrawTheImage() throws {
        let directory = try TemporaryDirectory()
        let logo = try Fixtures.writeJPEG(to: directory.url.appending(path: "Logo.jpg"), width: 200, height: 100)
        var settings = WatermarkSettings()
        settings.style = .graphic
        settings.proportionalSize = 50
        let frame = try #require(WatermarkRenderer.placement(settings, imageURL: logo, photoSize: photoSize)).frame
        #expect(abs(frame.width - 600) <= 1 && abs(frame.height - 300) <= 1)
    }
}

@Suite("Watermark Editor")
@MainActor
struct WatermarkEditorTests {
    private func editor(previews: [WatermarkPreviewPhoto] = []) throws -> (WatermarkEditorWindowController, TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        Defaults.store.removeObject(forKey: "WatermarkEditorPreset")
        Defaults.store.removeObject(forKey: "HiddenDefaultWatermarks")
        let editor = WatermarkEditorWindowController(presets: WatermarkPresets(directory: directory.url), previews: previews)
        return (editor, directory)
    }

    @Test func editingShowsEditedAndSavingMakesAPreset() throws {
        let (editor, directory) = try editor()
        _ = directory
        defer { editor.close() }
        #expect(editor.presetTitle == "Simple Copyright Watermark")
        #expect(editor.previewView.image != nil, "a sample photo with no photos selected")

        editor.opacityRow.slider.doubleValue = 60
        editor.opacityRow.slider.sendAction(editor.opacityRow.slider.action, to: editor.opacityRow.slider.target)
        #expect(editor.settings.opacity == 60)
        #expect(editor.presetTitle == "Simple Copyright Watermark (edited)")
        let menuTitles = editor.presetPopUp.itemTitles
        #expect(menuTitles.contains("Save Current Settings as New Preset…"))
        #expect(menuTitles.contains("Update preset “Simple Copyright Watermark”"))
        #expect(menuTitles.contains("Restore Default Presets"))

        try editor.saveAsNewPreset(named: "Faded")
        #expect(editor.presetTitle == "Faded")
        #expect(editor.presets.preset(named: "Faded")?.settings.opacity == 60)

        editor.choosePreset(named: "Simple Copyright Watermark")
        #expect(editor.settings.opacity == 100)
        #expect(editor.opacityRow.value == 100, "the controls follow the preset")
    }

    @Test func textOptionsApplyOnlyToTextWatermarks() throws {
        let (editor, directory) = try editor()
        _ = directory
        defer { editor.close() }
        #expect(editor.fontPopUp.isEnabled)
        editor.graphicStyleButton.performClick(nil)
        #expect(editor.settings.style == .graphic)
        #expect(!editor.fontPopUp.isEnabled)
        #expect(!editor.textView.isEditable)
        editor.textStyleButton.performClick(nil)
        #expect(editor.fontPopUp.isEnabled)
    }

    @Test func anchorsSizeAndRotationUpdateTheWatermark() throws {
        let (editor, directory) = try editor()
        _ = directory
        defer { editor.close() }
        try #require(editor.anchorButtons[.topRight]).performClick(nil)
        #expect(editor.settings.anchor == .topRight)
        #expect(editor.anchorButtons[.bottomLeft]?.state == .off)
        editor.fitButton.performClick(nil)
        #expect(editor.settings.size == .fit)
        #expect(!editor.proportionalSize.slider.isEnabled)
        editor.rotateLeftButton.performClick(nil)
        #expect(editor.settings.quarterTurns == 1)
        editor.rotateRightButton.performClick(nil)
        editor.rotateRightButton.performClick(nil)
        #expect(editor.settings.quarterTurns == 3)
    }

    @Test func theArrowsStepThroughTheSelectedPhotos() async throws {
        let folder = try TemporaryDirectory()
        let previews = try (0..<3).map {
            WatermarkPreviewPhoto(url: try Fixtures.writeJPEG(to: folder.url.appending(path: "P\($0).jpg")), adjustments: PhotoAdjustments())
        }
        let (editor, directory) = try editor(previews: previews)
        _ = directory
        defer { editor.close() }
        #expect(editor.previewStepper.isEnabled)
        editor.stepPreview(by: -1)
        #expect(editor.previewIndex == 2, "◀ wraps to the last photo")
        editor.stepPreview(by: 1)
        #expect(editor.previewIndex == 0)
    }

    @Test func theFontMenuShowsEachFontInItsOwnTypeface() throws {
        let (editor, directory) = try editor()
        _ = directory
        defer { editor.close() }
        let menu = try #require(editor.fontPopUp.menu)
        #expect(menu.delegate === editor.fontMenuStyler)
        let item = try #require(menu.item(withTitle: "Helvetica Neue"))
        #expect(item.attributedTitle == nil, "styled only when the menu opens")
        editor.fontMenuStyler.menuWillOpen(menu)
        let font = try #require(item.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.familyName == "Helvetica Neue")
        #expect(item.title == "Helvetica Neue", "choosing still goes by the family's name")
    }

    /// With one photo selected, ◀ ▶ move through the gallery, starting at it; with several, through those.
    @Test func theArrowsStepThroughTheGallery() async throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        var photos: [Photo] = []
        for index in 0..<4 {
            let photo = Photo(context: store.viewContext)
            photo.id = UUID()
            photo.fileName = "P\(index).jpg"
            photo.filePath = try Fixtures.writeJPEG(to: directory.url.appending(path: photo.fileName)).path(percentEncoded: false)
            photo.fileType = "JPG"
            photo.captureDate = Date(timeIntervalSince1970: Double(index))
            photo.importDate = Date()
            photo.editDate = Date()
            photos.append(photo)
        }
        try store.viewContext.save()
        let controller = CatalogWindowController(store: store)
        defer { controller.close() }
        controller.state.photoOrder = photos.map(\.objectID)
        controller.state.selectedPhotoIDs = [photos[2].objectID]
        let gallery = controller.watermarkPreviews
        #expect(gallery.count == 4 && gallery.startIndex == 2)
        #expect(gallery.photo(3)?.url.lastPathComponent == "P3.jpg")

        let presets = try TemporaryDirectory()
        let editor = WatermarkEditorWindowController(presets: WatermarkPresets(directory: presets.url), source: gallery)
        defer { editor.close() }
        #expect(editor.previewIndex == 2 && editor.previewStepper.isEnabled, "one photo selected: the whole gallery")
        // The stepper is wired to the editor; ▶ and ◀ step from the selected photo. (Selecting a segment
        // of a momentary control from code doesn't hold reliably, so the step is taken directly.)
        #expect(editor.previewStepper.target === editor && editor.previewStepper.action != nil)
        editor.stepPreview(by: 1)
        #expect(editor.previewIndex == 3)
        editor.stepPreview(by: -1)
        #expect(editor.previewIndex == 2)

        controller.state.selectedPhotoIDs = [photos[3].objectID, photos[1].objectID]
        let selection = controller.watermarkPreviews
        #expect(selection.count == 2 && selection.photo(0)?.url.lastPathComponent == "P1.jpg", "several selected: those, in grid order")
    }

    @Test func editWatermarksIsInTheAppMenu() {
        let appMenu = MainMenu.make().items.first?.submenu
        let titles = appMenu?.items.map(\.title) ?? []
        let settings = titles.firstIndex(of: "Settings…")
        #expect(titles.firstIndex(of: "Edit Watermarks…") == settings.map { $0 + 1 })
    }
}
