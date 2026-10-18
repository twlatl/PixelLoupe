import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Older process versions")
struct OlderProcessTests {
    private func map(_ text: String, version: String?, raw: Bool = true) throws -> (PhotoAdjustments, [LightroomDevelopMapper.Difference]) {
        var adjustments = PhotoAdjustments()
        let differences = LightroomDevelopMapper.apply(
            .init(settings: try #require(try LuaTableParser.parse(text).table), processVersion: version, whiteBalance: nil, isRaw: raw), to: &adjustments)
        return (adjustments, differences)
    }

    /// The pattern seen in a real 55,000-photo catalog: 17,000 photos from process version 11 carry
    /// Lightroom's old defaults (and some other non-zero legacy values) that no longer do anything.
    @Test("2012-and-later photos never pick up the legacy keys")
    func currentProcessIgnoresLegacyKeys() throws {
        let legacy = """
            { ProcessVersion = "11.0", Brightness = 50, Contrast = 25, Shadows = 5, FillLight = 20, HighlightRecovery = 30, Exposure = 1.5,
              Clarity = 40, ToneCurve = { 0, 0, 64, 40, 192, 220, 255, 255, }, ToneCurveName = "Custom",
              Exposure2012 = 0, Contrast2012 = 0, Highlights2012 = 0, Shadows2012 = 0, Whites2012 = 0, Blacks2012 = 0 }
            """
        for version in ["6.7", "10.0", "11.0", "15.4"] {
            let (adjustments, differences) = try map(legacy, version: version)
            #expect(adjustments.isDefault, "process \(version) must not use Brightness, Contrast, Shadows, Fill Light, Recovery, Exposure, Clarity or ToneCurve")
            #expect(differences.isEmpty, "process \(version): \(differences)")
        }
        // And the 2012 values still apply next to them.
        let both = try map(legacy.replacingOccurrences(of: "Exposure2012 = 0", with: "Exposure2012 = 0.5"), version: "11.0").0
        #expect(both.light.exposure == 0.5 && both.light.brightness == 0 && both.light.shadows == 0 && both.presence.clarity == 0)
    }

    @Test("A 2010 photo's exposure, fill light, recovery, blacks, brightness and contrast are converted from their defaults")
    func convertsPV2010() throws {
        let (adjustments, differences) = try map("""
            { ProcessVersion = "5.0", Exposure = 0.5, FillLight = 25, HighlightRecovery = 50, Shadows = 15, Brightness = 70, Contrast = 45, Clarity = 20 }
            """, version: "5.0")
        #expect(differences == [LightroomDevelopMapper.olderProcess])
        let light = adjustments.light
        #expect(light.exposure == 0.5)
        #expect(light.shadows == 0.2 && light.highlights == -0.4, "fill light lifts shadows, recovery pulls highlights down")
        #expect(abs(light.blackPoint - 0.1) < 1e-9, "blacks above their default of 5 darken")
        #expect(abs(light.brightness - 0.2) < 1e-9 && abs(light.contrast - 0.2) < 1e-9)
        #expect(adjustments.presence.clarity == 0.2)
        #expect(light.whites == 0, "no 2012-only slider is invented")
    }

    @Test("Lightroom's own defaults for the old process are no offset, but the photo is still reported")
    func legacyDefaults() throws {
        let (adjustments, differences) = try map("{ ProcessVersion = \"5.0\", Exposure = 0, Brightness = 50, Contrast = 25, Shadows = 5, FillLight = 0, HighlightRecovery = 0 }", version: "5.0")
        #expect(adjustments.light == PhotoAdjustments.Light() && differences == [LightroomDevelopMapper.olderProcess])
    }

    @Test("The legacy tone curve is imported, including the default Medium Contrast curve")
    func legacyCurve() throws {
        let medium = try map("""
            { ProcessVersion = "5.0", ToneCurveName = "Medium Contrast", ToneCurve = { 0, 0, 32, 22, 64, 56, 128, 128, 192, 196, 255, 255, },
              ToneCurveRed = { 0, 0, 255, 255, } }
            """, version: "5.0").0
        #expect(medium.curves.rgb.points.count == 6 && abs(medium.curves.rgb.value(at: 32.0 / 255) - 22.0 / 255) < 1e-9)
        #expect(medium.curves.red.isIdentity)
        // Linear is nothing.
        #expect(try map("{ ToneCurve = { 0, 0, 255, 255, } }", version: "3.0").0.curves.rgb.isIdentity)
    }

    @Test("Everything that isn't a tone control still imports for an older process")
    func restImports() throws {
        let (adjustments, differences) = try map("""
            { ProcessVersion = "5.0", WhiteBalance = "Custom", Temperature = 4800, Tint = -5, Sharpness = 80, SharpenRadius = 1.5,
              HueAdjustmentRed = 20, PostCropVignetteAmount = -30, Vibrance = 10, Saturation = -10, CropLeft = 0.1, CropRight = 0.9 }
            """, version: "5.0")
        #expect(differences == [LightroomDevelopMapper.olderProcess])
        #expect(adjustments.whiteBalance.temperature == 4800 && adjustments.sharpen.intensity > 0 && adjustments.selectiveColor[.red].hue == 0.2)
        #expect(adjustments.vignette.strength == 0.3 && adjustments.crop.isActive)
        #expect(adjustments.presence.vibrance == 0.1 && adjustments.presence.saturation == -0.1)
    }

    @Test("Process 2003 numbers (3.0 and below) take the same conversion")
    func pv2003() throws {
        let (adjustments, differences) = try map("{ ProcessVersion = \"3.0\", Exposure = -0.25, Shadows = 20 }", version: "3.0")
        #expect(differences == [LightroomDevelopMapper.olderProcess] && adjustments.light.exposure == -0.25 && abs(adjustments.light.blackPoint - 0.15) < 1e-9)
    }

    @Test("The develop phase tags older-process photos so they can be found")
    @MainActor
    func phaseReports() async throws {
        let fixture = try PhotosFixture()
        try fixture.run("""
            INSERT INTO Adobe_imageDevelopSettings (image, processVersion, whiteBalance, text) VALUES
                (10, '5.0', 'As Shot', 's = { ProcessVersion = "5.0", Exposure = 0.4, Brightness = 60 }'),
                (13, '11.0', 'As Shot', 's = { ProcessVersion = "11.0", Brightness = 50, Contrast = 25, Exposure2012 = 0 }');
            """)
        let (store, report) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }, { LightroomDevelopPhase() }])
        let photos = try store.viewContext.fetch(Photo.fetchRequest()).filter { !$0.isVirtualCopy }
        let old = try #require(photos.first { $0.fileName == "A.jpg" })
        #expect(old.adjustments.light.exposure == 0.4 && old.importDifferences?.contains("|older-process-version|") == true)
        let current = try #require(photos.first { $0.fileName == "D.cr2" })
        #expect(current.adjustments.light.brightness == 0 && current.importDifferences == nil, "version 11 ignores the legacy values")
        #expect(report.groups.contains { $0.key == "older-process-version" && $0.photoCount == 1 && $0.title == "Older process version — approximated" })
    }
}
