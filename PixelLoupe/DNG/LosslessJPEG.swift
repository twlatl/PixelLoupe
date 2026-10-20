import Foundation

/// Decodes lossless JPEG (ITU-T T.81 process 14, the "compression 7" DNGs use for their raw image, such as iPhone
/// ProRAW), which Apple's APIs read only inside the RAW engine. Supports any precision up to 16 bits, any number of
/// interleaved components, predictors 1 to 7, a point transform and restart intervals.
///
/// The loops over samples are `while` loops, which an unoptimized (Debug) build runs some 20 times faster than a
/// `for … in` over a range (see ``DNGRawImage``).
nonisolated struct LosslessJPEG {
    let width: Int
    let height: Int
    let components: Int
    let precision: Int
    /// Row by row, each pixel's components together.
    let samples: [UInt16]

    enum DecodeError: Error, Equatable {
        case notLossless
        case unsupported
        case corrupt
    }

    init(_ data: Data) throws {
        var parsed = Header()
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw DecodeError.corrupt }
            var at = 2
            func u16(_ offset: Int) -> Int { Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }
            while at + 4 <= bytes.count {
                guard bytes[at] == 0xFF else { throw DecodeError.corrupt }
                let marker = bytes[at + 1]
                if marker == 0xFF { at += 1; continue }  // fill byte
                let length = u16(at + 2), segment = at + 4, end = at + 2 + length
                guard length >= 2, end <= bytes.count else { throw DecodeError.corrupt }
                switch marker {
                case 0xC3:
                    guard length >= 8 else { throw DecodeError.corrupt }
                    parsed.precision = Int(bytes[segment])
                    parsed.height = u16(segment + 1)
                    parsed.width = u16(segment + 3)
                    parsed.components = Int(bytes[segment + 5])
                    guard (2...16).contains(parsed.precision), parsed.width > 0, parsed.height > 0,
                          (1...4).contains(parsed.components), length >= 8 + parsed.components * 3 else { throw DecodeError.corrupt }
                    for c in 0..<parsed.components {
                        // Only 1 × 1 sampling: DNG writes each component at full resolution.
                        guard bytes[segment + 7 + c * 3] == 0x11 else { throw DecodeError.unsupported }
                    }
                case 0xC0, 0xC1, 0xC2, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
                    throw DecodeError.notLossless
                case 0xC4:
                    var table = segment
                    while table < end {
                        let id = Int(bytes[table] & 0x0F)
                        guard id < 4, table + 17 <= end else { throw DecodeError.corrupt }
                        let counts = (0..<16).map { bytes[table + 1 + $0] }
                        let total = counts.reduce(0) { $0 + Int($1) }
                        guard table + 17 + total <= end else { throw DecodeError.corrupt }
                        parsed.tables[id] = try Huffman(counts: counts, symbols: (0..<total).map { bytes[table + 17 + $0] })
                        table += 17 + total
                    }
                case 0xDD:
                    parsed.restartInterval = u16(segment)
                case 0xDA:
                    let count = Int(bytes[segment])
                    guard count == parsed.components, length >= 6 + count * 2 else { throw DecodeError.unsupported }
                    parsed.componentTables = (0..<count).map { Int(bytes[segment + 2 + $0 * 2] >> 4) }
                    parsed.predictor = Int(bytes[segment + 1 + count * 2])
                    parsed.pointTransform = Int(bytes[segment + 3 + count * 2] & 0x0F)
                    guard (1...7).contains(parsed.predictor), parsed.componentTables.allSatisfy({ parsed.tables[$0] != nil })
                    else { throw DecodeError.unsupported }
                    parsed.scanStart = end
                    return
                default:
                    break
                }
                at = end
            }
            throw DecodeError.corrupt
        }
        width = parsed.width
        height = parsed.height
        components = parsed.components
        precision = parsed.precision
        samples = try data.withUnsafeBytes { try Self.decodeScan($0, parsed) }
    }

    private struct Header {
        var width = 0, height = 0, components = 0, precision = 0
        var tables = [Huffman?](repeating: nil, count: 4)
        var componentTables: [Int] = []
        var predictor = 1, pointTransform = 0, restartInterval = 0
        var scanStart = 0
    }

    /// A Huffman table as a lookup on the next 16 bits: (code length << 8) | symbol, 0 for no code.
    private struct Huffman {
        var lookup = [UInt16](repeating: 0, count: 65536)

        init(counts: [UInt8], symbols: [UInt8]) throws {
            var code = 0, index = 0
            for length in 1...16 {
                for _ in 0..<Int(counts[length - 1]) {
                    let shift = 16 - length
                    let first = code << shift, last = first | ((1 << shift) - 1)
                    guard last < 65536, symbols[index] <= 16 else { throw DecodeError.corrupt }
                    let entry = UInt16(length) << 8 | UInt16(symbols[index])
                    for slot in first...last { lookup[slot] = entry }
                    code += 1
                    index += 1
                }
                code <<= 1
            }
        }
    }

    /// The entropy-coded bits, with stuffed zero bytes removed; reads zeros at a marker.
    private struct Bits {
        let bytes: UnsafeRawBufferPointer
        var position: Int
        var buffer: UInt64 = 0
        var count = 0
        var atMarker = false

        mutating func fill() {
            while count <= 56 {
                var byte: UInt8 = 0
                if !atMarker, position < bytes.count {
                    byte = bytes[position]
                    if byte == 0xFF {
                        let next: UInt8 = position + 1 < bytes.count ? bytes[position + 1] : 0
                        if next == 0 { position += 2 } else { atMarker = true; byte = 0 }
                    } else {
                        position += 1
                    }
                }
                buffer |= UInt64(byte) << UInt64(56 - count)
                count += 8
            }
        }

        mutating func peek16() -> Int {
            if count < 16 { fill() }
            return Int(buffer >> 48)
        }

        mutating func skip(_ n: Int) {
            buffer <<= UInt64(n)
            count -= n
        }

        mutating func read(_ n: Int) -> Int {
            guard n > 0 else { return 0 }
            if count < n { fill() }
            let value = Int(buffer >> UInt64(64 - n))
            skip(n)
            return value
        }

        /// Skips to just after the restart marker that ends an interval, and starts reading afresh.
        mutating func restart() throws {
            var at = position
            while at + 1 < bytes.count, !(bytes[at] == 0xFF && (0xD0...0xD7).contains(bytes[at + 1])) { at += 1 }
            guard at + 1 < bytes.count else { throw DecodeError.corrupt }
            position = at + 2
            buffer = 0
            count = 0
            atMarker = false
        }
    }

    private static func decodeScan(_ bytes: UnsafeRawBufferPointer, _ header: Header) throws -> [UInt16] {
        let width = header.width, height = header.height, components = header.components
        let rowLength = width * components, predictor = header.predictor
        let initial = 1 << (header.precision - header.pointTransform - 1)
        // The components' tables one after another, so that each sample takes one lookup.
        let lookup = header.componentTables.reduce(into: [UInt16]()) { $0 += header.tables[$1]!.lookup }
        let interval = header.restartInterval
        // In lossless mode a restart interval is a whole number of rows, and the row after one starts afresh.
        guard interval == 0 || interval % width == 0 else { throw DecodeError.unsupported }
        var output = [UInt16](repeating: 0, count: rowLength * height)
        try lookup.withUnsafeBufferPointer { lookup in
            try output.withUnsafeMutableBufferPointer { out in
                var bits = Bits(bytes: bytes, position: header.scanStart)
                var firstRow = 0
                for y in 0..<height {
                    if interval > 0, y > 0, (y * width) % interval == 0 {
                        try bits.restart()
                        firstRow = y
                    }
                    var x = 0
                    while x < width {
                        var c = 0
                        while c < components {
                            let entry = lookup[c << 16 | bits.peek16()]
                            guard entry != 0 else { throw DecodeError.corrupt }
                            bits.skip(Int(entry >> 8))
                            let size = Int(entry & 0xFF)
                            var difference = 0
                            if size == 16 {
                                difference = 32768
                            } else if size > 0 {
                                let value = bits.read(size)
                                difference = value < (1 << (size - 1)) ? value - (1 << size) + 1 : value
                            }
                            let i = y * rowLength + x * components + c
                            let prediction: Int
                            if y == firstRow && x == 0 {
                                prediction = initial
                            } else if y == firstRow {
                                prediction = Int(out[i - components])
                            } else if x == 0 {
                                prediction = Int(out[i - rowLength])
                            } else {
                                let a = Int(out[i - components]), b = Int(out[i - rowLength])
                                let ab = Int(out[i - rowLength - components])
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
                            out[i] = UInt16(truncatingIfNeeded: prediction + difference)
                            c += 1
                        }
                        x += 1
                    }
                }
                if header.pointTransform > 0 {
                    var i = 0
                    while i < out.count {
                        out[i] <<= UInt16(header.pointTransform)
                        i += 1
                    }
                }
            }
        }
        return output
    }
}
