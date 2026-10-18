import Foundation
import ImageIO

/// The metadata fields a photo's file provides, formatted for the Metadata panel: EXIF, TIFF,
/// GPS, IPTC, DNG and XMP. Read without decoding the photo; editable fields (Title, Caption…) come
/// from here until something is typed into the catalog.
nonisolated struct FileMetadata: Sendable, Equatable {
    var values: [MetadataField.ID: String] = [:]
    /// The photo's location, for Show on Map.
    var coordinate: (latitude: Double, longitude: Double)?

    static func == (lhs: FileMetadata, rhs: FileMetadata) -> Bool {
        lhs.values == rhs.values && lhs.coordinate?.latitude == rhs.coordinate?.latitude
            && lhs.coordinate?.longitude == rhs.coordinate?.longitude
    }

    subscript(id: MetadataField.ID) -> String? { values[id] }

    static func read(from url: URL) -> FileMetadata {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0 else { return FileMetadata() }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] ?? [:]
        var metadata = FileMetadata(properties: properties)
        if let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
            metadata.merge(xmp: xmp)
        }
        return metadata
    }

    init() {}

    init(properties: [CFString: Any]) {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let dng = properties[kCGImagePropertyDNGDictionary] as? [CFString: Any]

        func set(_ id: MetadataField.ID, _ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)),
                  !value.isEmpty else { return }
            values[id] = value
        }
        func string(_ dictionary: [CFString: Any], _ key: CFString) -> String? {
            switch dictionary[key] {
            case let string as String: string
            case let strings as [String]: strings.joined(separator: ", ")
            case let number as NSNumber: number.stringValue
            default: nil
            }
        }
        func number(_ dictionary: [CFString: Any], _ key: CFString) -> Double? {
            (dictionary[key] as? NSNumber)?.doubleValue ?? (dictionary[key] as? [NSNumber])?.first?.doubleValue
        }

        // Dates.
        set(.dateTimeOriginal, Self.formatDate(string(exif, kCGImagePropertyExifDateTimeOriginal),
                                               subseconds: string(exif, kCGImagePropertyExifSubsecTimeOriginal)))
        set(.dateTimeDigitized, Self.formatDate(string(exif, kCGImagePropertyExifDateTimeDigitized),
                                                subseconds: string(exif, kCGImagePropertyExifSubsecTimeDigitized)))
        set(.dateTime, Self.formatDate(string(tiff, kCGImagePropertyTIFFDateTime), subseconds: string(exif, kCGImagePropertyExifSubsecTime)))

        // Exposure.
        let shooting = ShootingInfo(properties: properties)
        if let time = shooting.exposureTimeText {
            set(.exposure, shooting.apertureText.map { "\(time) at \($0)" } ?? time)
        }
        set(.focalLength, shooting.focalLengthText)
        set(.focalLength35mm, shooting.focalLength35mm.map { "\(Int($0.rounded())) mm" })
        set(.isoSpeedRating, shooting.isoText)
        set(.brightnessValue, number(exif, kCGImagePropertyExifBrightnessValue).map { String(format: "%.2f", $0) })
        if let bias = number(exif, kCGImagePropertyExifExposureBiasValue) {
            let rounded = (bias * 100).rounded() / 100
            set(.exposureBias, rounded == 0 ? "0 EV" : String(format: "%+g EV", rounded))
        }
        if let flash = number(exif, kCGImagePropertyExifFlash) {
            set(.flash, Int(flash) & 1 == 1 ? "Did fire" : "Did not fire")
        }
        set(.exposureProgram, number(exif, kCGImagePropertyExifExposureProgram).flatMap { Self.exposurePrograms[Int($0)] })
        set(.meteringMode, number(exif, kCGImagePropertyExifMeteringMode).flatMap { Self.meteringModes[Int($0)] })

        // Camera.
        set(.make, string(tiff, kCGImagePropertyTIFFMake))
        set(.model, string(tiff, kCGImagePropertyTIFFModel))
        set(.camera, Self.cameraName(make: string(tiff, kCGImagePropertyTIFFMake), model: string(tiff, kCGImagePropertyTIFFModel)))
        set(.serialNumber, string(exif, kCGImagePropertyExifBodySerialNumber))
        set(.lens, string(exif, kCGImagePropertyExifLensModel))
        set(.artist, string(tiff, kCGImagePropertyTIFFArtist))
        set(.software, string(tiff, kCGImagePropertyTIFFSoftware))
        set(.userComment, string(exif, kCGImagePropertyExifUserComment))

        // Location.
        if let latitude = number(gps, kCGImagePropertyGPSLatitude), let longitude = number(gps, kCGImagePropertyGPSLongitude) {
            let lat = (string(gps, kCGImagePropertyGPSLatitudeRef) == "S" ? -1 : 1) * latitude
            let lon = (string(gps, kCGImagePropertyGPSLongitudeRef) == "W" ? -1 : 1) * longitude
            coordinate = (lat, lon)
            set(.gps, Self.formatCoordinate(latitude: lat, longitude: lon))
        }
        if let altitude = number(gps, kCGImagePropertyGPSAltitude) {
            let below = (gps[kCGImagePropertyGPSAltitudeRef] as? NSNumber)?.intValue == 1
            set(.altitude, String(format: "%.1f m", below ? -altitude : altitude))
        }
        set(.direction, number(gps, kCGImagePropertyGPSImgDirection).map { String(format: "%.1f°", $0) })

        // DNG.
        set(.dngVersion, dng.flatMap { Self.version($0[kCGImagePropertyDNGVersion]) } ?? "Unknown")
        set(.dngCompatibility, dng.flatMap { Self.version($0[kCGImagePropertyDNGBackwardVersion]) } ?? "Unknown")
        set(.compatibility, dng.flatMap { Self.version($0[kCGImagePropertyDNGBackwardVersion]) }.map { "DNG \($0)" } ?? "Unknown")

        // IPTC (XMP, merged afterwards, wins).
        set(.title, string(iptc, kCGImagePropertyIPTCObjectName))
        set(.caption, string(iptc, kCGImagePropertyIPTCCaptionAbstract))
        set(.copyright, string(iptc, kCGImagePropertyIPTCCopyrightNotice) ?? string(tiff, kCGImagePropertyTIFFCopyright))
        set(.creator, string(iptc, kCGImagePropertyIPTCByline) ?? string(tiff, kCGImagePropertyTIFFArtist))
        set(.creatorJobTitle, string(iptc, kCGImagePropertyIPTCBylineTitle))
        set(.headline, string(iptc, kCGImagePropertyIPTCHeadline))
        set(.city, string(iptc, kCGImagePropertyIPTCCity))
        set(.state, string(iptc, kCGImagePropertyIPTCProvinceState))
        set(.country, string(iptc, kCGImagePropertyIPTCCountryPrimaryLocationName))
        set(.isoCountryCode, string(iptc, kCGImagePropertyIPTCCountryPrimaryLocationCode))
        set(.sublocation, string(iptc, kCGImagePropertyIPTCSubLocation))
        set(.creditLine, string(iptc, kCGImagePropertyIPTCCredit))
        set(.source, string(iptc, kCGImagePropertyIPTCSource))
        set(.instructions, string(iptc, kCGImagePropertyIPTCSpecialInstructions))
        set(.jobIdentifier, string(iptc, kCGImagePropertyIPTCOriginalTransmissionReference))
        set(.descriptionWriter, string(iptc, kCGImagePropertyIPTCWriterEditor))
        set(.category, string(iptc, kCGImagePropertyIPTCCategory))
        set(.otherCategories, string(iptc, kCGImagePropertyIPTCSupplementalCategory))
        set(.dateCreated, string(iptc, kCGImagePropertyIPTCDateCreated))
    }

    /// XMP paths for fields that XMP describes, in order of preference.
    static let xmpPaths: [MetadataField.ID: [String]] = [
        .title: ["dc:title"], .caption: ["dc:description"], .copyright: ["dc:rights"], .creator: ["dc:creator"],
        .headline: ["photoshop:Headline"], .city: ["photoshop:City"], .state: ["photoshop:State"],
        .country: ["photoshop:Country"], .isoCountryCode: ["Iptc4xmpCore:CountryCode"],
        .sublocation: ["Iptc4xmpCore:Location"], .creditLine: ["photoshop:Credit"], .source: ["photoshop:Source"],
        .instructions: ["photoshop:Instructions"], .jobIdentifier: ["photoshop:TransmissionReference"],
        .descriptionWriter: ["photoshop:CaptionWriter"], .category: ["photoshop:Category"],
        .otherCategories: ["photoshop:SupplementalCategories"], .dateCreated: ["photoshop:DateCreated"],
        .intellectualGenre: ["Iptc4xmpCore:IntellectualGenre"], .scene: ["Iptc4xmpCore:Scene"],
        .iptcSubjectCode: ["Iptc4xmpCore:SubjectCode"], .rightsUsageTerms: ["xmpRights:UsageTerms"],
        .copyrightInfoURL: ["xmpRights:WebStatement"], .label: ["xmp:Label"], .metadataDate: ["xmp:MetadataDate"],
        .creatorJobTitle: ["photoshop:AuthorsPosition"],
        .creatorAddress: ["Iptc4xmpCore:CreatorContactInfo/Iptc4xmpCore:CiAdrExtadr"],
        .creatorCity: ["Iptc4xmpCore:CreatorContactInfo/Iptc4xmpCore:CiAdrCity"],
        .creatorState: ["Iptc4xmpCore:CreatorContactInfo/Iptc4xmpCore:CiAdrRegion"],
        .creatorPostalCode: ["Iptc4xmpCore:CreatorContactInfo/Iptc4xmpCore:CiAdrPcode"],
        .creatorCountry: ["Iptc4xmpCore:CreatorContactInfo/Iptc4xmpCore:CiAdrCtry"],
        .creatorPhone: ["Iptc4xmpCore:CreatorContactInfo/Iptc4xmpCore:CiTelWork"],
        .creatorEmail: ["Iptc4xmpCore:CreatorContactInfo/Iptc4xmpCore:CiEmailWork"],
        .creatorWebsite: ["Iptc4xmpCore:CreatorContactInfo/Iptc4xmpCore:CiUrlWork"],
        .personShown: ["Iptc4xmpExt:PersonInImage"], .event: ["Iptc4xmpExt:Event"],
        .nameOfOrgShown: ["Iptc4xmpExt:OrganisationInImageName"], .codeOfOrgShown: ["Iptc4xmpExt:OrganisationInImageCode"],
        .additionalModelInfo: ["Iptc4xmpExt:AddlModelInfo"], .modelAge: ["Iptc4xmpExt:ModelAge"],
        .imageGUID: ["xmpMM:DocumentID"],
    ]

    mutating func merge(xmp: CGImageMetadata) {
        for (id, paths) in Self.xmpPaths {
            for path in paths {
                if let value = Self.xmpString(xmp, path), !value.isEmpty {
                    values[id] = value
                    break
                }
            }
        }
    }

    /// A tag's value as text: the default language of a language alternative, list items joined.
    static func xmpString(_ metadata: CGImageMetadata, _ path: String) -> String? {
        guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString) else { return nil }
        func text(_ value: CFTypeRef?) -> String? {
            switch value {
            case let string as String: return string
            case let tags as [CGImageMetadataTag]:
                let items = tags.compactMap { text(CGImageMetadataTagCopyValue($0)) }
                return items.isEmpty ? nil : CGImageMetadataTagGetType(tag) == .alternateText ? items.first : items.joined(separator: ", ")
            default: return nil
            }
        }
        return text(CGImageMetadataTagCopyValue(tag))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let exposurePrograms = [1: "Manual", 2: "Normal", 3: "Aperture Priority", 4: "Shutter Priority",
                                   5: "Creative", 6: "Action", 7: "Portrait", 8: "Landscape"]
    static let meteringModes = [1: "Average", 2: "Center Weighted Average", 3: "Spot", 4: "Multi-Spot",
                                5: "Pattern", 6: "Partial"]

    /// "Canon PowerShot SD780 IS" rather than "Canon Canon PowerShot SD780 IS".
    static func cameraName(make: String?, model: String?) -> String? {
        guard let model else { return make }
        guard let make, let brand = make.split(separator: " ").first,
              !model.lowercased().hasPrefix(brand.lowercased()) else { return model }
        return "\(brand.prefix(1).uppercased())\(brand.dropFirst().lowercased()) \(model)"
    }

    /// "1.4" from a DNG version ([1, 4, 0, 0]).
    static func version(_ value: Any?) -> String? {
        guard let parts = value as? [NSNumber], !parts.isEmpty else { return nil }
        var numbers = parts.map(\.intValue)
        while numbers.count > 2, numbers.last == 0 { numbers.removeLast() }
        return numbers.map(String.init).joined(separator: ".")
    }

    /// EXIF "2010:04:07 12:31:39" as a short date and time with milliseconds, like Lightroom.
    static func formatDate(_ exif: String?, subseconds: String?) -> String? {
        guard let exif else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard var date = parser.date(from: exif) else { return exif }
        if let subseconds, let fraction = Double("0." + subseconds.filter(\.isNumber)) {
            date += fraction
        }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate("Mdyy hmmssSSS a")
        return formatter.string(from: date)
    }

    /// 37°46′29.6″ N 122°25′9.8″ W
    static func formatCoordinate(latitude: Double, longitude: Double) -> String {
        func dms(_ value: Double, _ positive: String, _ negative: String) -> String {
            let absolute = abs(value)
            let degrees = Int(absolute), minutes = Int((absolute - Double(degrees)) * 60)
            let seconds = (absolute - Double(degrees) - Double(minutes) / 60) * 3600
            return String(format: "%d°%d′%.1f″ %@", degrees, minutes, seconds, value < 0 ? negative : positive)
        }
        return "\(dms(latitude, "N", "S")) \(dms(longitude, "E", "W"))"
    }
}
