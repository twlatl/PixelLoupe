import Compression
import Foundation

nonisolated enum LightroomXMP {
    /// Decodes the `Adobe_AdditionalMetadata.xmp` blob: a four-byte big-endian uncompressed length,
    /// then a zlib stream (two-byte header, deflate data, Adler-32 trailer).
    static func decode(_ blob: Data) -> String? {
        guard blob.count > 10 else { return nil }
        let bytes = [UInt8](blob)
        let expected = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard expected > 0, expected < 64 << 20 else { return nil }
        // COMPRESSION_ZLIB is raw deflate, so skip the zlib header and trailer.
        let deflate = Array(bytes[6..<(bytes.count - 4)])
        var output = [UInt8](repeating: 0, count: expected)
        let written = output.withUnsafeMutableBufferPointer { out in
            deflate.withUnsafeBufferPointer { input in
                compression_decode_buffer(out.baseAddress!, expected, input.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return String(decoding: output[0..<written], as: UTF8.self)
    }

    /// Encodes text the way Lightroom does; used by tests to build fixtures.
    static func encode(_ text: String) -> Data {
        let input = Array(text.utf8)
        var output = [UInt8](repeating: 0, count: input.count + 1024)
        let written = output.withUnsafeMutableBufferPointer { out in
            input.withUnsafeBufferPointer { source in
                compression_encode_buffer(out.baseAddress!, out.count, source.baseAddress!, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        let length = input.count
        var data = Data([UInt8(length >> 24 & 0xFF), UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
        data.append(contentsOf: [0x78, 0x9C])
        data.append(contentsOf: output[0..<written])
        // The decoder ignores the Adler-32 trailer, so zeros are enough for fixtures.
        data.append(contentsOf: [0, 0, 0, 0])
        return data
    }
}
