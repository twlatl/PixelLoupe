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
    /// Where the photo was taken, from the GPS metadata.
    var location: GPSCoordinate?
    /// Metres above sea level (negative below).
    var altitude: Double?
    var hasGPS: Bool { location != nil }
    var title: String?
    var caption: String?
    var creator: String?
    var copyright: String?
    /// The file's own rating (`xmp:Rating`): 1–5 stars, or -1 for a photo rejected in the camera or
    /// another app. `nil` when it has none.
    var rating: Int?

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
            metadata.rating = xmpRating(xmp)
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
        lensModel = Self.lensModel(properties)
        let shooting = ShootingInfo(properties: properties)
        iso = shooting.iso ?? 0
        focalLength = shooting.focalLength ?? 0
        aperture = shooting.aperture ?? 0
        shutterSpeed = shooting.exposureTime ?? 0
        (location, altitude) = Self.location(properties)
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

    static func xmpRating(_ metadata: CGImageMetadata) -> Int? {
        guard let text = CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:Rating" as CFString) as String?,
              let value = Double(text.trimmingCharacters(in: .whitespaces)) else { return nil }
        let rating = Int(value.rounded())
        return (-1...5).contains(rating) && rating != 0 ? rating : nil
    }

    /// The GPS position and altitude, with the signs the reference fields give them.
    static func location(_ properties: [CFString: Any]) -> (GPSCoordinate?, Double?) {
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        func number(_ key: CFString) -> Double? { (gps[key] as? NSNumber)?.doubleValue }
        var coordinate: GPSCoordinate?
        if let latitude = number(kCGImagePropertyGPSLatitude), let longitude = number(kCGImagePropertyGPSLongitude) {
            coordinate = GPSCoordinate(latitude: (gps[kCGImagePropertyGPSLatitudeRef] as? String == "S" ? -1 : 1) * latitude,
                                       longitude: (gps[kCGImagePropertyGPSLongitudeRef] as? String == "W" ? -1 : 1) * longitude)
        }
        let below = (gps[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue == 1
        return (coordinate, number(kCGImagePropertyGPSAltitude).map { below ? -$0 : $0 })
    }

    /// The lens name. Standard EXIF has it in LensModel, but cameras that only record it in their
    /// maker notes (Nikon NEFs, for one) have ImageIO put it under {ExifAux} instead.
    static func lensModel(_ properties: [CFString: Any]) -> String? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        return clean(exif[kCGImagePropertyExifLensModel] as? String) ?? clean(aux[kCGImagePropertyExifAuxLensModel] as? String)
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
        var location: GPSCoordinate?
        var altitude: Double?
        var title: String?
        var caption: String?
        var creator: String?
        var copyright: String?
    }

    var shooting: Shooting {
        Shooting(
            iso: iso, focalLength: focalLength, aperture: aperture, shutterSpeed: shutterSpeed, location: location, altitude: altitude,
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
        setFileLocation(shooting.location, altitude: shooting.altitude)
        titleText = shooting.title
        captionText = shooting.caption
        creatorText = shooting.creator
        copyrightText = shooting.copyright
    }
}
