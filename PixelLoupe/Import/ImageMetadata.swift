import Foundation
import ImageIO

/// The subset of EXIF/TIFF/IPTC/XMP metadata PixelLoupe catalogs.
nonisolated struct ImageMetadata: Equatable, Sendable {
    var captureDate: Date?
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var pixelWidth = 0
    var pixelHeight = 0
    var orientation = 1
    var keywords: [String] = []
    var isVideo = false
    /// A video's length in seconds.
    var duration = 0.0
    var iso = 0
    var focalLength = 0.0
    var aperture = 0.0
    var shutterSpeed = 0.0
    var hasGPS = false
    var title: String?
    var caption: String?
    var creator: String?
    var copyright: String?

    /// Reads metadata without decoding pixel data. Returns `nil` if the file isn't a readable image.
    static func read(from url: URL) -> ImageMetadata? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        else { return nil }

        var metadata = ImageMetadata(properties: properties)
        if let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            metadata.mergeKeywords(xmpKeywords(xmp))
        }
        return metadata
    }

    init() {}

    init(properties: [CFString: Any]) {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1

        cameraMake = Self.clean(tiff[kCGImagePropertyTIFFMake] as? String)
        cameraModel = Self.clean(tiff[kCGImagePropertyTIFFModel] as? String)
        lensModel = Self.clean(exif[kCGImagePropertyExifLensModel] as? String)
        let shooting = ShootingInfo(properties: properties)
        iso = shooting.iso ?? 0
        focalLength = shooting.focalLength ?? 0
        aperture = shooting.aperture ?? 0
        shutterSpeed = shooting.exposureTime ?? 0
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        hasGPS = gps[kCGImagePropertyGPSLatitude] != nil && gps[kCGImagePropertyGPSLongitude] != nil
        title = Self.clean(iptc[kCGImagePropertyIPTCObjectName] as? String)
        caption = Self.clean(iptc[kCGImagePropertyIPTCCaptionAbstract] as? String)
        creator = Self.clean(iptc[kCGImagePropertyIPTCByline] as? String) ?? Self.clean(tiff[kCGImagePropertyTIFFArtist] as? String)
        copyright = Self.clean(iptc[kCGImagePropertyIPTCCopyrightNotice] as? String) ?? Self.clean(tiff[kCGImagePropertyTIFFCopyright] as? String)

        if let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            captureDate = Self.parseExifDate(original, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
        } else if let digitized = exif[kCGImagePropertyExifDateTimeDigitized] as? String {
            captureDate = Self.parseExifDate(digitized, offset: exif[kCGImagePropertyExifOffsetTimeDigitized] as? String)
        } else if let tiffDate = tiff[kCGImagePropertyTIFFDateTime] as? String {
            captureDate = Self.parseExifDate(tiffDate, offset: nil)
        }

        switch iptc[kCGImagePropertyIPTCKeywords] {
        case let list as [String]: mergeKeywords(list)
        case let single as String: mergeKeywords([single])
        default: break
        }
    }

    mutating func mergeKeywords(_ newKeywords: [String]) {
        for keyword in newKeywords {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !keywords.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
            else { continue }
            keywords.append(trimmed)
        }
    }

    private static func xmpKeywords(_ metadata: CGImageMetadata) -> [String] {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "dc:subject" as CFString),
              let values = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag]
        else { return [] }
        return values.compactMap { CGImageMetadataTagCopyValue($0) as? String }
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Parses EXIF `yyyy:MM:dd HH:mm:ss` dates, honoring an optional `±HH:mm` offset.
    static func parseExifDate(_ string: String, offset: String?) -> Date? {
        let parts = string.split(whereSeparator: { $0 == ":" || $0 == " " }).compactMap { Int($0) }
        guard parts.count >= 6 else { return nil }
        var components = DateComponents(
            year: parts[0], month: parts[1], day: parts[2],
            hour: parts[3], minute: parts[4], second: parts[5]
        )
        components.timeZone = offset.flatMap(timeZone(fromOffset:)) ?? .current
        return Calendar(identifier: .gregorian).date(from: components)
    }

    private static func timeZone(fromOffset offset: String) -> TimeZone? {
        let sign: Int
        switch offset.first {
        case "+": sign = 1
        case "-": sign = -1
        default: return nil
        }
        let numbers = offset.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard numbers.count == 2 else { return nil }
        return TimeZone(secondsFromGMT: sign * (numbers[0] * 3600 + numbers[1] * 60))
    }
}

/// What smart collections search, from a file's metadata.
nonisolated extension ImageMetadata {
    struct Shooting: Sendable {
        var iso = 0
        var focalLength = 0.0
        var aperture = 0.0
        var shutterSpeed = 0.0
        var hasGPS = false
        var title: String?
        var caption: String?
        var creator: String?
        var copyright: String?
    }

    var shooting: Shooting {
        Shooting(
            iso: iso, focalLength: focalLength, aperture: aperture, shutterSpeed: shutterSpeed, hasGPS: hasGPS,
            title: title, caption: caption, creator: creator, copyright: copyright)
    }
}

nonisolated extension Photo {
    /// Copies the searchable shooting details and text into the photo.
    func apply(_ shooting: ImageMetadata.Shooting) {
        iso = Int32(clamping: shooting.iso)
        focalLength = shooting.focalLength
        aperture = shooting.aperture
        shutterSpeed = shooting.shutterSpeed
        hasGPS = shooting.hasGPS
        titleText = shooting.title
        captionText = shooting.caption
        creatorText = shooting.creator
        copyrightText = shooting.copyright
    }
}
