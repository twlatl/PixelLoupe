import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

/// RAW-57: Lightroom's preset Amount.
@Suite("Preset amount")
struct PresetAmountTests {
    private func pair() -> (PhotoAdjustments, PhotoAdjustments) {
        var before = PhotoAdjustments()
        before.light.exposure = 0.5
        before.presence.vibrance = 0
        before.effects.grainSeed = 3
        var full = before
        full.presence.vibrance = 0.4
        full.presence.clarity = -0.2
        full.blackAndWhite.isEnabled = true
        full.effects.grainSeed = 8
        full.curves.rgb = ToneCurve(points: [.init(x: 0, y: 0.1), .init(x: 0.5, y: 0.55), .init(x: 1, y: 0.95)])
        return (before, full)
    }

    @Test func numbersGoBetweenAndBeyond() {
        let (before, full) = pair()
        let half = PresetAmount.settings(before: before, full: full, amount: 0.5)
        #expect(abs(half.presence.vibrance - 0.2) < 1e-9 && abs(half.presence.clarity + 0.1) < 1e-9)
        #expect(half.light.exposure == 0.5, "unchanged settings stay")
        let double = PresetAmount.settings(before: before, full: full, amount: 2)
        #expect(abs(double.presence.vibrance - 0.8) < 1e-9, "200% doubles the change")
        #expect(PresetAmount.settings(before: before, full: full, amount: 0) == before)
        #expect(PresetAmount.settings(before: before, full: full, amount: 1) == full)
    }

    @Test func switchesAndShapesChangeAtHalfway() {
        let (before, full) = pair()
        #expect(!PresetAmount.settings(before: before, full: full, amount: 0.4).blackAndWhite.isEnabled)
        #expect(PresetAmount.settings(before: before, full: full, amount: 0.6).blackAndWhite.isEnabled)
        // The identity curve has two points, the preset's three: it switches rather than blends.
        #expect(PresetAmount.settings(before: before, full: full, amount: 0.4).curves.rgb == before.curves.rgb)
        #expect(PresetAmount.settings(before: before, full: full, amount: 0.6).curves.rgb == full.curves.rgb)
        // Whole numbers stay whole.
        let seed = PresetAmount.settings(before: before, full: full, amount: 0.5).effects.grainSeed
        #expect(seed == 6 || seed == 5)
    }
}

@Suite("Preset amount in Develop")
@MainActor
struct PresetAmountDevelopTests {
    @Test(.timeLimit(.minutes(3))) func theAmountSliderScalesThePresetAndEndsWithAnotherEdit() async throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        let photo = Photo(context: store.viewContext)
        photo.id = UUID()
        photo.fileName = "IMG.jpg"
        let url = directory.url.appending(path: photo.fileName)
        try Fixtures.writeJPEG(to: url, width: 400, height: 300)
        photo.filePath = url.path(percentEncoded: false)
        photo.fileType = "JPG"
        photo.pixelWidth = 400
        photo.pixelHeight = 300
        photo.captureDate = Date()
        photo.importDate = Date()
        photo.editDate = Date()
        try store.viewContext.save()
        let controller = CatalogWindowController(store: store)
        defer { controller.close() }
        controller.showWindow(nil)
        controller.state.selectedPhotoIDs = [photo.objectID]
        controller.state.mode = .develop
        controller.state.developTool = .presets
        let develop = controller.rootViewController.main.develop
        let start = Date()
        while !develop.canAutoLight, Date().timeIntervalSince(start) < 60 { try? await Task.sleep(for: .seconds(0.1)) }
        try #require(develop.canAutoLight)

        let preset = try #require(DevelopPreset.parse(PresetFixtures.xmp(name: "Punch", group: "Color", attributes: ["Vibrance": "40"]),
                                                      url: URL(filePath: "/p/punch.xmp"), defaultGroup: "x"))
        #expect(preset.supportsAmount)
        develop.applyPreset(preset)
        let panel = develop.presetsPanelForTesting
        #expect(panel.isShowingAmount && panel.amountSlider.doubleValue == 100 && panel.amountLabel.stringValue.contains("Punch"))
        let full = try #require(develop.currentAdjustments).presence.vibrance
        #expect(full > 0)

        develop.setPresetAmount(0.5, isFinal: true)
        #expect(abs(try #require(develop.currentAdjustments).presence.vibrance - full / 2) < 1e-9)
        #expect(abs(photo.adjustments.presence.vibrance - full / 2) < 1e-9, "saved")
        #expect(DevelopHistory.steps(for: photo).last?.name == "Preset: Punch 50%")
        develop.setPresetAmount(1.5, isFinal: true)
        #expect(abs(photo.adjustments.presence.vibrance - full * 1.5) < 1e-9, "past 100%")

        // Another edit ends it.
        develop.applyAutoLight()
        if photo.adjustments.light != PhotoAdjustments().light { #expect(!panel.isShowingAmount) }
        develop.applyPreset(preset)
        #expect(panel.isShowingAmount)
        let fixed = try #require(DevelopPreset.parse(
            PresetFixtures.xmp(name: "Fixed", group: "Color", attributes: ["Clarity2012": "15", "SupportsAmount": "False"]),
            url: URL(filePath: "/p/fixed.xmp"), defaultGroup: "x"))
        #expect(!fixed.supportsAmount)
        develop.applyPreset(fixed)
        #expect(!panel.isShowingAmount, "a preset without an amount hides it")
    }
}
