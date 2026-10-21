import CoreData

/// A kind of column in the Library Filter's Metadata mode, as in Lightroom's: the photos' values
/// for one piece of metadata, each with how many photos have it.
///
/// Every value has a string key, saved in the filter and turned back into a predicate; a key of ""
/// stands for photos with no value (Unknown Lens, No Creator…).
nonisolated enum MetadataColumn: String, CaseIterable, Codable, Sendable {
    case date, fileType, keyword, label, flag, rating
    case camera, lens, focalLength, shutterSpeed, aperture, iso
    case gps, treatment, aspectRatio, creator, copyright, folder

    var title: String {
        switch self {
        case .date: "Date"
        case .fileType: "File Type"
        case .keyword: "Keyword"
        case .label: "Label"
        case .flag: "Flag"
        case .rating: "Rating"
        case .camera: "Camera"
        case .lens: "Lens"
        case .focalLength: "Focal Length"
        case .shutterSpeed: "Shutter Speed"
        case .aperture: "Aperture"
        case .iso: "ISO Speed"
        case .gps: "GPS Data"
        case .treatment: "Treatment"
        case .aspectRatio: "Aspect Ratio"
        case .creator: "Creator"
        case .copyright: "Copyright"
        case .folder: "Folder"
        }
    }

    /// One row of a column: a value and how many photos have it. Dates have their months, and the
    /// months their days, as children.
    struct Value: Equatable, Sendable {
        var key: String
        var title: String
        var count: Int
        var children: [Value] = []
        /// The full value when the title is shortened (a keyword's path, a folder's).
        var toolTip: String?
    }

    // MARK: - Predicates

    /// The photos with the value `key`.
    func predicate(forKey key: String) -> NSPredicate {
        switch self {
        case .date:
            guard let range = Self.dateRange(forKey: key) else { return NSPredicate(format: "captureDate == nil") }
            return NSPredicate(format: "captureDate >= %@ AND captureDate < %@", range.lowerBound as NSDate, range.upperBound as NSDate)
        case .keyword:
            // A keyword and everything below it, as the keyword list's arrow shows.
            return NSPredicate(format: "ANY tags.pathKey ==[c] %@ OR ANY tags.pathKey BEGINSWITH[c] %@", key, key + Tag.pathSeparator)
        case .label:
            if key.hasPrefix("text:") { return NSPredicate(format: "labelText == %@", String(key.dropFirst(5))) }
            let raw = Int16(key) ?? 0
            // A custom label has no color; "no label" has neither.
            return raw == 0 ? NSPredicate(format: "colorLabel == 0 AND labelText == nil") : NSPredicate(format: "colorLabel == %d", raw)
        case .flag, .rating, .iso:
            return NSPredicate(format: "%K == %d", keyPath, Int(key) ?? 0)
        case .focalLength, .shutterSpeed, .aperture:
            return NSPredicate(format: "%K == %@", keyPath, NSNumber(value: Double(key) ?? 0))
        case .gps, .treatment:
            return NSPredicate(format: "%K == %@", keyPath, NSNumber(value: key == "1"))
        case .aspectRatio:
            // Orientations 5–8 turn the sensor's width into the photo's height.
            let upright = NSPredicate(format: "orientation < 5")
            let turned = NSPredicate(format: "orientation >= 5")
            func shape(_ wide: String, _ tall: String) -> NSPredicate {
                NSCompoundPredicate(orPredicateWithSubpredicates: [
                    NSCompoundPredicate(andPredicateWithSubpredicates: [upright, NSPredicate(format: wide)]),
                    NSCompoundPredicate(andPredicateWithSubpredicates: [turned, NSPredicate(format: tall)]),
                ])
            }
            return switch key {
            case "landscape": shape("pixelWidth > pixelHeight", "pixelHeight > pixelWidth")
            case "portrait": shape("pixelHeight > pixelWidth", "pixelWidth > pixelHeight")
            default: NSPredicate(format: "pixelWidth == pixelHeight")
            }
        case .fileType, .camera, .lens, .creator, .copyright, .folder:
            return key.isEmpty
                ? NSPredicate(format: "%K == nil OR %K == ''", keyPath, keyPath)
                : NSPredicate(format: "%K == %@", keyPath, key)
        }
    }

    /// The attribute grouped on (and compared) for most columns.
    private var keyPath: String {
        switch self {
        case .date: "captureDate"
        case .fileType: "fileType"
        case .keyword: "tags.pathKey"
        case .label: "colorLabel"
        case .flag: "flag"
        case .rating: "rating"
        case .camera: "cameraModel"
        case .lens: "lensModel"
        case .focalLength: "focalLength"
        case .shutterSpeed: "shutterSpeed"
        case .aperture: "aperture"
        case .iso: "iso"
        case .gps: "hasGPS"
        case .treatment: "isBlackAndWhite"
        case .aspectRatio: "pixelWidth"
        case .creator: "creatorText"
        case .copyright: "copyrightText"
        case .folder: "folder.path"
        }
    }

    // MARK: - Dates

    /// Keys are `2026`, `2026-10` and `2026-10-20`, in the user's calendar.
    static func dateRange(forKey key: String) -> Range<Date>? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard (1...3).contains(parts.count), parts.count == key.split(separator: "-").count else { return nil }
        let calendar = Calendar.current
        var components = DateComponents(year: parts[0], month: parts.count > 1 ? parts[1] : 1, day: parts.count > 2 ? parts[2] : 1)
        components.calendar = calendar
        guard let start = calendar.date(from: components) else { return nil }
        let unit: Calendar.Component = switch parts.count {
        case 1: .year
        case 2: .month
        default: .day
        }
        guard let end = calendar.date(byAdding: unit, value: 1, to: start) else { return nil }
        return start..<end
    }

    // MARK: - Values

    /// The column's values among the photos matching `predicate`, with their counts, in display
    /// order. Run on a background context: it fetches grouped counts, not photos (keywords fetch the
    /// photos that have any, with their keywords).
    func values(matching predicate: NSPredicate, in context: NSManagedObjectContext) throws -> [Value] {
        switch self {
        case .keyword: return try keywordValues(matching: predicate, in: context)
        case .date: return try dateValues(matching: predicate, in: context)
        default: break
        }
        let keyPaths: [String] = switch self {
        case .label: ["colorLabel", "labelText"]
        case .aspectRatio: ["pixelWidth", "pixelHeight", "orientation"]
        default: [keyPath]
        }
        var counts: [String: Int] = [:]
        for row in try groupedCounts(of: keyPaths, matching: predicate, in: context) {
            counts[key(for: row.values), default: 0] += row.count
        }
        return counts.map { Value(key: $0.key, title: title(forKey: $0.key), count: $0.value, toolTip: toolTip(forKey: $0.key)) }
            .sorted(by: areInDisplayOrder)
    }

    /// The title for a value, also for one chosen earlier that the photos no longer have.
    func title(forKey key: String) -> String {
        switch self {
        case .date:
            let parts = key.split(separator: "-").compactMap { Int($0) }
            guard let range = Self.dateRange(forKey: key) else { return "Unknown Date" }
            return switch parts.count {
            case 1: String(parts[0])
            case 2: range.lowerBound.formatted(.dateTime.month(.wide))
            default: range.lowerBound.formatted(.dateTime.day().weekday(.wide))
            }
        case .keyword:
            return key.components(separatedBy: Tag.pathSeparator).last ?? key
        case .label:
            if key.hasPrefix("text:") { return String(key.dropFirst(5)) }
            let label = ColorLabel(rawValue: Int16(key) ?? 0) ?? .none
            return label == .none ? "No Label" : label.title
        case .flag:
            return PhotoFlag(rawValue: Int16(key) ?? 0)?.title ?? "Unflagged"
        case .rating:
            let rating = Int(key) ?? 0
            return rating == 0 ? "Unrated" : String(repeating: "★", count: rating)
        case .focalLength:
            let value = Double(key) ?? 0
            return value > 0 ? "\(value.formatted(.number.precision(.fractionLength(0...1)))) mm" : "Unknown Focal Length"
        case .shutterSpeed:
            let value = Double(key) ?? 0
            guard value > 0 else { return "Unknown Shutter Speed" }
            return value >= 1 ? "\(value.formatted(.number.precision(.fractionLength(0...1)))) sec" : "1/\(Int((1 / value).rounded())) sec"
        case .aperture:
            let value = Double(key) ?? 0
            return value > 0 ? "f / \(value.formatted(.number.precision(.fractionLength(1))))" : "Unknown Aperture"
        case .iso:
            let value = Int(key) ?? 0
            return value > 0 ? "ISO \(value)" : "Unknown ISO"
        case .gps:
            return key == "1" ? "Has GPS" : "No GPS"
        case .treatment:
            return key == "1" ? "Black & White" : "Color"
        case .aspectRatio:
            return switch key {
            case "landscape": "Landscape"
            case "portrait": "Portrait"
            default: "Square"
            }
        case .folder:
            return key.isEmpty ? "No Folder" : (key as NSString).lastPathComponent
        case .fileType, .camera, .lens, .creator, .copyright:
            guard key.isEmpty else { return key }
            return switch self {
            case .fileType: "Unknown Type"
            case .camera: "Unknown Camera"
            case .lens: "Unknown Lens"
            case .creator: "No Creator"
            default: "No Copyright"
            }
        }
    }

    private func toolTip(forKey key: String) -> String? {
        switch self {
        case .keyword: key
        case .folder where !key.isEmpty: (key as NSString).abbreviatingWithTildeInPath
        default: nil
        }
    }

    /// The key for one grouped row (its attributes in `values(matching:in:)`'s order).
    private func key(for values: [Any?]) -> String {
        func number(_ index: Int) -> NSNumber? { values[index] as? NSNumber }
        switch self {
        case .label:
            let raw = number(0)?.int16Value ?? 0
            if raw == 0, let text = values[1] as? String, !text.isEmpty { return "text:\(text)" }
            return String(raw)
        case .flag, .rating, .iso:
            return String(number(0)?.intValue ?? 0)
        case .focalLength, .shutterSpeed, .aperture:
            return String(number(0)?.doubleValue ?? 0)
        case .gps, .treatment:
            return number(0)?.boolValue == true ? "1" : "0"
        case .aspectRatio:
            var width = number(0)?.intValue ?? 0, height = number(1)?.intValue ?? 0
            if (number(2)?.intValue ?? 1) >= 5 { swap(&width, &height) }
            return width > height ? "landscape" : height > width ? "portrait" : "square"
        default:
            return values[0] as? String ?? ""
        }
    }

    /// Unknown values last; ratings and flags best first, other numbers ascending, text alphabetically.
    private func areInDisplayOrder(_ a: Value, _ b: Value) -> Bool {
        if a.key.isEmpty != b.key.isEmpty { return b.key.isEmpty }
        switch self {
        case .rating, .flag:
            return (Int(a.key) ?? 0) > (Int(b.key) ?? 0)
        case .iso:
            return (Int(a.key) ?? 0) < (Int(b.key) ?? 0)
        case .focalLength, .shutterSpeed, .aperture:
            return (Double(a.key) ?? 0) < (Double(b.key) ?? 0)
        case .label:
            // Colors in label order, then custom labels, then no label.
            func rank(_ key: String) -> (Int, String) {
                if key.hasPrefix("text:") { return (10, key) }
                let raw = Int(key) ?? 0
                return (raw == 0 ? 11 : raw, key)
            }
            return rank(a.key) < rank(b.key)
        default:
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    // MARK: - Fetching

    /// `SELECT keyPaths…, COUNT(*) … GROUP BY keyPaths`.
    private func groupedCounts(
        of keyPaths: [String], matching predicate: NSPredicate, in context: NSManagedObjectContext
    ) throws -> [(values: [Any?], count: Int)] {
        let count = NSExpressionDescription()
        count.name = "count"
        count.expression = NSExpression(forFunction: "count:", arguments: [NSExpression.expressionForEvaluatedObject()])
        count.expressionResultType = .integer64AttributeType
        let request = NSFetchRequest<NSDictionary>(entityName: "Photo")
        request.resultType = .dictionaryResultType
        request.predicate = predicate
        request.propertiesToFetch = keyPaths + [count]
        request.propertiesToGroupBy = keyPaths
        return try context.fetch(request).map { row in
            (keyPaths.map { row[$0] is NSNull ? nil : row[$0] }, (row["count"] as? NSNumber)?.intValue ?? 0)
        }
    }

    /// Years, each with its months, each with its days.
    private func dateValues(matching predicate: NSPredicate, in context: NSManagedObjectContext) throws -> [Value] {
        let calendar = Calendar.current
        var days: [DateComponents: Int] = [:]
        var unknown = 0
        // Grouped by the exact time, then bucketed: one row per distinct capture time, no photos.
        for row in try groupedCounts(of: ["captureDate"], matching: predicate, in: context) {
            guard let date = row.values[0] as? Date else { unknown += row.count; continue }
            days[calendar.dateComponents([.year, .month, .day], from: date), default: 0] += row.count
        }
        func key(_ parts: Int?...) -> String {
            parts.compactMap { $0 }.enumerated().map { part in
                let digits = String(part.element)
                return part.offset == 0 || digits.count > 1 ? digits : "0" + digits
            }.joined(separator: "-")
        }
        let byYear = Dictionary(grouping: days, by: { $0.key.year ?? 0 })
        var years = byYear.keys.sorted().map { year in
            let byMonth = Dictionary(grouping: byYear[year]!, by: { $0.key.month ?? 0 })
            let months = byMonth.keys.sorted().map { month in
                let dayValues = byMonth[month]!.sorted { ($0.key.day ?? 0) < ($1.key.day ?? 0) }.map { day, count in
                    let dayKey = key(year, month, day.day)
                    return Value(key: dayKey, title: title(forKey: dayKey), count: count)
                }
                let monthKey = key(year, month)
                return Value(key: monthKey, title: title(forKey: monthKey), count: dayValues.reduce(0) { $0 + $1.count }, children: dayValues)
            }
            return Value(key: String(year), title: String(year), count: months.reduce(0) { $0 + $1.count }, children: months)
        }
        if unknown > 0 { years.append(Value(key: "", title: "Unknown Date", count: unknown)) }
        return years
    }

    /// Each keyword the photos have, with how many have it. Fetches only photos with keywords, with
    /// their keywords prefetched.
    private func keywordValues(matching predicate: NSPredicate, in context: NSManagedObjectContext) throws -> [Value] {
        let request = Photo.fetchRequest()
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, NSPredicate(format: "tags.@count > 0")])
        request.relationshipKeyPathsForPrefetching = ["tags"]
        request.fetchBatchSize = 500
        var counts: [String: Int] = [:]
        for photo in try context.fetch(request) {
            for tag in photo.tags { counts[tag.pathKey, default: 0] += 1 }
        }
        return counts.map { Value(key: $0.key, title: title(forKey: $0.key), count: $0.value, toolTip: $0.key) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }
}

nonisolated extension LibraryFilter.MetadataBrowser.Column {
    /// The chosen values, OR'd; nil when the column is on All.
    var predicate: NSPredicate? {
        guard !selection.isEmpty else { return nil }
        let predicates = selection.sorted().map { kind.predicate(forKey: $0) }
        return predicates.count == 1 ? predicates[0] : NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
    }
}

nonisolated extension LibraryFilter.MetadataBrowser {
    /// Every column's values: each counted among the photos `base` matches and the columns to its
    /// left leave. A chosen value the photos no longer have still gets a row (with its count), so it
    /// can be seen and unchosen.
    static func values(
        for columns: [Column], base: NSPredicate, in context: NSManagedObjectContext
    ) throws -> [[MetadataColumn.Value]] {
        try columns.indices.map { index in
            let column = columns[index]
            let left = columns.prefix(index).compactMap(\.predicate)
            let predicate = left.isEmpty ? base : NSCompoundPredicate(andPredicateWithSubpredicates: [base] + left)
            var values = try column.kind.values(matching: predicate, in: context)
            var present = Set<String>()
            func collect(_ values: [MetadataColumn.Value]) {
                for value in values { present.insert(value.key); collect(value.children) }
            }
            collect(values)
            for key in column.selection.sorted() where !present.contains(key) {
                let request = Photo.fetchRequest()
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, column.kind.predicate(forKey: key)])
                values.append(MetadataColumn.Value(
                    key: key, title: column.kind.title(forKey: key), count: try context.count(for: request),
                    toolTip: column.kind == .keyword ? key : nil
                ))
            }
            return values
        }
    }
}
