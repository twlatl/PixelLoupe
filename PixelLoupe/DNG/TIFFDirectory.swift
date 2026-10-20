import Foundation

/// One TIFF image file directory being built, little-endian: the IFDs of the DNGs PixelLoupe writes (Photo Merge's
/// Linear DNGs and Smart Previews).
nonisolated struct TIFFDirectory {
    private struct Entry {
        var tag: UInt16
        var type: UInt16
        var count: UInt32
        var value: Data
    }

    private var entries: [Entry] = []
    /// Tile offsets relative to the start of the pixel data, fixed up when the file is laid out.
    private var tileOffsets: [UInt32]?

    mutating func add(_ tag: UInt16, byte values: [UInt8]) {
        entries.append(Entry(tag: tag, type: 1, count: UInt32(values.count), value: Data(values)))
    }

    mutating func add(_ tag: UInt16, undefined values: [UInt8]) {
        entries.append(Entry(tag: tag, type: 7, count: UInt32(values.count), value: Data(values)))
    }

    mutating func add(_ tag: UInt16, ascii: String) {
        var value = Data(ascii.utf8)
        value.append(0)
        entries.append(Entry(tag: tag, type: 2, count: UInt32(value.count), value: value))
    }

    mutating func add(_ tag: UInt16, short values: [UInt16]) {
        entries.append(Entry(tag: tag, type: 3, count: UInt32(values.count), value: Self.bytes(values)))
    }

    mutating func add(_ tag: UInt16, long values: [UInt32]) {
        entries.append(Entry(tag: tag, type: 4, count: UInt32(values.count), value: Self.bytes(values)))
    }

    mutating func add(_ tag: UInt16, rational values: [Double]) {
        let parts = values.flatMap { value -> [UInt32] in
            let value = max(0, value)
            // Exposure times read best as 1/n.
            if value > 0, value < 1, abs(1 / value - (1 / value).rounded()) < 0.001 {
                return [1, UInt32((1 / value).rounded())]
            }
            return [UInt32(clamping: Int((value * 10_000).rounded())), 10_000]
        }
        entries.append(Entry(tag: tag, type: 5, count: UInt32(values.count), value: Self.bytes(parts)))
    }

    mutating func add(_ tag: UInt16, float values: [Float]) {
        entries.append(Entry(tag: tag, type: 11, count: UInt32(values.count), value: Self.bytes(values.map(\.bitPattern))))
    }

    mutating func add(_ tag: UInt16, srational values: [Double]) {
        let parts = values.flatMap { [Int32(clamping: Int(($0 * 1_000_000).rounded())), Int32(1_000_000)] }
        entries.append(Entry(tag: tag, type: 10, count: UInt32(values.count), value: Self.bytes(parts)))
    }

    mutating func addTiles(offsets: [UInt32], counts: [UInt32]) {
        tileOffsets = offsets
        add(324, long: offsets)
        add(325, long: counts)
    }

    private static func bytes<T: FixedWidthInteger>(_ values: [T]) -> Data {
        var data = Data(capacity: values.count * MemoryLayout<T>.size)
        for value in values { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    /// The directory and its out-of-line values, laid out at `offset`. `pixelsAt` is where the pixel
    /// data will start (for tile offsets); `exifAt` is the EXIF directory's offset, if any.
    private func encoded(at offset: Int, pixelsAt: Int, exifAt: Int?) -> Data {
        var entries = entries
        if let exifAt {
            entries.append(Entry(tag: 34665, type: 4, count: 1, value: Self.bytes([UInt32(exifAt)])))
        }
        if let tileOffsets, let index = entries.firstIndex(where: { $0.tag == 324 }) {
            entries[index].value = Self.bytes(tileOffsets.map { $0 + UInt32(pixelsAt) })
        }
        entries.sort { $0.tag < $1.tag }

        let directorySize = 2 + entries.count * 12 + 4
        var directory = Self.bytes([UInt16(entries.count)])
        var extra = Data()
        for entry in entries {
            directory.append(Self.bytes([entry.tag, entry.type]))
            directory.append(Self.bytes([entry.count]))
            if entry.value.count <= 4 {
                var value = entry.value
                value.append(Data(count: 4 - value.count))
                directory.append(value)
            } else {
                if extra.count % 2 == 1 { extra.append(0) }
                directory.append(Self.bytes([UInt32(offset + directorySize + extra.count)]))
                extra.append(entry.value)
            }
        }
        directory.append(Self.bytes([UInt32(0)]))
        if extra.count % 2 == 1 { extra.append(0) }
        return directory + extra
    }

    /// The start of a TIFF file: header, IFD0 (with a pointer to the EXIF directory), the EXIF
    /// directory and padding to a 4-byte boundary. The pixel data follows.
    static func prefix(ifd: TIFFDirectory, exif: TIFFDirectory) -> Data {
        let header = Data([0x49, 0x49, 42, 0]) + bytes([UInt32(8)])
        // Lay out once with placeholder offsets to learn the sizes (they don't depend on the values).
        let ifdLength = ifd.encoded(at: 8, pixelsAt: 0, exifAt: 0).count
        let exifOffset = 8 + ifdLength
        let exifLength = exif.encoded(at: exifOffset, pixelsAt: 0, exifAt: nil).count
        var pixelsOffset = exifOffset + exifLength
        let padding = (4 - pixelsOffset % 4) % 4
        pixelsOffset += padding

        var file = header
        file.append(ifd.encoded(at: 8, pixelsAt: pixelsOffset, exifAt: exifOffset))
        file.append(exif.encoded(at: exifOffset, pixelsAt: 0, exifAt: nil))
        file.append(Data(count: padding))
        return file
    }
}

extension String {
    /// The string, or nil when it's empty.
    nonisolated var nonEmpty: String? { isEmpty ? nil : self }
}
