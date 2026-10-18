import Foundation

/// A smart collection's rules: "Match all/any of the following", each rule a field, an operator and
/// a value, as in Lightroom's Create Smart Collection dialog. Every rule becomes part of a Core Data
/// predicate, so smart collections stay live and fast in large catalogs.
nonisolated struct SmartCollectionRules: Codable, Equatable, Sendable {
    enum Match: String, Codable, Sendable, CaseIterable {
        case all, any
        /// Photos that match none of the rules (Lightroom's "exclude").
        case none

        var title: String { rawValue }
    }

    enum Field: String, Codable, Sendable, CaseIterable {
        case rating, flag, keywords, camera, lens, captureDate, importDate, editDate, fileName, fileType, folder, edited, importedWithDifferences, labelColor, labelText
        case isoSpeed, focalLength, aperture, shutterSpeed, hasGPS, cropped, blackAndWhite, title, caption, creator, copyright, anyText, collection
        case virtualCopy, copyName, person

        var title: String {
            switch self {
            case .rating: "Rating"
            case .flag: "Pick Flag"
            case .keywords: "Keywords"
            case .camera: "Camera"
            case .lens: "Lens"
            case .captureDate: "Capture Date"
            case .importDate: "Import Date"
            case .editDate: "Edit Date"
            case .fileName: "File Name"
            case .fileType: "File Type"
            case .folder: "Folder"
            case .edited: "Has Adjustments"
            case .importedWithDifferences: "Imported with Differences"
            case .labelColor: "Label Color"
            case .labelText: "Label Text"
            case .isoSpeed: "ISO Speed"
            case .focalLength: "Focal Length"
            case .aperture: "Aperture"
            case .shutterSpeed: "Shutter Speed"
            case .hasGPS: "Has GPS"
            case .cropped: "Cropped"
            case .blackAndWhite: "Black & White"
            case .title: "Title"
            case .caption: "Caption"
            case .creator: "Creator"
            case .copyright: "Copyright"
            case .anyText: "Any Searchable Text"
            case .collection: "Collection"
            case .virtualCopy: "Is Virtual Copy"
            case .copyName: "Copy Name"
            case .person: "Person"
            }
        }

        enum ValueKind: Sendable {
            case rating, flag, text, date, fileType, bool, colorLabel
            /// A number: ISO, focal length, aperture or shutter speed.
            case number
        }

        var valueKind: ValueKind {
            switch self {
            case .rating: .rating
            case .flag: .flag
            case .keywords, .camera, .lens, .fileName, .folder, .labelText, .title, .caption, .creator, .copyright, .anyText, .collection, .copyName, .person: .text
            case .isoSpeed, .focalLength, .aperture, .shutterSpeed: .number
            case .labelColor: .colorLabel
            case .captureDate, .importDate, .editDate: .date
            case .fileType: .fileType
            case .edited, .importedWithDifferences, .hasGPS, .cropped, .blackAndWhite, .virtualCopy: .bool
            }
        }

        /// The operators the field offers, in groups (separators between them in the menu).
        var operatorGroups: [[Operator]] {
            switch valueKind {
            case .rating, .number: [[.is, .isNot], [.greaterThan, .lessThan], [.atLeast, .atMost], [.inRange]]
            case .flag, .fileType, .bool, .colorLabel: [[.is, .isNot]]
            case .text where self == .collection: [[.is, .isNot]]
            case .text where self == .person: [[.is, .isNot], [.contains, .doesNotContain], [.isEmpty, .isNotEmpty]]
            case .text where self == .keywords:
                [[.contains, .containsAll, .doesNotContain], [.startsWith, .endsWith], [.isEmpty, .isNotEmpty]]
            case .text: [[.contains, .doesNotContain], [.is, .isNot], [.startsWith, .endsWith], [.isEmpty, .isNotEmpty]]
            case .date: [[.is, .isNot], [.isAfter, .isBefore], [.inTheLast, .notInTheLast], [.inRange]]
            }
        }

        var operators: [Operator] { operatorGroups.flatMap { $0 } }
    }

    enum Operator: String, Codable, Sendable, CaseIterable {
        case `is`, isNot, greaterThan, lessThan, atLeast, atMost, inRange
        case contains, containsAll, doesNotContain, startsWith, endsWith, isEmpty, isNotEmpty
        case isAfter, isBefore, inTheLast, notInTheLast

        func title(for field: Field) -> String {
            switch self {
            case .is: "is"
            case .isNot: "is not"
            case .greaterThan: "is greater than"
            case .lessThan: "is less than"
            case .atLeast: "is greater than or equal to"
            case .atMost: "is less than or equal to"
            case .inRange: "is in range"
            case .contains: "contains"
            case .containsAll: "contains all"
            case .doesNotContain: "doesn't contain"
            case .startsWith: "starts with"
            case .endsWith: "ends with"
            case .isEmpty: field == .keywords ? "are empty" : "is empty"
            case .isNotEmpty: field == .keywords ? "aren't empty" : "isn't empty"
            case .isAfter: "is after"
            case .isBefore: "is before"
            case .inTheLast: "is in the last"
            case .notInTheLast: "is not in the last"
            }
        }

        /// Whether the operator needs a value (and, for ranges, a second one).
        var takesValue: Bool { self != .isEmpty && self != .isNotEmpty }
        var takesSecondValue: Bool { self == .inRange }
    }

    enum Unit: String, Codable, Sendable, CaseIterable {
        case days, weeks, months, years

        var component: Calendar.Component {
            switch self {
            case .days: .day
            case .weeks: .weekOfYear
            case .months: .month
            case .years: .year
            }
        }
    }

    struct Rule: Codable, Equatable, Sendable {
        var field: Field
        var `operator`: Operator
        /// Text, a rating ("3"), a flag ("picked"), a file type ("Raw"), "true"/"false", a date
        /// ("2026-10-13") or a count ("1" for "in the last 1 month").
        var value: String
        /// The end of a range.
        var value2: String = ""
        var unit: Unit = .days

        init(field: Field, operator: Operator, value: String, value2: String = "", unit: Unit = .days) {
            self.field = field
            self.operator = `operator`
            self.value = value
            self.value2 = value2
            self.unit = unit
        }

        /// A new rule's starting point for a field.
        static func `default`(for field: Field) -> Rule {
            switch field.valueKind {
            case .rating: Rule(field: field, operator: .atLeast, value: "3")
            case .flag: Rule(field: field, operator: .is, value: PhotoFlag.picked.ruleValue)
            case .text: Rule(field: field, operator: .contains, value: "")
            case .date: Rule(field: field, operator: .inTheLast, value: "1", unit: .months)
            case .fileType: Rule(field: field, operator: .is, value: SmartCollectionRules.fileTypes[0])
            case .bool: Rule(field: field, operator: .is, value: "true")
            case .colorLabel: Rule(field: field, operator: .is, value: ColorLabel.red.ruleValue)
            case .number: Rule(field: field, operator: .atLeast, value: field == .isoSpeed ? "400" : field == .aperture ? "2.8" : field == .shutterSpeed ? "0.01" : "50")
            }
        }
    }

    var match = Match.all
    var rules: [Rule] = [Rule.default(for: .rating)]
    /// Nested groups of rules, each with its own match, as Lightroom's smart collections can have.
    var groups: [SmartCollectionRules] = []

    init(match: Match = .all, rules: [Rule] = [Rule.default(for: .rating)], groups: [SmartCollectionRules] = []) {
        self.match = match
        self.rules = rules
        self.groups = groups
    }

    private enum CodingKeys: String, CodingKey { case match, rules, groups }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        match = try container.decode(Match.self, forKey: .match)
        rules = try container.decode([Rule].self, forKey: .rules)
        groups = try container.decodeIfPresent([SmartCollectionRules].self, forKey: .groups) ?? []
    }

    static let fileTypes = ["Raw", "JPEG", "HEIF", "TIFF", "PNG", "DNG", "Video"]
    /// Extensions of video files (not imported yet, but Lightroom catalogs have them).
    static let videoExtensions = ["MOV", "MP4", "M4V", "AVI", "MTS", "M2TS", "3GP", "MPG", "MPEG", "WMV"]
    /// Extensions of the formats that aren't camera RAW.
    static let nonRawExtensions = ["JPG", "JPEG", "HEIC", "HEIF", "TIF", "TIFF", "PNG", "DNG", "PSD"] + videoExtensions

    /// Dates in rules are calendar days, stored as "yyyy-MM-dd".
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Predicates

    var predicate: NSPredicate { predicate(now: Date()) }

    /// `now`: when "in the last N days" counts back from.
    func predicate(now: Date, calendar: Calendar = .current) -> NSPredicate {
        let parts = rules.map { $0.predicate(now: now, calendar: calendar) }
            + groups.map { $0.predicate(now: now, calendar: calendar) }
        guard !parts.isEmpty else { return NSPredicate(value: true) }
        switch match {
        case .all: return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
        case .any: return NSCompoundPredicate(orPredicateWithSubpredicates: parts)
        case .none: return NSCompoundPredicate(notPredicateWithSubpredicate: NSCompoundPredicate(orPredicateWithSubpredicates: parts))
        }
    }
}

nonisolated extension SmartCollectionRules.Rule {
    func predicate(now: Date, calendar: Calendar) -> NSPredicate {
        switch field.valueKind {
        case .rating: ratingPredicate
        case .flag: flagPredicate
        case .text: textPredicate
        case .date: datePredicate(now: now, calendar: calendar)
        case .fileType: fileTypePredicate
        case .bool: editedPredicate
        case .colorLabel: colorLabelPredicate
        case .number: numberPredicate
        }
    }

    private var ratingPredicate: NSPredicate {
        let rating = Int(value) ?? 0, end = Int(value2) ?? rating
        switch self.operator {
        case .is: return NSPredicate(format: "rating == %d", rating)
        case .isNot: return NSPredicate(format: "rating != %d", rating)
        case .greaterThan: return NSPredicate(format: "rating > %d", rating)
        case .lessThan: return NSPredicate(format: "rating < %d", rating)
        case .atMost: return NSPredicate(format: "rating <= %d", rating)
        case .inRange: return NSPredicate(format: "rating >= %d AND rating <= %d", min(rating, end), max(rating, end))
        default: return NSPredicate(format: "rating >= %d", rating)
        }
    }

    private var flagPredicate: NSPredicate {
        let flag = PhotoFlag(ruleValue: value) ?? .picked
        return NSPredicate(format: self.operator == .isNot ? "flag != %d" : "flag == %d", flag.rawValue)
    }

    private var fileTypePredicate: NSPredicate {
        let types: [String] = switch value {
        case "JPEG": ["JPG", "JPEG"]
        case "HEIF": ["HEIC", "HEIF"]
        case "TIFF": ["TIF", "TIFF"]
        case "PNG": ["PNG"]
        case "DNG": ["DNG"]
        case "Video": SmartCollectionRules.videoExtensions
        default: []
        }
        let matches = value == "Raw"
            ? NSPredicate(format: "NOT (fileType IN[c] %@)", SmartCollectionRules.nonRawExtensions)
            : NSPredicate(format: "fileType IN[c] %@", types)
        return self.operator == .isNot ? NSCompoundPredicate(notPredicateWithSubpredicate: matches) : matches
    }

    /// ISO, focal length, aperture and shutter speed. Photos without the value (0) never match.
    private var numberPredicate: NSPredicate {
        let key = switch field {
        case .isoSpeed: "iso"
        case .focalLength: "focalLength"
        case .aperture: "aperture"
        default: "shutterSpeed"
        }
        let number = Double(value) ?? 0, end = Double(value2) ?? number
        // Equality allows for rounding (ƒ/2.8 is 2.79 or 2.8 depending on the camera).
        let tolerance = max(abs(number) * 0.01, 0.0001)
        let known = NSPredicate(format: "\(key) > 0")
        let test: NSPredicate = switch self.operator {
        case .isNot: NSPredicate(format: "\(key) < %f OR \(key) > %f", number - tolerance, number + tolerance)
        case .greaterThan: NSPredicate(format: "\(key) > %f", number + tolerance)
        case .lessThan: NSPredicate(format: "\(key) < %f", number - tolerance)
        case .atLeast: NSPredicate(format: "\(key) >= %f", number - tolerance)
        case .atMost: NSPredicate(format: "\(key) <= %f", number + tolerance)
        case .inRange: NSPredicate(format: "\(key) >= %f AND \(key) <= %f", min(number, end) - tolerance, max(number, end) + tolerance)
        default: NSPredicate(format: "\(key) >= %f AND \(key) <= %f", number - tolerance, number + tolerance)
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: [known, test])
    }

    private var colorLabelPredicate: NSPredicate {
        let label = ColorLabel(ruleValue: value) ?? .red
        return NSPredicate(format: self.operator == .isNot ? "colorLabel != %d" : "colorLabel == %d", Int(label.rawValue))
    }

    private var editedPredicate: NSPredicate {
        let matches = (value == "true") != (self.operator == .isNot)
        switch field {
        case .importedWithDifferences: return NSPredicate(format: matches ? "importDifferences != nil" : "importDifferences == nil")
        case .hasGPS: return NSPredicate(format: "hasGPS == %@", NSNumber(value: matches))
        case .cropped: return NSPredicate(format: "isCropped == %@", NSNumber(value: matches))
        case .blackAndWhite: return NSPredicate(format: "isBlackAndWhite == %@", NSNumber(value: matches))
        case .virtualCopy: return NSPredicate(format: matches ? "master != nil" : "master == nil")
        default: break
        }
        return NSPredicate(format: matches ? "adjustmentsData != nil" : "adjustmentsData == nil")
    }

    /// Text rules compare against the field's key paths (any of them for Camera: make or model).
    private var textPredicate: NSPredicate {
        let text = value.trimmingCharacters(in: .whitespaces)
        if field == .keywords { return keywordPredicate(text) }
        if field == .person { return personPredicate(text) }
        if field == .collection {
            // By the collection's name; a set matches the photos of everything in it.
            let inCollection = NSPredicate(format: "SUBQUERY(collections, $c, $c.name ==[cd] %@).@count > 0", text)
            return self.operator == .isNot ? NSCompoundPredicate(notPredicateWithSubpredicate: inCollection) : inCollection
        }
        if field == .anyText { return anyTextPredicate(text) }
        let keyPaths: [String] = switch field {
        case .camera: ["cameraMake", "cameraModel"]
        case .lens: ["lensModel"]
        case .fileName: ["fileName"]
        case .labelText: ["labelText"]
        case .title: ["titleText"]
        case .caption: ["captionText"]
        case .creator: ["creatorText"]
        case .copyright: ["copyrightText"]
        case .copyName: ["copyName"]
        case .anyText: ["fileName", "titleText", "captionText", "creatorText", "copyrightText", "cameraModel", "lensModel", "labelText"]
        default: ["folder.path"]
        }
        func any(_ format: String) -> NSPredicate {
            NSCompoundPredicate(orPredicateWithSubpredicates: keyPaths.map { NSPredicate(format: format.replacingOccurrences(of: "$K", with: $0), text) })
        }
        switch self.operator {
        case .is: return any("$K ==[cd] %@")
        case .isNot: return NSCompoundPredicate(notPredicateWithSubpredicate: Self(field: field, operator: .is, value: value).textPredicate)
        case .startsWith: return any("$K BEGINSWITH[cd] %@")
        case .endsWith: return any("$K ENDSWITH[cd] %@")
        case .doesNotContain: return NSCompoundPredicate(notPredicateWithSubpredicate: any("$K CONTAINS[cd] %@"))
        case .isEmpty:
            return NSCompoundPredicate(andPredicateWithSubpredicates: keyPaths.map { NSPredicate(format: "\($0) == nil OR \($0) == ''") })
        case .isNotEmpty:
            return NSCompoundPredicate(orPredicateWithSubpredicates: keyPaths.map { NSPredicate(format: "\($0) != nil AND \($0) != ''") })
        default: return any("$K CONTAINS[cd] %@")
        }
    }

    /// Keywords match by name, synonym, or an ancestor's name, so `Ireland` finds photos tagged
    /// `Places > Ireland > Dublin`, as in Lightroom. (A keyword's path holds its ancestors' names.)
    /// "Searchable text" is any word of the text in the photo's text fields or keywords.
    private func anyTextPredicate(_ text: String) -> NSPredicate {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let keyPaths = ["fileName", "titleText", "captionText", "creatorText", "copyrightText", "cameraModel", "lensModel", "labelText"]
        func has(_ word: String) -> NSPredicate {
            NSCompoundPredicate(orPredicateWithSubpredicates:
                keyPaths.map { NSPredicate(format: "\($0) CONTAINS[cd] %@", word) }
                + [NSPredicate(format: "ANY tags.pathKey CONTAINS[cd] %@", word), NSPredicate(format: "ANY tags.synonymText CONTAINS[cd] %@", word)])
        }
        let all = NSCompoundPredicate(andPredicateWithSubpredicates: words.map(has))
        switch self.operator {
        case .doesNotContain: return NSCompoundPredicate(notPredicateWithSubpredicate: all)
        case .isEmpty: return NSPredicate(value: false)
        case .isNotEmpty: return NSPredicate(value: true)
        default: return words.isEmpty ? NSPredicate(value: true) : all
        }
    }

    /// "Person is Ada": the photo has a person keyword (marked as a person) of that name, or, for
    /// contains, with the text in it. Is empty means no person keyword at all.
    private func personPredicate(_ text: String) -> NSPredicate {
        func has(_ condition: String, _ value: String) -> NSPredicate {
            NSPredicate(format: "SUBQUERY(tags, $t, $t.isPerson == YES AND \(condition)).@count > 0", value)
        }
        switch self.operator {
        case .isEmpty: return NSPredicate(format: "SUBQUERY(tags, $t, $t.isPerson == YES).@count == 0")
        case .isNotEmpty: return NSPredicate(format: "SUBQUERY(tags, $t, $t.isPerson == YES).@count > 0")
        case .isNot: return NSCompoundPredicate(notPredicateWithSubpredicate: has("$t.name ==[cd] %@", text))
        case .doesNotContain: return NSCompoundPredicate(notPredicateWithSubpredicate: has("$t.name CONTAINS[cd] %@", text))
        case .contains: return has("$t.name CONTAINS[cd] %@", text)
        default: return has("$t.name ==[cd] %@", text)
        }
    }

    private func keywordPredicate(_ text: String) -> NSPredicate {
        let words = text.split { $0 == "," || $0.isWhitespace }.map(String.init)
        func any(_ format: String, _ value: String) -> NSPredicate { NSPredicate(format: format, value) }
        func contains(_ value: String) -> NSPredicate {
            NSCompoundPredicate(orPredicateWithSubpredicates: [
                any("ANY tags.pathKey CONTAINS[cd] %@", value), any("ANY tags.synonymText CONTAINS[cd] %@", value),
            ])
        }
        switch self.operator {
        case .isEmpty: return NSPredicate(format: "tags.@count == 0")
        case .isNotEmpty: return NSPredicate(format: "tags.@count > 0")
        case .startsWith:
            return NSCompoundPredicate(orPredicateWithSubpredicates: [
                any("ANY tags.name BEGINSWITH[cd] %@", text), any("ANY tags.synonymText BEGINSWITH[cd] %@", text),
                any("ANY tags.synonymText CONTAINS[cd] %@", "\n" + text),
            ])
        case .endsWith:
            return NSCompoundPredicate(orPredicateWithSubpredicates: [
                any("ANY tags.name ENDSWITH[cd] %@", text), any("ANY tags.synonymText ENDSWITH[cd] %@", text),
                any("ANY tags.synonymText CONTAINS[cd] %@", text + "\n"),
            ])
        case .doesNotContain:
            // (NOT ANY … doesn't translate to SQL for to-many relationships.)
            return NSPredicate(
                format: "SUBQUERY(tags, $tag, $tag.pathKey CONTAINS[cd] %@ OR $tag.synonymText CONTAINS[cd] %@).@count == 0", text, text)
        case .containsAll:
            guard !words.isEmpty else { return NSPredicate(value: true) }
            return NSCompoundPredicate(andPredicateWithSubpredicates: words.map(contains))
        default:
            return contains(text)
        }
    }

    private func datePredicate(now: Date, calendar: Calendar) -> NSPredicate {
        let key = switch field {
        case .importDate: "importDate"
        case .editDate: "editDate"
        default: "captureDate"
        }
        func day(_ string: String) -> (start: Date, end: Date)? {
            guard let date = SmartCollectionRules.dayFormatter.date(from: string) else { return nil }
            let start = calendar.startOfDay(for: date)
            return (start, calendar.date(byAdding: .day, value: 1, to: start)!)
        }
        switch self.operator {
        case .inTheLast, .notInTheLast:
            let count = max(0, Int(value) ?? 1)
            let since = calendar.date(byAdding: unit.component, value: -count, to: now) ?? now
            return NSPredicate(format: self.operator == .inTheLast ? "\(key) >= %@" : "\(key) < %@", since as NSDate)
        case .isAfter:
            guard let day = day(value) else { return NSPredicate(value: false) }
            return NSPredicate(format: "\(key) >= %@", day.end as NSDate)
        case .isBefore:
            guard let day = day(value) else { return NSPredicate(value: false) }
            return NSPredicate(format: "\(key) < %@", day.start as NSDate)
        case .inRange:
            guard let first = day(value), let last = day(value2.isEmpty ? value : value2) else { return NSPredicate(value: false) }
            return NSPredicate(format: "\(key) >= %@ AND \(key) < %@", min(first.start, last.start) as NSDate, max(first.end, last.end) as NSDate)
        case .isNot:
            guard let day = day(value) else { return NSPredicate(value: true) }
            return NSPredicate(format: "\(key) < %@ OR \(key) >= %@", day.start as NSDate, day.end as NSDate)
        default:
            guard let day = day(value) else { return NSPredicate(value: false) }
            return NSPredicate(format: "\(key) >= %@ AND \(key) < %@", day.start as NSDate, day.end as NSDate)
        }
    }
}

nonisolated extension PhotoFlag {
    /// How rules store a flag.
    var ruleValue: String {
        switch self {
        case .picked: "picked"
        case .unflagged: "unflagged"
        case .rejected: "rejected"
        }
    }

    init?(ruleValue: String) {
        switch ruleValue {
        case "picked": self = .picked
        case "unflagged": self = .unflagged
        case "rejected": self = .rejected
        default: return nil
        }
    }

    /// The title rules show: Lightroom's "flagged" for picks.
    var ruleTitle: String {
        switch self {
        case .picked: "flagged"
        case .unflagged: "unflagged"
        case .rejected: "rejected"
        }
    }
}
