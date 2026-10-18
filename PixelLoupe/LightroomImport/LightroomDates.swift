import Foundation

/// Date formats used inside Lightroom catalogs.
nonisolated enum LightroomDates {
    /// `Adobe_images.captureTime` (`2012-09-11T18:20:23`, optionally with fractional seconds) as a
    /// date in `timeZone`. Lightroom stores wall-clock time with no zone and shows it as local time,
    /// so the default is the current zone.
    static func localDate(fromCaptureTime text: String?, in timeZone: TimeZone = .current) -> Date? {
        guard let text else { return nil }
        let parts = text.split(whereSeparator: { "-T: ".contains($0) })
        guard parts.count >= 6, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let hour = Int(parts[3]), let minute = Int(parts[4]), let second = Double(parts[5]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        components.second = Int(second.rounded(.down))
        guard let base = calendar.date(from: components) else { return nil }
        return base.addingTimeInterval(second - second.rounded(.down))
    }

    /// `AgLibraryImport.importDate` (`2020-04-28T07:25:43-04:00`, or without an offset).
    static func importDate(from text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let date = try? Date.ISO8601FormatStyle(timeZoneSeparator: .colon).parse(text) { return date }
        if let date = try? Date.ISO8601FormatStyle(timeZoneSeparator: .colon, includingFractionalSeconds: true).parse(text) { return date }
        return localDate(fromCaptureTime: text)
    }

    /// `Adobe_images.touchTime`: seconds since 2001-01-01, or `nil` for the unset value 0.
    static func touchDate(_ touchTime: Double) -> Date? {
        touchTime > 0 ? Date(timeIntervalSinceReferenceDate: touchTime) : nil
    }
}
