import Compression
import CoreImage
import Foundation

/// Smart Previews of DNGs that are already demosaiced (`LinearRaw`) from other apps, such as iPhone ProRAW: a
/// downsized copy of the original DNG (RAW-118).
///
/// The Linear DNG recipe can't reproduce these: ProRAW renders with its own tone curve and local tone-mapping gain
/// map, which a Rec. 2020 proxy loses. Their data is linear already, so averaging it down is legitimate, and keeping
/// the original's own tags keeps its color, tone and white balance math exactly (ΔE00 0.3–0.7 before compression in
/// the RAW-85 spike). The copy has:
///
/// - IFD0: a small preview, and the original's profile and color tags, copied byte for byte (the file is written in
///   the original's byte order, which blobs such as the gain map follow);
/// - one SubIFD: the downsized raw image as 16-bit JPEG XL tiles, with the original's raw-image tags (the gain map,
///   black and white levels, default crop scaled down). The RAW engine only applies the gain map in this two-IFD layout;
/// - EXIF without the camera maker's note, which would turn on the engine's noise reduction, tuned for the original's
///   size, on the 2560 px copy.
///
/// Originals with opcode lists, per-row or per-column black levels, or samples the reader doesn't handle get none.
nonisolated extension SmartPreviewWriter {
    static func writeDNGCopy(
        _ original: URL, fingerprint: (modified: Date?, size: Int64), to destination: URL
    ) throws -> SmartPreviewInfo {
        guard let file = TIFFFile(contentsOf: original), let raw = file.mainImage else { throw WriteError.unreadable }
        let ifd0 = file.ifd0
        // Opcode lists and black level deltas are in pixel coordinates; copying them would need scaling.
        for tag: UInt16 in [51008, 51009, 51022, 50715, 50716] where raw[tag] != nil || ifd0[tag] != nil {
            throw WriteError.unsupported
        }
        guard let engine = CIRAWFilter(imageURL: original), let rendered = engine.outputImage,
              !rendered.extent.isEmpty, !rendered.extent.isInfinite else { throw WriteError.unreadable }

        var image = try DNGRawImage.read(file, raw)
        guard image.samplesPerPixel == 3 else { throw WriteError.unsupported }
        if let table = raw[50712].map(file.integers), !table.isEmpty { image.linearize(table) }
        if let area = raw[50829].map(file.integers), area.count == 4 {
            image.crop(top: area[0], left: area[1], bottom: area[2], right: area[3])
        }
        let fullWidth = image.width, fullHeight = image.height
        let scale = min(1, Double(longEdge) / Double(max(fullWidth, fullHeight)))
        let small = image.downsized(by: scale)

        let originalSize = rendered.extent.size
        let info = SmartPreviewInfo(
            kind: .dngCopy, originalSize: originalSize,
            scale: Double(max(small.width, small.height)) / Double(max(fullWidth, fullHeight)),
            sourceModificationDate: fingerprint.modified, sourceSize: fingerprint.size,
            shadowBias: engine.shadowBias, localToneMapAmount: engine.localToneMapAmount,
            hasBuiltInLensProfile: engine.isLensCorrectionSupported
        )

        let builder = TIFFBuilder(isBigEndian: file.isBigEndian)
        func copied(_ directory: TIFFFile.Directory, _ tag: UInt16) -> TIFFBuilder.Entry? {
            guard let entry = directory[tag], let value = file.bytes(entry) else { return nil }
            return TIFFBuilder.Entry(tag: tag, type: entry.type, count: entry.count, value: value)
        }

        // The raw image: the downsized samples as JPEG XL, with the original's raw-image tags.
        var rawDirectory = TIFFBuilder.Directory()
        let rawSource = raw.offset == ifd0.offset ? ifd0 : raw
        for tag in rawSource.orderedTags where !Self.structuralTags.contains(tag) && !Self.droppedRawTags.contains(tag) {
            // When the original's raw image is IFD0 itself, only its raw-image tags move to the SubIFD.
            if raw.offset == ifd0.offset, !Self.rawImageTags.contains(tag) { continue }
            if let entry = copied(rawSource, tag) { rawDirectory.set(entry) }
        }
        for tag: UInt16 in [50719, 50720] {
            // DefaultCropOrigin and DefaultCropSize, in pixels of the (active area of the) raw image.
            guard let entry = raw[tag] else { continue }
            let values = file.doubles(entry)
            if values.count == 2 {
                rawDirectory.set(builder.entry(tag, rational: values.map { $0 * Double(small.width) / Double(fullWidth) }))
            }
        }
        let tiles = try encodeTiles(small.samples, width: small.width, height: small.height)
        rawDirectory.blocks = tiles.data
        rawDirectory.blocksAreTiles = true
        rawDirectory.set(builder.entry(254, long: [0]))
        rawDirectory.set(builder.entry(256, long: [UInt32(small.width)]))
        rawDirectory.set(builder.entry(257, long: [UInt32(small.height)]))
        rawDirectory.set(builder.entry(258, short: [16, 16, 16]))
        rawDirectory.set(builder.entry(259, short: [52546]))  // JPEG XL
        rawDirectory.set(builder.entry(262, short: [34892]))  // LinearRaw
        rawDirectory.set(builder.entry(277, short: [3]))
        rawDirectory.set(builder.entry(284, short: [1]))
        rawDirectory.set(builder.entry(322, long: [UInt32(LinearDNGWriter.tileSize)]))
        rawDirectory.set(builder.entry(323, long: [UInt32(LinearDNGWriter.tileSize)]))
        rawDirectory.set(builder.entry(52553, float: [tileSettings.distance]))
        rawDirectory.set(builder.entry(52554, long: [UInt32(tileSettings.effort)]))
        rawDirectory.set(builder.entry(52555, long: [UInt32(tileSettings.decodingSpeed)]))

        // IFD0: a small preview, and the original's profile, color and camera tags.
        var directory = TIFFBuilder.Directory()
        for tag in ifd0.orderedTags where !Self.structuralTags.contains(tag) && !Self.droppedIFD0Tags.contains(tag) {
            if raw.offset == ifd0.offset, Self.rawImageTags.contains(tag) || Self.droppedRawTags.contains(tag) { continue }
            if let entry = copied(ifd0, tag) { directory.set(entry) }
        }
        let preview = small.preview(longEdge: 256, black: raw[50714].map(file.doubles)?.first ?? 0,
                                    white: raw[50717].map(file.doubles)?.first ?? 65535)
        directory.blocks = [preview.rgb]
        directory.blocksAreTiles = false
        directory.set(builder.entry(254, long: [1]))  // a reduced-resolution image
        directory.set(builder.entry(256, long: [UInt32(preview.width)]))
        directory.set(builder.entry(257, long: [UInt32(preview.height)]))
        directory.set(builder.entry(258, short: [8, 8, 8]))
        directory.set(builder.entry(259, short: [1]))
        directory.set(builder.entry(262, short: [2]))  // RGB
        directory.set(builder.entry(277, short: [3]))
        directory.set(builder.entry(278, long: [UInt32(preview.height)]))
        directory.set(builder.entry(284, short: [1]))
        directory.set(builder.entry(305, ascii: "PixelLoupe"))
        // DNG 1.7 for the JPEG XL tiles; never lower than the original's.
        let originalVersion = ifd0[50706].map(file.integers) ?? []
        let version = originalVersion.lexicographicallyPrecedes([1, 7, 0, 0]) ? [1, 7, 0, 0] : originalVersion
        directory.set(builder.entry(50706, byte: version.map { UInt8(clamping: $0) }))
        directory.set(builder.entry(50707, byte: [1, 7, 0, 0]))
        directory.set(builder.entry(50740, byte: try info.dngPrivateData()))
        directory.set(builder.entry(51089, long: [UInt32(fullWidth), UInt32(fullHeight)]))  // OriginalDefaultFinalSize
        directory.subDirectories = [rawDirectory]

        // EXIF, without the maker's note (and the interoperability directory it may point to).
        if let exif = file.exif(of: ifd0) {
            var copy = TIFFBuilder.Directory()
            for tag in exif.orderedTags where tag != 37500 && tag != 40965 && exif[tag]?.type != 13 {
                if let entry = copied(exif, tag) { copy.set(entry) }
            }
            directory.exif = copy
        }

        var data = builder.data(ifd0: directory)
        if data.count < smallestOpenableDNG { data.append(Data(count: smallestOpenableDNG - data.count)) }
        try replace(destination, with: data)
        return info
    }

    /// Tags that describe an image's layout: the builder writes its own.
    private static let structuralTags: Set<UInt16> = [
        254, 256, 257, 258, 259, 262, 273, 277, 278, 279, 284, 317, 322, 323, 324, 325, 330, 338, 339, 34665,
    ]
    /// IFD0 tags left out or replaced: software, XMP, IPTC, Photoshop and GPS data, the maker's note, DNG versions,
    /// private data, preview descriptions and original sizes.
    private static let droppedIFD0Tags: Set<UInt16> = [
        305, 700, 33723, 34377, 34853, 37500, 50706, 50707, 50740, 50966, 50967, 50968, 50969, 50970, 50971,
        51089, 51090, 51091,
    ]
    /// Raw-image tags that don't survive downsizing: the linearization table (the data is linearized), the active
    /// and masked areas (it's cropped to the active area), the default crop (rewritten scaled) and JPEG XL settings.
    private static let droppedRawTags: Set<UInt16> = [50712, 50719, 50720, 50829, 50830, 52553, 52554, 52555]
    /// Tags that belong with the raw image (the DNG specification's raw IFD tags) when an original keeps its raw
    /// image in IFD0.
    private static let rawImageTags: Set<UInt16> = [
        50713, 50714, 50717, 50718, 50733, 50738, 50780, 51041, 51110, 51125, 52525, 52526,
    ]
}

/// The raw image of a DNG, decoded to 16-bit samples, interleaved, row by row.
///
/// Loops over samples are `while` loops: in an unoptimized (Debug) build each step of a `for … in` over a range costs
/// some 70 ns, against 3 ns for a `while` loop, and a 48 MP ProRAW photo has 146 million samples.
nonisolated struct DNGRawImage: Sendable {
    var width: Int
    var height: Int
    var samplesPerPixel: Int
    var samples: [UInt16]

    /// Reads `directory`'s image from `file`: tiles or strips, uncompressed (8 or 16 bits), lossless JPEG, or Deflate
    /// (8 or 16 bits, with or without horizontal differencing).
    static func read(_ file: TIFFFile, _ directory: TIFFFile.Directory) throws -> DNGRawImage {
        func value(_ tag: UInt16, _ fallback: Int? = nil) -> Int? { directory[tag].flatMap { file.integers($0).first } ?? fallback }
        guard let width = value(256), let height = value(257), width > 0, height > 0 else { throw SmartPreviewWriter.WriteError.unreadable }
        let spp = value(277, 1)!, bits = value(258, 1)!, compression = value(259, 1)!
        let predictor = value(317, 1)!
        guard value(284, 1) == 1 || spp == 1, (value(339, 1) ?? 1) == 1 else { throw SmartPreviewWriter.WriteError.unsupported }
        guard [1, 7, 8].contains(compression), compression == 7 || bits == 8 || bits == 16, [1, 2].contains(predictor)
        else { throw SmartPreviewWriter.WriteError.unsupported }

        // The blocks: tiles, or strips as full-width tiles.
        let blockWidth: Int, blockHeight: Int, offsets: [Int], counts: [Int]
        if let tileWidth = value(322), let tileHeight = value(323) {
            (blockWidth, blockHeight) = (tileWidth, tileHeight)
            offsets = directory[324].map(file.integers) ?? []
            counts = directory[325].map(file.integers) ?? []
        } else {
            (blockWidth, blockHeight) = (width, value(278, height)!)
            offsets = directory[273].map(file.integers) ?? []
            counts = directory[279].map(file.integers) ?? []
        }
        let across = (width + blockWidth - 1) / blockWidth, down = (height + blockHeight - 1) / blockHeight
        guard blockWidth > 0, blockHeight > 0, offsets.count == across * down, counts.count == offsets.count
        else { throw SmartPreviewWriter.WriteError.unreadable }

        var samples = [UInt16](repeating: 0, count: width * height * spp)
        let failed = Flag()
        samples.withUnsafeMutableBufferPointer { buffer in
            // Each block writes its own rectangle.
            let output = SharedPointer(base: buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: offsets.count) { index in
                let start = offsets[index], end = start + counts[index]
                guard start >= 0, end <= file.data.count else { failed.set(); return }
                let block = file.data.subdata(in: (file.data.startIndex + start)..<(file.data.startIndex + end))
                let left = (index % across) * blockWidth, top = (index / across) * blockHeight
                let rows = min(blockHeight, height - top)
                guard let decoded = try? decodeBlock(
                    block, compression: compression, bits: bits, predictor: predictor, isBigEndian: file.isBigEndian,
                    width: blockWidth, rows: rows, samplesPerPixel: spp
                ) else { failed.set(); return }
                let columns = min(blockWidth, width - left)
                decoded.withUnsafeBufferPointer { decoded in
                    for row in 0..<rows {
                        (output.base + ((top + row) * width + left) * spp)
                            .update(from: decoded.baseAddress! + row * blockWidth * spp, count: columns * spp)
                    }
                }
            }
        }
        guard !failed.isSet else { throw SmartPreviewWriter.WriteError.unreadable }
        return DNGRawImage(width: width, height: height, samplesPerPixel: spp, samples: samples)
    }

    /// One block's samples, `width × rows × samplesPerPixel`.
    private static func decodeBlock(
        _ data: Data, compression: Int, bits: Int, predictor: Int, isBigEndian: Bool,
        width: Int, rows: Int, samplesPerPixel spp: Int
    ) throws -> [UInt16] {
        let count = width * rows * spp
        switch compression {
        case 7:
            let jpeg = try LosslessJPEG(data)
            // DNG writers may split a row's samples across "components"; only the totals have to agree.
            guard jpeg.width * jpeg.components == width * spp, jpeg.height >= rows else { throw SmartPreviewWriter.WriteError.unsupported }
            return jpeg.samples.count == count ? jpeg.samples : Array(jpeg.samples[..<count])
        case 8:
            let bytesPerSample = bits / 8
            var inflated = Data(count: count * bytesPerSample)
            // Deflate data is a zlib stream; the Compression framework reads it after the two-byte header.
            guard data.count > 2 else { throw SmartPreviewWriter.WriteError.unreadable }
            let written = inflated.withUnsafeMutableBytes { out in
                data.withUnsafeBytes { input in
                    compression_decode_buffer(
                        out.bindMemory(to: UInt8.self).baseAddress!, out.count,
                        input.bindMemory(to: UInt8.self).baseAddress! + 2, input.count - 2, nil, COMPRESSION_ZLIB
                    )
                }
            }
            guard written == inflated.count else { throw SmartPreviewWriter.WriteError.unreadable }
            var samples = unpack(inflated, bits: bits, isBigEndian: isBigEndian, count: count)
            if predictor == 2 {
                // Horizontal differencing: each sample is the difference from the one before it in its row.
                samples.withUnsafeMutableBufferPointer { samples in
                    for row in 0..<rows {
                        var i = row * width * spp + spp
                        while i < (row + 1) * width * spp {
                            samples[i] = samples[i] &+ samples[i - spp]
                            i += 1
                        }
                    }
                }
            }
            return samples
        default:
            guard data.count >= count * bits / 8 else { throw SmartPreviewWriter.WriteError.unreadable }
            return unpack(data, bits: bits, isBigEndian: isBigEndian, count: count)
        }
    }

    private static func unpack(_ data: Data, bits: Int, isBigEndian: Bool, count: Int) -> [UInt16] {
        var samples = [UInt16](repeating: 0, count: count)
        data.withUnsafeBytes { bytes in
            samples.withUnsafeMutableBufferPointer { samples in
                var i = 0
                while i < count {
                    if bits == 8 {
                        samples[i] = UInt16(bytes[i])
                    } else {
                        let a = UInt16(bytes[i * 2]), b = UInt16(bytes[i * 2 + 1])
                        samples[i] = isBigEndian ? a << 8 | b : b << 8 | a
                    }
                    i += 1
                }
            }
        }
        return samples
    }

    /// Maps samples through a `LinearizationTable`; values past its end take its last entry.
    mutating func linearize(_ table: [Int]) {
        guard let last = table.last else { return }
        // An entry for every 16-bit value.
        let lookup = table.prefix(65536).map { UInt16(clamping: $0) }
            + repeatElement(UInt16(clamping: last), count: max(0, 65536 - table.count))
        lookup.withUnsafeBufferPointer { lookup in
            samples.withUnsafeMutableBufferPointer { samples in
                var i = 0
                while i < samples.count {
                    samples[i] = lookup[Int(samples[i])]
                    i += 1
                }
            }
        }
    }

    /// Keeps the rows `top..<bottom` and columns `left..<right` (an `ActiveArea`).
    mutating func crop(top: Int, left: Int, bottom: Int, right: Int) {
        let top = max(0, min(top, height)), bottom = max(top, min(bottom, height))
        let left = max(0, min(left, width)), right = max(left, min(right, width))
        guard top > 0 || left > 0 || bottom < height || right < width else { return }
        let rowLength = (right - left) * samplesPerPixel
        var cropped = [UInt16](repeating: 0, count: (bottom - top) * rowLength)
        samples.withUnsafeBufferPointer { samples in
            cropped.withUnsafeMutableBufferPointer { cropped in
                for row in top..<bottom {
                    (cropped.baseAddress! + (row - top) * rowLength)
                        .update(from: samples.baseAddress! + (row * width + left) * samplesPerPixel, count: rowLength)
                }
            }
        }
        (samples, width, height) = (cropped, right - left, bottom - top)
    }

    /// The image averaged down by `scale` (at most 1): each output pixel is the mean of the input it covers, which is
    /// correct for linear data.
    func downsized(by scale: Double) -> DNGRawImage {
        guard scale < 1 else { return self }
        let width = width, height = height, spp = samplesPerPixel
        let outWidth = max(1, Int((Double(width) * scale).rounded())), outHeight = max(1, Int((Double(height) * scale).rounded()))
        let horizontal = BoxFilter(from: width, to: outWidth), vertical = BoxFilter(from: height, to: outHeight)
        // Across first, into floats, then down. Each pass writes its own rows from several threads.
        var across = [Float](repeating: 0, count: outWidth * height * spp)
        across.withUnsafeMutableBufferPointer { buffer in
            let output = SharedPointer(base: buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: height) { y in
                samples.withUnsafeBufferPointer { samples in
                    horizontal.apply(to: samples.baseAddress! + y * width * spp, channels: spp,
                                     into: output.base + y * outWidth * spp)
                }
            }
        }
        let rows = across
        var result = [UInt16](repeating: 0, count: outWidth * outHeight * spp)
        result.withUnsafeMutableBufferPointer { buffer in
            let output = SharedPointer(base: buffer.baseAddress!)
            DispatchQueue.concurrentPerform(iterations: outHeight) { y in
                rows.withUnsafeBufferPointer { across in
                    // Down one output row: the input rows it covers, weighted, for every sample in the row.
                    let rowLength = outWidth * spp
                    let row = output.base + y * rowLength
                    vertical.weights.withUnsafeBufferPointer { weights in
                        var sums = [Float](repeating: 0, count: rowLength)
                        sums.withUnsafeMutableBufferPointer { sums in
                            for k in 0..<vertical.span {
                                let weight = weights[y * vertical.span + k]
                                guard weight > 0 else { continue }
                                let source = across.baseAddress! + (vertical.first[y] + k) * rowLength
                                var i = 0
                                while i < rowLength {
                                    sums[i] += source[i] * weight
                                    i += 1
                                }
                            }
                            var i = 0
                            while i < rowLength {
                                row[i] = UInt16(max(0, min(65535, sums[i].rounded())))
                                i += 1
                            }
                        }
                    }
                }
            }
        }
        return DNGRawImage(width: outWidth, height: outHeight, samplesPerPixel: spp, samples: result)
    }

    /// Averaging `size` positions down to `out`: the input positions each output position covers, and how much of
    /// each, as `span` weights from a first position (some of them 0).
    private struct BoxFilter: Sendable {
        let span: Int
        let first: [Int]
        let weights: [Float]

        init(from size: Int, to out: Int) {
            let ratio = Double(size) / Double(out)
            let span = min(size, Int(ratio.rounded(.up)) + 1)
            var first = [Int](repeating: 0, count: out), weights = [Float](repeating: 0, count: out * span)
            for o in 0..<out {
                let a = Double(o) * ratio, b = min(Double(size), Double(o + 1) * ratio)
                // Shifted back at the end, so that every position read is inside the input.
                let start = min(Int(a.rounded(.down)), size - span)
                first[o] = start
                var i = Int(a.rounded(.down))
                while Double(i) < b {
                    weights[o * span + i - start] = Float((min(b, Double(i + 1)) - max(a, Double(i))) / ratio)
                    i += 1
                }
            }
            (self.span, self.first, self.weights) = (span, first, weights)
        }

        /// Averages one row of interleaved `channels` into `output`.
        func apply(to row: UnsafePointer<UInt16>, channels: Int, into output: UnsafeMutablePointer<Float>) {
            first.withUnsafeBufferPointer { first in
                weights.withUnsafeBufferPointer { weights in
                    var o = 0
                    while o < first.count {
                        let source = row + first[o] * channels, taps = weights.baseAddress! + o * span
                        var c = 0
                        while c < channels {
                            var sum: Float = 0, k = 0
                            while k < span {
                                sum += Float(source[k * channels + c]) * taps[k]
                                k += 1
                            }
                            output[o * channels + c] = sum
                            c += 1
                        }
                        o += 1
                    }
                }
            }
        }
    }

    /// An 8-bit RGB preview, at most `longEdge` on its long edge, with the levels stretched and a display gamma:
    /// enough for apps that show a DNG's preview, not a faithful rendering.
    func preview(longEdge: Int, black: Double, white: Double) -> (width: Int, height: Int, rgb: Data) {
        let small = downsized(by: min(1, Double(longEdge) / Double(max(width, height))))
        let range = max(white - black, 1)
        var rgb = Data(count: small.width * small.height * 3)
        for pixel in 0..<(small.width * small.height) {
            for c in 0..<3 {
                let value = max(0, min(1, (Double(small.samples[pixel * small.samplesPerPixel + min(c, small.samplesPerPixel - 1)]) - black) / range))
                rgb[pixel * 3 + c] = UInt8((pow(value, 1 / 2.2) * 255).rounded())
            }
        }
        return (small.width, small.height, rgb)
    }

    /// A buffer that several threads write at once, each its own part.
    private struct SharedPointer<Pointee>: @unchecked Sendable {
        let base: UnsafeMutablePointer<Pointee>
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }
}
