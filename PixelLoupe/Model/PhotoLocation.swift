import CoreData
import Foundation

/// A position on Earth, in degrees (north and east positive).
nonisolated struct GPSCoordinate: Equatable, Sendable {
    var latitude: Double
    var longitude: Double

    init?(latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Reads a typed location: the Metadata panel's degrees-minutes-seconds form
    /// (`37°46′29.6″ N 122°25′9.8″ W`), or decimal degrees (`37.7749, -122.4194`).
    init?(parsing text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let decimal = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        if decimal.count == 2, let latitude = decimal[0], let longitude = decimal[1] {
            self.init(latitude: latitude, longitude: longitude)
            return
        }
        let parts = text.matches(of: /(\d+(?:\.\d+)?)°\s*(?:(\d+(?:\.\d+)?)′\s*)?(?:(\d+(?:\.\d+)?)″\s*)?([NSEW])/).map { match in
            let value = Double(match.1)! + (match.2.flatMap { Double($0) } ?? 0) / 60 + (match.3.flatMap { Double($0) } ?? 0) / 3600
            return (value: match.4 == "S" || match.4 == "W" ? -value : value, isLatitude: match.4 == "N" || match.4 == "S")
        }
        guard parts.count == 2, parts[0].isLatitude, !parts[1].isLatitude else { return nil }
        self.init(latitude: parts[0].value, longitude: parts[1].value)
    }

    /// As the Metadata panel shows it, in degrees, minutes and seconds.
    var formatted: String { FileMetadata.formatCoordinate(latitude: latitude, longitude: longitude) }
}

/// A location typed into the catalog for a photo, overriding its file's (`Photo.locationOverride`).
/// Original files are never changed.
nonisolated enum LocationOverride: Int16, Sendable {
    /// The file's location (or none) is used.
    case file = 0
    /// `overrideLatitude` and `overrideLongitude` are used.
    case set = 1
    /// The photo has no location, whatever its file says.
    case cleared = 2
}

nonisolated extension Photo {
    /// The location recorded in the file (once read; see `locationRead`).
    var fileLocation: GPSCoordinate? {
        guard let latitude = fileLatitude?.doubleValue, let longitude = fileLongitude?.doubleValue else { return nil }
        return GPSCoordinate(latitude: latitude, longitude: longitude)
    }

    /// The location typed into the catalog, if one is set.
    var overrideLocation: GPSCoordinate? {
        guard locationKind == .set, let latitude = overrideLatitude?.doubleValue, let longitude = overrideLongitude?.doubleValue
        else { return nil }
        return GPSCoordinate(latitude: latitude, longitude: longitude)
    }

    var locationKind: LocationOverride {
        LocationOverride(rawValue: locationOverride) ?? .file
    }

    /// Where the photo was taken, as PixelLoupe shows it: the catalog's location, else the file's.
    var location: GPSCoordinate? {
        switch locationKind {
        case .set: overrideLocation
        case .cleared: nil
        case .file: fileLocation
        }
    }

    /// Records what the file says (at import, or when ``LocationBackfill`` reads it).
    func setFileLocation(_ coordinate: GPSCoordinate?, altitude: Double?) {
        let latitude = coordinate.map { NSNumber(value: $0.latitude) }, longitude = coordinate.map { NSNumber(value: $0.longitude) }
        if fileLatitude != latitude { fileLatitude = latitude }
        if fileLongitude != longitude { fileLongitude = longitude }
        let altitude = altitude.map { NSNumber(value: $0) }
        if fileAltitude != altitude { fileAltitude = altitude }
        if !locationRead { locationRead = true }
        updateHasGPS()
    }

    /// Gives the photo a location in the catalog (`.set`), removes its location (`.cleared`), or goes
    /// back to the file's (`.file`).
    func setLocationOverride(_ kind: LocationOverride, _ coordinate: GPSCoordinate? = nil) {
        let coordinate = kind == .set ? coordinate : nil
        guard kind != .set || coordinate != nil else { return }
        if locationOverride != kind.rawValue { locationOverride = kind.rawValue }
        let latitude = coordinate.map { NSNumber(value: $0.latitude) }, longitude = coordinate.map { NSNumber(value: $0.longitude) }
        if overrideLatitude != latitude { overrideLatitude = latitude }
        if overrideLongitude != longitude { overrideLongitude = longitude }
        updateHasGPS()
    }

    /// Copies the location fields from another photo (a virtual copy's master, or an Edit In original).
    func copyLocation(from source: Photo) {
        fileLatitude = source.fileLatitude
        fileLongitude = source.fileLongitude
        fileAltitude = source.fileAltitude
        locationRead = source.locationRead
        locationOverride = source.locationOverride
        overrideLatitude = source.overrideLatitude
        overrideLongitude = source.overrideLongitude
        hasGPS = source.hasGPS
    }

    /// `hasGPS` follows the shown location. Until the file is read, only an override can change it.
    func updateHasGPS() {
        let has: Bool
        switch locationKind {
        case .set: has = true
        case .cleared: has = false
        case .file:
            guard locationRead else { return }
            has = fileLocation != nil
        }
        if hasGPS != has { hasGPS = has }
    }
}
