import Foundation

/// Builds a TIFF or DNG file with sub-directories (`SubIFDs`), an EXIF directory and image data, in either byte
/// order. Smart Preview copies of DNGs use it: written in the original's byte order, every tag can be copied byte for
/// byte, including blobs such as `ProfileGainTableMap` whose layout follows the file's.
nonisolated struct TIFFBuilder {
    let isBigEndian: Bool

    /// One entry, its value already in the file's byte order.
    struct Entry {
        var tag: UInt16
        var type: UInt16
        var count: Int
        var value: Data
    }

    /// One image file directory, with the image data it points to and the directories under it.
    struct Directory {
        var entries: [UInt16: Entry] = [:]
        /// Strips or tiles, in order. The builder writes their offsets and byte counts.
        var blocks: [Data] = []
        /// Tiles (`TileOffsets`/`TileByteCounts`) or strips (`StripOffsets`/`StripByteCounts`).
        var blocksAreTiles = true
        var subDirectories: [Directory] = []
        /// The EXIF directory (kept in an array: a struct can't hold an optional of itself).
        private var exifDirectory: [Directory] = []
        var exif: Directory? {
            get { exifDirectory.first }
            set { exifDirectory = newValue.map { [$0] } ?? [] }
        }

        mutating func set(_ entry: Entry) { entries[entry.tag] = entry }
        mutating func remove(_ tag: UInt16) { entries[tag] = nil }
    }

    // MARK: - Values

    func entry(_ tag: UInt16, byte values: [UInt8]) -> Entry { Entry(tag: tag, type: 1, count: values.count, value: Data(values)) }

    func entry(_ tag: UInt16, ascii: String) -> Entry {
        let bytes = Array(ascii.utf8) + [0]
        return Entry(tag: tag, type: 2, count: bytes.count, value: Data(bytes))
    }

    func entry(_ tag: UInt16, short values: [UInt16]) -> Entry {
        Entry(tag: tag, type: 3, count: values.count, value: encode(values))
    }

    func entry(_ tag: UInt16, long values: [UInt32]) -> Entry {
        Entry(tag: tag, type: 4, count: values.count, value: encode(values))
    }

    func entry(_ tag: UInt16, rational values: [Double]) -> Entry {
        let parts = values.flatMap { value -> [UInt32] in [UInt32(clamping: Int((max(0, value) * 10_000).rounded())), 10_000] }
        return Entry(tag: tag, type: 5, count: values.count, value: encode(parts))
    }

    func entry(_ tag: UInt16, srational values: [Double]) -> Entry {
        let parts = values.flatMap { [Int32(clamping: Int(($0 * 1_000_000).rounded())), Int32(1_000_000)] }
        return Entry(tag: tag, type: 10, count: values.count, value: encode(parts))
    }

    func entry(_ tag: UInt16, float values: [Float]) -> Entry {
        Entry(tag: tag, type: 11, count: values.count, value: encode(values.map(\.bitPattern)))
    }

    func encode<T: FixedWidthInteger>(_ values: [T]) -> Data {
        var data = Data(capacity: values.count * MemoryLayout<T>.size)
        for value in values {
            withUnsafeBytes(of: isBigEndian ? value.bigEndian : value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    // MARK: - Layout

    /// The whole file, IFD0 first.
    func data(ifd0: Directory) -> Data {
        // Every directory, parents before children, and where each one's children are in the list.
        var flat: [Directory] = []
        var children: [[Int]] = []
        var exifIndex: [Int?] = []
        func visit(_ directory: Directory) -> Int {
            let index = flat.count
            flat.append(directory)
            children.append([])
            exifIndex.append(nil)
            let subDirectories = directory.subDirectories.map(visit)
            let exif = directory.exif.map(visit)
            children[index] = subDirectories
            exifIndex[index] = exif
            return index
        }
        _ = visit(ifd0)

        // The entries each directory will have, with the pointers as placeholders of the right size.
        let prepared = flat.indices.map { index -> [Entry] in
            var entries = flat[index].entries
            let directory = flat[index]
            if !directory.blocks.isEmpty {
                let count = directory.blocks.count
                let offsets: UInt16 = directory.blocksAreTiles ? 324 : 273, counts: UInt16 = directory.blocksAreTiles ? 325 : 279
                entries[offsets] = Entry(tag: offsets, type: 4, count: count, value: Data(count: count * 4))
                entries[counts] = entry(counts, long: directory.blocks.map { UInt32($0.count) })
            }
            if !children[index].isEmpty {
                entries[330] = Entry(tag: 330, type: 4, count: children[index].count, value: Data(count: children[index].count * 4))
            }
            if exifIndex[index] != nil { entries[34665] = Entry(tag: 34665, type: 4, count: 1, value: Data(count: 4)) }
            return entries.values.sorted { $0.tag < $1.tag }
        }
        func size(of entries: [Entry]) -> Int {
            2 + entries.count * 12 + 4 + entries.reduce(0) { $0 + ($1.value.count > 4 ? $1.value.count + $1.value.count % 2 : 0) }
        }
        var directoryOffsets: [Int] = []
        var at = 8
        for entries in prepared {
            directoryOffsets.append(at)
            at += size(of: entries)
            at += (4 - at % 4) % 4
        }
        var blockOffsets: [[Int]] = []
        for directory in flat {
            blockOffsets.append(directory.blocks.map { block in
                defer { at += block.count + block.count % 2 }
                return at
            })
        }

        var file = Data(isBigEndian ? [0x4D, 0x4D, 0, 42] : [0x49, 0x49, 42, 0])
        file.append(encode([UInt32(8)]))
        for (index, entries) in prepared.enumerated() {
            var entries = entries
            for i in entries.indices {
                switch entries[i].tag {
                case 324, 273:
                    if !flat[index].blocks.isEmpty { entries[i].value = encode(blockOffsets[index].map { UInt32($0) }) }
                case 330:
                    entries[i].value = encode(children[index].map { UInt32(directoryOffsets[$0]) })
                case 34665:
                    if let exif = exifIndex[index] { entries[i].value = encode([UInt32(directoryOffsets[exif])]) }
                default:
                    break
                }
            }
            let start = directoryOffsets[index]
            file.append(Data(count: start - file.count))
            var values = Data()
            let valuesStart = start + 2 + entries.count * 12 + 4
            file.append(encode([UInt16(entries.count)]))
            for entry in entries {
                file.append(encode([entry.tag, entry.type]))
                file.append(encode([UInt32(entry.count)]))
                if entry.value.count <= 4 {
                    file.append(entry.value + Data(count: 4 - entry.value.count))
                } else {
                    file.append(encode([UInt32(valuesStart + values.count)]))
                    values.append(entry.value)
                    if entry.value.count % 2 == 1 { values.append(0) }
                }
            }
            file.append(encode([UInt32(0)]))
            file.append(values)
        }
        for (index, directory) in flat.enumerated() {
            for (block, offset) in zip(directory.blocks, blockOffsets[index]) {
                file.append(Data(count: offset - file.count))
                file.append(block)
            }
        }
        return file
    }
}
