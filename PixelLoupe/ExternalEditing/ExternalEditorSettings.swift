import AppKit
import Foundation

/// How Photo ▸ Edit In hands a photo to another app: which app, and the file it gets. Laid out like an
/// editor section of Lightroom's Preferences ▸ External Editing (without its HDR column: PixelLoupe
/// edits in standard dynamic range). Codable for Settings and presets; decoding is tolerant.
nonisolated struct ExternalEditorSettings: Codable, Equatable, Sendable {
    enum Format: String, Codable, Sendable, CaseIterable {
        case tiff, psd

        var title: String { self == .tiff ? "TIFF" : "PSD" }

        var exportFormat: ExportSettings.Format { self == .tiff ? .tiff : .psd }
    }

    /// The editor's `.app`; nil until one is chosen.
    var applicationPath: String?
    var format = Format.tiff
    var colorSpace = ExportSettings.ColorSpace.proPhotoRGB
    /// 8 or 16.
    var bitDepth = 16
    /// Pixels per inch.
    var resolution = 240.0
    /// TIFF only.
    var compression = ExportSettings.TIFFCompression.zip

    init() {}

    /// Lightroom's starting point for the Additional External Editor: 8-bit sRGB with LZW.
    static let additionalDefault: ExternalEditorSettings = {
        var settings = ExternalEditorSettings()
        settings.colorSpace = .sRGB
        settings.bitDepth = 8
        settings.compression = .lzw
        return settings
    }()

    init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let decoded = try? container.decodeIfPresent(T.self, forKey: key) { value = decoded }
        }
        applicationPath = try? container.decodeIfPresent(String.self, forKey: .applicationPath)
        read(.format, &format); read(.colorSpace, &colorSpace); read(.bitDepth, &bitDepth)
        read(.resolution, &resolution); read(.compression, &compression)
    }

    var applicationURL: URL? { applicationPath.map { URL(filePath: $0) } }

    /// The app's name as Finder shows it ("Pixelmator Pro"), or nil when none is chosen.
    var applicationName: String? {
        applicationPath.map { FileManager.default.displayName(atPath: $0).replacingOccurrences(of: ".app", with: "") }
    }

    /// Whether the chosen app is still there.
    var applicationExists: Bool {
        applicationPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
    }

    /// Export settings that write this editor's file: full size, no sharpening or watermark, and all
    /// of the photo's metadata, named by `naming`.
    func exportSettings(naming: ExternalEditNaming) -> ExportSettings {
        var settings = ExportSettings()
        settings.destination = .sameFolderAsOriginal
        settings.existingFiles = .uniqueName
        settings.renames = true
        settings.namingTemplate = naming.template
        settings.customText = naming.customText
        settings.startNumber = naming.startNumber
        settings.format = format.exportFormat
        settings.colorSpace = colorSpace
        settings.bitDepth = bitDepth == 16 ? 16 : 8
        settings.tiffCompression = compression
        settings.resolution = resolution
        settings.resolutionUnit = .pixelsPerInch
        settings.resizes = false
        settings.sharpens = false
        settings.watermarks = false
        settings.metadata = .all
        return settings
    }
}

/// A saved Additional External Editor setup, listed by name in Photo ▸ Edit In.
nonisolated struct ExternalEditorPreset: Codable, Equatable, Sendable, Identifiable {
    var name: String
    var settings: ExternalEditorSettings

    var id: String { name }
}

/// Preferences ▸ External Editing ▸ Edit Externally File Naming: Export's templates, starting from
/// Filename-Edit ("IMG_0002-Edit.tif").
nonisolated struct ExternalEditNaming: Codable, Equatable, Sendable {
    var template = ExportSettings.NamingTemplate.filenameEdit
    var customText = "Edit"
    var startNumber = 1

    init() {}

    init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let decoded = try? container.decodeIfPresent(T.self, forKey: key) { value = decoded }
        }
        read(.template, &template); read(.customText, &customText); read(.startNumber, &startNumber)
    }

    /// The name the first photo would get, e.g. "IMG_0002-Edit.psd".
    func example(fileName: String = "IMG_0002.CR3", format: ExternalEditorSettings.Format) -> String {
        var settings = ExternalEditorSettings()
        settings.format = format
        let item = ExportItem(
            source: URL(filePath: "/\(fileName)"), adjustments: PhotoAdjustments(), metadata: PhotoMetadata(),
            keywords: [], rating: 0, captureDate: .now
        )
        return ExportNaming.fileName(for: item, index: 0, total: 1, settings: settings.exportSettings(naming: self))
    }
}

/// Preferences ▸ External Editing, saved in `Defaults.store` as JSON. Observable so Settings and the
/// Edit In menu follow changes.
@Observable
final class ExternalEditingPreferences {
    static let shared = ExternalEditingPreferences()

    static let didChangeNotification = Notification.Name("ExternalEditingPreferencesDidChange")

    private static let primaryKey = "ExternalEditorPrimary"
    private static let additionalKey = "ExternalEditorAdditional"
    private static let presetsKey = "ExternalEditorPresets"
    private static let stacksKey = "ExternalEditStacksWithOriginal"
    private static let namingKey = "ExternalEditNaming"

    /// Edit in (Primary), ⌘E.
    var primary: ExternalEditorSettings { didSet { save(primary, Self.primaryKey) } }
    /// Edit in (Additional), ⌥⌘E. Choosing a preset copies its settings here.
    var additional: ExternalEditorSettings { didSet { save(additional, Self.additionalKey) } }
    /// Saved Additional External Editor setups, by name.
    var presets: [ExternalEditorPreset] { didSet { save(presets, Self.presetsKey) } }
    /// Stack With Original: on by default, as in Lightroom.
    var stacksWithOriginal: Bool {
        didSet {
            Defaults.store.set(stacksWithOriginal, forKey: Self.stacksKey)
            changed()
        }
    }
    var naming: ExternalEditNaming { didSet { save(naming, Self.namingKey) } }

    /// Reads the saved preferences. Tests make their own.
    init() {
        primary = Self.load(Self.primaryKey) ?? ExternalEditorSettings()
        additional = Self.load(Self.additionalKey) ?? .additionalDefault
        presets = Self.load(Self.presetsKey) ?? []
        stacksWithOriginal = Defaults.store.object(forKey: Self.stacksKey) as? Bool ?? true
        naming = Self.load(Self.namingKey) ?? ExternalEditNaming()
    }

    /// The preset the Additional External Editor's settings came from, or nil ("Custom") once they differ.
    var currentPreset: ExternalEditorPreset? {
        presets.first { $0.settings == additional }
    }

    func preset(named name: String) -> ExternalEditorPreset? {
        presets.first { $0.name == name }
    }

    /// Save Current Settings as New Preset (replacing one of the same name).
    func savePreset(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var updated = presets.filter { $0.name != name }
        updated.append(ExternalEditorPreset(name: name, settings: additional))
        presets = updated.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func renamePreset(_ name: String, to newName: String) {
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != name, presets.contains(where: { $0.name == name }) else { return }
        var updated = presets.filter { $0.name != newName }
        if let index = updated.firstIndex(where: { $0.name == name }) { updated[index].name = newName }
        presets = updated.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func deletePreset(_ name: String) {
        presets.removeAll { $0.name == name }
    }

    /// Makes a preset's settings the Additional External Editor's.
    func applyPreset(_ name: String) {
        if let preset = preset(named: name) { additional = preset.settings }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        Defaults.store.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        Defaults.store.set(try? JSONEncoder().encode(value), forKey: key)
        changed()
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
