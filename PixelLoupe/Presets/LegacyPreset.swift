import Foundation

/// Lightroom's presets from before 7.3: `.lrtemplate` files, a Lua table with the preset's title and
/// its settings (`value.settings`), the same settings a catalog stores. Importing one writes it as an
/// `.xmp` preset, as Lightroom does when it converts them.
nonisolated enum LegacyPreset {
    static let fileExtension = "lrtemplate"

    struct Converted: Equatable {
        var name: String
        var group: String
        var xmp: Data
    }

    /// The preset as XMP; `nil` for files that aren't Develop presets (export or metadata templates).
    static func convert(_ data: Data, url: URL, defaultGroup: String) -> Converted? {
        guard var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        // Lightroom's own presets name themselves with localizable strings: ZSTR "$$$/Key=Text".
        text = text.replacingOccurrences(of: #"ZSTR\s*(?=["'])"#, with: "", options: .regularExpression)
        guard let root = try? LuaTableParser.parse(text).table,
              (root["type"]?.string ?? "Develop") == "Develop",
              let settings = root["value"]?["settings"]?.table, !settings.hash.isEmpty else { return nil }
        let name = (root["title"]?.string ?? root["internalName"]?.string).map(localized).flatMap { $0.isEmpty ? nil : $0 }
            ?? url.deletingPathExtension().lastPathComponent
        var values: [String: PresetWriter.Value] = [:]
        for (key, value) in settings.hash where !["HasSettings", "PresetType", "UUID"].contains(key) {
            switch value {
            case .table(let look) where key == "Look":
                // Lightroom 7.0–7.2 named the profile as a look.
                guard let lookName = look["Name"]?.string else { continue }
                values[key] = .look(name: localized(lookName), amount: look["Amount"]?.number ?? 1, uuid: look["UUID"]?.string)
            case .number(let number): values[key] = .number(number)
            case .bool(let flag): values[key] = .text(flag ? "True" : "False")
            case .string(let string): values[key] = .text(localized(string))
            case .table(let table):
                // Curves are flat lists of x, y; other tables (spot removal, local corrections) aren't
                // carried over.
                let numbers = table.array.compactMap(\.number)
                guard table.hash.isEmpty, !numbers.isEmpty, numbers.count == table.array.count, numbers.count.isMultiple(of: 2) else { continue }
                values[key] = .curve(stride(from: 0, to: numbers.count, by: 2).map { (numbers[$0], numbers[$0 + 1]) })
            }
        }
        // Presets that don't name their process version: the 2012 process for its sliders, else 2010.
        if values["ProcessVersion"] == nil { values["ProcessVersion"] = .text(values.keys.contains { $0.hasSuffix("2012") } ? "6.7" : "5.0") }
        let uuid = (root["value"]?["uuid"]?.string ?? root["id"]?.string)?.replacingOccurrences(of: "-", with: "")
        let xmp = PresetWriter.xmp(name: name, group: defaultGroup, settings: values,
                                   uuid: uuid.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString.replacingOccurrences(of: "-", with: ""))
        return Converted(name: name, group: defaultGroup, xmp: xmp)
    }

    /// "$$$/AgDevelop/Presets/Name=Punch" → "Punch".
    static func localized(_ text: String) -> String {
        guard text.hasPrefix("$$$/"), let equals = text.firstIndex(of: "=") else { return text }
        return String(text[text.index(after: equals)...])
    }
}
