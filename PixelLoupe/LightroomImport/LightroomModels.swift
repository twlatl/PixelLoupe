import Foundation

// Typed rows from a Lightroom Classic catalog. They mirror the catalog's columns, with Lightroom's
// loosely typed values (`rating` is stored as `4.0`) converted to Swift types. Interpreting them is
// the job of the import phases.

/// A row of `Adobe_images`: a photo, or a virtual copy when `masterImage` is set.
nonisolated struct LRImage: Sendable, Equatable {
    var id: Int
    var globalID: String
    /// `AgLibraryFile.id_local` of the original file.
    var rootFile: Int
    /// Local wall-clock time as Lightroom stores it (`2012-09-11T18:20:23`), without a time zone.
    var captureTime: String?
    /// Lightroom's orientation code (`AB` is upright; other values rotate or mirror).
    var orientation: String?
    var rating: Int?
    /// 1 flagged as pick, 0 unflagged, -1 rejected.
    var pick: Int
    /// The colour label name such as `Red`, or empty. Newer catalogs may store a localized name.
    var colorLabels: String
    /// For a virtual copy, the `id_local` of the master photo.
    var masterImage: Int?
    var copyName: String?
    var fileFormat: String
    var fileWidth: Int?
    var fileHeight: Int?
    /// Seconds since 2001-01-01 (Core Data's reference date) of the last change.
    var touchTime: Double

    var isVirtualCopy: Bool { masterImage != nil && masterImage != id }

    /// `captureTime` read as a UTC date. It is wall-clock time, so callers that need the true
    /// instant must apply the photo's own time zone (not stored in the catalog). See
    /// ``LightroomDates/localDate(fromCaptureTime:)`` for the local-time reading Lightroom uses.
    var captureDate: Date? {
        guard let captureTime else { return nil }
        let parts = captureTime.split(whereSeparator: { "-T:".contains($0) })
        guard parts.count == 6, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let hour = Int(parts[3]), let minute = Int(parts[4]), let second = Double(parts[5]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        // Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return Date(timeIntervalSince1970: Double(days * 86_400 + hour * 3_600 + minute * 60) + second)
    }
}

/// A photo with the file and import details needed to create its PixelLoupe record in one row.
nonisolated struct LRPhotoRecord: Sendable, Equatable {
    var image: LRImage
    /// `AgLibraryFile.idx_filename`: the file's name with extension.
    var fileName: String
    var fileExtension: String
    /// `AgLibraryFolder.id_local` of the file's folder.
    var folder: Int
    var sidecarExtensions: String?
    /// When the photo was first imported into Lightroom (ISO-8601 with an offset), if recorded.
    var importDate: String?
    /// The capture time before any capture-time edit, if different.
    var originalCaptureTime: String?
    /// Camera and lens Lightroom harvested from the file, for photos whose file can't be read.
    var harvestedCameraModel: String?
    var harvestedLens: String?
    /// Exposure details Lightroom harvested (ISO, focal length in mm, f-number, seconds), 0 if unknown.
    var harvestedISO = 0
    var harvestedFocalLength = 0.0
    var harvestedAperture = 0.0
    var harvestedShutterSpeed = 0.0
    var hasGPS = false
    /// Whether the photo is developed in black and white (`Adobe_imageDevelopSettings.grayscale`).
    var isGrayscale = false
    /// For a video (`AgVideoInfo`): its length in seconds, poster frame and trim points as Lightroom
    /// stores them (`numerator/denominator`, in hex).
    var videoDuration = 0.0
    var videoPoster: String?
    var videoTrimStart: String?
    var videoTrimEnd: String?
}

/// IPTC/XMP metadata and location for a photo, from `metadata`-style rows plus the harvested GPS.
nonisolated struct LRMetadataRecord: Sendable, Equatable {
    var metadata: LRMetadata
    var gpsLatitude: Double?
    var gpsLongitude: Double?
}

/// A row of `AgLibraryFile`: a file on disk that Lightroom knows about.
nonisolated struct LRFile: Sendable, Equatable {
    var id: Int
    var globalID: String
    var baseName: String
    var fileExtension: String
    var originalFilename: String
    /// `AgLibraryFolder.id_local`.
    var folder: Int
    var md5: String?
    /// Comma-separated sidecar extensions (`xmp`, `acr`, …).
    var sidecarExtensions: String?
    var modTime: Double?

    /// The file's name on disk, including extension.
    var fileName: String { fileExtension.isEmpty ? baseName : baseName + "." + fileExtension }
}

/// A row of `AgLibraryFolder`.
nonisolated struct LRFolder: Sendable, Equatable {
    var id: Int
    var globalID: String
    var parentID: Int?
    /// Path below the root folder, with a trailing slash (`2020/Trip/`), or empty for the root itself.
    var pathFromRoot: String
    var rootFolder: Int
    /// Lightroom's `visibility` for the folder, when it sets one.
    var visibility: String?
}

/// A row of `AgLibraryRootFolder`: a top-level folder Lightroom watches.
nonisolated struct LRRootFolder: Sendable, Equatable {
    var id: Int
    var globalID: String
    /// Absolute path with a trailing slash, as it was when the catalog was last used.
    var absolutePath: String
    var name: String
    var relativePathFromCatalog: String?
}

nonisolated struct LRKeyword: Sendable, Equatable {
    var id: Int
    var globalID: String
    var name: String
    var parent: Int?
    /// Slash-separated `id_local` path from the root keyword, e.g. `/564689/6123274`.
    var genealogy: String
    /// Lightroom's keyword type (for example `person` for face keywords); empty for plain keywords.
    var keywordType: String?
    var includeOnExport: Bool
    var includeParents: Bool
    var includeSynonyms: Bool
}

nonisolated struct LRKeywordSynonym: Sendable, Equatable {
    var keyword: Int
    var name: String
}

/// One keyword applied to one photo (`AgLibraryKeywordImage`).
nonisolated struct LRKeywordAssignment: Sendable, Equatable {
    var image: Int
    var keyword: Int
}

nonisolated struct LRCollection: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case collection
        case smartCollection
        /// A collection set: a folder of collections.
        case set
        /// Lightroom's own bookkeeping (Quick Collection, targets, …) and anything unrecognised.
        case system(String)
    }

    var id: Int
    var creationID: String
    var name: String
    var parent: Int?
    var genealogy: String
    /// Non-empty for collections Lightroom creates itself, such as the Quick Collection.
    var systemOnly: Bool

    var kind: Kind {
        switch creationID {
        case "com.adobe.ag.library.collection": systemOnly ? .system(creationID) : .collection
        case "com.adobe.ag.library.smart_collection": .smartCollection
        case "com.adobe.ag.library.group": .set
        default: .system(creationID)
        }
    }
}

/// One photo in a collection, in Lightroom's custom sort order.
nonisolated struct LRCollectionImage: Sendable, Equatable {
    var collection: Int
    var image: Int
    /// Lightroom's order key: usually text such as `---0`, `---1` … `---A` (compared as bytes), in older
    /// catalogs a number. `nil` for photos that were never put in an order.
    var position: String?
    var positionNumber: Double?

    /// Whether `self` comes before `other` in the collection's custom order. Ordered photos come first
    /// (numbers by value, text by bytes); the rest follow in the order they were added.
    static func isOrdered(_ lhs: (item: LRCollectionImage, arrival: Int), before rhs: (item: LRCollectionImage, arrival: Int)) -> Bool {
        switch (lhs.item.positionNumber, lhs.item.position, rhs.item.positionNumber, rhs.item.position) {
        case (let left?, _, let right?, _): return left != right ? left < right : lhs.arrival < rhs.arrival
        case (_, let left?, _, let right?):
            return left != right ? Array(left.utf8).lexicographicallyPrecedes(Array(right.utf8)) : lhs.arrival < rhs.arrival
        default:
            let leftHas = lhs.item.positionNumber != nil || lhs.item.position != nil
            let rightHas = rhs.item.positionNumber != nil || rhs.item.position != nil
            if leftHas != rightHas { return leftHas }
            return lhs.arrival < rhs.arrival
        }
    }
}

/// The Lua `content` of a collection, which holds a smart collection's rules.
nonisolated struct LRCollectionContent: Sendable, Equatable {
    var collection: Int
    var owningModule: String?
    /// Lua text; parse with ``LuaTableParser``.
    var text: String

    func parsed() throws -> LuaValue { try LuaTableParser.parse(text) }
}

nonisolated struct LRStack: Sendable, Equatable {
    var id: Int
    var globalID: String
    var collapsed: Bool
}

/// One photo in a stack. Position 1 is the top of the stack.
nonisolated struct LRStackImage: Sendable, Equatable {
    var stack: Int
    var image: Int
    /// Lightroom's order key (text such as `---0`, or a number in older catalogs); the lowest is the top.
    var position: String?
    var positionNumber: Double?
}

/// Develop settings for a photo (`Adobe_imageDevelopSettings`). The Lua text is parsed on demand,
/// since parsing every photo's settings is expensive and most callers need only some.
nonisolated struct LRDevelopSettings: Sendable, Equatable {
    var image: Int
    var processVersion: String?
    var whiteBalance: String?
    var grayscale: Bool
    var hasMasks: Bool
    var hasAIMasks: Bool
    var hasPointColor: Bool
    var hasLensBlur: Bool
    /// The settings reference data in the catalog's `-data` folder (a RocksDB store) that we don't read.
    var hasBigData: Bool
    /// Lua text of the settings table, or `nil` for a photo without a settings record.
    var text: String?

    func parsed() throws -> LuaValue? {
        guard let text, !text.isEmpty else { return nil }
        return try LuaTableParser.parse(text)
    }
}

/// A face region and the keyword it was named with (`AgLibraryFace` joined to `AgLibraryKeywordFace`).
nonisolated struct LRFaceRow: Sendable, Equatable {
    var id: Int
    var image: Int
    /// The corners, as fractions of the photo.
    var topLeft: (x: Double, y: Double)
    var topRight: (x: Double, y: Double)
    var bottomLeft: (x: Double, y: Double)
    var bottomRight: (x: Double, y: Double)
    var cluster: Int?
    var isIgnored: Bool
    /// The person keyword linked to the face, with whether a person picked or rejected it.
    var keyword: Int?
    var isPicked: Bool
    var isRejected: Bool

    static func == (lhs: LRFaceRow, rhs: LRFaceRow) -> Bool {
        lhs.id == rhs.id && lhs.image == rhs.image && lhs.keyword == rhs.keyword && lhs.topLeft == rhs.topLeft && lhs.bottomRight == rhs.bottomRight
    }

    /// The smallest rectangle holding the corners.
    var bounds: (x: Double, y: Double, width: Double, height: Double) {
        let xs = [topLeft.x, topRight.x, bottomLeft.x, bottomRight.x], ys = [topLeft.y, topRight.y, bottomLeft.y, bottomRight.y]
        let (minX, maxX, minY, maxY) = (xs.min() ?? 0, xs.max() ?? 0, ys.min() ?? 0, ys.max() ?? 0)
        return (minX, minY, maxX - minX, maxY - minY)
    }
}

/// An entry in a photo's Develop history (`Adobe_libraryImageDevelopHistoryStep`).
nonisolated struct LRHistoryStep: Sendable, Equatable {
    var id: Int
    var image: Int
    var name: String?
    var dateCreated: Double?
    var hasBigData: Bool
    var text: String?

    func parsed() throws -> LuaValue? {
        guard let text, !text.isEmpty else { return nil }
        return try LuaTableParser.parse(text)
    }
}

/// A Develop snapshot (`Adobe_libraryImageDevelopSnapshot`).
nonisolated struct LRSnapshot: Sendable, Equatable {
    var id: Int
    var image: Int
    var name: String?
    var locked: Bool
    var hasBigData: Bool
    var text: String?

    func parsed() throws -> LuaValue? {
        guard let text, !text.isEmpty else { return nil }
        return try LuaTableParser.parse(text)
    }
}

/// Text metadata for a photo: IPTC caption and copyright, plus the raw XMP packet.
nonisolated struct LRMetadata: Sendable, Equatable {
    var image: Int
    var caption: String?
    var copyright: String?
    /// The XMP packet as Lightroom stores it: a four-byte big-endian length followed by a zlib stream.
    /// See ``xmpPacket()``.
    var compressedXMP: Data?

    /// The XMP packet as UTF-8 text, or `nil` if the photo has none or it can't be decoded.
    func xmpPacket() -> String? {
        guard let compressedXMP else { return nil }
        return LightroomXMP.decode(compressedXMP)
    }
}

/// Camera data Lightroom harvested from the file (`AgHarvestedExifMetadata`).
nonisolated struct LRExif: Sendable, Equatable {
    var image: Int
    var cameraModel: String?
    var cameraSerial: String?
    var lens: String?
    var aperture: Double?
    var shutterSpeed: Double?
    var isoSpeed: Double?
    var focalLength: Double?
    var flashFired: Bool?
    var gpsLatitude: Double?
    var gpsLongitude: Double?
}

nonisolated struct LRFace: Sendable, Equatable {
    var id: Int
    var image: Int
    var cluster: Int?
    var ignored: Bool
    var regionType: Int
    /// Corner coordinates (0–1, relative to the image after orientation): top-left, top-right,
    /// bottom-left, bottom-right.
    var topLeft: LRPoint
    var topRight: LRPoint
    var bottomLeft: LRPoint
    var bottomRight: LRPoint
}

nonisolated struct LRPoint: Sendable, Equatable {
    var x: Double
    var y: Double
}

nonisolated struct LRVideoInfo: Sendable, Equatable {
    var image: Int
    var duration: Double?
    var frameRate: Double?
    var hasAudio: Bool
}
