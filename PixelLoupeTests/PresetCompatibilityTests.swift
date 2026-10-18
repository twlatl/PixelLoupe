import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

/// RAW-60. The presets are written by the tests, after the files Lightroom writes.
@Suite("Presets: compatibility")
@MainActor
struct PresetCompatibilityTests {
    private func preset(_ attributes: [String: String], look: String? = nil, name: String = "P") throws -> DevelopPreset {
        try #require(DevelopPreset.parse(PresetFixtures.xmp(name: name, group: "G", attributes: attributes, look: look),
                                         url: URL(filePath: "/p/\(name).xmp"), defaultGroup: "G"))
    }

    @Test func whatAPresetDeclaresDecidesWhetherItSuits() throws {
        let nikon = DevelopPreset.Photo(cameraModel: "NIKON Z 8")
        let empty = AdobeProfileLibrary(directory: URL(filePath: "/nonexistent-\(UUID())"))
        #expect(try preset(["Vibrance": "10"]).compatibility(with: nikon, profiles: empty) == .compatible)
        #expect(try preset(["CameraModelRestriction": "Nikon Z 8"]).compatibility(with: nikon, profiles: empty) == .compatible,
                "the same camera, however it's written")
        guard case .incompatible = try preset(["CameraModelRestriction": "Canon EOS R5"]).compatibility(with: nikon, profiles: empty) else {
            Issue.record("another camera's preset suits"); return
        }
        guard case .incompatible = try preset(["SupportsColor": "False"]).compatibility(with: nikon, profiles: empty) else {
            Issue.record("a monochrome-camera preset suits a color photo"); return
        }
        let monochrom = DevelopPreset.Photo(cameraModel: "LEICA M11 Monochrom")
        #expect(monochrom.isMonochrome)
        guard case .incompatible = try preset(["SupportsMonochrome": "False"]).compatibility(with: monochrom, profiles: empty) else {
            Issue.record("a color preset suits a monochrome camera"); return
        }
        guard case .incompatible = try preset(["SupportsNormalDynamicRange": "False"]).compatibility(with: nikon, profiles: empty) else {
            Issue.record("an HDR-only preset suits"); return
        }
    }

    @Test func aPresetWhoseProfileIsMissingIsPartiallyCompatible() throws {
        let photo = DevelopPreset.Photo(cameraModel: "NIKON Z 8")
        let profiles = AdobeProfileLibrary(directory: URL(filePath: "/nonexistent-\(UUID())"))
        #expect(try preset([:], look: "Adobe Vivid").compatibility(with: photo, profiles: profiles) == .compatible,
                "PixelLoupe has its own Adobe Vivid")
        #expect(try preset(["CameraProfile": "Default Color"]).compatibility(with: photo, profiles: profiles) == .compatible,
                "Lightroom's name for the camera's default profile")
        let vintage = try preset([:], look: "Vintage 06")
        #expect(vintage.compatibility(with: photo, profiles: profiles).reason?.contains("Vintage 06") == true)
        profiles.register(try #require(AdobeProfile.parse(ProfileFixtures.swapProfile(name: "Vintage 06"))))
        #expect(vintage.compatibility(with: photo, profiles: profiles) == .compatible, "once the profile is imported")
    }

    @Test func thePanelHidesIncompatibleAndDimsPartiallyCompatiblePresets() async throws {
        let directory = try TemporaryDirectory()
        let source = try directory.subdirectory("Source")
        try PresetFixtures.xmp(name: "Any", group: "G", attributes: ["Vibrance": "10"]).write(to: source.appending(path: "a.xmp"))
        try PresetFixtures.xmp(name: "Canon Only", group: "G", attributes: ["CameraModelRestriction": "Canon EOS R5"])
            .write(to: source.appending(path: "b.xmp"))
        try PresetFixtures.xmp(name: "Vintage", group: "G", attributes: [:], look: "Vintage 06").write(to: source.appending(path: "c.xmp"))
        let library = PresetLibrary(directory: directory.url.appending(path: "Settings", directoryHint: .isDirectory))
        await library.importPresets(from: [source])
        let suite = "PresetCompatibilityTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let panel = PresetsPanelViewController(library: library, defaults: defaults)
        _ = panel.view
        panel.reloadList()
        #expect(panel.groups.first?.presets.count == 3, "without a photo, every preset")
        panel.photo = .init(cameraModel: "NIKON Z 8")
        #expect(panel.groups.first?.presets.map(\.name) == ["Any", "Vintage"], "the Canon preset is hidden")
        let vintage = try #require(panel.groups.first?.presets.last)
        #expect(panel.partialCompatibility(of: vintage) != nil)
        #expect(panel.partialCompatibility(of: try #require(panel.groups.first?.presets.first)) == nil)

        panel.togglePartiallyCompatible(nil)
        #expect(!panel.showsPartiallyCompatible)
        #expect(panel.groups.first?.presets.map(\.name) == ["Any"])
        #expect(defaults.object(forKey: "ShowPartiallyCompatiblePresets") as? Bool == false, "remembered (in the test's own defaults)")
    }
}

@Suite("Presets: older .lrtemplate presets")
@MainActor
struct LegacyPresetTests {
    /// A Develop preset as Lightroom 7.2 and earlier wrote it.
    static let template = """
    s = {
    \tid = "6C1A3B5E-0000-4000-8000-000000000001",
    \tinternalName = "Faded",
    \ttitle = ZSTR "$$$/AgDevelop/Presets/Faded=Faded Film",
    \ttype = "Develop",
    \tvalue = {
    \t\tsettings = {
    \t\t\tExposure2012 = 0.35,
    \t\t\tContrast2012 = -20,
    \t\t\tConvertToGrayscale = false,
    \t\t\tToneCurveName2012 = "Custom",
    \t\t\tToneCurvePV2012 = {
    \t\t\t\t0,
    \t\t\t\t30,
    \t\t\t\t255,
    \t\t\t\t235,
    \t\t\t},
    \t\t\tRetouchInfo = {},
    \t\t},
    \t\tuuid = "6C1A3B5E-0000-4000-8000-000000000002",
    \t},
    \tversion = 0,
    }
    """

    @Test func aTemplateConvertsToAnXMPPreset() throws {
        let converted = try #require(LegacyPreset.convert(Data(Self.template.utf8), url: URL(filePath: "/x/Faded.lrtemplate"), defaultGroup: "Film"))
        #expect(converted.name == "Faded Film" && converted.group == "Film")
        let preset = try #require(DevelopPreset.parse(converted.xmp, url: URL(filePath: "/x/Faded Film.xmp"), defaultGroup: "x"))
        #expect(preset.name == "Faded Film" && preset.group == "Film")
        #expect(preset.settings["UUID"]?.string == "6C1A3B5E000040008000000000000002")
        let applied = preset.applied(to: PhotoAdjustments(), isRaw: true)
        var expected = PhotoAdjustments()
        _ = LightroomDevelopMapper.apply(.init(settings: try LuaTableParser.parse("{ Exposure2012 = 0.35, Contrast2012 = -20, ToneCurvePV2012 = { 0, 30, 255, 235 } }").table!,
                                               processVersion: "11.0", whiteBalance: nil, isRaw: true, seed: 1), to: &expected)
        #expect(applied.light.exposure == expected.light.exposure && applied.light.contrast == expected.light.contrast)
        #expect(applied.curves.rgb == expected.curves.rgb && !applied.curves.rgb.isIdentity)
        #expect(!applied.blackAndWhite.isEnabled)
    }

    @Test func otherTemplatesAreNotPresets() {
        let export = "s = { title = \"JPEG\", type = \"export\", value = { settings = {} } }"
        #expect(LegacyPreset.convert(Data(export.utf8), url: URL(filePath: "/x/e.lrtemplate"), defaultGroup: "x") == nil)
        #expect(LegacyPreset.convert(Data("not lua".utf8), url: URL(filePath: "/x/n.lrtemplate"), defaultGroup: "x") == nil)
    }

    @Test func importingAFolderConvertsItsTemplates() async throws {
        let directory = try TemporaryDirectory()
        let source = try directory.subdirectory("Develop Presets")
        let folder = source.appending(path: "Film Looks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(Self.template.utf8).write(to: folder.appending(path: "Faded.lrtemplate"))
        try PresetFixtures.xmp(name: "Warm", group: "Color", attributes: ["Vibrance": "20"]).write(to: source.appending(path: "Warm.xmp"))
        let library = PresetLibrary(directory: directory.url.appending(path: "Settings", directoryHint: .isDirectory))
        let result = await library.importPresets(from: [source])
        #expect(result.presets == 2)
        #expect(library.groups.map(\.name) == ["Color", "Film Looks"], "a template's group is its folder")
        let faded = try #require(library.presets.first { $0.name == "Faded Film" })
        #expect(faded.url.pathExtension == "xmp", "saved as .xmp")

        // A single template file too.
        let other = try directory.subdirectory("Loose")
        try Data(Self.template.replacingOccurrences(of: "Faded Film", with: "Loose One").utf8).write(to: other.appending(path: "L.lrtemplate"))
        #expect(await library.importPresets(from: [other.appending(path: "L.lrtemplate")]).presets == 1)
    }
}

@Suite("Presets: hover preview")
@MainActor
struct PresetHoverTests {
    @Test func hoveringPreviewsWithoutChangingThePhoto() async throws {
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
        let before = photo.adjustments
        let panel = develop.presetsPanelForTesting
        panel.setHovered(preset)
        var waited = Date()
        while controller.state.navigatorPreview == nil, Date().timeIntervalSince(waited) < 10 { try? await Task.sleep(for: .seconds(0.05)) }
        #expect(develop.isPreviewingPreset)
        #expect(controller.state.navigatorPreview != nil, "the Navigator shows the preview")
        #expect(photo.adjustments == before && develop.currentAdjustments == before, "nothing is applied")
        #expect(photo.historySteps.isEmpty)

        panel.setHovered(nil)
        #expect(!develop.isPreviewingPreset && controller.state.navigatorPreview == nil, "leaving the list ends the preview")

        // Applying a preset ends any preview.
        panel.setHovered(preset)
        waited = Date()
        while !develop.isPreviewingPreset, Date().timeIntervalSince(waited) < 10 { try? await Task.sleep(for: .seconds(0.05)) }
        develop.applyPreset(preset)
        #expect(!develop.isPreviewingPreset && photo.adjustments != before)
    }
}
