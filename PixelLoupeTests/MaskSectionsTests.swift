import AppKit
import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

@Suite("A mask's Develop sections (RAW-193)")
struct MaskSectionsTests {
    private typealias Settings = PhotoAdjustments.LocalSettings

    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    private let extent = CGRect(x: 0, y: 0, width: 200, height: 100)

    private func pixel(_ image: CIImage, _ x: Int = 100, _ y: Int = 50) -> [Float] {
        var data = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return Array(data.prefix(3))
    }

    // MARK: Model

    @Test("A mask saved before RAW-193 opens with its sliders in the sections they now belong to")
    func decodesOldMasks() throws {
        let old = #"{"exposure":-0.5,"contrast":0.2,"highlights":-0.1,"shadows":0.3,"whites":0.15,"blacks":0.3,"#
            + #""temperature":0.2,"tint":-0.1,"saturation":-0.4,"clarity":0.1,"texture":0.05,"dehaze":0.25}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        #expect(settings.light.exposure == -0.5 && settings.light.contrast == 0.2 && settings.light.highlights == -0.1)
        #expect(settings.light.shadows == 0.3 && settings.light.whites == 0.15 && settings.light.blackPoint == -0.3)
        #expect(settings.presence.saturation == -0.4 && settings.presence.clarity == 0.1)
        #expect(settings.presence.texture == 0.05 && settings.presence.dehaze == 0.25)
        #expect(settings.temperature == 0.2 && settings.tint == -0.1 && settings.isWhiteBalanceEnabled)
        // Saved again, it's in the new form, and the same.
        let resaved = try JSONEncoder().encode(settings)
        let keys = try #require(JSONSerialization.jsonObject(with: resaved) as? [String: Any]).keys
        #expect(Set(keys) == ["temperature", "tint", "light", "presence"], "\(keys)")
        #expect(try JSONDecoder().decode(Settings.self, from: resaved) == settings)
    }

    @Test("Only the sections a mask changes are saved; every section survives saving")
    func savesOnlyWhatChanged() throws {
        #expect(String(decoding: try JSONEncoder().encode(Settings()), as: UTF8.self) == "{}")
        var settings = Settings()
        settings.presence.vibrance = 0.3
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        #expect(json.contains("presence") && !json.contains("curves") && !json.contains("light"))

        settings.isWhiteBalanceEnabled = false
        settings.temperature = 0.4
        settings.light.brilliance = 0.2
        settings.color.shadows = .init(hue: 0.6, amount: 0.3, luminance: 0)
        settings.blackAndWhite = .init(isEnabled: true, tone: 0.2)
        settings.curves.rgb = ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.4), .init(x: 1, y: 1)])
        settings.levels.gamma = 1.2
        settings.definition.intensity = 0.3
        settings.selectiveColor.ranges[0].saturation = -0.5
        settings.noiseReduction.amount = 0.4
        settings.effects.grain = 0.3
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test("The sections go to the panel's controls and back unchanged, with the white balance shift and its switch")
    func adjustmentsRoundTrip() {
        var settings = Settings()
        settings.temperature = 0.3
        settings.tint = -0.2
        settings.isWhiteBalanceEnabled = false
        settings.levels.inputBlack = 0.1
        settings.effects.grain = 0.2
        let adjustments = settings.adjustments
        #expect(adjustments.whiteBalance.temperature == 0.3 && !adjustments.whiteBalance.isEnabled)
        #expect(Settings(adjustments) == settings, "turning White Balance off keeps its values")
        #expect(Settings(Settings().adjustments) == Settings())
    }

    // MARK: Rendering

    @Test("Each section changes what the mask covers")
    func eachSectionRenders() {
        let base = CIImage(color: CIColor(red: 0.6, green: 0.45, blue: 0.3)).cropped(to: extent)
        let plain = pixel(base)
        func rendered(_ configure: (inout Settings) -> Void) -> [Float] {
            var settings = Settings()
            configure(&settings)
            return pixel(LocalAdjustmentRenderer.adjust(base, with: settings))
        }
        func differs(_ a: [Float], _ b: [Float]) -> Bool { zip(a, b).contains { abs($0 - $1) > 0.01 } }

        let gray = rendered { $0.blackAndWhite = .init(isEnabled: true) }
        #expect(gray.max()! - gray.min()! < 0.01, "Black & White: \(gray)")
        #expect(rendered { $0.curves.rgb = ToneCurve(points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.3), .init(x: 1, y: 1)]) }[0] < plain[0])
        #expect(rendered { $0.levels.inputWhite = 0.7 }[0] > plain[0])
        #expect(differs(rendered { $0.color.global = .init(hue: 0.6, amount: 0.6, luminance: 0) }, plain), "Color Grading")
        #expect(differs(rendered { $0.selectiveColor.ranges[1].saturation = -1 }, plain), "Color Mixer (orange)")
        #expect(differs(rendered { $0.presence.vibrance = 1 }, plain))
        #expect(rendered { $0.light.brightness = 0.5 }[0] > plain[0])
        #expect(rendered { $0.temperature = 1 }[0] > plain[0])
        #expect(rendered { settings in
            settings.temperature = 1
            settings.isWhiteBalanceEnabled = false
        } == plain, "White Balance switched off")
        var off = Settings()
        off.light.exposure = 1
        off.light.isEnabled = false
        #expect(pixel(LocalAdjustmentRenderer.adjust(base, with: off)) == plain, "Light switched off")

        // Grain and noise reduction work on texture: grain varies a flat color.
        var grainy = Settings()
        grainy.effects.grain = 1
        grainy.effects.grainSeed = 7
        let grain = LocalAdjustmentRenderer.adjust(base, with: grainy)
        let samples = (0..<20).map { pixel(grain, 10 + $0 * 9, 50)[0] }
        #expect(samples.max()! - samples.min()! > 0.02)
    }

    @Test("A mask's sections render just as the photo's do")
    func matchesThePhotosSections() {
        let base = CIImage(color: CIColor(red: 0.5, green: 0.4, blue: 0.35)).cropped(to: extent)
        var settings = Settings()
        settings.light.contrast = 0.4
        settings.light.shadows = 0.3
        settings.levels.gamma = 1.3
        settings.color.highlights = .init(hue: 0.1, amount: 0.4, luminance: 0)
        settings.presence.saturation = 0.3
        let local = pixel(LocalAdjustmentRenderer.adjust(base, with: settings))
        let global = pixel(AdjustmentPipeline.applyTone(settings.adjustments, to: base, longEdge: 200, reducesNoise: true))
        #expect(zip(local, global).allSatisfy { abs($0 - $1) < 0.001 }, "\(local) vs \(global)")
    }

    // MARK: Panel

    @MainActor
    @Test("Under a mask: the Adjust panel's sections a mask can apply, in its order, editing the mask")
    func panelSections() throws {
        let panel = MaskPanelViewController()
        var mask = PhotoAdjustments.LocalAdjustment()
        mask.components = [.init(shape: .radial(MaskGeometry.defaultRadial()))]
        mask.settings.exposure = -0.5
        panel.display(masks: [mask])
        let view = panel.view

        let titles = ["White Balance", "Light", "Presence", "Color Grading", "Black & White", "Curves", "Levels", "Definition",
                      "Color Mixer", "Noise Reduction", "Effects"]
        let sections = titles.compactMap { subview("adjustSection.Mask.\($0)", of: AdjustmentSectionView.self, in: view) }
        #expect(sections.count == titles.count, "\(sections.count) of \(titles.count)")
        let tops = sections.map { $0.convert($0.bounds, to: view).midY }
        #expect(tops == tops.sorted(by: view.isFlipped ? (<) : (>)), "in order")
        for photoOnly in ["Profile", "Sharpen", "Post-Crop Vignette", "Transform", "Calibration", "Red-Eye"] {
            #expect(subview("adjustSection.Mask.\(photoOnly)", of: AdjustmentSectionView.self, in: view) == nil, "\(photoOnly)")
            #expect(subview("adjustSection.\(photoOnly)", of: AdjustmentSectionView.self, in: view) == nil, "\(photoOnly)")
        }
        #expect(subview("revertToOriginal", of: NSButton.self, in: view) == nil)
        // Only Light starts open (each remembers its own state under masks, apart from the photo's).
        #expect(Defaults.store.object(forKey: "AdjustSectionExpanded.Mask.Light") as? Bool == true)
        #expect(Defaults.store.object(forKey: "AdjustSectionExpanded.Mask.Color Grading") as? Bool == false)

        // The controls show the mask's settings and edit them.
        let exposure = try #require(subview("slider.Mask.Light.Exposure", of: SliderRow.self, in: view))
        #expect(exposure.value == -0.5)
        var sent: (PhotoAdjustments.LocalAdjustment, Bool, String)?
        panel.onChange = { masks, isFinal, action in sent = (masks[0], isFinal, action) }
        try #require(subview("slider.Mask.Presence.Vibrance", of: SliderRow.self, in: view)).onChange?(0.4, true)
        #expect(sent?.0.settings.presence.vibrance == 0.4 && sent?.0.settings.exposure == -0.5)
        #expect(sent?.1 == true && sent?.2 == "Adjust Mask Presence")
        try #require(subview("slider.Mask.White Balance.Temp", of: SliderRow.self, in: view)).onChange?(0.25, true)
        #expect(sent?.0.settings.temperature == 0.25 && sent?.0.settings.presence.vibrance == 0.4)

        // Another mask's settings replace them.
        var other = mask
        other.id = UUID()
        other.settings = .init()
        panel.display(masks: [mask, other], selecting: other.id)
        #expect(exposure.value == 0)
    }

    private func subview<View: NSView>(_ identifier: String, of type: View.Type, in view: NSView) -> View? {
        if let view = view as? View, view.accessibilityIdentifier() == identifier { return view }
        return view.subviews.lazy.compactMap { self.subview(identifier, of: type, in: $0) }.first
    }
}

@MainActor
@Suite("Undo in Masking (RAW-189)", .serialized)
struct MaskUndoTests {
    @Test("Undo and redo in Masking change the masks shown, not just the photo")
    func undoShowsInTheMaskingPanel() async throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let photo = Photo(context: store.viewContext)
        photo.id = UUID()
        photo.fileName = "IMG.jpg"
        let url = directory.url.appending(path: photo.fileName)
        try Fixtures.writeJPEG(to: url, width: 600, height: 400)
        photo.filePath = url.path(percentEncoded: false)
        photo.fileType = "JPG"
        photo.pixelWidth = 600
        photo.pixelHeight = 400
        photo.orientation = 1
        photo.captureDate = Date()
        photo.importDate = Date()
        photo.editDate = Date()
        try store.viewContext.save()
        let undo = try #require(store.viewContext.undoManager)
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        undo.removeAllActions()

        let controller = CatalogWindowController(store: store)
        controller.showWindow(nil)
        defer { controller.close() }
        controller.state.selectedPhotoIDs = [try #require(controller.state.photoOrder.first)]
        controller.state.mode = .develop
        controller.state.developTool = .mask
        let develop = controller.rootViewController.main.develop
        let start = Date()
        while !develop.canAutoLight, Date().timeIntervalSince(start) < 30 { try await Task.sleep(for: .milliseconds(50)) }

        undo.beginUndoGrouping()
        develop.addMask(.radial)
        undo.endUndoGrouping()
        #expect(photo.adjustments.masks.count == 1 && develop.shownMasks.count == 1)

        undo.undo()
        #expect(photo.adjustments.masks.isEmpty, "the photo's settings went back")
        #expect(develop.currentAdjustments?.masks.isEmpty == true)
        #expect(develop.shownMasks.isEmpty, "and the Masking panel shows it")

        undo.redo()
        #expect(develop.shownMasks.count == 1, "redo brings it back")
    }
}
