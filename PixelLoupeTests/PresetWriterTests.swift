import AppKit
import Foundation
import Testing
@testable import PixelLoupe

/// RAW-59: presets made in PixelLoupe.
@Suite("Preset writer")
struct PresetWriterTests {
    /// Settings with something in every section a preset can hold.
    static func edited() -> PhotoAdjustments {
        var a = PhotoAdjustments()
        a.whiteBalance = .init(isEnabled: true, temperature: 5200, tint: 12, preset: nil)
        a.light.exposure = 0.35
        a.light.contrast = 0.2
        a.light.highlights = -0.4
        a.light.shadows = 0.3
        a.light.whites = 0.1
        a.light.blackPoint = 0.15
        a.presence = .init(isEnabled: true, texture: 0.1, clarity: 0.25, dehaze: 0.05, vibrance: 0.3, saturation: -0.1)
        a.curves.rgb = ToneCurve(points: [.init(x: 0, y: 20.0 / 255), .init(x: 128.0 / 255, y: 140.0 / 255), .init(x: 1, y: 1)])
        a.curves.parametric = ParametricCurve(shadows: 0.1, darks: -0.2, lights: 0.15, highlights: -0.05, shadowSplit: 0.3, midtoneSplit: 0.5, highlightSplit: 0.7)
        a.selectiveColor[.blue].hue = -0.2
        a.selectiveColor[.orange].saturation = 0.3
        a.selectiveColor[.green].luminance = -0.1
        a.color.shadows = .init(hue: 0.6, amount: 0.2, luminance: -0.05)
        a.color.highlights = .init(hue: 0.1, amount: 0.15, luminance: 0)
        a.color.blending = 0.6
        a.color.balance = -0.2
        a.blackAndWhite.isEnabled = true
        a.blackAndWhite[.red] = -0.12
        a.blackAndWhite[.blue] = 0.15
        a.sharpen = .init(isEnabled: true, intensity: 0.4, radius: 1.2, detail: 0.3, masking: 0.2)
        a.noiseReduction.amount = 0.2
        a.noiseReduction.color = 0.3
        a.noiseReduction.detail = 0.6
        a.vignette.strength = 0.25
        a.vignette.radius = 0.4
        a.vignette.softness = 0.6
        a.effects.grain = 0.2
        a.effects.grainSize = 0.3
        a.effects.grainRoughness = 0.4
        a.transform.vertical = 0.1
        a.transform.rotate = 1.5
        a.calibration.redHue = 0.1
        a.calibration.blueSaturation = -0.2
        a.profile = .init(kind: .vivid, amount: 0.8)
        return a
    }

    @Test func aWrittenPresetAppliesTheSameSettings() throws {
        let original = Self.edited()
        let settings = PresetWriter.settings(for: original, sections: Set(PresetSection.allCases))
        let data = PresetWriter.xmp(name: "My <Look> & More", group: "Mine", settings: settings)
        let preset = try #require(DevelopPreset.parse(data, url: URL(filePath: "/p/mine.xmp"), defaultGroup: "x"))
        #expect(preset.name == "My <Look> & More" && preset.group == "Mine" && preset.supportsAmount)
        let applied = preset.applied(to: PhotoAdjustments(), isRaw: true)
        #expect(applied.whiteBalance.temperature == 5200 && applied.whiteBalance.tint == 12)
        // Shadows, Highlights, Clarity and the parametric curve aren't a straight ×100 in Lightroom (RAW-229), so
        // Lightroom's whole numbers bring them back to within a slider step.
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.01 }
        var light = applied.light
        #expect(close(light.highlights, original.light.highlights) && close(light.shadows, original.light.shadows))
        light.highlights = original.light.highlights
        light.shadows = original.light.shadows
        #expect(light == original.light, "\(applied.light) vs \(original.light)")
        var presence = applied.presence
        #expect(close(presence.clarity, original.presence.clarity))
        presence.clarity = original.presence.clarity
        #expect(presence == original.presence)
        let (p, q) = (applied.curves.parametric, original.curves.parametric)
        #expect(applied.curves.rgb == original.curves.rgb)
        #expect(zip(p.amounts, q.amounts).allSatisfy { close($0, $1) } && p.shadowSplit == q.shadowSplit && p.highlightSplit == q.highlightSplit)
        #expect(applied.selectiveColor == original.selectiveColor)
        #expect(applied.color == original.color, "\(applied.color) vs \(original.color)")
        #expect(applied.blackAndWhite.isEnabled && applied.blackAndWhite[.red] == original.blackAndWhite[.red])
        #expect(applied.sharpen == original.sharpen, "\(applied.sharpen) vs \(original.sharpen)")
        #expect(applied.noiseReduction.amount == 0.2 && applied.noiseReduction.color == 0.3 && applied.noiseReduction.detail == 0.6)
        #expect(applied.vignette.strength == 0.25 && applied.vignette.radius == 0.4 && applied.vignette.softness == 0.6)
        #expect(applied.effects.grain == 0.2 && applied.effects.grainSize == 0.3 && applied.effects.grainRoughness == 0.4)
        #expect(applied.transform.vertical == 0.1 && applied.transform.rotate == 1.5)
        #expect(applied.calibration == original.calibration)
        #expect(applied.profile.kind == .vivid && applied.profile.amount == 0.8)
    }

    @Test func onlyTheChosenSectionsAreWritten() throws {
        var photo = PhotoAdjustments()
        photo.light.exposure = 1.2
        photo.presence.clarity = 0.4
        let settings = PresetWriter.settings(for: Self.edited(), sections: [.presence])
        #expect(settings["Clarity2012"] == .number(30) && settings["Exposure2012"] == nil, "Clarity 0.25 is Lightroom's +30")
        let preset = try #require(DevelopPreset.parse(PresetWriter.xmp(name: "P", group: "G", settings: settings), url: URL(filePath: "/p/p.xmp"),
                                                      defaultGroup: "x"))
        let applied = preset.applied(to: photo, isRaw: true)
        #expect(applied.light.exposure == 1.2, "Basic Tone wasn't chosen")
        #expect(abs(applied.presence.clarity - 0.25) < 0.01)
        #expect(PresetSection.sections(of: preset.settingKeys) == [.presence])
    }

    @Test func signsLikeLightroom() {
        let text = String(decoding: PresetWriter.xmp(name: "S", group: "G", settings: PresetWriter.settings(for: Self.edited(), sections: Set(PresetSection.allCases))),
                          as: UTF8.self)
        #expect(text.contains(#"crs:Contrast2012="+20""#) && text.contains(#"crs:Blacks2012="-15""#))
        #expect(text.contains(#"crs:GrainAmount="20""#) && text.contains(#"crs:ColorGradeShadowHue="216""#) && text.contains(#"crs:Temperature="5200""#))
    }
}

@Suite("Your own presets")
@MainActor
struct UserPresetTests {
    private func library(_ directory: TemporaryDirectory) -> PresetLibrary {
        let library = PresetLibrary(directory: directory.url.appending(path: "Settings", directoryHint: .isDirectory))
        library.deletesToTrash = false
        return library
    }

    @Test func createUpdateRenameAndDelete() async throws {
        let directory = try TemporaryDirectory()
        let library = library(directory)
        var settings = PhotoAdjustments()
        settings.presence.clarity = 0.3
        settings.light.exposure = 0.5

        let preset = try await library.createPreset(name: "Crisp", group: "Mine", from: settings, sections: [.presence])
        #expect(preset.group == "Mine" && library.groups.map(\.name) == ["Mine"])
        #expect(preset.url.deletingLastPathComponent().lastPathComponent == "Mine")
        #expect(abs(preset.applied(to: PhotoAdjustments(), isRaw: true).presence.clarity - 0.3) < 0.01)
        #expect(preset.applied(to: PhotoAdjustments(), isRaw: true).light.exposure == 0, "only Presence was chosen")
        await #expect(throws: PresetLibrary.PresetError.self) {
            try await library.createPreset(name: "Crisp", group: "Mine", from: settings, sections: [.presence])
        }
        await #expect(throws: PresetLibrary.PresetError.self) {
            try await library.createPreset(name: "  ", group: "Mine", from: settings, sections: [.presence])
        }

        // Update with current settings: the same sections, the new values, the same identity.
        let uuid = preset.settings["UUID"]?.string
        settings.presence.clarity = -0.2
        try await library.update(preset, with: settings)
        let updated = try #require(library.presets.first)
        #expect(updated.applied(to: PhotoAdjustments(), isRaw: true).presence.clarity == -0.2)
        #expect(updated.settings["UUID"]?.string == uuid && updated.name == "Crisp")
        #expect(PresetSection.sections(of: updated.settingKeys) == [.presence])

        // Rename and move to another group.
        try await library.rename(updated, to: "Soft", group: "Other")
        #expect(library.presets.map(\.name) == ["Soft"] && library.groups.map(\.name) == ["Other"])
        #expect(!FileManager.default.fileExists(atPath: updated.url.path(percentEncoded: false)), "the old file is gone")
        let renamed = try #require(library.presets.first)
        #expect(renamed.applied(to: PhotoAdjustments(), isRaw: true).presence.clarity == -0.2, "settings untouched")

        try await library.delete(renamed)
        #expect(library.presets.isEmpty)
    }

    /// Renaming an imported preset edits only its name and group, so everything else in it survives.
    @Test func renamingKeepsEverythingElseInTheFile() async throws {
        let directory = try TemporaryDirectory()
        let library = library(directory)
        let source = try directory.subdirectory("Source")
        try PresetISOTests.adaptive().write(to: source.appending(path: "nr.xmp"))
        await library.importPresets(from: [source])
        let preset = try #require(library.presets.first)
        #expect(preset.isoPoints.count == 4)
        try await library.renameGroup(preset.group, to: "Noise")
        let moved = try #require(library.presets.first)
        #expect(moved.group == "Noise" && moved.name == preset.name && moved.isoPoints.count == 4)
    }

    @Test func thePanelCreatesAndSelectsTheNewPreset() async throws {
        let directory = try TemporaryDirectory()
        let library = library(directory)
        let panel = PresetsPanelViewController(library: library)
        _ = panel.view
        var settings = PhotoAdjustments()
        settings.presence.vibrance = 0.4
        panel.currentSettings = { settings }
        await panel.createPreset(name: "Bright", group: "Mine", from: settings, sections: [.presence])
        #expect(panel.selectedPreset?.name == "Bright", "selected in the list")
        #expect(panel.groups.map(\.name) == ["Mine"])
    }
}
