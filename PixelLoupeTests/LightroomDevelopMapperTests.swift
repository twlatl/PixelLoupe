import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Lightroom develop settings mapper")
struct LightroomDevelopMapperTests {
    private func table(_ text: String) throws -> LuaTable {
        try #require(try LuaTableParser.parse(text).table)
    }

    private func map(
        _ text: String, raw: Bool, processVersion: String? = "11.0", whiteBalance: String? = nil
    ) throws -> (PhotoAdjustments, [LightroomDevelopMapper.Difference]) {
        var adjustments = PhotoAdjustments()
        let differences = LightroomDevelopMapper.apply(
            .init(settings: try table(text), processVersion: processVersion, whiteBalance: whiteBalance, isRaw: raw), to: &adjustments)
        return (adjustments, differences)
    }

    private func map(_ fixture: DevelopSettingsFixtures.Fixture, raw: Bool) throws -> (PhotoAdjustments, [LightroomDevelopMapper.Difference]) {
        try map(fixture.text, raw: raw, processVersion: fixture.processVersion, whiteBalance: fixture.whiteBalance)
    }

    // MARK: Coverage

    @Test("Every key in the fixtures is in the coverage table")
    func fixturesAreCovered() throws {
        for fixture in DevelopSettingsFixtures.all {
            let settings = try table(fixture.text)
            let unknown = settings.hash.keys.filter { LightroomDevelopCoverage.status(of: $0) == nil }
            #expect(unknown.isEmpty, "\(fixture.name): \(unknown.sorted())")
        }
    }

    @Test("A key Lightroom adds later is reported once as unknown")
    func unknownKey() throws {
        let (_, differences) = try map("{ BrandNewSlider2030 = 4, Exposure2012 = 0 }", raw: true)
        #expect(differences == [LightroomDevelopMapper.unknownSettings])
    }

    @Test("Settings at their defaults produce no difference and no adjustments")
    func defaultsAreSilent() throws {
        for fixture in [DevelopSettingsFixtures.untouched, DevelopSettingsFixtures.rawDefaults] {
            let (adjustments, differences) = try map(fixture, raw: fixture.name.contains("RAW"))
            #expect(differences.filter { !$0.reportOnly }.isEmpty, "\(fixture.name): \(differences)")
            #expect(adjustments.isDefault, "\(fixture.name)")
        }
    }

    @Test("Settings that aren't imported yet are reported by group")
    func unsupportedGroups() throws {
        let (adjustments, differences) = try map(DevelopSettingsFixtures.editedJPEG, raw: false)
        let keys = Set(differences.map(\.key))
        #expect(keys == ["crop-approximated"], "everything maps; the straightened crop has no photo size here")
        #expect(adjustments.light.exposure == -0.35)
        let (_, local) = try map(DevelopSettingsFixtures.localEdits, raw: true)
        #expect(Set(local.map(\.key)) == ["masks-ai", "lens-profile-unmatched"], "the spot in RetouchInfo is imported now")
        let (_, hdr) = try map(DevelopSettingsFixtures.hdr, raw: true)
        #expect(Set(hdr.map(\.key)) == ["hdr"])
    }

    @Test("Neutral values per key")
    func neutralValues() {
        func neutral(_ key: String, _ value: LuaValue) -> Bool { LightroomDevelopCoverage.isNeutral(key, value) }
        #expect(neutral("Sharpness", .number(40)) && neutral("Sharpness", .number(0)) && !neutral("Sharpness", .number(61)))
        #expect(neutral("CropRight", .number(1)) && !neutral("CropRight", .number(0.8)) && neutral("CropLeft", .number(0)))
        #expect(neutral("ConvertToGrayscale", .bool(false)) && !neutral("ConvertToGrayscale", .bool(true)))
        #expect(neutral("CameraProfile", .string("Adobe Standard")) && !neutral("CameraProfile", .string("Camera Vivid")))
        #expect(neutral("ToneCurveRed", .table(LuaTable(array: [.number(0), .number(0), .number(255), .number(255)]))))
        #expect(!neutral("ToneCurveRed", .table(LuaTable(array: [.number(0), .number(0), .number(128), .number(160), .number(255), .number(255)]))))
        #expect(neutral("RetouchInfo", .table(LuaTable())))
    }

    // MARK: Exposure and white balance

    @Test("Exposure maps one to one and stays within five stops")
    func exposure() throws {
        #expect(try map("{ Exposure2012 = 1.25 }", raw: true).0.light.exposure == 1.25)
        #expect(try map("{ Exposure2012 = -4.8 }", raw: false).0.light.exposure == -4.8)
        #expect(try map("{ Exposure2012 = 9 }", raw: false).0.light.exposure == 5)
        #expect(try map("{ Exposure2012 = 0 }", raw: true).0.isDefault)
    }

    @Test("A RAW file's custom white balance becomes temperature and tint; As Shot stays As Shot")
    func rawWhiteBalance() throws {
        let custom = try map(DevelopSettingsFixtures.rawCustomWhiteBalance, raw: true)
        #expect(custom.0.whiteBalance == .init(isEnabled: true, temperature: 4350, tint: -8, preset: nil))
        #expect(custom.0.light.exposure == 0.65 && custom.1.isEmpty)
        // As Shot repeats Temperature and Tint in the settings, which must not apply.
        #expect(try map(DevelopSettingsFixtures.rawDefaults, raw: true).0.whiteBalance == .init())
    }

    @Test("A named light-source preset keeps its name")
    func presetNames() throws {
        let daylight = try map("{ WhiteBalance = \"Daylight\", Temperature = 5500, Tint = 10 }", raw: true).0.whiteBalance
        #expect(daylight.preset == "Daylight" && daylight.displayName == "Daylight")
        let flash = try map("{ WhiteBalance = \"Flash\", Temperature = 5400, Tint = 3 }", raw: true).0.whiteBalance
        #expect(flash.displayName == "Flash" && flash.temperature == 5400)
        #expect(try map("{ WhiteBalance = \"Custom\", Temperature = 5000, Tint = 0 }", raw: true).0.whiteBalance.displayName == "Custom")
    }

    @Test("Auto white balance is imported as As Shot and reported")
    func autoWhiteBalance() throws {
        let (adjustments, differences) = try map("{ WhiteBalance = \"Auto\", Temperature = 4900, Tint = 4 }", raw: true)
        #expect(adjustments.whiteBalance == .init() && differences == [LightroomDevelopMapper.autoWhiteBalance])
    }

    @Test("A temperature outside the slider's range is limited and reported")
    func temperatureRange() throws {
        let (adjustments, differences) = try map("{ WhiteBalance = \"Custom\", Temperature = 60000, Tint = 0 }", raw: true)
        #expect(adjustments.whiteBalance.temperature == 50000 && differences == [LightroomDevelopMapper.whiteBalanceRange])
        #expect(try map("{ WhiteBalance = \"Custom\", Temperature = 30000, Tint = 0 }", raw: true).0.whiteBalance.temperature == 30000)
    }

    @Test("A non-RAW file's incremental temperature and tint map around neutral")
    func incrementalWhiteBalance() throws {
        let warm = try map("{ IncrementalTemperature = 50, IncrementalTint = -20 }", raw: false).0.whiteBalance
        let cool = try map("{ IncrementalTemperature = -50 }", raw: false).0.whiteBalance
        #expect((warm.temperature ?? 0) > 6500 && (cool.temperature ?? 0) < 6500)
        #expect(warm.tint == -30 && cool.tint == nil)
        #expect(try map("{ IncrementalTemperature = 0, IncrementalTint = 0 }", raw: false).0.whiteBalance == .init())
        // 0 maps to exactly neutral, and the curve is symmetric in mireds.
        #expect(LightroomScales.incrementalTemperature(0) == 6500)
        let up = 1_000_000 / LightroomScales.incrementalTemperature(40), down = 1_000_000 / LightroomScales.incrementalTemperature(-40)
        #expect(abs((up + down) / 2 - 1_000_000 / 6500) < 1)
    }

    @Test("Older process versions are identified by their number")
    func processVersions() {
        for version in ["6.7", "10.0", "11.0", "15.4"] {
            #expect(LightroomDevelopMapper.isCurrentProcess(version))
        }
        #expect(!LightroomDevelopMapper.isCurrentProcess("5.0") && !LightroomDevelopMapper.isCurrentProcess("3.0"))
        #expect(LightroomDevelopMapper.isCurrentProcess(nil))
    }

    // MARK: Model

    @Test("White balance decodes from catalogs saved before presets")
    func oldWhiteBalanceDecodes() throws {
        let json = Data(#"{"isEnabled":true,"temperature":5200,"tint":4}"#.utf8)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.WhiteBalance.self, from: json)
        #expect(decoded.temperature == 5200 && decoded.preset == nil && decoded.displayName == "Custom")
        #expect(PhotoAdjustments.WhiteBalance().displayName == "As Shot")
    }

    // MARK: Estimator

    @Test("A neutral patch needs no change; a warm or green patch is pushed the other way")
    func estimator() throws {
        let current = (temperature: 5000.0, tint: 0.0)
        let neutral = try #require(WhiteBalanceEstimator.neutralizing([0.5, 0.5, 0.5], current: current))
        #expect(neutral.temperature == 5000 && neutral.tint == 0)
        let warm = try #require(WhiteBalanceEstimator.neutralizing([0.6, 0.5, 0.4], current: current))
        #expect(warm.temperature < 5000)
        let cool = try #require(WhiteBalanceEstimator.neutralizing([0.4, 0.5, 0.6], current: current))
        #expect(cool.temperature > 5000)
        let green = try #require(WhiteBalanceEstimator.neutralizing([0.45, 0.55, 0.45], current: current))
        #expect(green.tint > 0)
        let magenta = try #require(WhiteBalanceEstimator.neutralizing([0.55, 0.45, 0.55], current: current))
        #expect(magenta.tint < 0)
        // Clipped, black or strongly colored spots say nothing about the light.
        #expect(WhiteBalanceEstimator.neutralizing([1, 1, 1], current: current) == nil)
        #expect(WhiteBalanceEstimator.neutralizing([0, 0, 0], current: current) == nil)
        #expect(WhiteBalanceEstimator.neutralizing([0.9, 0.2, 0.1], current: current) == nil)
    }
}
