import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads Lightroom's rendered previews (`<Catalog> Previews.lrdata`), which already have the user's
/// edits applied, so the import can seed PixelLoupe's thumbnails without opening any original.
///
/// An `.lrprev` file is a series of blocks: a 32-byte header (`AgHg`, flags, the data length and the
/// padding length as big-endian 64-bit numbers, and an 8-byte name), then the data, then padding.
/// The first block, `header`, holds a Lua table describing the pyramid; each following block
/// (`level_1`, `level_2`, …) is one JPEG, smallest first.
nonisolated struct LightroomPreviewFile: Sendable, Equatable {
    struct Level: Sendable, Equatable {
        var name: String
        /// Pixel size of the stored JPEG (in the photo's own, unrotated frame).
        var width: Int
        var height: Int
        var dataOffset: UInt64
        var length: Int

        var longEdge: Int { max(width, height) }
    }

    var url: URL
    var levels: [Level]
    /// The size Lightroom rendered the preview for (before the photo's orientation is applied), if the
    /// header says. Compared with a level's shape, it shows a preview that is already turned.
    var croppedWidth: Int?
    var croppedHeight: Int?

    enum ReadError: Error, Equatable {
        case notAPreview
        case truncated
    }

    private static let magic = Array("AgHg".utf8)
    private static let headerSize: UInt64 = 32

    /// Reads the block structure of the file at `url`: a few small reads, no pixel data.
    static func read(at url: URL) throws -> LightroomPreviewFile {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset: UInt64 = 0
        var blocks: [(name: String, dataOffset: UInt64, length: Int)] = []
        while true {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: Int(headerSize)), !header.isEmpty else { break }
            guard header.count == Int(headerSize) else { throw ReadError.truncated }
            guard Array(header.prefix(4)) == magic else { throw ReadError.notAPreview }
            let length = header.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
            let padding = header.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self)) }
            guard length < 1 << 31, padding < 1 << 16 else { throw ReadError.notAPreview }
            let nameBytes = header.subdata(in: 24..<32).prefix { $0 != 0 }
            blocks.append((String(decoding: nameBytes, as: UTF8.self), offset + headerSize, Int(length)))
            offset += headerSize + length + padding
        }
        guard let first = blocks.first, first.name == "header" else { throw ReadError.notAPreview }

        // The header lists each level's size, in the order of the level blocks.
        try handle.seek(toOffset: first.dataOffset)
        let text = String(decoding: try handle.read(upToCount: first.length) ?? Data(), as: UTF8.self)
        let pyramid = try? LuaTableParser.parse(text)
        let sizes = (pyramid?["levels"]?.table?.array ?? []).compactMap { entry -> (Int, Int)? in
            guard let width = entry["width"]?.int, let height = entry["height"]?.int else { return nil }
            return (width, height)
        }
        let levelBlocks = blocks.dropFirst().filter { $0.name.hasPrefix("level_") }
        guard !levelBlocks.isEmpty, sizes.count >= levelBlocks.count else { throw ReadError.notAPreview }
        let levels = zip(levelBlocks, sizes).map { block, size in
            Level(name: block.name, width: size.0, height: size.1, dataOffset: block.dataOffset, length: block.length)
        }
        return LightroomPreviewFile(
            url: url, levels: levels, croppedWidth: pyramid?["croppedWidth"]?.int, croppedHeight: pyramid?["croppedHeight"]?.int)
    }

    /// The smallest level whose long edge is at least `minimumLongEdge`, or the largest there is.
    func bestLevel(minimumLongEdge: Int) -> Level? {
        let sorted = levels.sorted { $0.longEdge < $1.longEdge }
        return sorted.first { $0.longEdge >= minimumLongEdge } ?? sorted.last
    }

    /// The JPEG data of a level.
    func jpegData(for level: Level) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: level.dataOffset)
        guard let data = try handle.read(upToCount: level.length), data.count == level.length else { throw ReadError.truncated }
        return data
    }
}

/// Where Lightroom keeps previews, and how an image's preview is found.
nonisolated enum LightroomPreviews {
    /// `<Catalog> Previews.lrdata`, next to the catalog.
    static func folder(forCatalog catalog: URL) -> URL {
        let name = catalog.deletingPathExtension().lastPathComponent
        return catalog.deletingLastPathComponent().appending(path: "\(name) Previews.lrdata", directoryHint: .isDirectory)
    }

    /// `<hex>/<hex>/<uuid>-<digest>.lrprev`: the first character and the first four of the UUID.
    static func previewURL(uuid: String, digest: String, in folder: URL) -> URL {
        let id = uuid.uppercased()
        return folder
            .appending(path: String(id.prefix(1)), directoryHint: .isDirectory)
            .appending(path: String(id.prefix(4)), directoryHint: .isDirectory)
            .appending(path: "\(id)-\(digest).lrprev")
    }

    /// One row of the `previews.db` index: the preview file of an image and how it is oriented.
    struct Entry: Sendable, Equatable {
        var imageID: Int
        var uuid: String
        var digest: String
        /// Lightroom's orientation code for the preview, e.g. `DA`.
        var orientation: String?
    }

    static let thumbnailSize = ThumbnailStore.maxPixelSize
    /// A stored level up to this long is used as it is when no rotation is needed.
    private static let copyLimit = thumbnailSize + thumbnailSize / 16

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Writes the thumbnail for a preview to `destination`: the smallest level that is big enough,
    /// copied byte for byte when it needs no change, otherwise scaled to the thumbnail size and
    /// turned to Lightroom's orientation, then re-encoded.
    static func writeThumbnail(from file: LightroomPreviewFile, orientation: String?, to destination: URL) throws {
        guard let level = file.bestLevel(minimumLongEdge: thumbnailSize) else { throw LightroomPreviewFile.ReadError.notAPreview }
        let data = try file.jpegData(for: level)
        var exif = LightroomOrientation.exif(forCode: orientation) ?? 1
        // A few previews were saved already turned: their levels are portrait while the frame they
        // were rendered for is landscape (or the reverse). Don't turn those again.
        if let cropped = file.croppedWidth, let croppedHeight = file.croppedHeight, [5, 6, 7, 8].contains(exif),
           (level.width >= level.height) != (cropped >= croppedHeight) {
            exif = (exif == 5 || exif == 7) ? 2 : 1
        }
        if exif == 1, level.longEdge <= copyLimit {
            try data.write(to: destination, options: .atomic)
            return
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw LightroomPreviewFile.ReadError.notAPreview }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw LightroomPreviewFile.ReadError.notAPreview
        }
        if exif != 1 {
            let turned = CIImage(cgImage: image).oriented(forExifOrientation: Int32(exif))
            if let rendered = ciContext.createCGImage(turned, from: turned.extent) { image = rendered }
        }
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
    }
}
