import Foundation

/// Turns a Lightroom smart collection's rules (a Lua table) into PixelLoupe's ``SmartCollectionRules``.
///
/// Lightroom stores `s = { { criteria = "rating", operation = ">=", value = 5 }, combine = "intersect" }`.
/// `combine` is `intersect` (match all), `union` (any) or `exclude` (none); an entry that has its own
/// `combine` is a nested group. A rule PixelLoupe can't express is left out of the predicate and
/// listed in ``Translation/unmapped``, so the collection can be marked and reported.
nonisolated enum LightroomSmartRules {
    struct Translation: Equatable {
        var rules: SmartCollectionRules
        /// Descriptions of the rules that weren't translated, e.g. `copyName == "Copy 1"`.
        var unmapped: [String] = []
    }

    /// What a `collection` criterion's value can name: the Lightroom collection ids and names.
    struct Context {
        var collectionNames: [Int: String] = [:]
    }

    static func translate(_ value: LuaValue, context: Context = Context()) -> Translation {
        guard let table = value.table else { return Translation(rules: SmartCollectionRules(rules: [])) }
        var rules: [SmartCollectionRules.Rule] = []
        var groups: [SmartCollectionRules] = []
        var unmapped: [String] = []
        for entry in table.array {
            guard let entryTable = entry.table else { continue }
            if entryTable["criteria"] != nil {
                if let rule = rule(from: entryTable, context: context) {
                    rules.append(rule)
                } else {
                    unmapped.append(describe(entryTable))
                }
            } else if entryTable["combine"] != nil || !entryTable.array.isEmpty {
                let nested = translate(entry, context: context)
                groups.append(nested.rules)
                unmapped += nested.unmapped
            }
        }
        let match: SmartCollectionRules.Match = switch table["combine"]?.string {
        case "union": .any
        case "exclude": .none
        default: .all
        }
        return Translation(rules: SmartCollectionRules(match: match, rules: rules, groups: groups), unmapped: unmapped)
    }

    /// The rules in a smart collection settings file Lightroom exports (`.lrsmcol`, RAW-185): `s = { title = …,
    /// value = { rules… } }`.
    static func translateSettingsFile(_ data: Data) throws -> Translation {
        let parsed = try LuaTableParser.parse(data)
        guard let value = parsed["value"] else { throw CocoaError(.fileReadCorruptFile) }
        return translate(value)
    }

    /// `criteria operation value`, for the report.
    static func describe(_ rule: LuaTable) -> String {
        let criteria = rule["criteria"]?.string ?? "?"
        let operation = rule["operation"]?.string ?? ""
        let value = rule["value"].map(text) ?? ""
        return [criteria, operation, value].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func text(_ value: LuaValue) -> String {
        switch value {
        case .string(let string): string
        case .number(let number): number == number.rounded() ? String(Int(number)) : String(number)
        case .bool(let bool): String(bool)
        case .table: "…"
        }
    }

    // MARK: - One rule

    private typealias Field = SmartCollectionRules.Field
    private typealias Operator = SmartCollectionRules.Operator

    private static func rule(from table: LuaTable, context: Context) -> SmartCollectionRules.Rule? {
        guard let criteria = table["criteria"]?.string else { return nil }
        let operation = table["operation"]?.string ?? "=="
        let value = table["value"]
        let second = table["value2"]
        switch criteria {
        case "rating":
            return numeric(.rating, operation, value, second)
        case "pick":
            guard let flag = value?.int.flatMap({ PhotoFlag(rawValue: Int16($0)) }), operation == "==" || operation == "!=" else { return nil }
            return .init(field: .flag, operator: operation == "==" ? .is : .isNot, value: flag.ruleValue)
        case "labelColor":
            let label: ColorLabel? = value?.int.flatMap { ColorLabel(rawValue: Int16($0)) } ?? value?.string.flatMap { ColorLabel(name: $0) }
            guard let label, operation == "==" || operation == "!=" else { return nil }
            return .init(field: .labelColor, operator: operation == "==" ? .is : .isNot, value: label.ruleValue)
        case "labelText": return textRule(.labelText, operation, value)
        case "keywords": return textRule(.keywords, operation, value)
        case "filename": return textRule(.fileName, operation, value)
        case "folder": return textRule(.folder, operation, value)
        case "camera": return textRule(.camera, operation, value)
        case "lens": return textRule(.lens, operation, value)
        case "title": return textRule(.title, operation, value)
        case "caption": return textRule(.caption, operation, value)
        case "creator": return textRule(.creator, operation, value)
        case "copyright": return textRule(.copyright, operation, value)
        case "allText": return textRule(.anyText, operation, value)
        case "copyName": return textRule(.copyName, operation, value)
        case "captureTime": return dateRule(.captureDate, table)
        case "touchTime": return dateRule(.editDate, table)
        case "importDate": return dateRule(.importDate, table)
        case "isoSpeedRating": return numeric(.isoSpeed, operation, value, second)
        case "focalLength": return numeric(.focalLength, operation, value, second)
        case "aperture": return numeric(.aperture, operation, value, second)
        case "shutterSpeed": return numeric(.shutterSpeed, operation, value, second)
        case "fileFormat":
            guard let format = value?.string, operation == "==" || operation == "!=", let type = fileType(forFormat: format) else { return nil }
            return .init(field: .fileType, operator: operation == "==" ? .is : .isNot, value: type)
        case "collection":
            let name = value?.int.flatMap { context.collectionNames[$0] } ?? value?.string.flatMap { name in
                Int(name).flatMap { context.collectionNames[$0] } ?? (context.collectionNames.values.contains(name) ? name : nil)
            }
            guard let name, operation == "==" || operation == "!=" else { return nil }
            return .init(field: .collection, operator: operation == "==" ? .is : .isNot, value: name)
        case "hasGPS": return boolean(.hasGPS, operation, value)
        case "hasAdjustments": return boolean(.edited, operation, value)
        case "cropped": return boolean(.cropped, operation, value)
        case "treatment":
            guard let treatment = value?.string?.lowercased(), operation == "==" || operation == "!=" else { return nil }
            let blackAndWhite = treatment.hasPrefix("gray") || treatment.hasPrefix("grey") || treatment == "bw" || treatment.contains("black")
            guard blackAndWhite || treatment == "color" || treatment == "colour" else { return nil }
            let matches = (operation == "==") == blackAndWhite
            return .init(field: .blackAndWhite, operator: .is, value: matches ? "true" : "false")
        default:
            return nil  // aspectRatio and anything newer
        }
    }

    private static func numeric(_ field: Field, _ operation: String, _ value: LuaValue?, _ second: LuaValue?) -> SmartCollectionRules.Rule? {
        guard let number = value?.number else { return nil }
        let op: Operator
        switch operation {
        case "==": op = .is
        case "!=": op = .isNot
        case ">": op = .greaterThan
        case ">=": op = .atLeast
        case "<": op = .lessThan
        case "<=": op = .atMost
        case "in":
            guard let end = second?.number else { return nil }
            return .init(field: field, operator: .inRange, value: text(.number(number)), value2: text(.number(end)))
        default: return nil
        }
        return .init(field: field, operator: op, value: text(.number(number)))
    }

    private static func textRule(_ field: Field, _ operation: String, _ value: LuaValue?) -> SmartCollectionRules.Rule? {
        let string = value.map(text) ?? ""
        let op: Operator
        switch operation {
        case "==": op = .is
        case "!=": op = .isNot
        case "words", "any", "contains": op = .contains
        case "all": op = field == .keywords ? .containsAll : .contains
        case "noneOf": op = .doesNotContain
        case "beginsWith": op = .startsWith
        case "endsWith": op = .endsWith
        case "empty": return .init(field: field, operator: .isEmpty, value: "")
        case "notEmpty": return .init(field: field, operator: .isNotEmpty, value: "")
        default: return nil
        }
        // Keywords have no "is": a keyword named exactly so is what "contains" finds anyway.
        let resolved: Operator = field == .keywords && (op == .is) ? .contains : (field == .keywords && op == .isNot ? .doesNotContain : op)
        guard field.operators.contains(resolved) || resolved == .doesNotContain else { return nil }
        return .init(field: field, operator: resolved, value: string)
    }

    private static func boolean(_ field: Field, _ operation: String, _ value: LuaValue?) -> SmartCollectionRules.Rule? {
        guard operation == "==" || operation == "!=" else { return nil }
        let flag: Bool
        switch value {
        case .bool(let bool)?: flag = bool
        case .number(let number)?: flag = number != 0
        case .string(let string)?: flag = ["true", "yes", "1"].contains(string.lowercased())
        default: return nil
        }
        return .init(field: field, operator: .is, value: (flag == (operation == "==")) ? "true" : "false")
    }

    /// Lightroom's `fileFormat` names as PixelLoupe's file types.
    private static func fileType(forFormat format: String) -> String? {
        switch format.uppercased() {
        case "RAW": "Raw"
        case "DNG": "DNG"
        case "JPG", "JPEG": "JPEG"
        case "TIFF", "TIF": "TIFF"
        case "PNG": "PNG"
        case "HEIC", "HEIF": "HEIF"
        case "VIDEO": "Video"
        default: nil
        }
    }

    private static func dateRule(_ field: Field, _ table: LuaTable) -> SmartCollectionRules.Rule? {
        let operation = table["operation"]?.string ?? "=="
        func day(_ value: LuaValue?) -> String? {
            switch value {
            case .string(let string)?: String(string.prefix(10)).count == 10 ? String(string.prefix(10)) : nil
            default: nil
            }
        }
        switch operation {
        case "inLast", "notInLast":
            guard let count = table["value"]?.int else { return nil }
            let units = table["value_units"]?.string?.lowercased() ?? "days"
            guard let unit = SmartCollectionRules.Unit(rawValue: units.hasSuffix("s") ? units : units + "s") else { return nil }
            return .init(field: field, operator: operation == "inLast" ? .inTheLast : .notInTheLast, value: String(count), unit: unit)
        case "==": return day(table["value"]).map { .init(field: field, operator: .is, value: $0) }
        case "!=": return day(table["value"]).map { .init(field: field, operator: .isNot, value: $0) }
        case ">": return day(table["value"]).map { .init(field: field, operator: .isAfter, value: $0) }
        case "<": return day(table["value"]).map { .init(field: field, operator: .isBefore, value: $0) }
        case ">=": return day(table["value"]).flatMap(shift(by: -1)).map { .init(field: field, operator: .isAfter, value: $0) }
        case "<=": return day(table["value"]).flatMap(shift(by: 1)).map { .init(field: field, operator: .isBefore, value: $0) }
        case "in":
            guard let start = day(table["value"]), let end = day(table["value2"]) else { return nil }
            return .init(field: field, operator: .inRange, value: start, value2: end)
        default: return nil
        }
    }

    /// A day string moved by whole days ("on or after X" is "after the day before X").
    private static func shift(by days: Int) -> (String) -> String? {
        { day in
            guard let date = SmartCollectionRules.dayFormatter.date(from: day),
                  let moved = Calendar(identifier: .gregorian).date(byAdding: .day, value: days, to: date) else { return nil }
            return SmartCollectionRules.dayFormatter.string(from: moved)
        }
    }
}
