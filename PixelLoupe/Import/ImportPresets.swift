import Foundation

/// A named set of import window choices (the footer's Import Preset): Copy or Add, File Handling,
/// File Renaming, Apply During Import (but not keywords) and Destination. Not the source or which
/// photos are checked. Shared by every catalog.
nonisolated struct ImportPreset: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var settings: ImportSettings

    private static let key = "ImportPresets"
    private static let chosenKey = "ImportPresetByCatalog"

    /// The presets, by name.
    static func all(in defaults: UserDefaults = Defaults.store) -> [ImportPreset] {
        let presets = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([ImportPreset].self, from: $0) } ?? []
        return presets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func save(_ presets: [ImportPreset], in defaults: UserDefaults = Defaults.store) {
        defaults.set(try? JSONEncoder().encode(presets), forKey: key)
    }

    /// The preset last chosen in a catalog's import window, if it still exists.
    static func chosen(for catalog: URL, in defaults: UserDefaults = Defaults.store) -> UUID? {
        (defaults.dictionary(forKey: chosenKey)?[catalog.standardizedFileURL.path(percentEncoded: false)] as? String)
            .flatMap(UUID.init(uuidString:))
            .flatMap { id in all(in: defaults).contains { $0.id == id } ? id : nil }
    }

    static func setChosen(_ id: UUID?, for catalog: URL, in defaults: UserDefaults = Defaults.store) {
        var all = defaults.dictionary(forKey: chosenKey) ?? [:]
        all[catalog.standardizedFileURL.path(percentEncoded: false)] = id?.uuidString
        defaults.set(all, forKey: chosenKey)
    }
}
