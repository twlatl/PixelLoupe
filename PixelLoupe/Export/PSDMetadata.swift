import Foundation

/// Puts XMP metadata into a Photoshop file. ImageIO writes PSD files without the metadata it's given, so exports
/// add it afterwards as Photoshop does: an XMP block (resource 1060, `0x0424`) in the file's Image Resources
/// section, which Photoshop, Lightroom and ImageIO all read (RAW-268).
///
/// A PSD starts with a 26-byte header, then the color mode data and the image resources, each a big-endian
/// 32-bit length followed by that many bytes. Each resource is `8BIM`, a 16-bit ID, a Pascal-string name
/// padded to an even length, a 32-bit size and the data padded to an even length.
nonisolated enum PSDMetadata {
    static let xmpResourceID: UInt16 = 0x0424

    /// `psd` with `xmp` as its XMP block, replacing any it had; nil when `psd` isn't a Photoshop file this can read.
    static func inserting(xmp: Data, into psd: Data) -> Data? {
        let bytes = [UInt8](psd)
        let headerLength = 26
        guard bytes.count >= headerLength + 8, bytes[0..<4] == [0x38, 0x42, 0x50, 0x53] /* 8BPS */ else { return nil }
        let colorModeLength = Int(readUInt32(bytes, at: headerLength))
        let resourcesStart = headerLength + 4 + colorModeLength
        guard resourcesStart + 4 <= bytes.count else { return nil }
        let resourcesLength = Int(readUInt32(bytes, at: resourcesStart))
        let blocksStart = resourcesStart + 4, blocksEnd = blocksStart + resourcesLength
        guard blocksEnd <= bytes.count else { return nil }

        // Keep every resource but an old XMP block.
        var blocks: [UInt8] = []
        var offset = blocksStart
        while offset < blocksEnd {
            guard offset + 6 <= blocksEnd, bytes[offset..<offset + 4] == [0x38, 0x42, 0x49, 0x4D] /* 8BIM */ else { return nil }
            let id = UInt16(bytes[offset + 4]) << 8 | UInt16(bytes[offset + 5])
            let nameLength = Int(bytes[offset + 6])
            var cursor = offset + 6 + nameLength + 1
            if (nameLength + 1) % 2 == 1 { cursor += 1 }
            guard cursor + 4 <= blocksEnd else { return nil }
            let size = Int(readUInt32(bytes, at: cursor))
            let end = cursor + 4 + size + size % 2
            guard end <= blocksEnd else { return nil }
            if id != xmpResourceID { blocks += bytes[offset..<end] }
            offset = end
        }

        blocks += Array("8BIM".utf8)
        blocks += [UInt8(xmpResourceID >> 8), UInt8(xmpResourceID & 0xFF)]
        blocks += [0, 0] // An empty name, padded to an even length.
        blocks += uint32(UInt32(xmp.count))
        blocks += [UInt8](xmp)
        if xmp.count % 2 == 1 { blocks.append(0) }

        var result = [UInt8](bytes[0..<resourcesStart])
        result += uint32(UInt32(blocks.count))
        result += blocks
        result += bytes[blocksEnd...]
        return Data(result)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func uint32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}
