import Foundation

/// The catalog's own settings (Catalog Settings…, ⌥⌘,), stored in the package's `Settings.plist` so they
/// travel with the catalog. A key the file doesn't have reads as its default, so catalogs saved before a
/// setting existed need no migration. Each pane adds its settings here (RAW-265).
nonisolated struct CatalogSettings: Codable, Equatable, Sendable {
    /// Reads the settings saved in a catalog package; a missing or unreadable file means the defaults.
    static func load(from package: URL) -> CatalogSettings {
        guard let data = try? Data(contentsOf: CatalogPackage.settingsURL(in: package)),
              let settings = try? PropertyListDecoder().decode(CatalogSettings.self, from: data) else { return .init() }
        return settings
    }

    func save(to package: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(self).write(to: CatalogPackage.settingsURL(in: package), options: .atomic)
    }
}
