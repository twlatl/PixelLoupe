import Foundation
import Testing
@testable import PixelLoupe

/// The bundled libjxl (RAW-116) encodes tiles that Apple's RAW engine reads back as the samples it was given.
@Suite("JPEG XL tile encoder")
struct JXLTileEncoderTests {
    private static let side = 256

    /// A 256 × 256 tile with a different ramp in each channel, linear 16-bit, up to half of white: nearer white the
    /// RAW engine rolls highlights off toward neutral (its highlight recovery), which would hide what the encoder did.
    private static let ramps: [UInt16] = {
        var samples = [UInt16](repeating: 0, count: side * side * 3)
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 3
                samples[i] = UInt16(x * 128)
                samples[i + 1] = UInt16(y * 128)
                samples[i + 2] = UInt16((x + y) * 64)
            }
        }
        return samples
    }()

    /// Decodes `tile` through the RAW engine, as a one-tile DNG, to linear RGB.
    private static func decode(_ tile: Data) throws -> (width: Int, height: Int, pixels: [Float]) {
        let directory = try TemporaryDirectory()
        let url = directory.url.appending(path: "tile.dng")
        try OneTileJXLDNG.data(tile: tile, side: side).write(to: url)
        return try DNGFixtures.decodeLinear(url)
    }

    @Test func aLossyTileDecodesWithinOnePercent() throws {
        let tile = try JXLTileEncoder.encode(Self.ramps, width: Self.side, height: Self.side)
        #expect(tile.count < Self.ramps.count * 2 / 4, "compressed well below the raw samples")

        let decoded = try Self.decode(tile)
        try #require(decoded.width == Self.side && decoded.height == Self.side)
        var expected = SIMD3<Double>(repeating: 0), actual = SIMD3<Double>(repeating: 0)
        for y in 0..<Self.side {
            for x in 0..<Self.side {
                let i = (y * Self.side + x) * 3
                expected += SIMD3(Double(Self.ramps[i]), Double(Self.ramps[i + 1]), Double(Self.ramps[i + 2])) / 65535
                let pixel = DNGFixtures.pixel(decoded, x: x, y: y)
                actual += SIMD3(Double(pixel.x), Double(pixel.y), Double(pixel.z))
            }
        }
        let ratio = actual / expected
        #expect(
            abs(ratio.x - 1) < 0.01 && abs(ratio.y - 1) < 0.01 && abs(ratio.z - 1) < 0.01, "mean per channel: \(ratio)"
        )
    }

    @Test func aLosslessTileDecodesExactly() throws {
        var settings = JXLTileEncoder.Settings()
        settings.distance = 0
        let tile = try JXLTileEncoder.encode(Self.ramps, width: Self.side, height: Self.side, settings: settings)
        let decoded = try Self.decode(tile)
        var largest: Float = 0
        for y in 0..<Self.side {
            for x in 0..<Self.side {
                let i = (y * Self.side + x) * 3
                let pixel = DNGFixtures.pixel(decoded, x: x, y: y)
                let input = SIMD3(Float(Self.ramps[i]), Float(Self.ramps[i + 1]), Float(Self.ramps[i + 2])) / 65535
                let difference = pixel - input
                largest = max(largest, abs(difference.x), abs(difference.y), abs(difference.z))
            }
        }
        #expect(largest < 2 / 65535, "largest difference \(largest)")
    }

    @Test func tilesEncodeOnSeveralThreadsAtOnce() async throws {
        let samples = Self.ramps, side = Self.side
        let reference = try JXLTileEncoder.encode(samples, width: side, height: side)
        let tiles = await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<8 {
                group.addTask { try? JXLTileEncoder.encode(samples, width: side, height: side) }
            }
            var tiles: [Data?] = []
            for await tile in group { tiles.append(tile) }
            return tiles
        }
        #expect(tiles.count == 8 && tiles.allSatisfy { $0 == reference })
    }

    @Test func badInputIsRefused() {
        #expect(throws: JXLTileEncoder.EncodeError.invalidArgument) {
            try JXLTileEncoder.encode([], width: 0, height: 0)
        }
        #expect(throws: JXLTileEncoder.EncodeError.invalidArgument) {
            try JXLTileEncoder.encode([0, 0, 0], width: 2, height: 1)
        }
        var settings = JXLTileEncoder.Settings()
        settings.effort = 0
        #expect(throws: JXLTileEncoder.EncodeError.invalidArgument) {
            try JXLTileEncoder.encode([0, 0, 0], width: 1, height: 1, settings: settings)
        }
    }
}

/// A DNG holding one square LinearRaw tile of JPEG XL (DNG 1.7, compression 52546), with linear Rec. 2020 color and a
/// D65 white, so the RAW engine's linear output is the tile's samples / 65535. Smart Previews will write these for
/// real (RAW-117); this is just enough for the encoder's tests.
private enum OneTileJXLDNG {
    /// Apple's RAW engine doesn't open a DNG smaller than 100 KiB, whatever it holds, so the file is padded to that.
    static let smallestOpenable = 102_400

    static func data(tile: Data, side: Int) -> Data {
        // XYZ (D65) to linear Rec. 2020 (as LinearDNGWriter writes it), and a neutral of 1 1 1.
        let xyzToRec2020 = LinearDNGWriter.xyzToRec2020.flatMap {
            bytes(Int32(($0 * 1_000_000).rounded())) + bytes(Int32(1_000_000))
        }
        let neutral = (0..<3).flatMap { _ in bytes(UInt32(1)) + bytes(UInt32(1)) }
        var entries: [(tag: UInt16, type: UInt16, count: Int, value: Data)] = [
            (254, 4, 1, longs([0])),
            (256, 4, 1, longs([UInt32(side)])),
            (257, 4, 1, longs([UInt32(side)])),
            (258, 3, 3, shorts([16, 16, 16])),
            (259, 3, 1, shorts([52546])),
            (262, 3, 1, shorts([34892])),  // LinearRaw
            (274, 3, 1, shorts([1])),
            (277, 3, 1, shorts([3])),
            (284, 3, 1, shorts([1])),
            (322, 4, 1, longs([UInt32(side)])),
            (323, 4, 1, longs([UInt32(side)])),
            (324, 4, 1, longs([0])),  // fixed up below
            (325, 4, 1, longs([UInt32(tile.count)])),
            (50706, 1, 4, Data([1, 7, 0, 0])),
            (50707, 1, 4, Data([1, 7, 0, 0])),
            (50708, 2, 16, Data("PixelLoupe test\0".utf8)),
            (50717, 4, 1, longs([65535])),
            (50721, 10, 9, Data(xyzToRec2020)),
            (50728, 5, 3, Data(neutral)),
            (50778, 3, 1, shorts([21])),  // D65
        ]
        // Header, directory, then out-of-line values, then the tile.
        let directorySize = 2 + entries.count * 12 + 4
        var extra = Data()
        var offsets: [Int: Int] = [:]
        for (index, entry) in entries.enumerated() where entry.value.count > 4 {
            offsets[index] = 8 + directorySize + extra.count
            extra.append(entry.value)
            if extra.count % 2 == 1 { extra.append(0) }
        }
        let tileOffset = 8 + directorySize + extra.count
        if let index = entries.firstIndex(where: { $0.tag == 324 }) {
            entries[index].value = longs([UInt32(tileOffset)])
        }

        var file = Data([0x49, 0x49, 42, 0]) + longs([8])
        file.append(shorts([UInt16(entries.count)]))
        for (index, entry) in entries.enumerated() {
            file.append(shorts([entry.tag, entry.type]))
            file.append(longs([UInt32(entry.count)]))
            if let offset = offsets[index] {
                file.append(longs([UInt32(offset)]))
            } else {
                file.append(entry.value + Data(count: 4 - entry.value.count))
            }
        }
        file.append(longs([0]))
        file.append(extra)
        file.append(tile)
        file.append(Data(count: max(0, smallestOpenable - file.count)))
        return file
    }

    private static func bytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    private static func shorts(_ values: [UInt16]) -> Data { Data(values.flatMap(bytes)) }
    private static func longs(_ values: [UInt32]) -> Data { Data(values.flatMap(bytes)) }
}
