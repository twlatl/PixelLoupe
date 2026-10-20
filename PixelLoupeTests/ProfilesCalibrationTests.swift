import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Profiles and camera calibration")
struct ProfilesCalibrationTests {
    private func transform(_ configure: (inout PhotoAdjustments) -> Void) throws -> ColorLUT.Transform {
        var adjustments = PhotoAdjustments()
        configure(&adjustments)
        return ColorLUT.Transform(key: try #require(ColorLUT.key(for: adjustments)))
    }

    private func chroma(_ c: (r: Double, g: Double, b: Double)) -> Double { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }
    private func luma(_ c: (r: Double, g: Double, b: Double)) -> Double { 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }

    // MARK: Model

    @Test("Profile and calibration default to nothing and decode from older saves")
    func model() throws {
        #expect(!PhotoAdjustments().profile.isActive && !PhotoAdjustments().calibration.isActive)
        #expect(ColorLUT.key(for: PhotoAdjustments()) == nil)
        let old = try JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{"light":{"exposure":0.2}}"#.utf8))
        #expect(old.profile == .init() && old.calibration == .init())
        var edited = PhotoAdjustments()
        edited.profile = .init(kind: .vivid, amount: 1.4, importedName: "Camera Vivid")
        edited.calibration.redHue = 0.3
        edited.calibration.shadowTint = -0.2
        let data = try #require(edited.encoded)
        #expect(PhotoAdjustments(data: data) == edited)
        #expect(PhotoAdjustments.Profile.Kind.standard.title == "Default" && PhotoAdjustments.Profile.Kind.vivid.title == "Vivid")
    }

    @Test("An imported Adobe profile survives saving")
    func adobeProfileRoundTrips() throws {
        var edited = PhotoAdjustments()
        edited.profile = .init(kind: .standard, amount: 0.8, importedName: "Classic Chrome", adobeID: "UUID-CLASSIC-CHROME")
        let data = try #require(edited.encoded)
        #expect(PhotoAdjustments(data: data).profile.adobeID == "UUID-CLASSIC-CHROME")
        #expect(PhotoAdjustments(data: data) == edited)
    }

    @Test("A profile or calibration goes into the color table, not a new pass")
    func foldsIntoTable() {
        var adjustments = PhotoAdjustments()
        adjustments.profile.kind = .landscape
        let key = ColorLUT.key(for: adjustments)
        #expect(key?.profile?.kind == .landscape && key?.calibration == nil)
        adjustments.calibration.blueSaturation = 0.2
        #expect(ColorLUT.key(for: adjustments)?.calibration != nil)
        // Default stays out of it (and so does an amount of zero).
        var none = PhotoAdjustments()
        none.profile.amount = 0.3
        #expect(ColorLUT.key(for: none) == nil)
        none.profile.kind = .vivid
        none.profile.amount = 0
        #expect(ColorLUT.key(for: none) == nil)
    }

    // MARK: Profiles

    @Test("Each profile has its own character")
    func looks() throws {
        let muted = (r: 0.55, g: 0.45, b: 0.40), sky = (r: 0.30, g: 0.45, b: 0.75), grass = (r: 0.30, g: 0.55, b: 0.25)
        func result(_ kind: PhotoAdjustments.Profile.Kind, _ c: (r: Double, g: Double, b: Double)) throws -> (r: Double, g: Double, b: Double) {
            try transform { $0.profile.kind = kind }.apply(c.r, c.g, c.b)
        }
        // Vivid: more color and contrast.
        #expect(try chroma(result(.vivid, muted)) > chroma(muted) * 1.2)
        #expect(try result(.vivid, (0.7, 0.7, 0.7)).r > 0.7 && result(.vivid, (0.3, 0.3, 0.3)).r < 0.3)
        // Neutral: less of both.
        #expect(try chroma(result(.neutral, muted)) < chroma(muted))
        #expect(try result(.neutral, (0.7, 0.7, 0.7)).r < 0.7)
        // Landscape: colorful greens and blues, and a deeper sky.
        #expect(try chroma(result(.landscape, grass)) > chroma(grass) * 1.15)
        #expect(try luma(result(.landscape, sky)) < luma(sky))
        // Portrait: calmer skin than vivid, a touch warm.
        let skin = (r: 0.80, g: 0.60, b: 0.50)
        #expect(try chroma(result(.portrait, skin)) < chroma(skin))
        let warm = try result(.portrait, (0.5, 0.5, 0.5))
        #expect(warm.r > warm.b)
        // Monochrome: gray.
        let mono = try result(.monochrome, muted)
        #expect(abs(mono.r - mono.g) < 1e-9 && abs(mono.g - mono.b) < 1e-9)
        // Default does nothing.
        let same = ColorLUT.Transform(key: ColorLUT.Key(profile: .init(kind: .standard))).apply(0.4, 0.5, 0.6)
        #expect(same.r == 0.4 && same.g == 0.5 && same.b == 0.6)
    }

    @Test("Amount scales a profile, from nothing to exaggerated")
    func amount() throws {
        let c = (r: 0.55, g: 0.45, b: 0.40)
        func chromaAt(_ amount: Double) throws -> Double {
            let t = ColorLUT.Transform(key: ColorLUT.Key(profile: .init(kind: .vivid, amount: amount)))
            return chroma(t.apply(c.r, c.g, c.b))
        }
        #expect(try abs(chromaAt(0) - chroma(c)) < 1e-9)
        let half = try chromaAt(0.5), full = try chromaAt(1), double = try chromaAt(2)
        #expect(chroma(c) < half && half < full && full < double)
    }

    // MARK: Calibration

    @Test("Zero calibration is the identity matrix")
    func identityMatrix() {
        let m = ColorLUT.Transform.primariesMatrix(.init())
        for (a, b) in zip(m, [1.0, 0, 0, 0, 1, 0, 0, 0, 1]) { #expect(abs(a - b) < 1e-12) }
    }

    @Test("Saturating a primary strengthens that color; hue turns it")
    func primaries() throws {
        let red = try transform { $0.calibration.redSaturation = 1 }.apply(0.8, 0.3, 0.3)
        #expect(chroma(red) > chroma((0.8, 0.3, 0.3)) * 1.3)
        // Gray is unchanged (the primaries' means are kept).
        let gray = try transform { $0.calibration.redSaturation = 1; $0.calibration.blueHue = 0.5 }.apply(0.5, 0.5, 0.5)
        #expect(abs(gray.r - 0.5) < 1e-9 && abs(gray.g - 0.5) < 1e-9 && abs(gray.b - 0.5) < 1e-9)
        // A pure blue pushed in hue gains green or red.
        let turned = try transform { $0.calibration.blueHue = 1 }.apply(0, 0, 1)
        #expect(abs(turned.r - 0) > 0.05 || abs(turned.g - 0) > 0.05)
        // The opposite hue goes the other way.
        let back = try transform { $0.calibration.blueHue = -1 }.apply(0, 0, 1)
        #expect((turned.r - back.r) * (turned.g - back.g) <= 0 || abs(turned.r - back.r) + abs(turned.g - back.g) > 0.05)
    }

    @Test("Shadow tint changes shadows and leaves highlights")
    func shadowTint() throws {
        let green = try transform { $0.calibration.shadowTint = 1 }
        let dark = green.apply(0.1, 0.1, 0.1), bright = green.apply(0.9, 0.9, 0.9)
        #expect(dark.g > dark.r + 0.02 && dark.g > dark.b + 0.02)
        #expect(abs(bright.g - 0.9) < 0.01)
        let magenta = try transform { $0.calibration.shadowTint = -1 }.apply(0.1, 0.1, 0.1)
        #expect(magenta.g < magenta.r)
    }

    // MARK: Lightroom

    @Test("Lightroom's profile names map as the ticket says",
          arguments: [
            ("Embedded", LightroomDevelopMapper.ProfileMapping.none),
            ("Adobe Color", .defaultLook), ("Adobe Standard", .defaultLook), ("Adobe Standard v2", .defaultLook),
            ("Camera Standard", .defaultLook), ("Camera Faithful", .defaultLook),
            ("Adobe Vivid", .look(.vivid)), ("Camera Vivid", .look(.vivid)), ("Camera Vivid v2", .look(.vivid)),
            ("Adobe Landscape", .look(.landscape)), ("Camera Landscape", .look(.landscape)),
            ("Adobe Portrait", .look(.portrait)), ("Camera Portrait", .look(.portrait)),
            ("Adobe Monochrome", .look(.monochrome)), ("Camera Monochrome", .look(.monochrome)),
            ("Camera Neutral", .look(.neutral)), ("Camera VV", .unknown), ("Modern 01", .unknown),
            ("B&W 01", .blackAndWhite), ("B&W 17", .blackAndWhite), ("b&w 05", .blackAndWhite), ("B&W Infrared", .unknown),
          ])
    func names(name: String, expected: LightroomDevelopMapper.ProfileMapping) {
        #expect(LightroomDevelopMapper.profileMapping(for: name) == expected)
    }

    private func map(_ text: String) throws -> (PhotoAdjustments, [LightroomDevelopMapper.Difference]) {
        var adjustments = PhotoAdjustments()
        let differences = LightroomDevelopMapper.apply(
            .init(settings: try #require(try LuaTableParser.parse(text).table), processVersion: "11.0", whiteBalance: nil, isRaw: true),
            to: &adjustments)
        return (adjustments, differences)
    }

    @Test("Profiles import as PixelLoupe looks, noted or reported by what they are")
    func importsProfiles() throws {
        // Adobe Color / Standard: Default, noted only in the report.
        let standard = try map(#"{ CameraProfile = "Adobe Standard", Look = { Amount = 1, Name = "Adobe Color" } }"#)
        #expect(standard.0.profile == .init() && standard.1 == [LightroomDevelopMapper.defaultProfileNote] && standard.1[0].reportOnly)
        // The look's name wins over the camera profile, and its amount comes along.
        let vivid = try map(#"{ CameraProfile = "Adobe Standard", Look = { Amount = 0.6, Name = "Adobe Vivid" } }"#)
        #expect(vivid.0.profile == .init(kind: .vivid, amount: 0.6, importedName: "Adobe Vivid"))
        #expect(vivid.1.map(\.key) == ["profile-approximated"] && !vivid.1[0].reportOnly)
        // A camera profile alone.
        #expect(try map(#"{ CameraProfile = "Camera Landscape" }"#).0.profile.kind == .landscape)
        // Embedded (JPEG) is nothing.
        let embedded = try map(#"{ CameraProfile = "Embedded" }"#)
        #expect(embedded.0.isDefault && embedded.1.isEmpty)
        // Unknown ones are reported by name.
        let unknown = try map(#"{ CameraProfile = "Camera CLASSIC Neg" }"#)
        #expect(unknown.0.profile == .init() && unknown.1.map(\.key) == ["profile-camera-classic-neg"])
        #expect(unknown.1[0].title.contains("Camera CLASSIC Neg"))
        #expect(LightroomDevelopMapper.profileKey(for: "B&W 01") == "profile-b-w-01")
    }

    /// Adobe's newer B&W presets and edits turn a photo black and white with a B&W profile, not
    /// ConvertToGrayscale: the photo must come out black and white, with its B&W mix.
    @Test("Adobe's B&W profiles make the photo black and white")
    func importsBlackAndWhiteProfiles() throws {
        let (adjustments, differences) = try map(#"{ Look = { Amount = 1.2, Name = "B&W 11" }, GrayMixerRed = -12, GrayMixerBlue = 15 }"#)
        #expect(adjustments.blackAndWhite.isEnabled && adjustments.blackAndWhite.isActive)
        #expect(adjustments.blackAndWhite[.red] < 0 && adjustments.blackAndWhite[.blue] > 0, "the mix applies")
        #expect(adjustments.profile.importedName == "B&W 11" && !adjustments.profile.isActive, "no color look on top")
        #expect(differences.map(\.key) == ["profile-black-and-white"])
    }

    @Test("Camera calibration imports 1:1 on a ±1 scale")
    func importsCalibration() throws {
        let (adjustments, differences) = try map("""
            { ShadowTint = -15, RedHue = 10, RedSaturation = -20, GreenHue = 0, GreenSaturation = 5, BlueHue = -30, BlueSaturation = 40 }
            """)
        #expect(differences.isEmpty)
        #expect(adjustments.calibration == .init(shadowTint: -0.15, redHue: 0.1, redSaturation: -0.2, greenHue: 0, greenSaturation: 0.05, blueHue: -0.3, blueSaturation: 0.4))
        #expect(try map("{ ShadowTint = 0, RedHue = 0 }").0.isDefault)
    }

    @Test("The develop phase counts the standard profiles in the report instead of tagging every photo")
    @MainActor
    func phaseNotes() async throws {
        let fixture = try PhotosFixture()
        let standard = #"s = { CameraProfile = "Adobe Standard", Look = { Amount = 1, Name = "Adobe Color" } }"#
        let odd = #"s = { CameraProfile = "Camera CLASSIC Neg" }"#
        try fixture.run("""
            INSERT INTO Adobe_imageDevelopSettings (image, processVersion, whiteBalance, text) VALUES
                (10, '11.0', 'As Shot', '\(standard)'), (13, '11.0', 'As Shot', '\(standard)'), (15, '11.0', 'As Shot', '\(odd)');
            """)
        let (store, report) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }, { LightroomDevelopPhase() }])
        #expect(report.warnings.contains { $0.contains("2 photos use an Adobe Color or Standard profile") })
        #expect(report.groups.map(\.key) == ["profile-camera-classic-neg"])
        let photos = try store.viewContext.fetch(Photo.fetchRequest()).filter { $0.importDifferences != nil }
        #expect(photos.map(\.fileName) == ["E.jpg"], "only the unknown profile tags a photo")
    }
}
