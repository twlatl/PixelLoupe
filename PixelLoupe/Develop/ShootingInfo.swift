import Foundation
import ImageIO

/// How a photo was taken, from its EXIF: shown under the histogram (ISO, focal length, aperture
/// and shutter speed) and used to pick and fit lens profiles.
nonisolated struct ShootingInfo: Equatable, Sendable {
    var iso: Int?
    var focalLength: Double?
    var aperture: Double?
    var exposureTime: Double?
    /// The focal length as on a 35 mm (full-frame) camera, which gives the sensor's crop factor.
    var focalLength35mm: Double?
    /// Focus distance in meters.
    var subjectDistance: Double?

    init(iso: Int? = nil, focalLength: Double? = nil, aperture: Double? = nil, exposureTime: Double? = nil,
         focalLength35mm: Double? = nil, subjectDistance: Double? = nil) {
        self.iso = iso
        self.focalLength = focalLength
        self.aperture = aperture
        self.exposureTime = exposureTime
        self.focalLength35mm = focalLength35mm
        self.subjectDistance = subjectDistance
    }

    /// The camera's crop factor, when the file records both focal lengths.
    var cropFactor: Double? {
        guard let focalLength, focalLength > 0, let focalLength35mm, focalLength35mm > 0 else { return nil }
        return focalLength35mm / focalLength
    }

    init(properties: [CFString: Any]) {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
            ?? (exif[kCGImagePropertyExifRecommendedExposureIndex] as? Int)
        focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
        aperture = exif[kCGImagePropertyExifFNumber] as? Double
        exposureTime = exif[kCGImagePropertyExifExposureTime] as? Double
        focalLength35mm = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Double).flatMap { $0 > 0 ? $0 : nil }
        subjectDistance = (exif[kCGImagePropertyExifSubjectDistance] as? Double).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Reads the settings without decoding the photo.
    static func read(from url: URL) -> ShootingInfo {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        else { return ShootingInfo() }
        return ShootingInfo(properties: properties)
    }

    var isoText: String? { iso.map { "ISO \($0)" } }

    var focalLengthText: String? {
        focalLength.map { "\(Self.number($0)) mm" }
    }

    var apertureText: String? {
        aperture.map { "ƒ / \(Self.number($0))" }
    }

    var exposureTimeText: String? {
        guard let exposureTime, exposureTime > 0 else { return nil }
        if exposureTime < 0.4 {
            return "1/\(Int((1 / exposureTime).rounded())) sec"
        }
        return "\(Self.number(exposureTime)) sec"
    }

    /// Up to one decimal place, without a trailing ".0".
    private static func number(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}
