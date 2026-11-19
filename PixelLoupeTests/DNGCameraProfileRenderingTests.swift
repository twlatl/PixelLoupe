import AppKit
import CoreImage
import Foundation
import simd
import Testing
@testable import PixelLoupe

/// RAW-304: camera profiles (`.dcp`) rendered on Apple's RAW engine, imported, and listed in the Profile menu.
extension DCPFixtures {
    /// A profile with nothing but its matrices and what's given: no tables, no curve.
    static func profile(name: String = "Fixture Look", cameraModel: String = "Fixture Camera 1", illuminants: [UInt16] = [21],
                        hueSatMaps: [[Float]] = [], hueSatMapDims: [UInt32]? = nil, lookTable: [Float]? = nil, lookTableDims: [UInt32]? = nil,
                        toneCurve: [Float]? = nil, baselineExposureOffset: Double? = nil) throws -> DNGCameraProfile {
        try #require(DNGCameraProfile.parse(file(contents(
            name: name, cameraModel: cameraModel, illuminants: illuminants, hueSatMaps: hueSatMaps, hueSatMapDims: hueSatMapDims,
            lookTable: lookTable, lookTableDims: lookTableDims, toneCurve: toneCurve, baselineExposureOffset: baselineExposureOffset
        ))))
    }

    static func contents(name: String = "Fixture Look", cameraModel: String = "Fixture Camera 1", illuminants: [UInt16] = [21],
                         hueSatMaps: [[Float]] = [], hueSatMapDims: [UInt32]? = nil, lookTable: [Float]? = nil, lookTableDims: [UInt32]? = nil,
                         toneCurve: [Float]? = nil, baselineExposureOffset: Double? = nil) -> Contents {
        Contents(
            name: name, cameraModel: cameraModel, signature: nil, copyright: nil, embedPolicy: nil, illuminants: illuminants,
            colorMatrices: illuminants.map { _ in matrix(1) }, forwardMatrices: [], hueSatMapDims: hueSatMapDims, hueSatMaps: hueSatMaps,
            lookTableDims: lookTableDims, lookTable: lookTable, lookTableEncoding: nil, toneCurve: toneCurve,
            baselineExposureOffset: baselineExposureOffset, defaultBlackRender: nil
        )
    }

    /// A 1 × 2 × 1 table with the same change everywhere.
    static func uniformTable(hueShift: Float = 0, saturationScale: Float = 1, valueScale: Float = 1) -> (dims: [UInt32], data: [Float]) {
        ([1, 2, 1], [hueShift, saturationScale, valueScale, hueShift, saturationScale, valueScale])
    }

    /// A curve that lifts everything: through (0.25, 0.5).
    static let liftingCurve: [Float] = [0, 0, 0.25, 0.5, 1, 1]
}

struct DNGCameraProfileRenderingTests {
    // MARK: - The pieces

    @Test func aToneCurvePassesThroughItsPointsAndStaysSmooth() throws {
        let points = stride(from: 0, to: DCPFixtures.liftingCurve.count, by: 2).map {
            DNGCameraProfile.TonePoint(input: DCPFixtures.liftingCurve[$0], output: DCPFixtures.liftingCurve[$0 + 1])
        }
        let curve = DNGCameraProfile.ToneCurve(points)
        for point in points { #expect(abs(curve.value(at: Double(point.input)) - Double(point.output)) < 1e-9) }
        #expect(curve.value(at: -1) == 0 && curve.value(at: 2) == 1)
        // Rising, and no jump either side of a point.
        var last = -1.0
        for step in 0...1000 {
            let value = curve.value(at: Double(step) / 1000)
            #expect(value >= last - 1e-9)
            last = value
        }
        #expect(abs(curve.value(at: 0.2499) - curve.value(at: 0.2501)) < 0.001)

        // Points on a line give the line.
        let line = DNGCameraProfile.ToneCurve([.init(input: 0, output: 0), .init(input: 0.3, output: 0.3), .init(input: 0.4, output: 0.4), .init(input: 1, output: 1)])
        for step in 0...20 { #expect(abs(line.value(at: Double(step) / 20) - Double(step) / 20) < 1e-9) }
    }

    @Test func aToneCurveKeepsAColorsHue() {
        let curve = DNGCameraProfile.ToneCurve([.init(input: 0, output: 0), .init(input: 0.25, output: 0.5), .init(input: 1, output: 1)])
        let gray = curve.apply(SIMD3(0.25, 0.25, 0.25))
        #expect(abs(gray.x - 0.5) < 1e-6 && gray.x == gray.y && gray.y == gray.z)
        let color = SIMD3<Float>(0.6, 0.3, 0.1), toned = curve.apply(color)
        #expect(abs(Double(toned.x) - curve.value(at: 0.6)) < 1e-6 && abs(Double(toned.z) - curve.value(at: 0.1)) < 1e-6)
        // The middle channel stays where it was between the other two.
        #expect(abs((toned.y - toned.z) / (toned.x - toned.z) - (color.y - color.z) / (color.x - color.z)) < 1e-5)
        let before = AdobeProfile.LookTable.hsv(color).0, after = AdobeProfile.LookTable.hsv(toned).0
        #expect(abs(before - after) < 1e-4)
    }

    @Test func theLightPicksBetweenTheTwoCalibrations() throws {
        let warm = DCPFixtures.uniformTable(hueShift: 10), cool = DCPFixtures.uniformTable(hueShift: 30)
        let profile = try DCPFixtures.profile(illuminants: [17, 21], hueSatMaps: [warm.data, cool.data], hueSatMapDims: warm.dims)
        // Standard Light A is 2850 K and D65 6500 K.
        #expect(profile.firstCalibrationWeight(temperature: 2000) == 1)
        #expect(profile.firstCalibrationWeight(temperature: 2850) == 1)
        #expect(profile.firstCalibrationWeight(temperature: 6500) == 0)
        #expect(profile.firstCalibrationWeight(temperature: 9000) == 0)
        // Halfway by the inverse of the temperature.
        let middle = 1 / ((1 / 2850.0 + 1 / 6500.0) / 2)
        #expect(abs(profile.firstCalibrationWeight(temperature: middle) - 0.5) < 1e-9)
        #expect(profile.hueSaturationMap(firstCalibrationWeight: 1)?.entries.first?.x == 10)
        #expect(profile.hueSaturationMap(firstCalibrationWeight: 0)?.entries.first?.x == 30)
        #expect(profile.hueSaturationMap(firstCalibrationWeight: 0.25)?.entries.first?.x == 25)

        let single = try DCPFixtures.profile(hueSatMaps: [warm.data], hueSatMapDims: warm.dims)
        #expect(single.firstCalibrationWeight(temperature: 9000) == 1)
        #expect(single.hueSaturationMap(firstCalibrationWeight: 0)?.entries.first?.x == 10)
    }

    @Test func aProfileKnowsItsCamera() throws {
        let sony = try DCPFixtures.profile(cameraModel: "Sony ILCE-7CM2")
        #expect(sony.isFor(cameraMake: "SONY", model: "ILCE-7CM2"))
        #expect(!sony.isFor(cameraMake: "SONY", model: "ILCE-7M4"))
        #expect(!sony.isFor(cameraMake: nil, model: nil))
        let nikon = try DCPFixtures.profile(cameraModel: "Nikon Z 8")
        #expect(nikon.isFor(cameraMake: "NIKON CORPORATION", model: "NIKON Z 8"))
        #expect(!nikon.isFor(cameraMake: "NIKON CORPORATION", model: "NIKON Z 9"))
        #expect(sony.id == "dcp:sonyilce7cm2:fixture look")
        #expect(sony.id != nikon.id)
    }

    /// The cube's value at a corner of its grid.
    private func sample(_ cube: AdobeProfile.Cube, red: Int, green: Int, blue: Int) -> SIMD3<Float> {
        let n = cube.dimension
        return cube.data.withUnsafeBytes { bytes in
            let values = bytes.bindMemory(to: Float.self), i = ((blue * n + green) * n + red) * 4
            return SIMD3(values[i], values[i + 1], values[i + 2])
        }
    }

    @Test func theCubeAppliesTheMapThenTheLookThenTheCurve() throws {
        let n = 9
        func axis(_ index: Int) -> Float { Float(index) / Float(n - 1) }
        func linear(_ encoded: SIMD3<Float>) -> SIMD3<Float> { SIMD3(pow(encoded.x, 1.8), pow(encoded.y, 1.8), pow(encoded.z, 1.8)) }
        func encoded(_ linear: SIMD3<Float>) -> SIMD3<Float> { SIMD3(pow(linear.x, 1 / 1.8), pow(linear.y, 1 / 1.8), pow(linear.z, 1 / 1.8)) }

        // Nothing in the profile: the cube changes nothing.
        let plain = try DCPFixtures.profile().cube(amount: 1, dimension: n)
        #expect(plain.colorSpaceName == CGColorSpace.rommrgb as String && plain.data.count == n * n * n * 16)
        for index in [(0, 0, 0), (8, 8, 8), (3, 5, 1)] {
            let value = sample(plain, red: index.0, green: index.1, blue: index.2)
            #expect(simd_distance(value, SIMD3(axis(index.0), axis(index.1), axis(index.2))) < 1e-5)
        }

        // A map that turns the hue, a look that halves the saturation, and a curve.
        let map = DCPFixtures.uniformTable(hueShift: 120), look = DCPFixtures.uniformTable(saturationScale: 0.5)
        let profile = try DCPFixtures.profile(hueSatMaps: [map.data], hueSatMapDims: map.dims, lookTable: look.data, lookTableDims: look.dims,
                                              toneCurve: DCPFixtures.liftingCurve)
        let curve = DNGCameraProfile.ToneCurve(try #require(profile.toneCurve))
        let mapTable = try #require(profile.calibrations[0].hueSaturationMap), lookTable = try #require(profile.lookTable)
        let input = linear(SIMD3(axis(6), axis(2), axis(1)))

        let whole = sample(profile.cube(amount: 1, dimension: n), red: 6, green: 2, blue: 1)
        #expect(simd_distance(whole, encoded(curve.apply(lookTable.apply(mapTable.apply(input, amount: 1), amount: 1)))) < 1e-5)
        // On another camera's photo the map is left out.
        let elsewhere = sample(profile.cube(amount: 1, usesCalibration: false, dimension: n), red: 6, green: 2, blue: 1)
        #expect(simd_distance(elsewhere, encoded(curve.apply(lookTable.apply(input, amount: 1)))) < 1e-5)
        // Amount scales the look only: at 0 the map and the curve are still there.
        let none = sample(profile.cube(amount: 0, dimension: n), red: 6, green: 2, blue: 1)
        #expect(simd_distance(none, encoded(curve.apply(mapTable.apply(input, amount: 1)))) < 1e-5)
        let half = sample(profile.cube(amount: 0.5, dimension: n), red: 6, green: 2, blue: 1)
        #expect(simd_distance(half, encoded(curve.apply(lookTable.apply(mapTable.apply(input, amount: 1), amount: 0.5)))) < 1e-5)
    }

    // MARK: - On the RAW engine

    /// A RAW file: gray on the left, orange on the right.
    private func rawFile(in directory: TemporaryDirectory, make: String = "Sony", model: String = "ILCE-7CM2") throws -> URL {
        let image = DNGFixtures.image(width: 64, height: 32) { x, _ in x < 32 ? SIMD3(0.18, 0.18, 0.18) : SIMD3(0.4, 0.2, 0.05) }
        let url = directory.url.appending(path: "\(model)-\(UUID().uuidString).dng")
        try LinearDNGWriter.write(image, metadata: DNGMetadata(make: make, model: model, captureDate: Date(timeIntervalSince1970: 1_700_000_000)), to: url)
        return url
    }

    /// The decoded photo's gray and orange patches, linear sRGB.
    private func patches(_ source: DevelopSource, _ adjustments: PhotoAdjustments) -> (gray: SIMD3<Float>, orange: SIMD3<Float>) {
        let image = source.baseImage(with: adjustments, scale: 1)
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        CIContext(options: [.cacheIntermediates: false]).render(image, toBitmap: &pixels, rowBytes: width * 16, bounds: extent, format: .RGBAf,
                                                                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        func pixel(_ x: Int) -> SIMD3<Float> {
            let i = (height / 2 * width + x) * 4
            return SIMD3(pixels[i], pixels[i + 1], pixels[i + 2])
        }
        return (pixel(width / 4), pixel(width * 3 / 4))
    }

    private func adjustments(_ profile: DNGCameraProfile?, amount: Double = 1) -> PhotoAdjustments {
        var adjustments = PhotoAdjustments()
        adjustments.profile.adobeID = profile?.id
        adjustments.profile.amount = amount
        return adjustments
    }

    private func source(_ url: URL, _ profiles: DNGCameraProfile...) throws -> DevelopSource {
        let source = try #require(DevelopSource(url: url))
        let library = AdobeProfileLibrary(directory: url.deletingLastPathComponent().appending(path: "Profiles-\(UUID().uuidString)"))
        for profile in profiles { library.register(profile) }
        source.profiles = library
        return source
    }

    /// The photo as the RAW engine decodes it with its own tone curve off.
    private func linearPatches(_ url: URL) throws -> (gray: SIMD3<Float>, orange: SIMD3<Float>) {
        let line = try DCPFixtures.profile(name: "Line", toneCurve: [0, 0, 1, 1])
        return patches(try source(url, line), adjustments(line))
    }

    @Test func aProfileWithoutTablesOrCurveLeavesThePhotoAsItWas() throws {
        let directory = try TemporaryDirectory()
        let url = try rawFile(in: directory)
        let empty = try DCPFixtures.profile()
        let source = try source(url, empty)
        let standard = patches(source, PhotoAdjustments()), profiled = patches(source, adjustments(empty))
        #expect(simd_distance(standard.gray, profiled.gray) < 0.01)
        #expect(simd_distance(standard.orange, profiled.orange) < 0.02)
    }

    @Test func aProfilesCurveReplacesTheEnginesTone() throws {
        let directory = try TemporaryDirectory()
        let url = try rawFile(in: directory)
        let lifting = try DCPFixtures.profile(name: "Lift", toneCurve: DCPFixtures.liftingCurve)
        let source = try source(url, lifting)
        let standard = patches(source, PhotoAdjustments())
        let linear = try linearPatches(url)
        // A straight curve shows the engine's linear stage, which its own tone curve brightens.
        #expect(linear.gray.y > 0.05 && linear.gray.y < standard.gray.y)

        let lifted = patches(source, adjustments(lifting))
        let curve = DNGCameraProfile.ToneCurve(try #require(lifting.toneCurve))
        #expect(abs(Double(lifted.gray.y) - curve.value(at: Double(linear.gray.y))) < 0.01)
        #expect(abs(lifted.gray.x - lifted.gray.z) < 0.01, "gray stays gray")

        // Going back to Default brings the engine's own rendering back.
        let again = patches(source, PhotoAdjustments())
        #expect(simd_distance(again.gray, standard.gray) < 1e-4 && simd_distance(again.orange, standard.orange) < 1e-4)
    }

    @Test func exposureComesBeforeTheProfileAndTheProfilesOffsetAddsToIt() throws {
        let directory = try TemporaryDirectory()
        let url = try rawFile(in: directory)
        let line = try DCPFixtures.profile(name: "Line", toneCurve: [0, 0, 1, 1])
        let brighter = try DCPFixtures.profile(name: "Brighter", toneCurve: [0, 0, 1, 1], baselineExposureOffset: 1)
        let source = try source(url, line, brighter)
        let plain = patches(source, adjustments(line))
        #expect(abs(patches(source, adjustments(brighter)).gray.y / plain.gray.y - 2) < 0.05)
        var exposed = adjustments(line)
        exposed.light.exposure = 1
        #expect(abs(patches(source, exposed).gray.y / plain.gray.y - 2) < 0.05)
    }

    @Test func theLookTableFollowsAmountAndAppliesOnAnyCamera() throws {
        let directory = try TemporaryDirectory()
        let look = DCPFixtures.uniformTable(saturationScale: 0)
        let profile = try DCPFixtures.profile(cameraModel: "Sony ILCE-7CM2", lookTable: look.data, lookTableDims: look.dims, toneCurve: [0, 0, 1, 1])
        func spread(_ color: SIMD3<Float>) -> Float { color.max() - color.min() }
        for model in ["ILCE-7CM2", "ILCE-7M4", "ILCE-7CR"] {
            let source = try source(try rawFile(in: directory, model: model), profile)
            let full = patches(source, adjustments(profile))
            #expect(spread(full.orange) < 0.01, "\(model): the look takes the color out")
            let none = patches(source, adjustments(profile, amount: 0))
            #expect(spread(none.orange) > 0.1, "\(model): at 0 the look is off")
            let half = patches(source, adjustments(profile, amount: 0.5))
            #expect(spread(half.orange) > spread(full.orange) + 0.03 && spread(half.orange) < spread(none.orange) - 0.03)
        }
    }

    /// The map goes with the profile's matrices, which Apple's engine doesn't use: it's left out unless asked for, and
    /// then only for the profile's own camera.
    @Test func theHueSaturationMapIsLeftOut() throws {
        let directory = try TemporaryDirectory()
        let map = DCPFixtures.uniformTable(saturationScale: 0)
        let profile = try DCPFixtures.profile(cameraModel: "Sony ILCE-7CM2", hueSatMaps: [map.data], hueSatMapDims: map.dims, toneCurve: [0, 0, 1, 1])
        func spread(_ color: SIMD3<Float>) -> Float { color.max() - color.min() }
        let own = try source(try rawFile(in: directory, model: "ILCE-7CM2"), profile)
        #expect(spread(patches(own, adjustments(profile)).orange) > 0.1)

        let asked = try source(try rawFile(in: directory, model: "ILCE-7CM2"), profile)
        asked.profiles.appliesHueSaturationMaps = true
        #expect(spread(patches(asked, adjustments(profile)).orange) < 0.01)
        let other = try source(try rawFile(in: directory, model: "ILCE-7M4"), profile)
        other.profiles.appliesHueSaturationMaps = true
        #expect(spread(patches(other, adjustments(profile)).orange) > 0.1)
    }

    @Test func aPhotoThatIsntRawIgnoresTheProfile() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "photo.png")
        let image = CIImage(color: CIColor(red: 0.4, green: 0.2, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        try CIContext().writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let look = DCPFixtures.uniformTable(saturationScale: 0)
        let profile = try DCPFixtures.profile(lookTable: look.data, lookTableDims: look.dims, toneCurve: DCPFixtures.liftingCurve)
        let source = try source(url, profile)
        #expect(!source.isRaw)
        let before = source.image(with: PhotoAdjustments(), scale: 1), after = source.image(with: adjustments(profile), scale: 1)
        let context = CIContext()
        func pixel(_ image: CIImage) -> [UInt8] {
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 8, y: 8, width: 1, height: 1), format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return pixel
        }
        #expect(pixel(before) == pixel(after))
    }

    @Test func aCameraProfileCountsAsAnEditAtAnyAmount() throws {
        let profile = try DCPFixtures.profile(toneCurve: DCPFixtures.liftingCurve)
        var settings = PhotoAdjustments.Profile()
        #expect(!settings.isActive && !settings.isCameraProfile)
        settings.adobeID = profile.id
        settings.amount = 0
        #expect(settings.isCameraProfile && settings.isActive, "its tone curve still applies")
        settings.adobeID = "B7C1A0E2-AAAA-BBBB-CCCC-000000000000"
        #expect(!settings.isCameraProfile && !settings.isActive, "an Adobe look at 0 is nothing")
        settings.isEnabled = false
        settings.adobeID = profile.id
        #expect(!settings.isActive)
    }

    // MARK: - The library

    @Test func aPickedProfileIsFiledIndexedAndOfferedForEveryCamera() throws {
        let directory = try TemporaryDirectory()
        let picked = directory.url.appending(path: "Downloads/Sony ILCE-7CM2 Classic Look.dcp")
        try FileManager.default.createDirectory(at: picked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try DCPFixtures.file(DCPFixtures.contents(name: "Classic Look", cameraModel: "Sony ILCE-7CM2", toneCurve: DCPFixtures.liftingCurve)).write(to: picked)

        let library = AdobeProfileLibrary(directory: directory.url.appending(path: "Profiles"))
        #expect(library.importCameraProfile(picked))
        library.saveIndex()
        let entry = try #require(library.allEntries.first)
        #expect(entry.id == "dcp:sonyilce7cm2:classic look" && entry.name == "Classic Look")
        #expect(entry.group == "Profiles" && entry.cameraModel.isEmpty, "listed for every camera")
        #expect(entry.cameraProfileModel == "Sony ILCE-7CM2" && entry.isCameraProfile)
        #expect(entry.file == "Camera Profiles/Sony ILCE-7CM2/Classic Look.dcp")
        #expect(FileManager.default.fileExists(atPath: library.directory.appending(path: entry.file).path(percentEncoded: false)))
        #expect(library.cameraProfile(id: entry.id)?.toneCurve?.count == 3)
        // It isn't an Adobe look: no cubes or hidden settings of that kind.
        #expect(library.profile(id: entry.id) == nil && library.cubes(id: entry.id, amount: 1).isEmpty && library.hiddenSettings(id: entry.id) == nil)
        #expect(library.find(id: nil, name: "classic look", cameraModel: "ILCE-7M4")?.id == entry.id)

        // The index is read back, and rebuilt from the files when it's gone.
        let reopened = AdobeProfileLibrary(directory: library.directory)
        #expect(reopened.allEntries == [entry])
        try FileManager.default.removeItem(at: library.directory.appending(path: "Index.json"))
        #expect(AdobeProfileLibrary(directory: library.directory).allEntries == [entry])

        // A newer copy of the same profile replaces it.
        try DCPFixtures.file(DCPFixtures.contents(name: "Classic Look", cameraModel: "Sony ILCE-7CM2", toneCurve: [0, 0, 1, 1])).write(to: picked)
        #expect(library.importCameraProfile(picked))
        #expect(library.allEntries.count == 1 && library.cameraProfile(id: entry.id)?.toneCurve?.count == 2)
    }

    @Test func aProfileKeptToItsCameraIsFiledWithTheCameraMatchingOnes() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appending(path: "Camera Standard.dcp")
        try DCPFixtures.file(DCPFixtures.contents(name: "Camera Standard", cameraModel: "Nikon Z 8")).write(to: file)
        let library = AdobeProfileLibrary(directory: directory.url.appending(path: "Profiles"))
        #expect(library.importCameraProfile(file, forItsCameraOnly: true))
        let entry = try #require(library.allEntries.first)
        #expect(entry.cameraModel == "Nikon Z 8" && entry.file == "Camera/Nikon Z 8/Camera Standard.dcp")
        try? FileManager.default.removeItem(at: library.directory.appending(path: "Index.json"))
        #expect(AdobeProfileLibrary(directory: library.directory).allEntries == [entry])
    }

    @Test func filesThatArentCameraProfilesArentImported() throws {
        let directory = try TemporaryDirectory()
        let library = AdobeProfileLibrary(directory: directory.url.appending(path: "Profiles"))
        let nameless = directory.url.appending(path: "nameless.dcp")
        var contents = DCPFixtures.contents()
        contents.name = nil
        try DCPFixtures.file(contents).write(to: nameless)
        #expect(!library.importCameraProfile(nameless))
        let junk = directory.url.appending(path: "junk.dcp")
        try Data("not a profile".utf8).write(to: junk)
        #expect(!library.importCameraProfile(junk))
        #expect(library.allEntries.isEmpty)
    }

    @Test @MainActor func importProfilesAndPresetsTakesCameraProfiles() async throws {
        let directory = try TemporaryDirectory()
        let folder = directory.url.appending(path: "Picked/Looks")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try DCPFixtures.file(DCPFixtures.contents(name: "One", cameraModel: "Sony ILCE-7CM2")).write(to: folder.appending(path: "One.dcp"))
        try DCPFixtures.file(DCPFixtures.contents(name: "Two", cameraModel: "Sony ILCE-7CM2")).write(to: folder.appending(path: "Two.DCP"))
        let single = directory.url.appending(path: "Three.dcp")
        try DCPFixtures.file(DCPFixtures.contents(name: "Three", cameraModel: "Sony ILCE-7M4")).write(to: single)

        // A preset library elsewhere keeps its profiles in a Profiles folder beside it.
        let library = PresetLibrary(directory: directory.url.appending(path: "Settings"))
        let profiles = library.profiles
        let result = await library.importPresets(from: [folder.deletingLastPathComponent(), single])
        #expect(result == .init(presets: 0, profiles: 3))
        #expect(profiles.allEntries.map(\.name) == ["One", "Three", "Two"])
        #expect(AdobeProfileLibrary(directory: profiles.directory).allEntries.count == 3, "the index was saved")
    }

    // MARK: - The Profile menu

    @Test @MainActor func pickedProfilesAreListedForEveryRawPhoto() throws {
        let directory = try TemporaryDirectory()
        let library = AdobeProfileLibrary(directory: directory.url)
        let classic = try DCPFixtures.profile(name: "Classic Look", cameraModel: "Sony ILCE-7CM2")
        library.register(classic)
        library.register(try DCPFixtures.profile(name: "Classic Look", cameraModel: "Sony ILCE-7M4"))
        library.register(try DCPFixtures.profile(name: "Soft Look", cameraModel: "Sony ILCE-7CM2"))
        library.register(try DCPFixtures.profile(name: "Camera Standard", cameraModel: "Nikon Z 8"), forItsCameraOnly: true)

        let panel = AdjustmentsPanelViewController()
        panel.profiles = library
        _ = panel.view
        panel.isEditingEnabled = true
        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        let popUp = try #require(allViews(panel.view).first { $0.accessibilityIdentifier() == "profilePopUp" } as? NSPopUpButton)
        func group(_ title: String) -> [String]? { popUp.menu?.items.first { $0.submenu?.title == title }?.submenu?.items.map(\.title) }
        /// The menu itself, a separator as "-".
        func titles() -> [String] { (popUp.menu?.items ?? []).map { $0.isSeparatorItem ? "-" : $0.title } }
        let own = ["Default", "Neutral", "Vivid", "Landscape", "Portrait", "Monochrome"]
        let picked = ["Classic Look (Sony ILCE-7CM2)", "Classic Look (Sony ILCE-7M4)", "Soft Look"]

        // In the menu itself, after PixelLoupe's own looks and a separator, whatever the camera; profiles of one name
        // are told apart by theirs.
        for camera in ["ILCE-7CR", "NIKON Z 9"] {
            panel.cameraModel = camera
            #expect(titles() == own + ["-"] + picked)
            #expect(group("Profiles") == nil && group("Camera Matching") == nil)
        }
        // One kept to its camera shows for that camera only, in its group after another separator.
        panel.cameraModel = "NIKON Z 8"
        #expect(titles() == own + ["-"] + picked + ["-", "Camera Matching"])
        #expect(group("Camera Matching") == ["Camera Standard"])

        // Choosing one names it in the photo's settings.
        var changed: PhotoAdjustments?
        panel.onChange = { adjustments, _, _ in changed = adjustments }
        let item = try #require(popUp.menu?.item(withTitle: picked[0]))
        _ = item.target?.perform(item.action, with: item)
        #expect(changed?.profile.adobeID == classic.id && changed?.profile.importedName == "Classic Look")
        #expect(popUp.toolTip == "Camera profile, rendered from its own tables and tone curve")
        // The pop-up shows it where it's listed, not as an extra item at the end.
        #expect(popUp.titleOfSelectedItem == picked[0] && titles() == own + ["-"] + picked + ["-", "Camera Matching"])

        // Not for photos that aren't RAW.
        panel.display(PhotoAdjustments(), asShotWhiteBalance: (6500, 0), isRaw: false)
        #expect(titles() == own)
        panel.display(PhotoAdjustments(), asShotWhiteBalance: (5200, 4), isRaw: true)
        #expect(titles() == own + ["-"] + picked + ["-", "Camera Matching"])
    }

    // MARK: - Lightroom's own camera profiles (RAW-305)

    @Test func adobesCameraNamesMatchExifModels() {
        #expect(AdobeProfile.isCamera("Sony ILCE-7CM2", "ILCE-7CM2"))
        #expect(AdobeProfile.isCamera("Fujifilm X-T4", "X-T4"))
        #expect(AdobeProfile.isCamera("Nikon Z 8", "NIKON Z 8"))
        #expect(AdobeProfile.isCamera("Nikon Z 50 2", "NIKON Z 50_2"))
        #expect(AdobeProfile.isCamera("Canon EOS R5", "Canon EOS R5"))
        #expect(!AdobeProfile.isCamera("Sony ILCE-7CM2", "ILCE-7M4"))
        #expect(!AdobeProfile.isCamera("Sony ILCE-7", "ILCE-7CM2"))
        #expect(!AdobeProfile.isCamera("Nikon Z 8", "Z 9"))
        #expect(!AdobeProfile.isCamera("Sony ILCE-7CM2", nil) && !AdobeProfile.isCamera("", "ILCE-7CM2"))
    }

    @Test @MainActor func lightroomsCameraProfilesStayWithTheirCamera() async throws {
        let directory = try TemporaryDirectory()
        // Laid out as Camera Raw's CameraProfiles folder is.
        let adobe = directory.url.appending(path: "CameraProfiles")
        for (folder, name, camera) in [("Camera/Sony ILCE-7CM2", "Camera Standard", "Sony ILCE-7CM2"), ("Camera/Sony ILCE-7CM2", "Camera Vivid", "Sony ILCE-7CM2"),
                                       ("Camera/Nikon Z 8", "Camera Standard", "Nikon Z 8"), ("Adobe Standard", "Adobe Standard", "Sony ILCE-7CM2")] {
            let file = adobe.appending(path: folder).appending(path: "\(camera) \(name).dcp")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DCPFixtures.file(DCPFixtures.contents(name: name, cameraModel: camera)).write(to: file)
        }
        let library = PresetLibrary(directory: directory.url.appending(path: "Settings"))
        let profiles = library.profiles
        #expect(await library.importPresets(from: [adobe], cameraProfilesForTheirCameraOnly: true) == .init(presets: 0, profiles: 4))
        #expect(profiles.allEntries.allSatisfy { !$0.cameraModel.isEmpty && $0.isCameraProfile && $0.file.hasPrefix("Camera/") })

        // Only the photo's camera's, and only for RAW photos.
        #expect(profiles.entries(forCameraModel: "ILCE-7CM2", isRaw: true).map(\.name) == ["Adobe Standard", "Camera Standard", "Camera Vivid"])
        #expect(profiles.entries(forCameraModel: "NIKON Z 8", isRaw: true).map(\.name) == ["Camera Standard"])
        #expect(profiles.entries(forCameraModel: "ILCE-7M4", isRaw: true).isEmpty)
        #expect(profiles.entries(forCameraModel: "ILCE-7CM2", isRaw: false).isEmpty)
        #expect(profiles.entries(forCameraModel: nil, isRaw: true).isEmpty)

        let panel = AdjustmentsPanelViewController()
        panel.profiles = profiles
        _ = panel.view
        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        let popUp = try #require(allViews(panel.view).first { $0.accessibilityIdentifier() == "profilePopUp" } as? NSPopUpButton)
        func group(_ title: String) -> [String]? { popUp.menu?.items.first { $0.submenu?.title == title }?.submenu?.items.map(\.title) }
        panel.cameraModel = "ILCE-7CM2"
        #expect(group("Camera Matching") == ["Adobe Standard", "Camera Standard", "Camera Vivid"])
        panel.cameraModel = "ILCE-7M4"
        #expect(group("Camera Matching") == nil)
    }

    @Test func theMenusProfilesAreFoundAmongThousands() throws {
        let directory = try TemporaryDirectory()
        let library = AdobeProfileLibrary(directory: directory.url)
        let one = try DCPFixtures.profile()
        // As many as Lightroom's 395 camera folders hold.
        for camera in 0..<400 {
            for name in ["Camera Standard", "Camera Vivid", "Camera Neutral", "Camera Portrait", "Camera Landscape", "Camera Deep", "Camera Light",
                         "Camera Monochrome", "Camera Flat", "Adobe Standard"] {
                library.register(DNGCameraProfile(
                    name: name, cameraModel: "Maker Model \(camera)", calibrationSignature: "", copyright: "", embedPolicy: .allowCopying,
                    calibrations: one.calibrations, lookTable: nil, toneCurve: nil, baselineExposureOffset: 0, defaultBlackRender: .auto
                ), forItsCameraOnly: true)
            }
        }
        #expect(library.allEntries.count == 4000)
        let clock = ContinuousClock.now
        for _ in 0..<20 { #expect(library.entries(forCameraModel: "Model 123", isRaw: true).count == 10) }
        let each = clock.duration(to: .now) / 20
        // Generous, for slow test machines: sorting all 4,000 first took several times this.
        #expect(each < .milliseconds(100), "the Profile menu is rebuilt on every refresh: \(each) each")
    }

    @Test func aLookRendersOnTheCameraProfileItNames() throws {
        let directory = try TemporaryDirectory()
        let url = try rawFile(in: directory, model: "ILCE-7CM2")
        // Nikon's Creative Picture Controls and the like: a look that says which camera profile it sits on.
        let look = try #require(AdobeProfile.parse(ProfileFixtures.xmp(name: "Dream", group: "Camera Matching", uuid: "UUID-DREAM", camera: "Sony ILCE-7CM2",
                                                                         lookTable: ProfileFixtures.lookTable(hueShift: 0), settings: ["CameraProfile": "Camera Standard"])))
        let base = try DCPFixtures.profile(name: "Camera Standard", cameraModel: "Sony ILCE-7CM2", toneCurve: DCPFixtures.liftingCurve)
        let otherCameras = try DCPFixtures.profile(name: "Camera Standard", cameraModel: "Sony ILCE-7M4", toneCurve: [0, 0, 1, 1])
        var dream = PhotoAdjustments()
        dream.profile.adobeID = look.id

        // Without the base imported, the look is on Default as before.
        let source = try source(url, otherCameras)
        source.profiles.register(look)
        #expect(source.profiles.baseCameraProfileID(forLook: look.id, cameraModel: "ILCE-7CM2") == nil)
        let standard = patches(source, PhotoAdjustments())
        #expect(simd_distance(patches(source, dream).gray, standard.gray) < 1e-4)

        // With it, the base's tone curve is under the look, whatever the look's amount.
        source.profiles.register(base, forItsCameraOnly: true)
        #expect(source.profiles.baseCameraProfileID(forLook: look.id, cameraModel: "ILCE-7CM2") == base.id)
        let onBase = patches(source, adjustments(base))
        #expect(simd_distance(onBase.gray, standard.gray) > 0.02)
        #expect(simd_distance(patches(source, dream).gray, onBase.gray) < 1e-4)
        dream.profile.amount = 0.5
        #expect(simd_distance(patches(source, dream).gray, onBase.gray) < 1e-4)
        // A camera profile has no base of its own, and neither has a look that names none.
        #expect(source.profiles.baseCameraProfileID(forLook: base.id, cameraModel: "ILCE-7CM2") == nil)
        let plain = try #require(AdobeProfile.parse(ProfileFixtures.xmp(name: "Plain", group: "Looks", uuid: "UUID-PLAIN",
                                                                          lookTable: ProfileFixtures.lookTable(hueShift: 0))))
        source.profiles.register(plain)
        #expect(source.profiles.baseCameraProfileID(forLook: plain.id, cameraModel: "ILCE-7CM2") == nil)
    }

    @Test func aCatalogsCameraProfileUsesTheImportedOne() throws {
        let directory = try TemporaryDirectory()
        let library = AdobeProfileLibrary(directory: directory.url)
        let standard = try DCPFixtures.profile(name: "Camera Standard", cameraModel: "Sony ILCE-7CM2")
        let vivid = try DCPFixtures.profile(name: "Camera Vivid", cameraModel: "Sony ILCE-7CM2")
        let adobeStandard = try DCPFixtures.profile(name: "Adobe Standard", cameraModel: "Sony ILCE-7CM2")
        for profile in [standard, vivid, adobeStandard] { library.register(profile, forItsCameraOnly: true) }
        func map(_ text: String, camera: String = "ILCE-7CM2") throws -> (PhotoAdjustments, [LightroomDevelopMapper.Difference]) {
            var adjustments = PhotoAdjustments()
            var input = LightroomDevelopMapper.Input(settings: try #require(try LuaTableParser.parse(text).table), processVersion: "11.0",
                                                     whiteBalance: nil, isRaw: true)
            input.profiles = library
            input.cameraModel = camera
            let differences = LightroomDevelopMapper.apply(input, to: &adjustments)
            return (adjustments, differences)
        }
        // The camera's own profiles, where PixelLoupe had only its Default or its own look.
        let mappedStandard = try map(#"{ CameraProfile = "Camera Standard" }"#)
        #expect(mappedStandard.0.profile.adobeID == standard.id && mappedStandard.1.isEmpty)
        let mappedVivid = try map(#"{ Look = { Name = "Camera Vivid", Amount = 1 } }"#)
        #expect(mappedVivid.0.profile.adobeID == vivid.id && mappedVivid.0.profile.kind == .standard)
        // Another camera's photo has no such profile: as before.
        let other = try map(#"{ Look = { Name = "Camera Vivid", Amount = 1 } }"#, camera: "ILCE-7M4")
        #expect(other.0.profile.adobeID == nil && other.0.profile.kind == .vivid)
        #expect(try map(#"{ CameraProfile = "Camera Standard" }"#, camera: "ILCE-7M4").0.profile.adobeID == nil)
        // Adobe's defaults stay PixelLoupe's own rendering, though the camera's Adobe Standard is imported.
        #expect(try map(#"{ CameraProfile = "Adobe Standard" }"#).0.profile.adobeID == nil)
        #expect(try map(#"{ Look = { Name = "Adobe Color", Amount = 1 } }"#).0.profile.adobeID == nil)
    }
}
