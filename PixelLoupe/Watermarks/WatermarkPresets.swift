import Foundation
import UniformTypeIdentifiers

/// Saved watermarks, shared by every catalog: one JSON file per preset in
/// ~/Library/Application Support/PixelLoupe/Watermarks, with graphic watermarks' images copied into
/// its Images folder. Lightroom's Simple Copyright Watermark is built in; deleting it hides it
/// until Restore Default Presets.
final class WatermarkPresets {
    static let shared = WatermarkPresets(directory: URL.applicationSupportDirectory.appending(path: "PixelLoupe/Watermarks", directoryHint: .isDirectory))

    static let didChangeNotification = Notification.Name("WatermarkPresetsDidChange")
    nonisolated static let simpleCopyrightName = "Simple Copyright Watermark"
    static let fileExtension = "rlwatermark"
    private static let hiddenDefaultsKey = "HiddenDefaultWatermarks"

    let directory: URL
    var imagesDirectory: URL { directory.appending(path: "Images", directoryHint: .isDirectory) }

    init(directory: URL) {
        self.directory = directory
    }

    static var defaults: [WatermarkPreset] {
        [WatermarkPreset(name: simpleCopyrightName, settings: WatermarkSettings())]
    }

    /// The built-in presets (unless deleted), then the saved ones by name.
    var all: [WatermarkPreset] {
        let hidden = Set(Defaults.store.stringArray(forKey: Self.hiddenDefaultsKey) ?? [])
        let saved = savedPresets()
        let savedNames = Set(saved.map(\.name))
        let builtIn = Self.defaults.filter { !hidden.contains($0.name) && !savedNames.contains($0.name) }
        return builtIn + saved.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func preset(named name: String) -> WatermarkPreset? {
        all.first { $0.name == name }
    }

    /// Saves (or replaces) a preset.
    func save(_ preset: WatermarkPreset) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preset).write(to: fileURL(for: preset.name), options: .atomic)
        // A saved preset with a built-in's name takes its place; showing it again isn't needed.
        unhide(preset.name)
        changed()
    }

    func delete(named name: String) {
        try? FileManager.default.removeItem(at: fileURL(for: name))
        if Self.defaults.contains(where: { $0.name == name }) {
            var hidden = Defaults.store.stringArray(forKey: Self.hiddenDefaultsKey) ?? []
            if !hidden.contains(name) { hidden.append(name) }
            Defaults.store.set(hidden, forKey: Self.hiddenDefaultsKey)
        }
        changed()
    }

    func rename(_ name: String, to newName: String) throws {
        guard var preset = preset(named: name), name != newName else { return }
        preset.name = newName
        try save(preset)
        delete(named: name)
    }

    /// Brings back the built-in presets that were deleted.
    func restoreDefaults() {
        Defaults.store.removeObject(forKey: Self.hiddenDefaultsKey)
        changed()
    }

    /// Copies a PNG or JPEG into the presets folder for a graphic watermark; returns its name.
    func importImage(from url: URL) throws -> String {
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).\(url.pathExtension.lowercased())"
        try FileManager.default.copyItem(at: url, to: imagesDirectory.appending(path: name))
        return name
    }

    func imageURL(named name: String) -> URL {
        imagesDirectory.appending(path: name)
    }

    // MARK: - Private

    private func savedPresets() -> [WatermarkPreset] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == Self.fileExtension }
            .compactMap { try? decoder.decode(WatermarkPreset.self, from: Data(contentsOf: $0)) }
    }

    private func fileURL(for name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return directory.appending(path: "\(safe).\(Self.fileExtension)")
    }

    private func unhide(_ name: String) {
        guard var hidden = Defaults.store.stringArray(forKey: Self.hiddenDefaultsKey), hidden.contains(name) else { return }
        hidden.removeAll { $0 == name }
        Defaults.store.set(hidden, forKey: Self.hiddenDefaultsKey)
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
