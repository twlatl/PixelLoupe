import Foundation
import ImageIO

/// What a Smart Preview records about its original, inside the proxy file itself: a DNG's `DNGPrivateData`, a
/// HEIC's XMP. With it, a proxy can stand in for its original without the original (RAW-85).
nonisolated struct SmartPreviewInfo: Codable, Sendable, Equatable {
    /// How the proxy was made.
    enum Kind: String, Codable, Sendable {
        /// A camera RAW file (or one of PixelLoupe's own merges), decoded into a linear Rec. 2020 DNG.
        case linearDNG
        /// A DNG that was already demosaiced (iPhone ProRAW and the like), downsized with its own tags kept.
        case dngCopy
        /// Any other photo, as a HEIC.
        case image
    }

    /// Bumped when what a proxy holds changes, so older ones can be rebuilt.
    static let currentVersion = 1

    var version = SmartPreviewInfo.currentVersion
    var kind: Kind
    /// The original's full-resolution size, upright (what `DevelopSource.nativeSize` reports for it).
    var originalWidth: Int
    var originalHeight: Int
    /// The proxy's size over the original's: at most 1.
    var scale: Double
    /// The original when the proxy was made. A proxy whose original has changed since is stale.
    var sourceModificationDate: Date?
    var sourceSize: Int64
    /// The RAW engine's defaults for the original that the proxy can't infer (camera RAW files only).
    var shadowBias: Float?
    var localToneMapAmount: Float?
    /// Whether the original carries the camera's own lens profile, and whether it's applied in the proxy's pixels
    /// (for cameras whose RAW files always apply it).
    var hasBuiltInLensProfile = false
    var isBuiltInLensProfileApplied = false
    /// The brightness a camera RAW file's Smart Preview misses away from As Shot (camera RAW files only, RAW-121).
    var whiteBalance: SmartPreviewWhiteBalance?

    var originalSize: CGSize { CGSize(width: originalWidth, height: originalHeight) }

    /// The creator name a DNG's `DNGPrivateData` starts with, before the info's JSON.
    static let privateDataCreator = "PixelLoupe"
    /// Where a HEIC keeps the info, as XMP.
    static let xmpNamespace = "http://ns.pixegen.net/pixelloupe/smartpreview/1.0/"
    static let xmpPrefix = "pixelloupeSmartPreview"
    static let xmpPath = "\(xmpPrefix):Info"

    /// The info as `DNGPrivateData`: the creator name, a zero, then JSON.
    func dngPrivateData() throws -> [UInt8] {
        Array(Self.privateDataCreator.utf8) + [0] + Array(try JSONEncoder().encode(self))
    }

    init(
        kind: Kind, originalSize: CGSize, scale: Double, sourceModificationDate: Date?, sourceSize: Int64,
        shadowBias: Float? = nil, localToneMapAmount: Float? = nil,
        hasBuiltInLensProfile: Bool = false, isBuiltInLensProfileApplied: Bool = false
    ) {
        self.kind = kind
        originalWidth = Int(originalSize.width.rounded())
        originalHeight = Int(originalSize.height.rounded())
        self.scale = scale
        self.sourceModificationDate = sourceModificationDate
        self.sourceSize = sourceSize
        self.shadowBias = shadowBias
        self.localToneMapAmount = localToneMapAmount
        self.hasBuiltInLensProfile = hasBuiltInLensProfile
        self.isBuiltInLensProfileApplied = isBuiltInLensProfileApplied
    }

    /// Reads the info back from a Smart Preview, or nil when `url` isn't one PixelLoupe wrote.
    static func read(from url: URL) -> SmartPreviewInfo? {
        if url.pathExtension.lowercased() == "dng" {
            guard let file = TIFFFile(contentsOf: url), let entry = file.ifd0[50740], let bytes = file.bytes(entry),
                  let zero = bytes.firstIndex(of: 0),
                  String(decoding: bytes[bytes.startIndex..<zero], as: UTF8.self) == privateDataCreator
            else { return nil }
            return try? JSONDecoder().decode(SmartPreviewInfo.self, from: bytes[(zero + 1)...])
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let json = CGImageMetadataCopyStringValueWithPath(metadata, nil, xmpPath as CFString)
        else { return nil }
        return try? JSONDecoder().decode(SmartPreviewInfo.self, from: Data((json as String).utf8))
    }

    /// The original's size and modification date, for ``isCurrent(for:)``, read from the file system each time.
    static func fingerprint(of original: URL) -> (modified: Date?, size: Int64)? {
        FileManager.default.sizeAndModificationDate(atPath: original.path(percentEncoded: false)).map { ($0.modified, $0.size) }
    }

    /// Whether the proxy still matches `original`: same writer version, and the file hasn't changed since. An
    /// original that can't be read (offline) counts as unchanged, so its proxy keeps being used.
    func isCurrent(for original: URL) -> Bool {
        guard version == Self.currentVersion else { return false }
        guard let now = Self.fingerprint(of: original) else { return true }
        guard now.size == sourceSize else { return false }
        switch (now.modified, sourceModificationDate) {
        case let (modified?, recorded?): return abs(modified.timeIntervalSince(recorded)) < 1
        default: return true
        }
    }
}
