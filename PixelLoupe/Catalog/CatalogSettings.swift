import Foundation

/// The catalog's own settings (Catalog Settings…, ⌥⌘,), stored in the package's `Settings.plist` so they
/// travel with the catalog. A key the file doesn't have reads as its default, so catalogs saved before a
/// setting existed need no migration. Each pane adds its settings here (RAW-265).
nonisolated struct CatalogSettings: Codable, Equatable, Sendable {
    // MARK: Previews (RAW-267)

    /// Catalog Settings ▸ Previews ▸ Standard Preview Size: the long edge of Standard previews.
    enum PreviewSize: Int, Codable, CaseIterable, Identifiable, Sendable {
        /// The long edge of the largest connected display, in pixels.
        case auto = 0
        case pixels1024 = 1024
        case pixels1440 = 1440
        case pixels1680 = 1680
        case pixels2048 = 2048
        case pixels2560 = 2560
        case pixels2880 = 2880

        var id: Self { self }
    }

    /// Catalog Settings ▸ Previews ▸ Preview Quality: the JPEG quality of Standard previews.
    enum PreviewQuality: String, Codable, CaseIterable, Identifiable, Sendable {
        case high, medium, low

        var id: Self { self }
        var title: String { rawValue.capitalized }
        var jpegQuality: Double {
            switch self {
            case .high: 0.9
            case .medium: 0.8
            case .low: 0.6
            }
        }
    }

    var standardPreviewSize = PreviewSize.auto
    var previewQuality = PreviewQuality.medium
    /// Limit Preview Cache Size, in GB; nil for no limit. Only Standard previews count, and the least
    /// recently viewed go first.
    var previewCacheLimitGB: Double?

    // MARK: Metadata (RAW-268)

    /// Include Develop Settings in metadata inside JPEG, TIFF, PNG and PSD files: exports, Publish, Edit In and
    /// web galleries carry the photo's develop settings as Lightroom `crs:` XMP. Off by default, so exported
    /// files don't reveal how they were edited.
    var includesDevelopSettingsInExports = false

    /// Automatically detect duplicates for all photos (RAW-292): originals are hashed in the background and photos
    /// with the same contents show in the Catalog section's Duplicates. Off by default, since hashing a large
    /// library reads every original.
    var detectsDuplicates = false

    /// The cache limit in bytes; nil for none (a limit of zero or less is none).
    var previewCacheLimitBytes: Int64? {
        guard let previewCacheLimitGB, previewCacheLimitGB > 0 else { return nil }
        return Int64(previewCacheLimitGB * 1_000_000_000)
    }

    /// The Standard preview size and quality these settings ask for, Auto resolved with `autoPixelSize`.
    func standardPreviewFormat(autoPixelSize: Int) -> StandardPreviewFormat {
        StandardPreviewFormat(
            pixelSize: standardPreviewSize == .auto ? autoPixelSize : standardPreviewSize.rawValue,
            quality: previewQuality.jpegQuality
        )
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case standardPreviewSize, previewQuality, previewCacheLimitGB, includesDevelopSettingsInExports, detectsDuplicates
    }

    /// Missing keys, and values a later version wrote that this one doesn't know, read as the defaults.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        standardPreviewSize = (try? container.decodeIfPresent(PreviewSize.self, forKey: .standardPreviewSize)) ?? .auto
        previewQuality = (try? container.decodeIfPresent(PreviewQuality.self, forKey: .previewQuality)) ?? .medium
        previewCacheLimitGB = try? container.decodeIfPresent(Double.self, forKey: .previewCacheLimitGB)
        includesDevelopSettingsInExports = (try? container.decodeIfPresent(Bool.self, forKey: .includesDevelopSettingsInExports)) ?? false
        detectsDuplicates = (try? container.decodeIfPresent(Bool.self, forKey: .detectsDuplicates)) ?? false
    }

    // MARK: File

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

/// The size and JPEG quality a Standard preview is drawn at. Each preview records the format it was drawn with
/// in its own metadata, so a preview drawn before the settings changed can be told apart and drawn again.
nonisolated struct StandardPreviewFormat: Equatable, Hashable, Sendable {
    var pixelSize: Int
    var quality: Double

    /// What every Standard preview was drawn at before Catalog Settings (RAW-267); previews with no recorded
    /// format are taken to be this.
    static let original = StandardPreviewFormat(pixelSize: 2560, quality: 0.8)

    /// Recorded in the preview JPEG's EXIF UserComment field, e.g. `PixelLoupe Standard Preview 2560 q0.80`.
    var tag: String { "\(Self.tagPrefix)\(pixelSize) q\(String(format: "%.2f", quality))" }
    static let tagPrefix = "PixelLoupe Standard Preview "

    /// The format a preview's tag names; nil for a preview with no tag (drawn before RAW-267).
    init?(tag: String?) {
        guard let tag, tag.hasPrefix(Self.tagPrefix) else { return nil }
        let parts = tag.dropFirst(Self.tagPrefix.count).split(separator: " ")
        guard parts.count == 2, let size = Int(parts[0]), parts[1].hasPrefix("q"), let quality = Double(parts[1].dropFirst())
        else { return nil }
        self.init(pixelSize: size, quality: quality)
    }

    init(pixelSize: Int, quality: Double) {
        self.pixelSize = pixelSize
        self.quality = quality
    }
}
