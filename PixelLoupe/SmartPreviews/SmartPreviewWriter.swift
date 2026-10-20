import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes the Smart Preview of an original (RAW-85): a compact stand-in, 2560 px on the long edge, that Develop,
/// the Library and Export can use while the original is offline.
///
/// - A camera RAW file, or one of PixelLoupe's own merges, becomes a Linear DNG: the RAW engine's linear decode in
///   Rec. 2020 with the neutral at D65, as 16-bit JPEG XL tiles. The original's as-shot white balance goes in
///   `AsShotNeutral`, so Temperature and Tint mean the same on the proxy, and the RAW-stage controls still work.
/// - A DNG from another app that's already demosaiced (iPhone ProRAW, `LinearRaw`) becomes a downsized copy of
///   itself, keeping its own color profile, tone curve and gain map (see `SmartPreviewWriter+DNGCopy.swift`).
/// - Any other photo becomes a HEIC in its own color space, which Develop opens as it opens the original.
///
/// Each proxy carries a ``SmartPreviewInfo`` about its original. Videos get none.
nonisolated enum SmartPreviewWriter {
    /// The long edge of a Smart Preview, as Lightroom's.
    static let longEdge = 2560
    /// Apple's RAW engine doesn't open a DNG smaller than 100 KiB, whatever it holds, so smaller proxies are padded.
    static let smallestOpenableDNG = 102_400
    /// JPEG XL settings for the tiles (see the RAW-85 JPEG XL spike).
    static let tileSettings = JXLTileEncoder.Settings(distance: 0.5, effort: 7, decodingSpeed: 4)

    enum WriteError: Error, Equatable {
        /// Videos, and kinds of original that have no recipe yet.
        case unsupported
        case unreadable
        case unwritable
    }

    /// How a Smart Preview of `original` is made, or nil when it gets none.
    enum Recipe: Equatable {
        case linearDNG, dngCopy, image
    }

    static func recipe(for original: URL) -> Recipe? {
        if SupportedImageTypes.isVideo(original) { return nil }
        guard SupportedImageTypes.isRaw(original) else { return .image }
        // A DNG that's already demosaiced, from another app, keeps its own rendering data (RAW-118). PixelLoupe's
        // own merges are linear Rec. 2020 already, so the Linear DNG recipe reproduces them exactly.
        if original.pathExtension.lowercased() == "dng", let file = TIFFFile(contentsOf: original),
           let main = file.mainImage, let photometric = main[262], file.integers(photometric).first == 34892,
           file.ifd0[305].flatMap(file.string) != "PixelLoupe" {
            return .dngCopy
        }
        return .linearDNG
    }

    /// The file extension a Smart Preview of `original` has.
    static func fileExtension(for original: URL) -> String? {
        switch recipe(for: original) {
        case .linearDNG?, .dngCopy?: "dng"
        case .image?: "heic"
        case nil: nil
        }
    }

    /// Writes the Smart Preview of `original` to `destination`, replacing what's there, and returns what it records.
    /// Slow (a RAW decode and an encode): call it off the main thread.
    @discardableResult
    static func write(original: URL, to destination: URL) throws -> SmartPreviewInfo {
        guard let fingerprint = SmartPreviewInfo.fingerprint(of: original) else { throw WriteError.unreadable }
        switch recipe(for: original) {
        case .linearDNG?: return try writeLinearDNG(original, fingerprint: fingerprint, to: destination)
        case .image?: return try writeImage(original, fingerprint: fingerprint, to: destination)
        case .dngCopy?: return try writeDNGCopy(original, fingerprint: fingerprint, to: destination)
        case nil: throw WriteError.unsupported
        }
    }

    // MARK: - Linear DNG

    private static let linearRec2020 = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!
    private static let context = CIContext(options: [.workingColorSpace: linearRec2020, .cacheIntermediates: false])
    /// D65, where the proxy's pixels are white balanced (that is, not at all).
    private static let d65 = CGPoint(x: 0.3127, y: 0.3290)

    private static func writeLinearDNG(
        _ original: URL, fingerprint: (modified: Date?, size: Int64), to destination: URL
    ) throws -> SmartPreviewInfo {
        guard let raw = CIRAWFilter(imageURL: original), let full = raw.outputImage,
              !full.extent.isEmpty, !full.extent.isInfinite else { throw WriteError.unreadable }
        // The original's defaults, before the decode below changes them.
        let originalSize = full.extent.size
        let asShot = raw.neutralChromaticity
        let baselineExposure = Double(raw.baselineExposure)
        let hasLensProfile = raw.isLensCorrectionSupported
        let lensProfileApplied = hasLensProfile && raw.isLensCorrectionEnabled
        var info = SmartPreviewInfo(
            kind: .linearDNG, originalSize: originalSize, scale: 1, sourceModificationDate: fingerprint.modified,
            sourceSize: fingerprint.size, shadowBias: raw.shadowBias, localToneMapAmount: raw.localToneMapAmount,
            hasBuiltInLensProfile: hasLensProfile, isBuiltInLensProfileApplied: lensProfileApplied
        )

        // The linear decode: no look (exposure, tone boost, shadow bias, local tone mapping, gamut mapping), no
        // engine sharpening (the pipeline sharpens), and no white balance. The camera's default noise reduction
        // stays, and so does a built-in lens profile the camera always applies.
        let scale = min(1, Double(longEdge) / max(originalSize.width, originalSize.height))
        raw.scaleFactor = Float(scale)
        raw.exposure = 0
        raw.baselineExposure = 0
        raw.boostAmount = 0
        raw.shadowBias = 0
        raw.localToneMapAmount = 0
        raw.isGamutMappingEnabled = false
        raw.neutralChromaticity = d65
        if raw.isSharpnessSupported { raw.sharpnessAmount = 0 }
        if raw.isDetailSupported { raw.detailAmount = 0 }
        if hasLensProfile { raw.isLensCorrectionEnabled = lensProfileApplied }
        guard let decoded = raw.outputImage else { throw WriteError.unreadable }
        let extent = decoded.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0 else { throw WriteError.unreadable }
        info.scale = Double(max(width, height)) / Double(max(originalSize.width, originalSize.height))

        var linear = [Float](repeating: 0, count: width * height * 4)
        context.render(decoded, toBitmap: &linear, rowBytes: width * 16, bounds: extent, format: .RGBAf, colorSpace: linearRec2020)

        // Highlights above white are kept by bringing the brightest pixel down to white and adding the stops back
        // in BaselineExposure, as Photo Merge's DNGs do.
        var peak: Float = 0
        for index in stride(from: 0, to: linear.count, by: 4) {
            peak = max(peak, linear[index], linear[index + 1], linear[index + 2])
        }
        let headroom = LinearDNGWriter.headroom(peak: peak)
        let gain: Float = peak > 1 ? 65535 / peak : 65535
        var samples = [UInt16](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            for channel in 0..<3 {
                let value = linear[pixel * 4 + channel] * gain
                samples[pixel * 3 + channel] = value.isFinite ? UInt16(max(0, min(65535, value.rounded()))) : 0
            }
        }

        let tiles = try encodeTiles(samples, width: width, height: height)
        let metadata = dngMetadata(for: original)
        var ifd = TIFFDirectory()
        ifd.add(254, long: [0])
        ifd.add(256, long: [UInt32(width)])
        ifd.add(257, long: [UInt32(height)])
        ifd.add(258, short: [16, 16, 16])
        ifd.add(259, short: [52546])  // JPEG XL
        ifd.add(262, short: [34892])  // LinearRaw
        if let make = metadata.make { ifd.add(271, ascii: make) }
        if let model = metadata.model { ifd.add(272, ascii: model) }
        ifd.add(274, short: [1])
        ifd.add(277, short: [3])
        ifd.add(284, short: [1])
        ifd.add(305, ascii: "PixelLoupe")
        if let date = metadata.captureDate { ifd.add(306, ascii: LinearDNGWriter.exifDate(date, timeZone: metadata.timeZone)) }
        ifd.add(322, long: [UInt32(LinearDNGWriter.tileSize)])
        ifd.add(323, long: [UInt32(LinearDNGWriter.tileSize)])
        ifd.addTiles(offsets: tiles.offsets, counts: tiles.data.map { UInt32($0.count) })
        ifd.add(50706, byte: [1, 7, 0, 0])
        ifd.add(50707, byte: [1, 7, 0, 0])
        ifd.add(50708, ascii: [metadata.make, metadata.model].compactMap { $0 }.joined(separator: " ").nonEmpty ?? "PixelLoupe Smart Preview")
        ifd.add(50717, long: [65535])
        ifd.add(50721, srational: LinearDNGWriter.xyzToRec2020)
        ifd.add(50728, rational: rec2020Neutral(of: asShot))
        ifd.add(50730, srational: [baselineExposure + headroom])
        ifd.add(50740, byte: try info.dngPrivateData())
        ifd.add(50778, short: [21])  // D65
        ifd.add(51089, long: [UInt32(info.originalWidth), UInt32(info.originalHeight)])  // OriginalDefaultFinalSize
        ifd.add(52553, float: [tileSettings.distance])
        ifd.add(52554, long: [UInt32(tileSettings.effort)])
        ifd.add(52555, long: [UInt32(tileSettings.decodingSpeed)])

        var file = TIFFDirectory.prefix(ifd: ifd, exif: LinearDNGWriter.exif(for: metadata))
        for tile in tiles.data {
            file.append(tile)
            if tile.count % 2 == 1 { file.append(0) }
        }
        if file.count < smallestOpenableDNG { file.append(Data(count: smallestOpenableDNG - file.count)) }
        try replace(destination, with: file)
        return info
    }

    /// The tiles of `samples`, each a JPEG XL codestream, with their offsets from the first one's start (each padded
    /// to an even length). Tiles at the right and bottom edges repeat the last column and row.
    static func encodeTiles(_ samples: [UInt16], width: Int, height: Int) throws -> (data: [Data], offsets: [UInt32]) {
        let tile = LinearDNGWriter.tileSize
        let across = (width + tile - 1) / tile, down = (height + tile - 1) / tile
        let results = Tiles(count: across * down)
        DispatchQueue.concurrentPerform(iterations: across * down) { index in
            let left = (index % across) * tile, top = (index / across) * tile
            var block = [UInt16](repeating: 0, count: tile * tile * 3)
            for row in 0..<tile {
                let y = min(top + row, height - 1)
                for column in 0..<tile {
                    let from = (y * width + min(left + column, width - 1)) * 3, to = (row * tile + column) * 3
                    block[to] = samples[from]
                    block[to + 1] = samples[from + 1]
                    block[to + 2] = samples[from + 2]
                }
            }
            results.set(index, try? JXLTileEncoder.encode(block, width: tile, height: tile, settings: tileSettings))
        }
        var data: [Data] = [], offsets: [UInt32] = []
        var offset = 0
        for result in results.all {
            guard let result else { throw WriteError.unwritable }
            offsets.append(UInt32(offset))
            data.append(result)
            offset += result.count + result.count % 2
        }
        return (data, offsets)
    }

    /// Encoded tiles, collected from the threads that encode them.
    private final class Tiles: @unchecked Sendable {
        private let lock = NSLock()
        private var tiles: [Data?]

        init(count: Int) { tiles = Array(repeating: nil, count: count) }

        func set(_ index: Int, _ tile: Data?) { lock.withLock { tiles[index] = tile } }
        var all: [Data?] { lock.withLock { tiles } }
    }

    /// The as-shot neutral `chromaticity` (CIE xy) in the proxy's camera space, linear Rec. 2020, brightest channel 1.
    static func rec2020Neutral(of chromaticity: CGPoint) -> [Double] {
        let x = Double(chromaticity.x), y = max(Double(chromaticity.y), 1e-6)
        let xyz = [x / y, 1, (1 - x - y) / y]
        let m = LinearDNGWriter.xyzToRec2020
        let rgb = (0..<3).map { row in (0..<3).reduce(0) { $0 + m[row * 3 + $1] * xyz[$1] } }
        let largest = max(rgb.max() ?? 1, 1e-6)
        return rgb.map { max($0 / largest, 1e-4) }
    }

    /// The original's camera and capture details, for the proxy's TIFF and EXIF tags.
    private static func dngMetadata(for original: URL) -> DNGMetadata {
        guard let read = ImageMetadata.read(from: original) else { return DNGMetadata() }
        return DNGMetadata(
            make: read.cameraMake, model: read.cameraModel, lensModel: read.lensModel, captureDate: read.captureDate,
            timeZone: nil, exposureTime: read.shutterSpeed, aperture: read.aperture, iso: read.iso,
            focalLength: read.focalLength
        )
    }

    // MARK: - Other photos

    private static func writeImage(
        _ original: URL, fingerprint: (modified: Date?, size: Int64), to destination: URL
    ) throws -> SmartPreviewInfo {
        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int else { throw WriteError.unreadable }
        // Upright, as Develop shows it.
        let turned = (properties[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
        let originalSize = turned ? CGSize(width: pixelHeight, height: pixelWidth) : CGSize(width: pixelWidth, height: pixelHeight)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw WriteError.unreadable
        }
        let info = SmartPreviewInfo(
            kind: .image, originalSize: originalSize,
            scale: Double(max(image.width, image.height)) / Double(max(originalSize.width, originalSize.height)),
            sourceModificationDate: fingerprint.modified, sourceSize: fingerprint.size
        )

        let metadata = CGImageMetadataCreateMutable()
        guard CGImageMetadataRegisterNamespaceForPrefix(
                metadata, SmartPreviewInfo.xmpNamespace as CFString, SmartPreviewInfo.xmpPrefix as CFString, nil
              ),
              let json = String(data: try JSONEncoder().encode(info), encoding: .utf8),
              CGImageMetadataSetValueWithPath(metadata, nil, SmartPreviewInfo.xmpPath as CFString, json as CFString)
        else { throw WriteError.unwritable }
        let output = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(output, UTType.heic.identifier as CFString, 1, nil) else {
            throw WriteError.unwritable
        }
        CGImageDestinationAddImageAndMetadata(writer, image, metadata, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw WriteError.unwritable }
        try replace(destination, with: output as Data)
        return info
    }

    // MARK: - Files

    /// Writes `data` to a temporary file next to `destination`, then moves it into place, so a reader never sees a
    /// half-written proxy.
    static func replace(_ destination: URL, with data: Data) throws {
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(UUID().uuidString)-\(destination.lastPathComponent)")
        do {
            try data.write(to: temporary)
            if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw WriteError.unwritable
        }
    }
}
