import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PixelLoupe

/// The fidelity suite: PixelLoupe's renders of imported Lightroom settings against Lightroom's own
/// exports. The comparison against real exports runs only when `PIXELLOUPE_FIDELITY_DIR` names a
/// fixtures folder (see Scripts/fidelity.sh); the rest checks the tooling.
@Suite("Fidelity")
struct FidelityTests {
    // MARK: The real comparison

    @Test("PixelLoupe renders match Lightroom's exports within each family's target",
          .enabled(if: ProcessInfo.processInfo.environment["PIXELLOUPE_FIDELITY_DIR"] != nil), .timeLimit(.minutes(30)))
    func lightroomExports() throws {
        let folder = URL(filePath: try #require(ProcessInfo.processInfo.environment["PIXELLOUPE_FIDELITY_DIR"]), directoryHint: .isDirectory)
        let cases = FidelityHarness.discover(in: folder)
        try #require(!cases.isEmpty, "no <family>/<case>/{source.*, settings.xmp, reference.tif} in \(folder.path)")
        var results: [FidelityHarness.Result] = []
        for testCase in cases { results.append(try FidelityHarness.run(testCase)) }
        let reportURL = URL(filePath: ProcessInfo.processInfo.environment["PIXELLOUPE_FIDELITY_REPORT"] ?? folder.appending(path: "report.html").path)
        try FidelityHarness.report(results).write(to: reportURL, atomically: true, encoding: .utf8)
        print("Fidelity report: \(reportURL.path)")
        for result in results {
            let m = result.metrics
            #expect(result.passes, "\(result.testCase.family)/\(result.testCase.name): mean ΔE \(m.meanDeltaE), p95 \(m.p95DeltaE), \(m.sizeDifference) px off; target \(result.target)")
        }
    }

    // MARK: Color difference

    /// Sharma, Wu and Dalal's published CIEDE2000 test pairs.
    @Test("ΔE2000 matches the published test data", arguments: [
        ((50.0, 2.6772, -79.7751), (50.0, 0.0, -82.7485), 2.0425),
        ((50.0, 3.1571, -77.2803), (50.0, 0.0, -82.7485), 2.8615),
        ((50.0, 2.5, 0.0), (50.0, 0.0, -2.5), 4.3065),
        ((50.0, 0.0, 0.0), (50.0, -1.0, 2.0), 2.3669),
        ((50.0, 2.5, 0.0), (73.0, 25.0, -18.0), 27.1492),
        ((60.2574, -34.0099, 36.2677), (60.4626, -34.1751, 39.4387), 1.2644),
        ((22.7233, 20.0904, -46.694), (23.0331, 14.973, -42.5619), 2.0373),
    ] as [((Double, Double, Double), (Double, Double, Double), Double)])
    func deltaE(one: (Double, Double, Double), two: (Double, Double, Double), expected: Double) {
        let value = ColorDifference.deltaE2000(.init(l: one.0, a: one.1, b: one.2), .init(l: two.0, a: two.1, b: two.2))
        #expect(abs(value - expected) < 0.0001, "got \(value)")
        let reversed = ColorDifference.deltaE2000(.init(l: two.0, a: two.1, b: two.2), .init(l: one.0, a: one.1, b: one.2))
        #expect(abs(value - reversed) < 0.0001, "ΔE2000 is symmetric")
    }

    @Test("Display P3 white is L 100 and gray is neutral; saturated colors are not")
    func labValues() {
        let white = ColorDifference.lab(displayP3: 1, 1, 1), black = ColorDifference.lab(displayP3: 0, 0, 0), gray = ColorDifference.lab(displayP3: 0.5, 0.5, 0.5)
        #expect(abs(white.l - 100) < 0.05 && abs(white.a) < 0.05 && abs(white.b) < 0.05)
        #expect(black.l == 0 && abs(gray.a) < 0.05 && abs(gray.b) < 0.05 && gray.l > 50 && gray.l < 55)
        let red = ColorDifference.lab(displayP3: 1, 0, 0)
        #expect(red.a > 60)
        // A one-level step is about a ΔE of 0.4 near the middle.
        let step = ColorDifference.deltaE2000(ColorDifference.lab(displayP3: 0.5, 0.5, 0.5), ColorDifference.lab(displayP3: 129.0 / 255, 129.0 / 255, 129.0 / 255))
        #expect(step > 0.2 && step < 0.8)
    }

    @Test("SSIM is 1 for the same picture and falls with noise or a shift")
    func ssim() {
        let size = 64
        let image = (0..<(size * size)).map { index in 0.5 + 0.3 * sin(Double(index % size) / 5) * cos(Double(index / size) / 7) }
        #expect(abs(ColorDifference.ssim(image, image, width: size, height: size) - 1) < 1e-9)
        var generator = SystemRandomNumberGenerator()
        let noisy = image.map { $0 + Double.random(in: -0.15...0.15, using: &generator) }
        let noisyScore = ColorDifference.ssim(image, noisy, width: size, height: size)
        #expect(noisyScore < 0.95 && noisyScore > 0)
        let shifted = (0..<(size * size)).map { image[($0 + 5) % image.count] }
        #expect(ColorDifference.ssim(image, shifted, width: size, height: size) < 0.9)
    }

    // MARK: Sweep fitting

    @Test("A sweep is fitted monotone, interpolated, and printed as a table")
    func sweepFit() {
        // Measured match values with noise that dips against the trend.
        let measurements = [(-100.0, -0.9), (-50.0, -0.52), (0.0, 0.0), (25.0, 0.18), (50.0, 0.15), (100.0, 0.8)].map {
            SliderSweepFit.Point(lightroom: $0.0, pixelLoupe: $0.1)
        }
        let fitted = SliderSweepFit.fit(measurements)
        #expect(zip(fitted, fitted.dropFirst()).allSatisfy { $0.pixelLoupe <= $1.pixelLoupe + 1e-12 }, "never decreases")
        #expect(fitted.count == 6 && fitted[0].pixelLoupe == -0.9 && fitted[2].pixelLoupe == 0)
        #expect(abs(fitted[3].pixelLoupe - 0.165) < 1e-9 && fitted[3].pixelLoupe == fitted[4].pixelLoupe, "the dip is pooled")
        #expect(abs(SliderSweepFit.evaluate(fitted, at: -25) + 0.26) < 1e-9)
        #expect(SliderSweepFit.evaluate(fitted, at: -500) == -0.9 && SliderSweepFit.evaluate(fitted, at: 500) == 0.8)
        #expect(SliderSweepFit.swiftTable(named: "contrast", fitted).hasPrefix("static let contrast: [(lightroom: Double, pixelLoupe: Double)] = [(-100.000, -0.9000)"))
        #expect(SliderSweepFit.evaluate([], at: 3) == 3)
    }

    // MARK: XMP settings

    private static let xmp = """
        <?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:ProcessVersion="11.0" crs:WhiteBalance="Custom" crs:Temperature="4350" crs:Tint="-8"
          crs:Exposure2012="+0.50" crs:Contrast2012="+10" crs:Highlights2012="-25" crs:ConvertToGrayscale="False" crs:HasCrop="True"
          crs:CropLeft="0.1" crs:CropTop="0.1" crs:CropRight="0.9" crs:CropBottom="0.9" crs:CropAngle="0">
          <crs:ToneCurvePV2012><rdf:Seq><rdf:li>0, 0</rdf:li><rdf:li>128, 140</rdf:li><rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012>
          <crs:Look><rdf:Description crs:Name="Adobe Color"/></crs:Look>
        </rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end="w"?>
        """

    @Test("Develop settings in an XMP read as the same table the catalog gives, and feed the mapper")
    func xmpSettings() throws {
        let table = try #require(XMPDevelopSettings.parse(Data(Self.xmp.utf8)))
        #expect(table["Exposure2012"]?.number == 0.5 && table["Highlights2012"]?.number == -25 && table["Temperature"]?.number == 4350)
        #expect(table["ConvertToGrayscale"]?.bool == false && table["HasCrop"]?.bool == true && table["WhiteBalance"]?.string == "Custom")
        #expect(table["ToneCurvePV2012"]?.table?.array.compactMap(\.number) == [0, 0, 128, 140, 255, 255])
        var adjustments = PhotoAdjustments()
        let differences = LightroomDevelopMapper.apply(.init(settings: table, processVersion: "11.0", whiteBalance: nil, isRaw: true, imageSize: CGSize(width: 3000, height: 2000)), to: &adjustments)
        #expect(adjustments.light.exposure == 0.5 && adjustments.light.contrast == 0.1 && adjustments.light.highlights == -0.25)
        #expect(adjustments.whiteBalance.temperature == 4350 && adjustments.curves.rgb.points.count == 3 && adjustments.crop.isActive)
        #expect(differences.allSatisfy { $0.key != "unknown-settings" }, "XMP-only keys such as HasCrop are known: \(differences)")
        #expect(XMPDevelopSettings.parse(Data("not xml".utf8)) == nil)
        #expect(XMPDevelopSettings.parse(Data("<x:xmpmeta xmlns:x='adobe:ns:meta/'/>".utf8)) == nil)
    }

    // MARK: The harness

    /// Writes a fixtures folder with one JPEG photo and the cases given as (family, name, XMP, reference exposure).
    private func makeFixtures(_ cases: [(family: String, name: String, referenceExposure: Double)]) throws -> (TemporaryDirectory, URL) {
        let directory = try TemporaryDirectory()
        let root = try directory.subdirectory("Fixtures")
        let context = CIContext(options: [.workingColorSpace: FidelityHarness.displayP3])
        for entry in cases {
            let folder = try directory.subdirectory("Fixtures/\(entry.family)/\(entry.name)")
            try Fixtures.writeJPEG(to: folder.appending(path: "source.jpg"), width: 320, height: 240)
            let settings = Self.xmp.replacingOccurrences(of: "crs:HasCrop=\"True\"", with: "crs:HasCrop=\"False\"")
                .replacingOccurrences(of: "crs:CropLeft=\"0.1\" crs:CropTop=\"0.1\" crs:CropRight=\"0.9\" crs:CropBottom=\"0.9\"", with: "")
                .replacingOccurrences(of: "crs:WhiteBalance=\"Custom\" crs:Temperature=\"4350\" crs:Tint=\"-8\"", with: "")
            try settings.write(to: folder.appending(path: "settings.xmp"), atomically: true, encoding: .utf8)
            // The "export": the same settings rendered here, or with a different exposure to stand in for a bad match.
            let testCase = FidelityHarness.Case(
                family: entry.family, name: entry.name, source: folder.appending(path: "source.jpg"), settings: folder.appending(path: "settings.xmp"),
                reference: folder.appending(path: "reference.tif"))
            var referenceXMP = settings
            if entry.referenceExposure != 0.5 {
                referenceXMP = settings.replacingOccurrences(of: "crs:Exposure2012=\"+0.50\"", with: String(format: "crs:Exposure2012=\"%+.2f\"", entry.referenceExposure))
            }
            let referenceSettings = folder.appending(path: "reference-settings.xmp")
            try referenceXMP.write(to: referenceSettings, atomically: true, encoding: .utf8)
            var referenceCase = testCase
            referenceCase.settings = referenceSettings
            let image = try FidelityHarness.render(referenceCase, size: CGSize(width: 320, height: 240), context: context)
            let destination = try #require(CGImageDestinationCreateWithURL(testCase.reference as CFURL, UTType.tiff.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            try FileManager.default.removeItem(at: referenceSettings)
        }
        return (directory, root)
    }

    @Test("Cases are found by family and name; folders missing a piece are skipped")
    func discover() throws {
        let (directory, root) = try makeFixtures([("basic", "daylight", 0.5), ("curve", "s-curve", 0.5)])
        _ = try directory.subdirectory("Fixtures/basic/incomplete")
        let cases = FidelityHarness.discover(in: root)
        #expect(cases.map { "\($0.family)/\($0.name)" } == ["basic/daylight", "curve/s-curve"])
        #expect(cases.allSatisfy { $0.source.lastPathComponent == "source.jpg" && $0.reference.pathExtension == "tif" })
        #expect(FidelityHarness.discover(in: directory.url.appending(path: "Nothing")).isEmpty)
    }

    @Test("A render of the same settings matches its export; a different exposure does not; the report says which")
    func runAndReport() throws {
        let (directory, root) = try makeFixtures([("basic", "matches", 0.5), ("basic", "off-by-a-stop", -1.0), ("crop", "matches", 0.5)])
        defer { withExtendedLifetime(directory) {} }
        let cases = FidelityHarness.discover(in: root)
        let results = try cases.map { try FidelityHarness.run($0) }
        let byName = Dictionary(uniqueKeysWithValues: results.map { ("\($0.testCase.family)/\($0.testCase.name)", $0) })
        let good = try #require(byName["basic/matches"])
        #expect(good.metrics.meanDeltaE < 0.6 && good.metrics.p95DeltaE < 1.5 && good.metrics.ssim > 0.98 && good.metrics.sizeDifference == 0, "\(good.metrics)")
        #expect(good.passes && byName["crop/matches"]?.passes == true)
        let bad = try #require(byName["basic/off-by-a-stop"])
        #expect(bad.metrics.meanDeltaE > 5 && !bad.passes, "\(bad.metrics)")
        #expect(FidelityHarness.target(for: "crop").pixels == 1 && FidelityHarness.target(for: "unknown-family") == FidelityHarness.defaultTarget)

        let html = FidelityHarness.report(results)
        #expect(html.contains("basic") && html.contains("off-by-a-stop") && html.contains("FAIL") && html.contains(">pass<"))
        #expect(html.contains("data:image/png;base64,") && html.contains("2 of 3 within target."))
    }

    @Test("Geometry families fail when the size is more than their pixels off")
    func geometryTarget() {
        let image = FidelityHarness.differenceImage([0, 0, 0, 0], width: 2, height: 2)!
        var result = FidelityHarness.Result(
            testCase: .init(family: "crop", name: "x", source: URL(filePath: "/s"), settings: URL(filePath: "/t"), reference: URL(filePath: "/r")),
            metrics: .init(meanDeltaE: 0, p95DeltaE: 0, ssim: 1, sizeDifference: 1), target: FidelityHarness.target(for: "crop"), render: image, reference: image)
        #expect(result.passes)
        result.metrics.sizeDifference = 2
        #expect(!result.passes)
    }
}
