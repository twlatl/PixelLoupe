import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

/// Smart Previews of DNGs from other apps that are already demosaiced, such as iPhone ProRAW (RAW-118): a downsized
/// copy of the original that keeps its own tags.
@Suite("Smart Preview copies of LinearRaw DNGs")
struct SmartPreviewCopyTests {
    @Test(arguments: 1...7)
    func losslessJPEGRoundTrips(predictor: Int) throws {
        for (components, precision, restartRows) in [(3, 12, 0), (1, 16, 0), (3, 16, 4)] {
            let width = 40, height = 24
            var generator = SystemRandomNumberGenerator()
            let samples = (0..<(width * height * components)).map { i -> UInt16 in
                // Smooth with some noise, and some extremes, so every difference size shows up.
                let smooth = (i / components) % width * (1 << (precision - 6))
                return UInt16(min((1 << precision) - 1, smooth + Int.random(in: 0...(1 << (precision - 3)), using: &generator)))
            }
            let encoded = LosslessJPEGEncoder.encode(
                samples, width: width, height: height, components: components, precision: precision,
                predictor: predictor, restartRows: restartRows
            )
            let decoded = try LosslessJPEG(encoded)
            #expect(decoded.width == width && decoded.height == height && decoded.components == components)
            #expect(decoded.samples == samples, "\(components) components, \(precision) bits, restarts every \(restartRows) rows")
        }
    }

    @Test func aLinearRawDNGFromAnotherAppBecomesADownsizedCopy() throws {
        let directory = try TemporaryDirectory()
        let original = directory.url.appending(path: "IMG_0001.DNG")
        try ProRAWLikeDNG.data(width: 2700, height: 400).write(to: original)
        #expect(SmartPreviewWriter.recipe(for: original) == .dngCopy)

        let proxy = directory.url.appending(path: "proxy.dng")
        let info = try SmartPreviewWriter.write(original: original, to: proxy)
        #expect(info.kind == .dngCopy && info.originalWidth == 2700 && info.originalHeight == 400)
        #expect(abs(info.scale - 2560.0 / 2700) < 0.001)
        #expect(SmartPreviewInfo.read(from: proxy) == info)
        let size = try #require(try proxy.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(size >= SmartPreviewWriter.smallestOpenableDNG)

        // The original's layout and tags, in its byte order.
        let source = try #require(TIFFFile(contentsOf: original)), copy = try #require(TIFFFile(contentsOf: proxy))
        #expect(copy.isBigEndian, "written in the original's byte order")
        #expect(copy.ifd0[254].map(copy.integers) == [1], "IFD0 is a preview")
        for tag: UInt16 in [50721, 50728, 50730, 50940, 271, 272] {
            #expect(copy.ifd0[tag].flatMap(copy.bytes) == source.ifd0[tag].flatMap(source.bytes), "tag \(tag) copied as it is")
        }
        let raw = try #require(copy.subDirectories(of: copy.ifd0).first)
        #expect(raw[259].map(copy.integers) == [52546] && raw[256].map(copy.integers) == [2560], "JPEG XL tiles, 2560 wide")
        #expect(raw[50712] == nil, "the data is linearized")
        #expect(raw[51110].map(copy.integers) == [1], "raw-image tags come along")
        let exif = try #require(copy.exif(of: copy.ifd0))
        #expect(exif[33434] != nil && exif[37500] == nil, "EXIF without the maker's note")

        // It renders like the original at the same size, with the same white balance.
        let expected = try DNGFixtures.decodeLinear(original, scale: Float(info.scale))
        let decoded = try DNGFixtures.decodeLinear(proxy)
        // The RAW engine and the downsizing can round a scaled size differently, by a pixel.
        try #require(abs(decoded.width - expected.width) <= 1 && abs(decoded.height - expected.height) <= 1,
                     "\(decoded.width) × \(decoded.height) against \(expected.width) × \(expected.height)")
        for (fx, fy) in [(0.02, 0.05), (0.5, 0.5), (0.98, 0.95), (0.25, 0.8), (0.75, 0.2)] {
            func at(_ image: (width: Int, height: Int, pixels: [Float])) -> SIMD3<Float> {
                DNGFixtures.pixel(image, x: Int(fx * Double(image.width - 1)), y: Int(fy * Double(image.height - 1)))
            }
            let difference = at(decoded) - at(expected)
            #expect(max(abs(difference.x), abs(difference.y), abs(difference.z)) < 0.01, "(\(fx), \(fy)) off by \(difference)")
        }
        let originalFilter = try #require(CIRAWFilter(imageURL: original)), proxyFilter = try #require(CIRAWFilter(imageURL: proxy))
        #expect(abs(proxyFilter.neutralTemperature - originalFilter.neutralTemperature) < 25)
    }

    @Test func originalsWithOpcodeListsGetNone() throws {
        let directory = try TemporaryDirectory()
        let original = directory.url.appending(path: "IMG_0002.DNG")
        let builder = TIFFBuilder(isBigEndian: true)
        let opcodes = builder.entry(51022, byte: [0, 0, 0, 0])  // an (empty) OpcodeList3
        try ProRAWLikeDNG.data(width: 600, height: 400, extraRawTags: [opcodes]).write(to: original)
        #expect(throws: SmartPreviewWriter.WriteError.unsupported) {
            try SmartPreviewWriter.write(original: original, to: directory.url.appending(path: "proxy.dng"))
        }
    }

    /// A real iPhone ProRAW file, when `PIXELLOUPE_PRORAW_SAMPLE` names one: the copy renders like the original. The
    /// RAW-85 ProRAW spike measured mean ΔE00 1.9 at As Shot with JPEG XL tiles.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PIXELLOUPE_PRORAW_SAMPLE"] != nil))
    func aProRAWSampleRendersLikeItsOriginal() throws {
        let original = URL(filePath: try #require(ProcessInfo.processInfo.environment["PIXELLOUPE_PRORAW_SAMPLE"]))
        let directory = try TemporaryDirectory()
        let proxy = directory.url.appending(path: "proxy.dng")
        let info = try SmartPreviewWriter.write(original: original, to: proxy)
        #expect(info.kind == .dngCopy)

        let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
        func render(_ url: URL, scale: Float) throws -> [Float] {
            let filter = try #require(CIRAWFilter(imageURL: url))
            filter.scaleFactor = scale
            if filter.isSharpnessSupported { filter.sharpnessAmount = 0 }
            if filter.isDetailSupported { filter.detailAmount = 0 }
            let image = try #require(filter.outputImage)
            let extent = image.extent.integral
            var pixels = [Float](repeating: 0, count: Int(extent.width) * Int(extent.height) * 4)
            CIContext().render(image, toBitmap: &pixels, rowBytes: Int(extent.width) * 16, bounds: extent, format: .RGBAf, colorSpace: displayP3)
            return pixels
        }
        let expected = try render(original, scale: Float(info.scale)), actual = try render(proxy, scale: 1)
        try #require(expected.count == actual.count)
        var total = 0.0, count = 0
        for index in stride(from: 0, to: expected.count, by: 4 * 7) {
            func lab(_ p: [Float]) -> ColorDifference.Lab {
                ColorDifference.lab(displayP3: Double(min(max(p[index], 0), 1)), Double(min(max(p[index + 1], 0), 1)), Double(min(max(p[index + 2], 0), 1)))
            }
            total += ColorDifference.deltaE2000(lab(expected), lab(actual))
            count += 1
        }
        let mean = total / Double(count)
        print("ProRAW Smart Preview at As Shot: mean ΔE00 \(mean)")
        #expect(mean < 3, "mean ΔE00 \(mean)")
    }
}

/// A DNG laid out like iPhone ProRAW, big-endian: IFD0 holds a preview, the color profile (Rec. 2020 primaries, so
/// the RAW engine's output is easy to predict) and a tone curve, with EXIF and a maker's note; a SubIFD holds the raw
/// image, `LinearRaw`, as 12-bit lossless JPEG tiles behind a linearization table.
enum ProRAWLikeDNG {
    static func data(width: Int, height: Int, extraRawTags: [TIFFBuilder.Entry] = []) -> Data {
        let builder = TIFFBuilder(isBigEndian: true)
        // Ramps below half of white, out of the RAW engine's highlight roll-off.
        func value(_ x: Int, _ y: Int) -> SIMD3<Double> {
            SIMD3(0.05 + 0.4 * Double(x) / Double(width - 1), 0.05 + 0.4 * Double(y) / Double(height - 1), 0.2)
        }
        let tile = 256, across = (width + tile - 1) / tile, down = (height + tile - 1) / tile
        var tiles: [Data] = []
        for ty in 0..<down {
            for tx in 0..<across {
                var samples = [UInt16](repeating: 0, count: tile * tile * 3)
                for row in 0..<tile {
                    for column in 0..<tile {
                        let rgb = value(min(tx * tile + column, width - 1), min(ty * tile + row, height - 1))
                        for c in 0..<3 { samples[(row * tile + column) * 3 + c] = UInt16((rgb[c] * 4095).rounded()) }
                    }
                }
                tiles.append(LosslessJPEGEncoder.encode(samples, width: tile, height: tile, components: 3, precision: 12, predictor: 7))
            }
        }
        var raw = TIFFBuilder.Directory()
        raw.blocks = tiles
        for entry in [
            builder.entry(254, long: [0]), builder.entry(256, long: [UInt32(width)]), builder.entry(257, long: [UInt32(height)]),
            builder.entry(258, short: [12, 12, 12]), builder.entry(259, short: [7]), builder.entry(262, short: [34892]),
            builder.entry(277, short: [3]), builder.entry(284, short: [1]),
            builder.entry(322, long: [UInt32(tile)]), builder.entry(323, long: [UInt32(tile)]),
            builder.entry(50712, short: (0..<4096).map { UInt16($0 * 65535 / 4095) }),
            builder.entry(50714, short: [0]), builder.entry(50717, long: [65535]), builder.entry(51110, long: [1]),
        ] + extraRawTags { raw.set(entry) }

        var ifd0 = TIFFBuilder.Directory()
        ifd0.blocks = [Data(repeating: 128, count: 16 * 4 * 3)]
        ifd0.blocksAreTiles = false
        for entry in [
            builder.entry(254, long: [1]), builder.entry(256, long: [16]), builder.entry(257, long: [4]),
            builder.entry(258, short: [8, 8, 8]), builder.entry(259, short: [1]), builder.entry(262, short: [2]),
            builder.entry(271, ascii: "Apple"), builder.entry(272, ascii: "Test Phone"), builder.entry(274, short: [1]),
            builder.entry(277, short: [3]), builder.entry(278, long: [4]), builder.entry(284, short: [1]),
            builder.entry(305, ascii: "Another App"),
            builder.entry(50706, byte: [1, 6, 0, 0]), builder.entry(50707, byte: [1, 4, 0, 0]),
            builder.entry(50708, ascii: "Apple Test Phone"), builder.entry(50721, srational: LinearDNGWriter.xyzToRec2020),
            builder.entry(50728, rational: [1, 1, 1]), builder.entry(50730, srational: [0]), builder.entry(50778, short: [21]),
            // A gentle S-curve, so the copy has to bring it along to render the same.
            builder.entry(50940, float: [0, 0, 0.25, 0.22, 0.5, 0.5, 0.75, 0.78, 1, 1]),
        ] { ifd0.set(entry) }
        var exif = TIFFBuilder.Directory()
        exif.set(builder.entry(33434, rational: [1.0 / 125]))
        exif.set(TIFFBuilder.Entry(tag: 37500, type: 7, count: 9, value: Data("Apple iOS".utf8)))
        ifd0.exif = exif
        ifd0.subDirectories = [raw]
        var data = builder.data(ifd0: ifd0)
        // The RAW engine doesn't open DNGs under 100 KiB.
        if data.count < 102_400 { data.append(Data(count: 102_400 - data.count)) }
        return data
    }
}

/// A test-only lossless JPEG encoder (ITU-T T.81 process 14), with one Huffman table for every component: categories
/// 0–14 take four bits and 15–16 five.
enum LosslessJPEGEncoder {
    static func encode(
        _ samples: [UInt16], width: Int, height: Int, components: Int, precision: Int, predictor: Int, restartRows: Int = 0
    ) -> Data {
        func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
        var out: [UInt8] = [0xFF, 0xD8]
        var frame: [UInt8] = [UInt8(precision)] + u16(height) + u16(width) + [UInt8(components)]
        for c in 0..<components { frame += [UInt8(c), 0x11, 0] }
        out += [0xFF, 0xC3] + u16(frame.count + 2) + frame
        var counts = [UInt8](repeating: 0, count: 16)
        counts[3] = 15
        counts[4] = 2
        let table: [UInt8] = [0] + counts + (0...16).map { UInt8($0) }
        out += [0xFF, 0xC4] + u16(table.count + 2) + table
        if restartRows > 0 { out += [0xFF, 0xDD, 0, 4] + u16(restartRows * width) }
        var scan: [UInt8] = [UInt8(components)]
        for c in 0..<components { scan += [UInt8(c), 0] }
        scan += [UInt8(predictor), 0, 0]
        out += [0xFF, 0xDA] + u16(scan.count + 2) + scan

        var buffer = 0, filled = 0
        func put(_ value: Int, _ length: Int) {
            for bit in stride(from: length - 1, through: 0, by: -1) {
                buffer = buffer << 1 | (value >> bit & 1)
                filled += 1
                if filled == 8 {
                    out.append(UInt8(buffer))
                    if buffer == 0xFF { out.append(0) }
                    buffer = 0
                    filled = 0
                }
            }
        }
        func flush() {
            if filled > 0 { put((1 << (8 - filled)) - 1, 8 - filled) }
        }
        var firstRow = 0, restarts = 0
        for y in 0..<height {
            if restartRows > 0, y > 0, y % restartRows == 0 {
                flush()
                out += [0xFF, UInt8(0xD0 + restarts % 8)]
                restarts += 1
                firstRow = y
            }
            for x in 0..<width {
                for c in 0..<components {
                    let i = (y * width + x) * components + c
                    let prediction: Int
                    if y == firstRow && x == 0 {
                        prediction = 1 << (precision - 1)
                    } else if y == firstRow {
                        prediction = Int(samples[i - components])
                    } else if x == 0 {
                        prediction = Int(samples[i - width * components])
                    } else {
                        let a = Int(samples[i - components]), b = Int(samples[i - width * components])
                        let ab = Int(samples[i - width * components - components])
                        switch predictor {
                        case 1: prediction = a
                        case 2: prediction = b
                        case 3: prediction = ab
                        case 4: prediction = a + b - ab
                        case 5: prediction = a + ((b - ab) >> 1)
                        case 6: prediction = b + ((a - ab) >> 1)
                        default: prediction = (a + b) >> 1
                        }
                    }
                    var difference = (Int(samples[i]) - prediction) & 0xFFFF
                    if difference >= 32768 { difference -= 65536 }
                    if difference == -32768 {
                        put(0b11111, 5)
                        continue
                    }
                    let magnitude = abs(difference)
                    let category = magnitude == 0 ? 0 : Int.bitWidth - magnitude.leadingZeroBitCount
                    if category < 15 { put(category, 4) } else { put(0b11110, 5) }
                    if category > 0 { put(difference >= 0 ? difference : difference + (1 << category) - 1, category) }
                }
            }
        }
        flush()
        out += [0xFF, 0xD9]
        return Data(out)
    }
}
