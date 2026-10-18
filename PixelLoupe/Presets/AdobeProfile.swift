import CoreGraphics
import Foundation
import simd

/// An Adobe profile (a Lightroom / Camera Raw profile `.xmp`, `crs:PresetType="Look"`): Adobe Color,
/// the B&W, Modern, Vintage and Artistic looks, and the camera-matching profiles.
///
/// Its look is up to two tables, stored in the file as Adobe's DNG "big tables" (zlib-compressed,
/// then base-85 text):
/// - a **look table** (`crs:LookTable`): hue shifts and saturation and value scales over a
///   hue × saturation × value grid of linear ProPhoto RGB, as in the DNG specification's
///   ProfileLookTable;
/// - an **RGB table** (`crs:RGBTable`): a 3-D lookup table in its own color space (usually Adobe RGB),
///   scaled by the profile's amount.
///
/// Some profiles also hold ordinary settings (a B&W mix, a curve) that come with them. PixelLoupe bakes
/// each table into a Core Image color cube; see ``cubes(amount:)``.
nonisolated struct AdobeProfile: Sendable {
    /// `crs:UUID`, which Lightroom's settings refer to (with the name).
    let id: String
    let name: String
    let group: String
    /// The camera model the profile is for (camera-matching profiles), else empty.
    let cameraModel: String
    let isMonochrome: Bool
    /// The RGB table's strength at an amount of 100% (`crs:RGBTableAmount`, else 1).
    let tableAmount: Double
    let rgbTable: RGBTable?
    let lookTable: LookTable?
    /// The settings that come with the profile (its B&W mix and the like), without the tables.
    let settings: LuaTable

    struct RGBTable: Sendable, Equatable {
        /// Samples per axis.
        let divisions: Int
        /// RGB triples, 0…1, red slowest and blue fastest.
        let samples: [Float]
        let colorSpaceName: String
        /// The RGB table's own limits on its amount.
        let amountRange: ClosedRange<Double>
    }

    struct LookTable: Sendable, Equatable {
        let hueDivisions: Int, saturationDivisions: Int, valueDivisions: Int
        /// The value axis is sRGB-encoded (else linear).
        let valueIsSRGB: Bool
        /// (hue shift in degrees, saturation scale, value scale) triples: value slowest, then hue, then
        /// saturation.
        let entries: [SIMD3<Float>]
    }

    // MARK: - Reading

    /// Reads a profile file. `nil` for files that aren't profiles.
    static func load(_ url: URL) -> AdobeProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data, defaultGroup: url.deletingLastPathComponent().lastPathComponent)
    }

    static func parse(_ data: Data, defaultGroup: String = "Profiles") -> AdobeProfile? {
        let attributes = TopAttributes.read(data)
        guard attributes["PresetType"] == "Look", let id = attributes["UUID"], !id.isEmpty else { return nil }
        let text = PresetText.read(data)
        guard let name = text["Name"].flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
        func table(_ key: String) -> Data? {
            attributes[key].flatMap { attributes["Table_" + $0] }.flatMap(BigTable.decode)
        }
        var settings = XMPDevelopSettings.parse(data) ?? LuaTable()
        for key in settings.hash.keys where key.hasPrefix("Table_") || ["RGBTable", "LookTable", "Name", "ShortName", "SortName", "Group", "Description"].contains(key) {
            settings.hash[key] = nil
        }
        return AdobeProfile(
            id: id, name: name,
            group: text["Group"].flatMap { $0.isEmpty || $0 == "Profiles" ? nil : $0 } ?? defaultGroup,
            cameraModel: attributes["CameraModelRestriction"] ?? "",
            isMonochrome: attributes["ConvertToGrayscale"]?.lowercased() == "true",
            tableAmount: attributes["RGBTableAmount"].flatMap(Double.init) ?? 1,
            rgbTable: table("RGBTable").flatMap(RGBTable.parse),
            lookTable: table("LookTable").flatMap(LookTable.parse),
            settings: settings
        )
    }

    /// Whether the profile is for this photo's camera (profiles for no camera in particular always are).
    func suits(cameraModel model: String?) -> Bool {
        cameraModel.isEmpty || model.map { Self.normalized($0) == Self.normalized(cameraModel) } ?? false
    }

    /// Camera names written differently (Lightroom's "Nikon Z 50 2", EXIF's "NIKON Z 50_2"): letters and
    /// digits only, lowercased.
    static func normalized(_ model: String) -> String {
        String(model.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    // MARK: - Rendering

    /// A color cube for Core Image: `dimension`³ RGBA floats, in `colorSpaceName`.
    struct Cube: Sendable {
        let dimension: Int
        let data: Data
        let colorSpaceName: String
    }

    /// The profile's look at `amount` (1 is 100%): the look table first, then the RGB table, as
    /// Camera Raw applies them.
    func cubes(amount: Double) -> [Cube] {
        var cubes: [Cube] = []
        if let lookTable { cubes.append(lookTable.cube(amount: amount)) }
        if let rgbTable { cubes.append(rgbTable.cube(amount: (amount * tableAmount).clamped(to: rgbTable.amountRange))) }
        return cubes
    }
}

// MARK: - DNG big tables

/// Adobe's encoding of large binary tables in XMP (DNG SDK `dng_big_table`): base-85 text of a
/// 4-byte little-endian length followed by zlib data.
nonisolated enum BigTable {
    static let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?`'|()[]{}@%$#".utf8)
    private static let values: [UInt8: UInt32] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, UInt32($0)) })

    static func decode(_ text: String) -> Data? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count * 4 / 5 + 4)
        var value: UInt32 = 0, power: UInt32 = 1, phase = 0
        for character in text.utf8 {
            guard let digit = values[character] else { continue }
            value = value &+ digit &* power
            power = power &* 85
            phase += 1
            if phase == 5 {
                bytes += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)]
                value = 0; power = 1; phase = 0
            }
        }
        if phase > 1 {
            let tail = [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)]
            bytes += tail.prefix(phase - 1)
        }
        guard bytes.count > 6 else { return nil }
        let length = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        // zlib: a 2-byte header, raw deflate, a checksum. Foundation's .zlib is the raw deflate part.
        let deflated = Data(bytes[6...])
        guard let inflated = try? (deflated as NSData).decompressed(using: .zlib) as Data, inflated.count == length else { return nil }
        return inflated
    }

    /// The reverse, for tests and writing profiles.
    static func encode(_ data: Data) -> String {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return "" }
        var bytes: [UInt8] = []
        let length = UInt32(data.count)
        bytes += [UInt8(length & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 24)]
        bytes += [0x78, 0x9C]
        bytes += deflated
        bytes += adler32(data)
        var text: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let chunk = bytes[index..<min(index + 4, bytes.count)]
            var value: UInt32 = 0
            for (offset, byte) in chunk.enumerated() { value |= UInt32(byte) << (8 * UInt32(offset)) }
            for _ in 0..<(chunk.count == 4 ? 5 : chunk.count + 1) {
                text.append(alphabet[Int(value % 85)])
                value /= 85
            }
            index += 4
        }
        return String(decoding: text, as: UTF8.self)
    }

    private static func adler32(_ data: Data) -> [UInt8] {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let value = b << 16 | a
        return [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}

/// Little-endian reads from a decoded table.
private nonisolated struct Reader {
    let data: Data
    var offset = 0

    mutating func uint32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        defer { offset += 4 }
        return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    mutating func uint16() -> UInt16? {
        guard offset + 2 <= data.count else { return nil }
        defer { offset += 2 }
        return data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }

    mutating func float32() -> Float? { uint32().map(Float.init(bitPattern:)) }

    mutating func float64() -> Double? {
        guard offset + 8 <= data.count else { return nil }
        defer { offset += 8 }
        return data.withUnsafeBytes { Double(bitPattern: UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self))) }
    }
}

nonisolated extension AdobeProfile.RGBTable {
    /// DNG SDK `dng_rgb_table`: type 1, version 1, dimensions, divisions, the samples as 16-bit offsets
    /// from the identity, then primaries, gamma, gamut and the amount range.
    static func parse(_ data: Data) -> Self? {
        var reader = Reader(data: data)
        guard reader.uint32() == 1, reader.uint32() == 1, reader.uint32() == 3,
              let divisions = reader.uint32().map(Int.init), (2...64).contains(divisions) else { return nil }
        let count = divisions * divisions * divisions
        var samples = [Float](repeating: 0, count: count * 3)
        func identity(_ index: Int) -> Int { (index * 0xFFFF + (divisions - 1) / 2) / (divisions - 1) }
        var position = 0
        for red in 0..<divisions {
            for green in 0..<divisions {
                for blue in 0..<divisions {
                    for (channel, index) in [red, green, blue].enumerated() {
                        guard let delta = reader.uint16() else { return nil }
                        samples[position * 3 + channel] = Float((Int(delta) + identity(index)) & 0xFFFF) / 65535
                    }
                    position += 1
                }
            }
        }
        let primaries = reader.uint32() ?? 0, gamma = reader.uint32() ?? 1
        _ = reader.uint32()   // gamut: clip or extend; Core Image's cube clips
        let minimum = reader.float64() ?? 0, maximum = reader.float64() ?? 1
        return Self(
            divisions: divisions, samples: samples, colorSpaceName: colorSpaceName(primaries: primaries, gamma: gamma),
            amountRange: min(minimum, maximum)...max(maximum, minimum, 0)
        )
    }

    /// DNG SDK's primaries (sRGB, Adobe RGB, ProPhoto, P3, Rec. 2020) and gammas (linear, sRGB, 1.8, 2.2, Rec. 2020).
    static func colorSpaceName(primaries: UInt32, gamma: UInt32) -> String {
        let name: CFString = switch (primaries, gamma) {
        case (0, 0): CGColorSpace.linearSRGB
        case (1, _): CGColorSpace.adobeRGB1998
        case (2, _): CGColorSpace.rommrgb   // (no profile uses linear ProPhoto)
        case (3, 0): CGColorSpace.linearDisplayP3
        case (3, _): CGColorSpace.displayP3
        case (4, 0): CGColorSpace.linearITUR_2020
        case (4, _): CGColorSpace.itur_2020
        default: CGColorSpace.sRGB
        }
        return name as String
    }

    /// The table at `amount`: the identity moved toward (or past) the table.
    func cube(amount: Double) -> AdobeProfile.Cube {
        let n = divisions
        var values = [Float](repeating: 1, count: n * n * n * 4)
        let k = Float(amount)
        // Core Image's cube runs red fastest; the table runs blue fastest.
        for blue in 0..<n {
            for green in 0..<n {
                for red in 0..<n {
                    let source = ((red * n + green) * n + blue) * 3
                    let target = ((blue * n + green) * n + red) * 4
                    let identity = [Float(red), Float(green), Float(blue)].map { $0 / Float(n - 1) }
                    for channel in 0..<3 {
                        values[target + channel] = identity[channel] + k * (samples[source + channel] - identity[channel])
                    }
                }
            }
        }
        return .init(dimension: n, data: values.withUnsafeBufferPointer { Data(buffer: $0) }, colorSpaceName: colorSpaceName)
    }
}

nonisolated extension AdobeProfile.LookTable {
    /// DNG SDK look table: type, version, hue, saturation and value divisions, encoding, then the entries
    /// (version 2 adds an amount range after them).
    static func parse(_ data: Data) -> Self? {
        var reader = Reader(data: data)
        guard reader.uint32() != nil, let version = reader.uint32(), (1...2).contains(version),
              let hue = reader.uint32().map(Int.init), let saturation = reader.uint32().map(Int.init),
              let value = reader.uint32().map(Int.init), let encoding = reader.uint32(),
              (1...360).contains(hue), (2...256).contains(saturation), (1...256).contains(value) else { return nil }
        var entries: [SIMD3<Float>] = []
        entries.reserveCapacity(hue * saturation * value)
        for _ in 0..<(hue * saturation * value) {
            guard let shift = reader.float32(), let scale = reader.float32(), let valueScale = reader.float32() else { return nil }
            entries.append(.init(shift, scale, valueScale))
        }
        return Self(hueDivisions: hue, saturationDivisions: saturation, valueDivisions: value, valueIsSRGB: encoding == 1, entries: entries)
    }

    /// Applies the table to a linear ProPhoto color (DNG specification, ProfileHueSatMap), at `amount`.
    func apply(_ rgb: SIMD3<Float>, amount: Float) -> SIMD3<Float> {
        var (h, s, v) = Self.hsv(rgb)
        if valueIsSRGB { v = Self.srgbEncode(v) }
        let hScaled = h * Float(hueDivisions) / 6
        let sScaled = s * Float(saturationDivisions - 1)
        let vScaled = valueDivisions > 1 ? min(v, 1) * Float(valueDivisions - 1) : 0
        let h0 = Int(hScaled.rounded(.down)) % hueDivisions, h1 = (h0 + 1) % hueDivisions
        let s0 = min(Int(sScaled.rounded(.down)), saturationDivisions - 2), s1 = s0 + 1
        let v0 = valueDivisions > 1 ? min(Int(vScaled.rounded(.down)), valueDivisions - 2) : 0, v1 = valueDivisions > 1 ? v0 + 1 : 0
        let hf = hScaled - hScaled.rounded(.down), sf = sScaled - Float(s0), vf = valueDivisions > 1 ? vScaled - Float(v0) : 0
        func entry(_ vi: Int, _ hi: Int, _ si: Int) -> SIMD3<Float> { entries[(vi * hueDivisions + hi) * saturationDivisions + si] }
        func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
        let low = mix(mix(entry(v0, h0, s0), entry(v0, h0, s1), sf), mix(entry(v0, h1, s0), entry(v0, h1, s1), sf), hf)
        let high = mix(mix(entry(v1, h0, s0), entry(v1, h0, s1), sf), mix(entry(v1, h1, s0), entry(v1, h1, s1), sf), hf)
        var change = mix(low, high, vf)
        // At less than 100%, toward no change.
        change = SIMD3(change.x * amount, 1 + (change.y - 1) * amount, 1 + (change.z - 1) * amount)
        h += change.x * 6 / 360
        h = h.truncatingRemainder(dividingBy: 6)
        if h < 0 { h += 6 }
        s = min(s * change.y, 1)
        v *= change.z
        if valueIsSRGB { v = Self.srgbDecode(v) }
        return Self.rgb(h: h, s: s, v: v)
    }

    /// The table baked into a cube over ROMM (ProPhoto) RGB, gamma 1.8.
    func cube(amount: Double, dimension n: Int = 32) -> AdobeProfile.Cube {
        var values = [Float](repeating: 1, count: n * n * n * 4)
        let k = Float(amount)
        for blue in 0..<n {
            for green in 0..<n {
                for red in 0..<n {
                    let encoded = SIMD3<Float>(Float(red), Float(green), Float(blue)) / Float(n - 1)
                    let linear = SIMD3(pow(encoded.x, 1.8), pow(encoded.y, 1.8), pow(encoded.z, 1.8))
                    let result = apply(linear, amount: k)
                    let target = ((blue * n + green) * n + red) * 4
                    values[target] = pow(max(result.x, 0), 1 / 1.8)
                    values[target + 1] = pow(max(result.y, 0), 1 / 1.8)
                    values[target + 2] = pow(max(result.z, 0), 1 / 1.8)
                }
            }
        }
        return .init(dimension: n, data: values.withUnsafeBufferPointer { Data(buffer: $0) }, colorSpaceName: CGColorSpace.rommrgb as String)
    }

    /// Hue 0…6, saturation and value as in the DNG SDK.
    static func hsv(_ c: SIMD3<Float>) -> (Float, Float, Float) {
        let maximum = max(c.x, c.y, c.z), minimum = min(c.x, c.y, c.z), delta = maximum - minimum
        guard maximum > 0 else { return (0, 0, 0) }
        let s = delta / maximum
        guard delta > 0 else { return (0, s, maximum) }
        var h: Float
        if c.x == maximum { h = (c.y - c.z) / delta } else if c.y == maximum { h = 2 + (c.z - c.x) / delta } else { h = 4 + (c.x - c.y) / delta }
        if h < 0 { h += 6 }
        return (h, s, maximum)
    }

    static func rgb(h: Float, s: Float, v: Float) -> SIMD3<Float> {
        guard s > 0 else { return SIMD3(repeating: v) }
        let i = Int(h.rounded(.down)) % 6, f = h - h.rounded(.down)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }

    static func srgbEncode(_ x: Float) -> Float { x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055 }
    static func srgbDecode(_ x: Float) -> Float { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
}

// MARK: - XMP text

/// The top-level `crs:` attributes as written (the tables are long base-85 strings that must stay text).
private nonisolated enum TopAttributes {
    static func read(_ data: Data) -> [String: String] {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.values
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        private var done = false
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            guard !done, elementName == "rdf:Description" else { return }
            for (name, value) in attributes where name.hasPrefix("crs:") { values[String(name.dropFirst(4))] = value }
            done = true
        }
    }
}
