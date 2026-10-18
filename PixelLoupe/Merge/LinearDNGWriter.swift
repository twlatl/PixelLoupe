import Foundation

/// A demosaiced, scene-linear image to save as a DNG: what Photo Merge produces.
nonisolated struct LinearDNGImage: Sendable {
    var width: Int
    var height: Int
    /// Interleaved RGB, top row first, in linear Rec. 2020 with a D65 white (the space the merge works
    /// in). Values aren't limited to 0…1: an HDR merge keeps highlights several stops above white.
    var pixels: [Float16]
    /// When set, the pixels are already scaled to 0…1 and this is how many stops they were brought
    /// down (see ``LinearDNGWriter``); when nil, the writer scales them.
    var headroom: Double?

    init(width: Int, height: Int, pixels: [Float16], headroom: Double? = nil) {
        precondition(pixels.count == width * height * 3)
        self.width = width
        self.height = height
        self.pixels = pixels
        self.headroom = headroom
    }
}

/// What the DNG says about how the photo was taken (from the merge's reference exposure).
nonisolated struct DNGMetadata: Sendable, Equatable {
    var make: String?
    var model: String?
    var lensModel: String?
    var captureDate: Date?
    var timeZone: TimeZone?
    /// Seconds, or 0 when unknown.
    var exposureTime = 0.0
    /// F-number, or 0.
    var aperture = 0.0
    var iso = 0
    /// Millimeters, or 0.
    var focalLength = 0.0
    /// Stops added to the default rendering, on top of what the merge needs to keep highlights.
    var baselineExposure = 0.0
}

/// Writes ``LinearDNGImage``s as Linear DNG files (DNG 1.4, `LinearRaw`, 16-bit floating point), the
/// format Lightroom's HDR merges use, so the result opens like any RAW file: Apple's RAW engine
/// decodes it, and white balance and exposure keep their full range.
///
/// The pixels are scaled so the brightest is 1.0 (the RAW engine clips at the white level) and
/// `BaselineExposure` brings them back up, so the default rendering matches the reference exposure
/// and pulling Exposure down recovers the highlights.
nonisolated enum LinearDNGWriter {
    /// The pixels are stored in square tiles, as cameras and Lightroom write DNGs. (Apple's RAW engine
    /// can drop parts of the picture from a large DNG stored in strips when it's decoded at a new scale
    /// while an earlier decode is still running, as Develop does.)
    static let tileSize = 256

    /// XYZ (D65) to linear Rec. 2020: the DNG's `ColorMatrix1`, which says the pixels are Rec. 2020.
    static let xyzToRec2020: [Double] = [
        1.7166512, -0.3556708, -0.2533663,
        -0.6666844, 1.6164812, 0.0157685,
        0.0176399, -0.0427706, 0.9421031,
    ]

    /// Writes the DNG a row of tiles at a time (to a temporary file, moved into place when it's
    /// complete), so a large merge isn't held in memory twice more while it's saved.
    static func write(_ image: LinearDNGImage, metadata: DNGMetadata, to url: URL) throws {
        let layout = Layout(image: image, metadata: metadata)
        let temporary = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString)-\(url.lastPathComponent)")
        guard FileManager.default.createFile(atPath: temporary.path(percentEncoded: false), contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path(percentEncoded: false)])
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: layout.prefix)
            for row in 0..<layout.tilesDown { try handle.write(contentsOf: layout.tiles(row: row, of: image)) }
            try handle.close()
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// The stops `BaselineExposure` adds back for pixels whose brightest value is `peak`.
    static func headroom(peak: Float) -> Double {
        peak > 1 ? Double(log2(peak)) : 0
    }

    /// The whole DNG in memory (what ``write(_:metadata:to:)`` writes).
    static func data(for image: LinearDNGImage, metadata: DNGMetadata) -> Data {
        let layout = Layout(image: image, metadata: metadata)
        var data = layout.prefix
        for row in 0..<layout.tilesDown { data.append(layout.tiles(row: row, of: image)) }
        return data
    }

    /// Where everything goes in the file: the header, IFD and EXIF directory, then the tiles, left to
    /// right and top to bottom (those at the right and bottom edges padded with zeros).
    private struct Layout {
        let scale: Float
        let tilesAcross: Int
        let tilesDown: Int
        let tileBytes: Int
        /// Everything before the pixels.
        let prefix: Data

        init(image: LinearDNGImage, metadata: DNGMetadata) {
            let headroom: Double
            if let given = image.headroom {
                headroom = given
                scale = 1
            } else {
                let peak = image.pixels.reduce(Float(0)) { max($0, Float($1)) }
                headroom = LinearDNGWriter.headroom(peak: peak)
                scale = peak > 1 ? 1 / peak : 1
            }
            let tile = tileSize
            tilesAcross = (image.width + tile - 1) / tile
            tilesDown = (image.height + tile - 1) / tile
            tileBytes = tile * tile * 3 * 2
            let tileBytes = tileBytes
            let tileOffsets = (0..<(tilesAcross * tilesDown)).map { UInt32($0 * tileBytes) }

            var ifd = TIFFDirectory()
            ifd.add(254, long: [0])
            ifd.add(256, long: [UInt32(image.width)])
            ifd.add(257, long: [UInt32(image.height)])
            ifd.add(258, short: [16, 16, 16])
            ifd.add(259, short: [1])
            ifd.add(262, short: [34892])  // LinearRaw
            if let make = metadata.make { ifd.add(271, ascii: make) }
            if let model = metadata.model { ifd.add(272, ascii: model) }
            ifd.add(274, short: [1])
            ifd.add(277, short: [3])
            ifd.add(284, short: [1])
            ifd.add(322, long: [UInt32(tile)])
            ifd.add(323, long: [UInt32(tile)])
            ifd.addTiles(offsets: tileOffsets, counts: Array(repeating: UInt32(tileBytes), count: tileOffsets.count))
            ifd.add(305, ascii: "PixelLoupe")
            if let date = metadata.captureDate { ifd.add(306, ascii: exifDate(date, timeZone: metadata.timeZone)) }
            ifd.add(339, short: [3, 3, 3])  // floating point
            ifd.add(50706, byte: [1, 4, 0, 0])
            ifd.add(50707, byte: [1, 4, 0, 0])
            ifd.add(50708, ascii: [metadata.make, metadata.model].compactMap { $0 }.joined(separator: " ").nonEmpty ?? "PixelLoupe HDR")
            ifd.add(50717, long: [1])
            ifd.add(50721, srational: xyzToRec2020)
            ifd.add(50728, rational: [1, 1, 1])
            ifd.add(50730, srational: [metadata.baselineExposure + headroom])
            ifd.add(50778, short: [21])  // D65

            var exif = TIFFDirectory()
            if metadata.exposureTime > 0 { exif.add(33434, rational: [metadata.exposureTime]) }
            if metadata.aperture > 0 { exif.add(33437, rational: [metadata.aperture]) }
            if metadata.iso > 0 { exif.add(34855, short: [UInt16(clamping: metadata.iso)]) }
            exif.add(36864, undefined: Array("0231".utf8))
            if let date = metadata.captureDate {
                exif.add(36867, ascii: exifDate(date, timeZone: metadata.timeZone))
                exif.add(36881, ascii: offsetString(for: date, timeZone: metadata.timeZone))
            }
            if metadata.focalLength > 0 { exif.add(37386, rational: [metadata.focalLength]) }
            if let lens = metadata.lensModel { exif.add(42036, ascii: lens) }

            prefix = TIFFDirectory.prefix(ifd: ifd, exif: exif)
        }

        /// One row of tiles' pixels, as stored (half floats, little-endian).
        func tiles(row tileY: Int, of image: LinearDNGImage) -> Data {
            let tile = tileSize
            var data = Data(count: tilesAcross * tileBytes)
            data.withUnsafeMutableBytes { raw in
                let output = raw.bindMemory(to: UInt16.self)
                image.pixels.withUnsafeBufferPointer { input in
                    for tileX in 0..<tilesAcross {
                        let base = tileX * tile * tile * 3
                        let columns = min(tile, image.width - tileX * tile)
                        for row in 0..<min(tile, image.height - tileY * tile) {
                            let from = ((tileY * tile + row) * image.width + tileX * tile) * 3
                            let to = base + row * tile * 3
                            if scale == 1 {
                                // Already in range: copy the row's bits (both little-endian half floats).
                                UnsafeMutableRawPointer(output.baseAddress! + to).copyMemory(
                                    from: UnsafeRawPointer(input.baseAddress! + from), byteCount: columns * 3 * 2
                                )
                                continue
                            }
                            for i in 0..<(columns * 3) {
                                let value = Float(input[from + i]) * scale
                                output[to + i] = Float16(value.isFinite ? max(0, value) : 0).bitPattern.littleEndian
                            }
                        }
                    }
                }
            }
            return data
        }
    }

    private static func exifDate(_ date: Date, timeZone: TimeZone?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone ?? .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func offsetString(for date: Date, timeZone: TimeZone?) -> String {
        let seconds = (timeZone ?? .current).secondsFromGMT(for: date)
        let minutes = abs(seconds) / 60
        return String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", minutes / 60, minutes % 60)
    }
}

/// One TIFF image file directory being built, little-endian.
nonisolated private struct TIFFDirectory {
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

private extension String {
    nonisolated var nonEmpty: String? { isEmpty ? nil : self }
}
