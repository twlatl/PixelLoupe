import Foundation
import Testing
@testable import PixelLoupe

/// RAW-303. The profiles here are built by the tests (nobody's `.dcp` files are in the repository).
enum DCPFixtures {
    /// What goes into a profile file. Every part can be left out or made wrong.
    struct Contents {
        var name: String? = "Fixture Look"
        var cameraModel: String? = "Fixture Camera 1"
        var signature: String? = "com.example.calibration"
        var copyright: String? = "Made by the tests"
        var embedPolicy: UInt32? = 3
        var illuminants: [UInt16] = [17, 21]
        var colorMatrices: [[Double]] = [DCPFixtures.matrix(0.75), DCPFixtures.matrix(0.5)]
        var forwardMatrices: [[Double]] = [DCPFixtures.matrix(0.25), DCPFixtures.matrix(0.125)]
        var reductionMatrices: [[Double]] = []
        var hueSatMapDims: [UInt32]? = [3, 2, 1]
        var hueSatMaps: [[Float]] = [DCPFixtures.table(entries: 6, hueShift: 2), DCPFixtures.table(entries: 6, hueShift: -4)]
        var hueSatMapEncoding: UInt32?
        var lookTableDims: [UInt32]? = [2, 2, 2]
        var lookTable: [Float]? = DCPFixtures.table(entries: 8, hueShift: 10)
        var lookTableEncoding: UInt32? = 1
        var toneCurve: [Float]? = [0, 0, 0.25, 0.125, 0.5, 0.75, 1, 1]
        var baselineExposureOffset: Double? = -0.5
        var defaultBlackRender: UInt32? = 1
    }

    /// A 3 × 3 matrix whose numbers survive being written as fractions exactly.
    static func matrix(_ scale: Double) -> [Double] {
        [1, -0.25, 0.5, -0.5, 1, 0.25, 0.125, -0.125, 1].map { $0 * scale }
    }

    /// A table whose entries differ, so their order is checked.
    static func table(entries: Int, hueShift: Float) -> [Float] {
        (0..<entries).flatMap { [hueShift + Float($0), 1 + Float($0) / 8, 1 - Float($0) / 16] }
    }

    /// The profile file: a TIFF directory with a `.dcp`'s number in its header.
    static func file(_ contents: Contents = Contents(), isBigEndian: Bool = false, isProfile: Bool = true) -> Data {
        let builder = TIFFBuilder(isBigEndian: isBigEndian)
        var directory = TIFFBuilder.Directory()
        if let name = contents.name { directory.set(builder.entry(50936, ascii: name)) }
        if let model = contents.cameraModel { directory.set(builder.entry(50708, ascii: model)) }
        if let signature = contents.signature { directory.set(builder.entry(50932, ascii: signature)) }
        if let copyright = contents.copyright { directory.set(builder.entry(50942, ascii: copyright)) }
        if let policy = contents.embedPolicy { directory.set(builder.entry(50941, long: [policy])) }
        for (tag, illuminant) in zip([50778, 50779] as [UInt16], contents.illuminants) {
            directory.set(builder.entry(tag, short: [illuminant]))
        }
        for (tag, matrix) in zip([50721, 50722] as [UInt16], contents.colorMatrices) { directory.set(builder.entry(tag, srational: matrix)) }
        for (tag, matrix) in zip([50964, 50965] as [UInt16], contents.forwardMatrices) { directory.set(builder.entry(tag, srational: matrix)) }
        for (tag, matrix) in zip([50725, 50726] as [UInt16], contents.reductionMatrices) { directory.set(builder.entry(tag, srational: matrix)) }
        if let dims = contents.hueSatMapDims { directory.set(builder.entry(50937, long: dims)) }
        for (tag, map) in zip([50938, 50939] as [UInt16], contents.hueSatMaps) { directory.set(builder.entry(tag, float: map)) }
        if let encoding = contents.hueSatMapEncoding { directory.set(builder.entry(51107, long: [encoding])) }
        if let dims = contents.lookTableDims { directory.set(builder.entry(50981, long: dims)) }
        if let table = contents.lookTable { directory.set(builder.entry(50982, float: table)) }
        if let encoding = contents.lookTableEncoding { directory.set(builder.entry(51108, long: [encoding])) }
        if let curve = contents.toneCurve { directory.set(builder.entry(50940, float: curve)) }
        if let offset = contents.baselineExposureOffset { directory.set(builder.entry(51109, srational: [offset])) }
        if let render = contents.defaultBlackRender { directory.set(builder.entry(51110, long: [render])) }
        var data = builder.data(ifd0: directory)
        // "IIRC" or "MMCR" where a TIFF has 42.
        if isProfile { data.replaceSubrange(2..<4, with: isBigEndian ? [0x43, 0x52] : [0x52, 0x43]) }
        return data
    }

    static func entries(_ samples: [Float]) -> [SIMD3<Float>] {
        stride(from: 0, to: samples.count, by: 3).map { SIMD3(samples[$0], samples[$0 + 1], samples[$0 + 2]) }
    }
}

struct DNGCameraProfileTests {
    @Test(arguments: [false, true])
    func readsEveryTag(isBigEndian: Bool) throws {
        let contents = DCPFixtures.Contents()
        let profile = try #require(DNGCameraProfile.parse(DCPFixtures.file(contents, isBigEndian: isBigEndian)))

        #expect(profile.name == "Fixture Look")
        #expect(profile.cameraModel == "Fixture Camera 1")
        #expect(profile.calibrationSignature == "com.example.calibration")
        #expect(profile.copyright == "Made by the tests")
        #expect(profile.embedPolicy == .noRestrictions)
        #expect(profile.baselineExposureOffset == -0.5)
        #expect(profile.defaultBlackRender == .none)

        try #require(profile.calibrations.count == 2)
        for (index, calibration) in profile.calibrations.enumerated() {
            #expect(calibration.illuminant == [17, 21][index])
            #expect(calibration.colorPlanes == 3)
            #expect(calibration.colorMatrix == contents.colorMatrices[index])
            #expect(calibration.forwardMatrix == contents.forwardMatrices[index])
            #expect(calibration.reductionMatrix == nil)
            let map = try #require(calibration.hueSaturationMap)
            #expect(map.hueDivisions == 3 && map.saturationDivisions == 2 && map.valueDivisions == 1)
            #expect(!map.valueIsSRGB)
            #expect(map.entries == DCPFixtures.entries(contents.hueSatMaps[index]))
        }

        let look = try #require(profile.lookTable)
        #expect(look.hueDivisions == 2 && look.saturationDivisions == 2 && look.valueDivisions == 2)
        #expect(look.valueIsSRGB)
        #expect(look.entries == DCPFixtures.entries(try #require(contents.lookTable)))

        #expect(profile.toneCurve == [
            .init(input: 0, output: 0), .init(input: 0.25, output: 0.125), .init(input: 0.5, output: 0.75), .init(input: 1, output: 1),
        ])
    }

    @Test func aProfileWithOnlyAColorMatrixGetsTheDefaults() throws {
        let contents = DCPFixtures.Contents(
            name: nil, cameraModel: nil, signature: nil, copyright: nil, embedPolicy: nil, illuminants: [], colorMatrices: [DCPFixtures.matrix(1)],
            forwardMatrices: [], hueSatMapDims: nil, hueSatMaps: [], lookTableDims: nil, lookTable: nil, lookTableEncoding: nil, toneCurve: nil,
            baselineExposureOffset: nil, defaultBlackRender: nil
        )
        let profile = try #require(DNGCameraProfile.parse(DCPFixtures.file(contents)))
        #expect(profile.name.isEmpty)
        #expect(profile.cameraModel.isEmpty)
        #expect(profile.embedPolicy == .allowCopying)
        #expect(profile.calibrations.count == 1)
        #expect(profile.calibrations[0].forwardMatrix == nil)
        #expect(profile.calibrations[0].hueSaturationMap == nil)
        #expect(profile.lookTable == nil)
        #expect(profile.toneCurve == nil)
        #expect(profile.baselineExposureOffset == 0)
        #expect(profile.defaultBlackRender == .auto)
    }

    @Test func oneHueSaturationMapServesBothLights() throws {
        var contents = DCPFixtures.Contents()
        contents.hueSatMaps.removeLast()
        contents.hueSatMapEncoding = 1
        let profile = try #require(DNGCameraProfile.parse(DCPFixtures.file(contents)))
        let first = try #require(profile.calibrations[0].hueSaturationMap)
        #expect(first.valueIsSRGB)
        #expect(profile.calibrations[1].hueSaturationMap == first)
    }

    @Test func aTableWithoutAValueAxisHasOneDivision() throws {
        var contents = DCPFixtures.Contents()
        contents.lookTableDims = [2, 2]
        contents.lookTable = DCPFixtures.table(entries: 4, hueShift: 1)
        let look = try #require(DNGCameraProfile.parse(DCPFixtures.file(contents))?.lookTable)
        #expect(look.valueDivisions == 1)
        #expect(look.entries.count == 4)
    }

    @Test func aFourColorSensorKeepsItsReductionMatrix() throws {
        var contents = DCPFixtures.Contents()
        let fourColors = DCPFixtures.matrix(1) + [0.5, 0.25, 0.125]
        contents.colorMatrices = [fourColors]
        contents.forwardMatrices = []
        contents.reductionMatrices = [fourColors]
        let calibration = try #require(DNGCameraProfile.parse(DCPFixtures.file(contents))?.calibrations.first)
        #expect(calibration.colorPlanes == 4)
        #expect(calibration.reductionMatrix == fourColors)
    }

    @Test func filesThatArentProfilesAreRefused() {
        #expect(DNGCameraProfile.parse(Data()) == nil)
        #expect(DNGCameraProfile.parse(Data("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>".utf8)) == nil)
        // An ordinary TIFF with the same tags.
        #expect(DNGCameraProfile.parse(DCPFixtures.file(isProfile: false)) == nil)
        var withoutMatrix = DCPFixtures.Contents()
        withoutMatrix.colorMatrices = []
        #expect(DNGCameraProfile.parse(DCPFixtures.file(withoutMatrix)) == nil)
        #expect(DNGCameraProfile.load(URL(fileURLWithPath: "/nonexistent/profile.dcp")) == nil)
    }

    @Test func malformedTagsRefuseTheProfile() {
        func refused(_ change: (inout DCPFixtures.Contents) -> Void) -> Bool {
            var contents = DCPFixtures.Contents()
            change(&contents)
            return DNGCameraProfile.parse(DCPFixtures.file(contents)) == nil
        }
        // A matrix of the wrong size, or one that doesn't match the color matrix.
        #expect(refused { $0.colorMatrices[0].removeLast() })
        #expect(refused { $0.forwardMatrices[1] += [0, 0, 0] })
        // Tables whose data isn't the size their dimensions say.
        #expect(refused { $0.lookTable?.removeLast(3) })
        #expect(refused { $0.hueSatMaps[1] += [0, 1, 1] })
        #expect(refused { $0.lookTableDims = [2, 2, 2, 2] })
        // Dimensions outside the specification's: no hues, one saturation, too many values.
        #expect(refused { $0.lookTableDims = [0, 2, 2] })
        #expect(refused { $0.hueSatMapDims = [6, 1, 1] })
        #expect(refused { $0.lookTableDims = [2, 2, 100_000] })
        #expect(refused { $0.lookTableEncoding = 2 })
        #expect(refused { $0.lookTable?[4] = .nan })
        // Tone curves: half a point, one point, not from black, not to white, inputs going back.
        #expect(refused { $0.toneCurve?.removeLast() })
        #expect(refused { $0.toneCurve = [0, 0] })
        #expect(refused { $0.toneCurve?[1] = 0.1 })
        #expect(refused { $0.toneCurve = [0, 0, 0.5, 0.5, 0.9, 0.9] })
        #expect(refused { $0.toneCurve = [0, 0, 0.5, 0.5, 0.25, 0.25, 1, 1] })
    }

    /// Cut off anywhere, a file is either refused or, when only padding is missing, the whole profile: never part of one.
    @Test func truncatedFilesAreRefused() throws {
        let file = DCPFixtures.file()
        let whole = try #require(DNGCameraProfile.parse(file))
        for length in 0..<file.count {
            let parsed = DNGCameraProfile.parse(file.prefix(length))
            #expect(parsed == nil || parsed == whole, "cut to \(length) of \(file.count) bytes")
        }
        #expect(DNGCameraProfile.parse(file.prefix(file.count / 2)) == nil)
        #expect(DNGCameraProfile.parse(file.prefix(file.count - 8)) == nil)
    }

    @Test func loadsFromAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DNGCameraProfileTests-\(UUID().uuidString).dcp")
        defer { try? FileManager.default.removeItem(at: url) }
        try DCPFixtures.file().write(to: url)
        #expect(DNGCameraProfile.load(url)?.name == "Fixture Look")
    }
}
