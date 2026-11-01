import Foundation
import Testing
@testable import PixelLoupe

/// RAW-244: the presets PixelLoupe ships with, listed as “PixelLoupe Presets” and read-only.
@MainActor
struct BuiltInPresetTests {
    @Test func appShipsItsPresetsUnderOneGroup() throws {
        let files = PresetLibrary.bundledPresetFiles
        #expect(files.count == 27)
        let presets = files.compactMap { DevelopPreset.load($0, defaultGroup: "") }
        #expect(presets.count == files.count, "every bundled file is a preset")
        #expect(Set(presets.map(\.group)) == [PresetLibrary.builtInGroup])
        #expect(Set(presets.map(\.name)).count == presets.count, "no two share a name")
        #expect(Set(presets.compactMap { $0.settings["UUID"]?.string }).count == presets.count, "each has its own UUID")
        #expect(presets.contains { $0.name == "Film Simulation - Velvia" })
        #expect(presets.contains { $0.name == "Portrait - Red/Orange Glow" })
    }

    @Test func bundledPresetsLeaveLensAndPhotoToolsAlone() {
        // Applying a look mustn't turn off the photo's lens corrections, Upright or Portrait Lighting.
        let prefixes = ["Lens", "Perspective", "Defringe", "AutoLateralCA", "PixelLoupe"]
        for url in PresetLibrary.bundledPresetFiles {
            guard let preset = DevelopPreset.load(url, defaultGroup: "") else { continue }
            let keys = preset.settingKeys.filter { key in prefixes.contains { key.hasPrefix($0) } }
            #expect(keys.isEmpty, "\(preset.name) sets \(keys.sorted())")
        }
    }

    @Test func bundledPresetsNeedNoProfileTheUserMightNotHave() {
        // Only Adobe's standard looks, which PixelLoupe has stand-ins for: no third-party profiles.
        let photo = DevelopPreset.Photo(cameraModel: "Canon EOS R5")
        let profiles = AdobeProfileLibrary(directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        for url in PresetLibrary.bundledPresetFiles {
            guard let preset = DevelopPreset.load(url, defaultGroup: "") else { continue }
            #expect(preset.compatibility(with: photo, profiles: profiles) == .compatible, "\(preset.name)")
        }
    }

    @Test func libraryListsBuiltInPresetsButWontChangeThem() async throws {
        let directory = try TemporaryDirectory()
        let source = try directory.subdirectory("Source")
        let builtIn = source.appending(path: "Warm.xmp")
        try PresetFixtures.xmp(name: "Warm", group: PresetLibrary.builtInGroup, attributes: ["Vibrance": "20"]).write(to: builtIn)
        let library = PresetLibrary(directory: directory.url.appending(path: "Settings", directoryHint: .isDirectory), builtInFiles: [builtIn])
        library.deletesToTrash = false
        await library.load()
        let preset = try #require(library.presets.first)
        #expect(library.groups.map(\.name) == [PresetLibrary.builtInGroup])
        #expect(library.isBuiltIn(preset))

        await #expect(throws: PresetLibrary.PresetError.self) { try await library.rename(preset, to: "Hot") }
        await #expect(throws: PresetLibrary.PresetError.self) { try await library.delete(preset) }
        await #expect(throws: PresetLibrary.PresetError.self) { try await library.update(preset, with: PhotoAdjustments()) }
        #expect(FileManager.default.fileExists(atPath: builtIn.path(percentEncoded: false)), "the file is untouched")

        // Your own presets sit alongside and stay editable.
        let own = try await library.createPreset(name: "Mine", group: "User Presets", from: PhotoAdjustments(), sections: [.basicTone])
        #expect(!library.isBuiltIn(own))
        #expect(library.groups.map(\.name) == [PresetLibrary.builtInGroup, "User Presets"])
    }
}
