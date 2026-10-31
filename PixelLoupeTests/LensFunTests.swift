import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

@Suite("LensFun database")
struct LensFunDatabaseTests {
    private let xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <lensdatabase version="2">
        <mount><name>Sony E</name><compat>M42</compat></mount>
        <camera>
            <maker>Sony</maker>
            <model>ILCE-7M4</model>
            <model lang="en">Alpha 7 IV</model>
            <mount>Sony E</mount>
            <cropfactor>1</cropfactor>
        </camera>
        <camera>
            <maker>Sony</maker>
            <model>ILCE-6600</model>
            <mount>Sony E</mount>
            <cropfactor>1.534</cropfactor>
        </camera>
        <lens>
            <maker>Sony</maker>
            <model>FE 24-70mm f/2.8 GM II</model>
            <mount>Sony E</mount>
            <cropfactor>1.0</cropfactor>
            <calibration>
                <distortion model="ptlens" focal="24" a="0.01" b="-0.04" c="0.02"/>
                <distortion model="ptlens" focal="70" a="0.0" b="0.01" c="0.0"/>
                <tca model="poly3" focal="24" vr="1.0004" cr="0" br="0" vb="0.9996" cb="0" bb="0"/>
                <vignetting model="pa" focal="24" aperture="2.8" distance="1000" k1="-0.8" k2="0.4" k3="-0.1"/>
                <vignetting model="pa" focal="24" aperture="5.6" distance="1000" k1="-0.4" k2="0.2" k3="-0.05"/>
            </calibration>
        </lens>
        <lens>
            <maker>Sony</maker>
            <model>FE 70-200mm f/2.8 GM OSS</model>
            <mount>Sony E</mount>
            <cropfactor>1.0</cropfactor>
            <calibration><distortion model="poly3" focal="70" k1="0.01"/></calibration>
        </lens>
        <lens>
            <maker>Generic</maker>
            <model>M42 50mm f/1.8</model>
            <mount>M42</mount>
            <cropfactor>1.5</cropfactor>
            <aspect-ratio>3:2</aspect-ratio>
            <calibration><distortion model="poly5" focal="50" k1="0.01" k2="0.002"/></calibration>
        </lens>
        <lens>
            <maker>Canon</maker>
            <model>EF 50mm f/1.8 STM</model>
            <mount>Canon EF</mount>
            <cropfactor>1.0</cropfactor>
            <calibration><distortion model="poly3" focal="50" k1="0.01"/></calibration>
        </lens>
    </lensdatabase>
    """

    private var database: LensFunDatabase { LensFunDatabase.load([Data(xml.utf8)]) }

    @Test func parsesCamerasLensesAndModels() throws {
        let database = database
        #expect(database.cameras.count == 2 && database.lenses.count == 4)
        let lens = try #require(database.lenses.first)
        #expect(lens.model == "FE 24-70mm f/2.8 GM II")
        // ptlens a, b, c → (a, b, c, 1 − a − b − c, 0).
        #expect(lens.distortion[0].coefficients == [0.01, -0.04, 0.02, 1.01, 0])
        #expect(lens.tca[0].red == [0, 0, 1.0004] && lens.tca[0].blue == [0, 0, 0.9996])
        #expect(lens.vignetting.count == 2)
        let m42 = try #require(database.lenses.first { $0.maker == "Generic" })
        #expect(m42.distortion[0].coefficients == [0, 0.01, 0, 1, 0.002], "poly5")
        #expect(m42.aspectRatio == 1.5)
        #expect(database.compatibleMounts["Sony E"] == ["M42"])
    }

    @Test func matchesCamerasAsTheyNameThemselves() {
        let database = database
        #expect(database.camera(make: "SONY", model: "ILCE-7M4")?.cropFactor == 1)
        #expect(database.camera(make: "Sony Corporation", model: "ilce-6600")?.cropFactor == 1.534)
        #expect(database.camera(make: "Canon", model: "ILCE-7M4") == nil)
    }

    @Test func matchesLensesByName() {
        let database = database
        #expect(database.match(make: "SONY", model: "ILCE-7M4", lens: "FE 24-70mm F2.8 GM II")?.model == "FE 24-70mm f/2.8 GM II")
        // Version words must agree: the Mk II isn't the Mk I.
        #expect(database.match(make: "SONY", model: "ILCE-7M4", lens: "FE 70-200mm F2.8 GM OSS II") == nil)
        #expect(database.match(make: "SONY", model: "ILCE-7M4", lens: "FE 70-200mm F2.8 GM OSS")?.model == "FE 70-200mm f/2.8 GM OSS")
        // Different focal lengths never match.
        #expect(database.match(make: "SONY", model: "ILCE-7M4", lens: "FE 24-105mm F4 G OSS") == nil)
        // Lenses for other mounts don't fit (but adapted M42 lenses do).
        #expect(database.match(make: "SONY", model: "ILCE-7M4", lens: "EF 50mm f/1.8 STM") == nil)
        #expect(Set(database.lenses(for: database.camera(make: "SONY", model: "ILCE-7M4")).map(\.maker)) == ["Sony", "Generic"])
    }

    @Test func tokens() {
        #expect(LensFunDatabase.tokens("FE 24-70mm F2.8 GM II") == ["fe", "24", "70", "mm", "2.8", "gm", "ii"])
        #expect(LensFunDatabase.tokens("Summilux-M 1:1.4/50 ASPH.") == ["summilux", "m", "1", "1.4", "50", "asph"])
        #expect(LensFunDatabase.tokens("50mm f/2.80") == ["50", "mm", "2.8"])
    }

    @Test func resolvesAProfileForThePhoto() throws {
        let lens = try #require(database.lenses.first)
        let profile = LensFunDatabase.profile(for: lens, cropFactor: 1, focalLength: 47, aperture: 4, distance: nil)
        // Halfway between 24 mm and 70 mm.
        #expect(abs(profile.distortion[0] - 0.005) < 1e-9 && abs(profile.distortion[1] - -0.015) < 1e-9)
        // Vignetting between f/2.8 and f/5.6, interpolated in stops.
        let t = (log2(4.0) - log2(2.8)) / (log2(5.6) - log2(2.8))
        #expect(abs(profile.vignetting[0] - (-0.8 + 0.4 * t)) < 1e-9)
        #expect(profile.tcaRed == [0, 0, 1.0004])
        // Full frame, 3:2: r = 1 at half the short side; vignetting r = 1 at the corner.
        #expect(abs(profile.distortionUnit - 1 / (3.25).squareRoot()) < 1e-9)
        #expect(profile.vignettingUnit == 1)
        // On an APS-C camera the same calibration covers a smaller part of the frame.
        let cropped = LensFunDatabase.profile(for: lens, cropFactor: 1.5, focalLength: 24, aperture: 2.8, distance: nil)
        #expect(abs(cropped.vignettingUnit - 1.5) < 1e-9)
    }

    @Test func theBundledDatabaseLoads() {
        let database = LensFunDatabase.shared
        #expect(database.cameras.count > 500)
        #expect(database.lenses.count > 1000)
        #expect(database.match(make: "SONY", model: "ILCE-7M4", lens: "FE 24-70mm F2.8 GM II")?.distortion.isEmpty == false)
        // A Nikon D750's lens, as ImageIO reads it from the NEF's {ExifAux}.
        let nikkor = database.match(make: "NIKON CORPORATION", model: "NIKON D750", lens: "AF-S Nikkor 24-120mm f/4G ED VR")
        #expect(nikkor?.model == "Nikon AF-S Nikkor 24-120mm f/4G ED VR 170" && nikkor?.hasCorrections == true)
    }
}

@Suite("Lens corrections settings")
struct LensSettingsTests {
    @Test func olderSettingsStillLoad() throws {
        let adjustments = PhotoAdjustments(data: Data(#"{"light":{"isEnabled":true,"exposure":0.5,"brilliance":0,"highlights":0,"shadows":0,"brightness":0,"contrast":0,"blackPoint":0}}"#.utf8))
        #expect(adjustments.light.exposure == 0.5)
        #expect(adjustments.lens == .init())
        let partial = try JSONDecoder().decode(PhotoAdjustments.LensCorrections.self, from: Data(#"{"purpleAmount":0.5}"#.utf8))
        #expect(partial.purpleAmount == 0.5 && partial.greenHue == .init(lower: 0.4, upper: 0.6))
    }

    @Test func roundTrips() throws {
        var adjustments = PhotoAdjustments()
        adjustments.lens.enableProfileCorrections = true
        adjustments.lens.profile = .init(maker: "Sony", model: "FE 24-70mm f/2.8 GM II", distortion: [0, 0.01, 0, 0.99, 0])
        adjustments.lens.removeChromaticAberration = true
        adjustments.lens.chromaticAberration = .init(red: 1.0003, blue: 0.9998)
        #expect(PhotoAdjustments(data: adjustments.encoded) == adjustments)
    }

    @Test func eyedropperPicksPurpleOrGreen() throws {
        let lens = PhotoAdjustments.LensCorrections()
        let purple = try #require(DevelopViewController.defringe(lens, picking: [0.55, 0.2, 0.75]))
        #expect(purple.purpleAmount == 0.25 && purple.greenAmount == 0)
        #expect(purple.purpleHue.lower < 0.5 && purple.purpleHue.upper > 0.5, "centered on the picked hue: \(purple.purpleHue)")
        let green = try #require(DevelopViewController.defringe(lens, picking: [0.3, 0.7, 0.3]))
        #expect(green.greenAmount == 0.25 && green.purpleAmount == 0)
        #expect(abs((green.greenHue.lower + green.greenHue.upper) / 2 - 0.5) < 0.01, "pure green is mid-slider")
        #expect(DevelopViewController.defringe(lens, picking: [0.5, 0.5, 0.5]) == nil, "gray isn't a fringe")
    }
}

@Suite("Chromatic aberration measurement")
struct ChromaticAberrationTests {
    /// Dark squares on light gray across the frame, with red drawn `red`× larger and blue `blue`×
    /// larger than green about the center, as a lens with lateral CA does.
    private func scene(red: Double, blue: Double) -> CIImage {
        let size = CGRect(x: 0, y: 0, width: 1800, height: 1200)
        func channel(_ scale: Double, _ color: CIColor) -> CIImage {
            // Each square drawn where the scaled image puts it, then softened like a lens would.
            var image = CIImage(color: color).cropped(to: size.insetBy(dx: -200, dy: -200))
            for x in stride(from: 60.0, to: 1800, by: 150) {
                for y in stride(from: 60.0, to: 1200, by: 150) {
                    let square = CGRect(x: 900 + (x - 900) * scale, y: 600 + (y - 600) * scale, width: 70 * scale, height: 70 * scale)
                    image = CIImage(color: .black).cropped(to: square).composited(over: image)
                }
            }
            return image.clampedToExtent().applyingGaussianBlur(sigma: 1).cropped(to: size)
        }
        // Combine one channel from each, in the color space the estimator measures (so no channel
        // leaks into another).
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let r = channel(red, CIColor(red: 0.8, green: 0, blue: 0, colorSpace: space)!)
        let g = channel(1, CIColor(red: 0, green: 0.8, blue: 0, colorSpace: space)!)
        let b = channel(blue, CIColor(red: 0, green: 0, blue: 0.8, colorSpace: space)!)
        return r.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: g])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: b])
            .cropped(to: size)
    }

    @Test func measuresRedAndBlueScale() throws {
        let measured = try #require(ChromaticAberrationEstimator.estimate(scene(red: 1.002, blue: 0.9985)))
        #expect(abs(measured.red - 1.002) < 0.0002, "red \(measured.red)")
        #expect(abs(measured.blue - 0.9985) < 0.0002, "blue \(measured.blue)")
    }

    @Test func aCleanLensMeasuresNothing() throws {
        let measured = try #require(ChromaticAberrationEstimator.estimate(scene(red: 1, blue: 1)))
        #expect(measured.isIdentity)
    }
}
