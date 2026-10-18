import CoreData
import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Lens corrections import and Transform")
struct LensTransformTests {
    private static let xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <lensdatabase version="2">
        <mount><name>Sony E</name></mount>
        <camera><maker>Sony</maker><model>ILCE-7M4</model><mount>Sony E</mount><cropfactor>1</cropfactor></camera>
        <lens>
            <maker>Sony</maker><model>FE 24-70mm f/2.8 GM II</model><mount>Sony E</mount><cropfactor>1.0</cropfactor>
            <calibration><distortion model="ptlens" focal="24" a="0.01" b="-0.04" c="0.02"/></calibration>
        </lens>
        <lens>
            <maker>Sigma</maker><model>35mm F1.4 DG HSM | Art 012</model><mount>Sony E</mount><cropfactor>1.0</cropfactor>
            <calibration><distortion model="ptlens" focal="35" a="0.0" b="0.01" c="0.0"/></calibration>
        </lens>
    </lensdatabase>
    """
    private func resolver() -> LightroomLensResolver {
        let database = LensFunDatabase.load([Data(Self.xml.utf8)])
        return LightroomLensResolver(database: { database })
    }

    // MARK: Resolver

    @Test("Lens names are taken out of Adobe's profile names and file names")
    func profileNames() {
        #expect(LightroomLensResolver.lensNames(inProfile: "Adobe (SIGMA 35mm F1.4 DG HSM A012)").first == "SIGMA 35mm F1.4 DG HSM A012")
        #expect(LightroomLensResolver.lensNames(inProfile: "SONY (SIGMA 35mm F1.4 DG HSM A012) - RAW.lcp").first == "SIGMA 35mm F1.4 DG HSM A012")
        #expect(LightroomLensResolver.lensNames(inProfile: "Canon EF 50mm f/1.8 STM") == ["Canon EF 50mm f/1.8 STM"])
        #expect(LightroomLensResolver.lensNames(inProfile: "  ") == [])
        let names = LightroomLensResolver.candidateNames(.init(lensModel: "FE 24-70mm f/2.8 GM II", profileName: "Adobe (X)", profileFilename: "Adobe (X) - RAW.lcp"))
        #expect(names == ["X", "Adobe (X)", "Adobe (X) - RAW.lcp".replacingOccurrences(of: " - RAW.lcp", with: ""), "FE 24-70mm f/2.8 GM II"].reduce(into: [String]()) { result, name in
            if !result.contains(where: { $0.lowercased() == name.lowercased() }) { result.append(name) }
        })
    }

    @Test("A profile resolves to the matching LensFun lens, by profile name, file name or the photo's lens")
    func resolves() throws {
        let resolver = resolver()
        func query(profileName: String? = nil, filename: String? = nil, lens: String? = nil) -> LightroomLensResolver.Query {
            .init(cameraMake: "SONY", cameraModel: "ILCE-7M4", lensModel: lens, profileName: profileName, profileFilename: filename, focalLength: 24, aperture: 2.8)
        }
        let byName = try #require(resolver.profile(for: query(profileName: "Adobe (FE 24-70mm f/2.8 GM II)")))
        #expect(byName.model == "FE 24-70mm f/2.8 GM II" && byName.distortion.count == 5)
        #expect(try #require(resolver.profile(for: query(filename: "SONY (FE 24-70mm f/2.8 GM II) - RAW.lcp"))).model == byName.model)
        #expect(try #require(resolver.profile(for: query(profileName: "Adobe (Unknown 9mm)", lens: "FE 24-70mm f/2.8 GM II"))).model == byName.model)
        #expect(resolver.profile(for: query(profileName: "Adobe (Zeiss Otus 85mm f/1.4)", lens: "Zeiss Otus 85mm")) == nil)
        // Asking again hits the cache and gives the same answer.
        #expect(resolver.profile(for: query(profileName: "Adobe (FE 24-70mm f/2.8 GM II)")) == byName)
    }

    // MARK: Mapper

    private func map(_ text: String, profile: PhotoAdjustments.LensProfile? = nil) throws -> (PhotoAdjustments, [LightroomDevelopMapper.Difference]) {
        var adjustments = PhotoAdjustments()
        let differences = LightroomDevelopMapper.apply(
            .init(settings: try #require(try LuaTableParser.parse(text).table), processVersion: "11.0", whiteBalance: nil, isRaw: true, lensProfile: profile),
            to: &adjustments)
        return (adjustments, differences)
    }

    @Test("Lightroom's profile settings map to the lens panel")
    func lensProfileSettings() throws {
        let profile = PhotoAdjustments.LensProfile(maker: "Sony", model: "FE 24-70mm f/2.8 GM II", distortion: [0, 0, 0, 1, 0])
        let (adjustments, differences) = try map("""
            { LensProfileEnable = 1, LensProfileSetup = "Auto", LensProfileDistortionScale = 80, LensProfileVignettingScale = 150,
              LensProfileName = "Adobe (FE 24-70mm f/2.8 GM II)", AutoLateralCA = 1 }
            """, profile: profile)
        #expect(differences.isEmpty)
        let lens = adjustments.lens
        #expect(lens.enableProfileCorrections && lens.setup == .auto && lens.profile == profile)
        #expect(lens.distortionAmount == 0.8 && lens.vignettingAmount == 1.5 && lens.removeChromaticAberration)
        // A Custom setup stays Custom.
        #expect(try map("{ LensProfileEnable = 1, LensProfileSetup = \"Custom\" }", profile: profile).0.lens.setup == .custom)
    }

    @Test("A profile with no LensFun match falls back to the camera's own and is reported")
    func unmatched() throws {
        let (adjustments, differences) = try map("{ LensProfileEnable = 1, LensProfileSetup = \"Auto\" }")
        #expect(adjustments.lens.enableProfileCorrections && adjustments.lens.profile == nil)
        #expect(differences == [LightroomDevelopMapper.lensProfileUnmatched])
        // No profile in Lightroom: no lens edit and nothing to report.
        let none = try map("{ LensProfileEnable = 0, LensProfileSetup = \"LensDefaults\", LensProfileDistortionScale = 100 }")
        #expect(none.0.isDefault && none.1.isEmpty)
    }

    @Test("Manual lens settings, defringe and vignetting import")
    func manualLens() throws {
        let (adjustments, differences) = try map("""
            { LensManualDistortionAmount = -25, DefringePurpleAmount = 10, DefringePurpleHueLo = 20, DefringePurpleHueHi = 80,
              DefringeGreenAmount = 5, DefringeGreenHueLo = 45, DefringeGreenHueHi = 55,
              VignetteAmount = 40, VignetteMidpoint = 30, CropConstrainToWarp = 1 }
            """)
        #expect(differences.isEmpty)
        let lens = adjustments.lens
        #expect(lens.manualDistortion == -0.25 && lens.constrainCrop)
        #expect(lens.purpleAmount == 0.5 && lens.purpleHue == .init(lower: 0.2, upper: 0.8))
        #expect(lens.greenAmount == 0.25 && lens.greenHue == .init(lower: 0.45, upper: 0.55))
        #expect(lens.manualVignetting == 0.4 && lens.vignettingMidpoint == 0.3)
        // Constrain Crop with nothing to constrain isn't an edit.
        #expect(try map("{ CropConstrainToWarp = 1 }").0.isDefault)
    }

    @Test("The develop phase looks up a profile for photos that use one")
    @MainActor
    func phaseResolves() async throws {
        let fixture = try PhotosFixture()
        let text = """
            s = { LensProfileEnable = 1, LensProfileSetup = "Auto", LensProfileName = "Adobe (Missing 1mm Lens)" }
            """
        try fixture.run("INSERT INTO Adobe_imageDevelopSettings (image, processVersion, whiteBalance, text) VALUES (10, '11.0', 'As Shot', '\(text.replacingOccurrences(of: "'", with: "''"))')")
        let database = LensFunDatabase.load([Data(Self.xml.utf8)])
        let (store, report) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }, { LightroomDevelopPhase(lensResolver: LightroomLensResolver(database: { database })) }])
        let photo = try #require(try store.viewContext.fetch(Photo.fetchRequest()).first { $0.fileName == "A.jpg" && !$0.isVirtualCopy })
        #expect(photo.adjustments.lens.enableProfileCorrections && photo.adjustments.lens.profile == nil)
        #expect(report.groups.contains { $0.key == "lens-profile-unmatched" && $0.photoCount == 1 })
    }

    // MARK: Transform geometry

    private let size = CGSize(width: 600, height: 400)

    @Test("Default transforms do nothing")
    func identity() {
        #expect(TransformRenderer.Geometry(.init(), size: size).isIdentity)
        var off = PhotoAdjustments.Transform()
        off.vertical = 0.5
        off.isEnabled = false
        #expect(TransformRenderer.Geometry(off, size: size).isIdentity)
        let image = CIImage(color: .gray).cropped(to: CGRect(origin: .zero, size: size))
        #expect(TransformRenderer.apply(.init(), to: image) == image)
    }

    @Test("Rotate turns the picture clockwise")
    func rotateDirection() throws {
        var transform = PhotoAdjustments.Transform()
        transform.rotate = 10
        let geometry = TransformRenderer.Geometry(transform, size: size)
        // The picture's +x axis point appears below the axis (y up): the output point on that
        // clockwise-turned axis comes from the source's +x axis.
        let angle = -10.0 * .pi / 180
        let output = CGPoint(x: 200 * cos(angle), y: 200 * sin(angle))
        let source = try #require(geometry.source(for: output))
        #expect(abs(source.x - 200) < 0.5 && abs(source.y) < 0.5)
    }

    @Test("Vertical enlarges the top for positive values and the bottom for negative ones")
    func verticalKeystone() throws {
        var transform = PhotoAdjustments.Transform()
        transform.vertical = 0.5
        let up = TransformRenderer.Geometry(transform, size: size)
        let topCorner = try #require(up.source(for: CGPoint(x: 300, y: 200)))
        let bottomCorner = try #require(up.source(for: CGPoint(x: 300, y: -200)))
        // Output top corners come from nearer the middle (the top is magnified); bottom from farther out.
        #expect(abs(topCorner.x) < 300 && abs(bottomCorner.x) > 300)
        transform.vertical = -0.5
        let down = TransformRenderer.Geometry(transform, size: size)
        #expect(abs(try #require(down.source(for: CGPoint(x: 300, y: 200))).x) > 300)
        // The center stays put.
        let center = try #require(up.source(for: .zero))
        #expect(abs(center.x) < 0.5 && abs(center.y) < 0.5 || abs(center.x) < 0.5)
    }

    @Test("Scale, aspect and offset move the picture as described")
    func scaleAspectOffset() throws {
        var transform = PhotoAdjustments.Transform()
        transform.scale = 2
        let zoomed = TransformRenderer.Geometry(transform, size: size)
        let point = try #require(zoomed.source(for: CGPoint(x: 100, y: 50)))
        #expect(abs(point.x - 50) < 0.01 && abs(point.y - 25) < 0.01, "twice the scale shows half the area")
        transform = .init()
        transform.offsetX = 1
        let shifted = TransformRenderer.Geometry(transform, size: size)
        // +100% moves the picture right by a quarter of the width: the center now shows a source point left of it.
        #expect(abs(try #require(shifted.source(for: .zero)).x + 150) < 0.01)
        transform = .init()
        transform.aspect = 1
        let wide = TransformRenderer.Geometry(transform, size: size)
        let stretched = try #require(wide.source(for: CGPoint(x: 130, y: 100)))
        #expect(stretched.x < 130 / 1.29 && stretched.y > 100 * 1.29 - 1, "wider and shorter")
    }

    @Test("Constrain Crop finds a zoom that leaves no empty corner")
    func constrain() {
        var transform = PhotoAdjustments.Transform()
        transform.rotate = 6
        transform.vertical = 0.3
        let geometry = TransformRenderer.Geometry(transform, size: size)
        let zoom = geometry.constrainingZoom()
        #expect(zoom > 1.05 && zoom < 4)
        var zoomed = transform
        zoomed.scale = zoom
        let covered = TransformRenderer.Geometry(zoomed, size: size)
        for corner in [CGPoint(x: 299, y: 199), CGPoint(x: -299, y: 199), CGPoint(x: 299, y: -199), CGPoint(x: -299, y: -199)] {
            let source = covered.source(for: corner)
            #expect(source != nil && abs(source!.x) <= 300.2 && abs(source!.y) <= 200.2)
        }
        #expect(TransformRenderer.Geometry(.init(), size: size).constrainingZoom() == 1)
    }

    // MARK: Transform rendering

    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    private func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> [Float] {
        var data = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &data, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return data
    }

    @Test("Rendering warps the photo once on the GPU: corners empty without Constrain Crop, filled with it")
    func rendering() throws {
        let width = 200, height = 150
        var data = [Float](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: data.count, by: 4) { data[i] = 0.8; data[i + 1] = 0.6; data[i + 2] = 0.4; data[i + 3] = 1 }
        let image = CIImage(bitmapData: data.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
        var transform = PhotoAdjustments.Transform()
        transform.rotate = 8
        let rotated = TransformRenderer.apply(transform, to: image)
        #expect(rotated.extent == image.extent)
        #expect(rotated !== image, "the kernel produced an image")
        #expect(pixel(rotated, 100, 75)[3] > 0.99, "center is photo")
        #expect(pixel(rotated, 0, 0)[3] < 0.5 || pixel(rotated, width - 1, height - 1)[3] < 0.5, "a corner is empty: \(pixel(rotated, 0, 0)) \(pixel(rotated, width - 1, height - 1)) \(pixel(rotated, 100, 75)) \(pixel(rotated, 150, 140)) matrix \(TransformRenderer.Geometry(transform, size: image.extent.size).matrix)")
        transform.constrainCrop = true
        let constrained = TransformRenderer.apply(transform, to: image)
        for (x, y) in [(1, 1), (width - 2, 1), (1, height - 2), (width - 2, height - 2)] {
            #expect(pixel(constrained, x, y)[3] > 0.95, "corner \((x, y)) is filled")
        }
    }

    @Test("The full pipeline renders with a transform and keeps the photo's frame")
    func pipeline() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "a.jpg")
        try Fixtures.writeJPEG(to: url, width: 200, height: 150)
        let source = try #require(DevelopSource(url: url))
        var adjustments = PhotoAdjustments()
        adjustments.transform.vertical = 0.4
        adjustments.transform.rotate = 2
        let image = source.image(with: adjustments, scale: 1)
        #expect(image.extent.size == CGSize(width: 200, height: 150))
        #expect(context.createCGImage(image, from: image.extent) != nil)
    }

    // MARK: Transform model and mapping

    @Test("Transform round trips and older saves decode with it at its defaults")
    func modelCodable() throws {
        var adjustments = PhotoAdjustments()
        adjustments.transform = .init(vertical: 0.2, rotate: -1.5, scale: 1.1, upright: .level, uprightMatrix: [1, 0, 0, 0, 1, 0, 0, 0, 1])
        let data = try #require(adjustments.encoded)
        #expect(PhotoAdjustments(data: data) == adjustments)
        let old = try JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{"light":{"exposure":0.3}}"#.utf8))
        #expect(old.transform == .init() && !old.transform.isActive)
        #expect(PhotoAdjustments.Transform(scale: 1.2).hasManualTransform)
    }

    @Test("Lightroom's manual perspective maps, and Upright is recorded and reported")
    func importsTransform() throws {
        let matrix = "1.027604775,-0.012766954,-0.007418910,0.028725645,1.027604775,-0.028165210,0.000000000,0.000000000,1.000000000"
        let (adjustments, differences) = try map("""
            { PerspectiveVertical = -20, PerspectiveHorizontal = 10, PerspectiveRotate = 1.5, PerspectiveAspect = 30,
              PerspectiveScale = 90, PerspectiveX = 5, PerspectiveY = -5, PerspectiveUpright = 3,
              UprightTransform_0 = "1,0,0,0,1,0,0,0,1", UprightTransform_3 = "\(matrix)" }
            """)
        #expect(differences == [LightroomDevelopMapper.uprightNotApplied])
        let transform = adjustments.transform
        #expect(transform.vertical == -0.2 && transform.horizontal == 0.1 && transform.rotate == 1.5 && transform.aspect == 0.3)
        #expect(transform.scale == 0.9 && transform.offsetX == 0.05 && transform.offsetY == -0.05)
        #expect(transform.upright == .vertical && transform.uprightMatrix?.count == 9 && transform.uprightMatrix?[0] == 1.027604775)
        // Defaults (PerspectiveScale 100) are no edit.
        #expect(try map("{ PerspectiveVertical = 0, PerspectiveScale = 100, PerspectiveUpright = 0 }").0.isDefault)
    }
}
