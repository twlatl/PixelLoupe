import Foundation

/// A DNG camera profile (a `.dcp` file): how one camera's colors are rendered, in the tags the DNG specification
/// defines for camera profiles. Lightroom's Camera Matching profiles for most makers are these, and so is every
/// custom profile (ColorChecker Camera Calibration, Lumariver, dcamprof) and the community's film looks.
///
/// The file is a TIFF directory with its own number after the byte order ("IIRC" or "MMCR" where a TIFF has 42).
/// A profile has:
/// - one or two **calibrations**, each for a light (`CalibrationIlluminant`): the matrices between the camera's
///   colors and XYZ, and a hue/saturation map that refines them;
/// - a **look table**, applied after the hue/saturation map whatever the light: the profile's look;
/// - a **tone curve**; without one the renderer uses the specification's default.
///
/// This type only reads. The whole profile is kept, matrices included, though PixelLoupe's rendering on Apple's RAW
/// engine can't use them (RAW-126).
nonisolated struct DNGCameraProfile: Sendable, Equatable {
    /// `ProfileName`: what the Profile menu shows.
    let name: String
    /// `UniqueCameraModel`: the camera the profile was made for, as Adobe names it ("Sony ILCE-7CM2").
    let cameraModel: String
    /// `ProfileCalibrationSignature`, else empty.
    let calibrationSignature: String
    /// `ProfileCopyright`, else empty.
    let copyright: String
    let embedPolicy: EmbedPolicy
    /// The first calibration, then the second when the profile has two.
    let calibrations: [Calibration]
    /// `ProfileLookTableData`: hue shifts and saturation and value scales over a hue × saturation × value grid.
    let lookTable: AdobeProfile.LookTable?
    /// `ProfileToneCurve`: points from (0, 0) to (1, 1), inputs rising.
    let toneCurve: [TonePoint]?
    /// `BaselineExposureOffset`, in stops: added to the camera's baseline exposure.
    let baselineExposureOffset: Double
    let defaultBlackRender: DefaultBlackRender

    /// The color of one light, and the camera's colors under it.
    struct Calibration: Sendable, Equatable {
        /// `CalibrationIlluminant`, an EXIF `LightSource` value (17 is Standard Light A, 21 is D65).
        let illuminant: Int
        /// `ColorMatrix`: XYZ to the camera's colors, a row per color plane (three, or four for a four-color sensor).
        let colorMatrix: [Double]
        /// `ForwardMatrix`: white-balanced camera colors to XYZ D50, three rows of a column per color plane.
        let forwardMatrix: [Double]?
        /// `ReductionMatrix`: for four-color sensors, the camera's colors down to three.
        let reductionMatrix: [Double]?
        /// `ProfileHueSatMapData`.
        let hueSaturationMap: AdobeProfile.LookTable?

        /// How many colors the sensor records.
        var colorPlanes: Int { colorMatrix.count / 3 }
    }

    /// One point of a tone curve, both 0…1.
    struct TonePoint: Sendable, Equatable {
        let input: Float
        let output: Float
    }

    /// `ProfileEmbedPolicy`: what the profile's maker allows.
    enum EmbedPolicy: Int, Sendable {
        case allowCopying = 0, embedIfUsed, embedNever, noRestrictions
    }

    /// `DefaultBlackRender`: whether the renderer should set its own black point (`auto`) or leave the shadows as
    /// the profile's curve puts them (`none`).
    enum DefaultBlackRender: Int, Sendable {
        case auto = 0, none
    }

    // MARK: - Reading

    /// Reads a profile file. `nil` for files that aren't camera profiles, or are damaged.
    static func load(_ url: URL) -> DNGCameraProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> DNGCameraProfile? {
        guard let file = TIFFFile(data: data, magic: Tag.magic) else { return nil }
        let reader = Reader(file: file)
        do {
            return try reader.profile()
        } catch {
            return nil
        }
    }

    /// The camera profile tags of the DNG specification.
    private enum Tag {
        /// "CR" where a TIFF has 42.
        static let magic = 0x4352

        static let uniqueCameraModel: UInt16 = 50708
        static let colorMatrix: [UInt16] = [50721, 50722]
        static let reductionMatrix: [UInt16] = [50725, 50726]
        static let calibrationIlluminant: [UInt16] = [50778, 50779]
        static let profileCalibrationSignature: UInt16 = 50932
        static let profileName: UInt16 = 50936
        static let profileHueSatMapDims: UInt16 = 50937
        static let profileHueSatMapData: [UInt16] = [50938, 50939]
        static let profileToneCurve: UInt16 = 50940
        static let profileEmbedPolicy: UInt16 = 50941
        static let profileCopyright: UInt16 = 50942
        static let forwardMatrix: [UInt16] = [50964, 50965]
        static let profileLookTableDims: UInt16 = 50981
        static let profileLookTableData: UInt16 = 50982
        static let profileHueSatMapEncoding: UInt16 = 51107
        static let profileLookTableEncoding: UInt16 = 51108
        static let baselineExposureOffset: UInt16 = 51109
        static let defaultBlackRender: UInt16 = 51110
    }

    /// A tag that's there but can't be what the specification says.
    private struct Malformed: Error {}

    /// Reads the tags, each all there or the profile refused: a truncated file mustn't become a profile with half a table.
    private struct Reader {
        let file: TIFFFile
        var directory: TIFFFile.Directory { file.ifd0 }

        /// The largest tables the DNG SDK accepts.
        static let maximumDivisions = (hue: 360, saturation: 256, value: 256)

        func profile() throws -> DNGCameraProfile {
            let hueSatMaps = try hueSaturationMaps()
            var calibrations: [Calibration] = []
            for index in 0..<2 {
                guard let colorMatrix = try matrix(Tag.colorMatrix[index]) else { break }
                guard colorMatrix.count == 9 || colorMatrix.count == 12 else { throw Malformed() }
                let forward = try matrix(Tag.forwardMatrix[index]), reduction = try matrix(Tag.reductionMatrix[index])
                // Both are three rows of a column per color, so as many numbers as the color matrix.
                if let forward, forward.count != colorMatrix.count { throw Malformed() }
                if let reduction, reduction.count != colorMatrix.count { throw Malformed() }
                calibrations.append(Calibration(
                    illuminant: try integers(Tag.calibrationIlluminant[index], count: 1)?.first ?? 0,
                    colorMatrix: colorMatrix, forwardMatrix: forward, reductionMatrix: reduction,
                    // A profile with one map and two lights uses it for both.
                    hueSaturationMap: hueSatMaps[index] ?? hueSatMaps[0]
                ))
            }
            // A profile is for a camera's colors: without the first matrix it's some other file.
            guard !calibrations.isEmpty else { throw Malformed() }

            return DNGCameraProfile(
                name: try string(Tag.profileName) ?? "",
                cameraModel: try string(Tag.uniqueCameraModel) ?? "",
                calibrationSignature: try string(Tag.profileCalibrationSignature) ?? "",
                copyright: try string(Tag.profileCopyright) ?? "",
                embedPolicy: try integers(Tag.profileEmbedPolicy, count: 1)?.first.flatMap(EmbedPolicy.init) ?? .allowCopying,
                calibrations: calibrations,
                lookTable: try table(dims: Tag.profileLookTableDims, data: Tag.profileLookTableData, encoding: Tag.profileLookTableEncoding),
                toneCurve: try toneCurve(),
                baselineExposureOffset: try doubles(Tag.baselineExposureOffset, count: 1)?.first ?? 0,
                defaultBlackRender: try integers(Tag.defaultBlackRender, count: 1)?.first.flatMap(DefaultBlackRender.init) ?? .auto
            )
        }

        // MARK: Values

        /// The tag's values, or nil when the profile doesn't have it. Throws when some of them are past the end of the file.
        private func doubles(_ tag: UInt16, count: Int? = nil) throws -> [Double]? {
            guard let entry = directory[tag] else { return nil }
            let values = file.doubles(entry)
            guard values.count == entry.count, count.map({ $0 == values.count }) ?? true,
                  values.allSatisfy(\.isFinite) else { throw Malformed() }
            return values
        }

        private func integers(_ tag: UInt16, count: Int? = nil) throws -> [Int]? {
            guard let entry = directory[tag] else { return nil }
            let values = file.integers(entry)
            guard values.count == entry.count, count.map({ $0 == values.count }) ?? true else { throw Malformed() }
            return values
        }

        private func string(_ tag: UInt16) throws -> String? {
            guard let entry = directory[tag] else { return nil }
            guard let value = file.string(entry) else { throw Malformed() }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func matrix(_ tag: UInt16) throws -> [Double]? {
            try doubles(tag)
        }

        // MARK: Tables

        /// The two hue/saturation maps, which share their size and encoding.
        private func hueSaturationMaps() throws -> [AdobeProfile.LookTable?] {
            try Tag.profileHueSatMapData.map {
                try table(dims: Tag.profileHueSatMapDims, data: $0, encoding: Tag.profileHueSatMapEncoding)
            }
        }

        /// A hue × saturation × value table of (hue shift, saturation scale, value scale): the data ordered value
        /// slowest, then hue, then saturation. Nil when the profile has no such table.
        private func table(dims: UInt16, data: UInt16, encoding: UInt16) throws -> AdobeProfile.LookTable? {
            guard let dims = try integers(dims) else { return nil }
            // The value axis can be left out, for one division.
            guard dims.count == 2 || dims.count == 3 else { throw Malformed() }
            let hues = dims[0], saturations = dims[1], values = dims.count == 3 ? dims[2] : 1
            let maximum = Self.maximumDivisions
            guard (1...maximum.hue).contains(hues), (2...maximum.saturation).contains(saturations),
                  (1...maximum.value).contains(values) else { throw Malformed() }
            guard let samples = try doubles(data, count: hues * saturations * values * 3) else { return nil }
            let entries = stride(from: 0, to: samples.count, by: 3).map {
                SIMD3(Float(samples[$0]), Float(samples[$0 + 1]), Float(samples[$0 + 2]))
            }
            let encoding = try integers(encoding, count: 1)?.first ?? 0
            guard encoding == 0 || encoding == 1 else { throw Malformed() }
            return AdobeProfile.LookTable(hueDivisions: hues, saturationDivisions: saturations, valueDivisions: values,
                                          valueIsSRGB: encoding == 1, entries: entries)
        }

        private func toneCurve() throws -> [TonePoint]? {
            guard let samples = try doubles(Tag.profileToneCurve) else { return nil }
            guard samples.count >= 4, samples.count.isMultiple(of: 2) else { throw Malformed() }
            let points = stride(from: 0, to: samples.count, by: 2).map {
                TonePoint(input: Float(samples[$0]), output: Float(samples[$0 + 1]))
            }
            guard points.first == TonePoint(input: 0, output: 0), points.last == TonePoint(input: 1, output: 1),
                  points.allSatisfy({ (0...1).contains($0.output) }),
                  zip(points, points.dropFirst()).allSatisfy({ $0.input < $1.input }) else { throw Malformed() }
            return points
        }
    }
}
