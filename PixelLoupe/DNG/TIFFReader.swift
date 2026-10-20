import Foundation

/// Reads the structure of a TIFF or DNG file: its image file directories and their entries, in either byte order,
/// without decoding any pixels. Smart Previews use it to tell what kind of DNG an original is, to copy an original's
/// tags, and to read back what they recorded about themselves.
nonisolated struct TIFFFile: Sendable {
    /// One entry of a directory: where its value is, not the value itself.
    struct Entry: Sendable {
        let tag: UInt16
        let type: UInt16
        let count: Int
        /// Where the value's bytes start in the file (inside the entry when they fit in four bytes).
        let valueOffset: Int

        /// Bytes per value for each TIFF type; unknown types count as one byte.
        static func size(of type: UInt16) -> Int {
            switch type {
            case 3, 8: 2
            case 4, 9, 11, 13: 4
            case 5, 10, 12, 16, 17, 18: 8
            default: 1
            }
        }

        var byteCount: Int { count * Self.size(of: type) }
    }

    /// One image file directory.
    struct Directory: Sendable {
        let offset: Int
        let entries: [UInt16: Entry]
        /// The entries in the order the file lists them.
        let orderedTags: [UInt16]

        subscript(tag: UInt16) -> Entry? { entries[tag] }
    }

    let data: Data
    let isBigEndian: Bool
    /// IFD0 and the directories chained after it.
    let directories: [Directory]

    init?(data: Data) {
        guard data.count >= 8 else { return nil }
        self.data = data
        switch (data[data.startIndex], data[data.startIndex + 1]) {
        case (0x49, 0x49): isBigEndian = false
        case (0x4D, 0x4D): isBigEndian = true
        default: return nil
        }
        var directories: [Directory] = []
        let reader = Self.Reader(data: data, isBigEndian: isBigEndian)
        guard reader.u16(2) == 42, var next = reader.u32(4) else { return nil }
        var seen = Set<Int>()
        while next != 0, directories.count < 64, seen.insert(next).inserted {
            guard let directory = reader.directory(at: next) else { break }
            directories.append(directory)
            next = reader.u32(directory.offset + 2 + directory.entries.count * 12) ?? 0
        }
        guard !directories.isEmpty else { return nil }
        self.directories = directories
    }

    /// Opens `url` without reading it all into memory.
    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        self.init(data: data)
    }

    var ifd0: Directory { directories[0] }

    /// The directories a `SubIFDs` entry (330) of `directory` points to.
    func subDirectories(of directory: Directory) -> [Directory] {
        guard let entry = directory[330] else { return [] }
        let reader = Self.Reader(data: data, isBigEndian: isBigEndian)
        return integers(entry).compactMap { reader.directory(at: $0) }
    }

    /// The EXIF directory `directory` points to, if any.
    func exif(of directory: Directory) -> Directory? {
        guard let entry = directory[34665], let offset = integers(entry).first else { return nil }
        let reader = Self.Reader(data: data, isBigEndian: isBigEndian)
        return reader.directory(at: offset)
    }

    /// The full-resolution image's directory (`NewSubfileType` 0): IFD0, or one of its sub-directories.
    var mainImage: Directory? {
        let candidates = [ifd0] + subDirectories(of: ifd0) + directories.dropFirst()
        return candidates.first { directory in
            directory[256] != nil && (directory[254].map { integers($0).first ?? 0 } ?? 0) == 0
        }
    }

    // MARK: - Values

    /// The value's bytes as stored (in the file's byte order).
    func bytes(_ entry: Entry) -> Data? {
        let start = entry.valueOffset, end = start + entry.byteCount
        guard start >= 0, end <= data.count else { return nil }
        return data.subdata(in: (data.startIndex + start)..<(data.startIndex + end))
    }

    /// BYTE, SHORT, LONG and IFD values as integers.
    func integers(_ entry: Entry) -> [Int] {
        let reader = Self.Reader(data: data, isBigEndian: isBigEndian)
        return (0..<entry.count).compactMap { index -> Int? in
            let at = entry.valueOffset + index * Entry.size(of: entry.type)
            switch entry.type {
            case 1, 7: return reader.u8(at)
            case 3: return reader.u16(at)
            case 4, 13: return reader.u32(at)
            case 8: return reader.u16(at).map { Int(Int16(truncatingIfNeeded: $0)) }
            case 9: return reader.u32(at).map { Int(Int32(truncatingIfNeeded: $0)) }
            default: return nil
            }
        }
    }

    /// RATIONAL, SRATIONAL, FLOAT, DOUBLE (and integer) values as doubles.
    func doubles(_ entry: Entry) -> [Double] {
        let reader = Self.Reader(data: data, isBigEndian: isBigEndian)
        switch entry.type {
        case 5, 10:
            return (0..<entry.count).compactMap { index in
                let at = entry.valueOffset + index * 8
                guard let n = reader.u32(at), let d = reader.u32(at + 4), d != 0 else { return nil }
                return entry.type == 5 ? Double(n) / Double(d)
                    : Double(Int32(truncatingIfNeeded: n)) / Double(Int32(truncatingIfNeeded: d))
            }
        case 11:
            return (0..<entry.count).compactMap { reader.u32(entry.valueOffset + $0 * 4).map { Double(Float(bitPattern: UInt32($0))) } }
        case 12:
            return (0..<entry.count).compactMap { reader.u64(entry.valueOffset + $0 * 8).map { Double(bitPattern: $0) } }
        default:
            return integers(entry).map(Double.init)
        }
    }

    /// An ASCII value, without its terminating zero.
    func string(_ entry: Entry) -> String? {
        guard let bytes = bytes(entry) else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Reads numbers from the file in its byte order.
    private struct Reader {
        let data: Data
        let isBigEndian: Bool

        func u8(_ offset: Int) -> Int? {
            guard offset >= 0, offset < data.count else { return nil }
            return Int(data[data.startIndex + offset])
        }

        func u16(_ offset: Int) -> Int? { value(offset, 2).map(Int.init) }
        func u32(_ offset: Int) -> Int? { value(offset, 4).map(Int.init) }
        func u64(_ offset: Int) -> UInt64? { value(offset, 8) }

        private func value(_ offset: Int, _ size: Int) -> UInt64? {
            guard offset >= 0, offset + size <= data.count else { return nil }
            var result: UInt64 = 0
            for index in 0..<size {
                let byte = UInt64(data[data.startIndex + offset + (isBigEndian ? index : size - 1 - index)])
                result = result << 8 | byte
            }
            return result
        }

        func directory(at offset: Int) -> Directory? {
            guard let count = u16(offset), count > 0, count < 4096, offset + 2 + count * 12 + 4 <= data.count else { return nil }
            var entries: [UInt16: Entry] = [:]
            var order: [UInt16] = []
            for index in 0..<count {
                let at = offset + 2 + index * 12
                guard let tag = u16(at), let type = u16(at + 2), let count = u32(at + 4) else { return nil }
                let size = Entry.size(of: UInt16(type)) * count
                let valueOffset = size <= 4 ? at + 8 : (u32(at + 8) ?? -1)
                let entry = Entry(tag: UInt16(tag), type: UInt16(type), count: count, valueOffset: valueOffset)
                if entries[entry.tag] == nil { order.append(entry.tag) }
                entries[entry.tag] = entry
            }
            return Directory(offset: offset, entries: entries, orderedTags: order)
        }
    }
}
