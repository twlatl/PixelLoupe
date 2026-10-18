import Foundation

/// A saved set of export settings.
nonisolated struct ExportPreset: Codable, Equatable, Sendable {
    var name: String
    var settings: ExportSettings
}

/// Export presets, shared by every catalog: PixelLoupe's built-in presets, then the user's, one JSON
/// file each in ~/Library/Application Support/PixelLoupe/Export Presets. Also remembers the last
/// export's settings, for Export with Previous and the dialog's starting point.
final class ExportPresets {
    static let shared = ExportPresets(directory: URL.applicationSupportDirectory.appending(path: "PixelLoupe/Export Presets", directoryHint: .isDirectory))

    static let didChangeNotification = Notification.Name("ExportPresetsDidChange")
    static let fileExtension = "rlexport"
    private static let previousKey = "ExportPreviousSettings"

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The built-in presets (RAW-14): For Email, For Website and Full Sized JPEGs. They ask for a
    /// folder when used.
    static let builtIn: [ExportPreset] = {
        var email = ExportSettings()
        email.destination = .chooseLater
        email.quality = 60
        email.resizes = true
        email.resizeMode = .longEdge
        email.edge = 500
        email.resolution = 72
        email.metadata = .copyrightAndContact

        var website = email
        website.quality = 80
        website.edge = 1500
        website.sharpens = true

        var full = ExportSettings()
        full.destination = .chooseLater
        full.quality = 100
        full.resizes = false
        full.metadata = .all

        return [
            ExportPreset(name: "For Email", settings: email),
            ExportPreset(name: "For Website", settings: website),
            ExportPreset(name: "Full Sized JPEGs", settings: full),
        ]
    }()

    static func isBuiltIn(_ name: String) -> Bool {
        builtIn.contains { $0.name == name }
    }

    /// The user's presets, by name.
    var userPresets: [ExportPreset] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == Self.fileExtension }
            .compactMap { try? decoder.decode(ExportPreset.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var all: [ExportPreset] { Self.builtIn + userPresets }

    func preset(named name: String) -> ExportPreset? {
        all.first { $0.name == name }
    }

    /// Saves (or replaces) a user preset.
    func save(_ preset: ExportPreset) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preset).write(to: fileURL(for: preset.name), options: .atomic)
        changed()
    }

    func delete(named name: String) {
        try? FileManager.default.removeItem(at: fileURL(for: name))
        changed()
    }

    func rename(_ name: String, to newName: String) throws {
        guard var preset = userPresets.first(where: { $0.name == name }), name != newName else { return }
        preset.name = newName
        try save(preset)
        delete(named: name)
    }

    /// The last export's settings (or defaults before the first export).
    var previous: ExportSettings? {
        get {
            Defaults.store.data(forKey: Self.previousKey).flatMap { try? JSONDecoder().decode(ExportSettings.self, from: $0) }
        }
        set {
            Defaults.store.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.previousKey)
        }
    }

    private func fileURL(for name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return directory.appending(path: "\(safe).\(Self.fileExtension)")
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
