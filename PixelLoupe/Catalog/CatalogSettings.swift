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

    /// Catalog Settings ▸ Metadata ▸ Automatically clear history (RAW-309): when every photo's Develop history is
    /// cleared as the catalog opens. Current settings and snapshots are kept; only the history steps go.
    enum HistoryCleanup: String, Codable, CaseIterable, Identifiable, Sendable {
        case never
        /// Once, the next time the catalog opens; then Never.
        case nextLaunch
        case everyLaunch
        case monthly
        case yearly

        var id: Self { self }
        var title: String {
            switch self {
            case .never: "Never"
            case .nextLaunch: "When PixelLoupe next relaunches"
            case .everyLaunch: "Every time PixelLoupe relaunches"
            case .monthly: "Once a month"
            case .yearly: "Once a year"
            }
        }
    }

    private(set) var historyCleanup = HistoryCleanup.never
    /// When the current choice was made: Once a month and Once a year count from here until history is first cleared.
    private(set) var historyCleanupChosen: Date?
    /// When history was last cleared automatically.
    private(set) var lastHistoryCleanup: Date?

    /// Chooses when history is cleared. Choosing starts the clock for Once a month and Once a year, so history isn't
    /// cleared the next time the catalog opens just because it never has been.
    mutating func chooseHistoryCleanup(_ cleanup: HistoryCleanup, now: Date = .now) {
        guard cleanup != historyCleanup else { return }
        historyCleanup = cleanup
        historyCleanupChosen = now
    }

    /// Whether history should be cleared as the catalog opens. Once a month and Once a year count from the later of
    /// the last clear and when the choice was made.
    func isHistoryCleanupDue(now: Date = .now, calendar: Calendar = .current) -> Bool {
        let interval: DateComponents
        switch historyCleanup {
        case .never: return false
        case .nextLaunch, .everyLaunch: return true
        case .monthly: interval = DateComponents(month: 1)
        case .yearly: interval = DateComponents(year: 1)
        }
        guard let start = [lastHistoryCleanup, historyCleanupChosen].compactMap(\.self).max(),
              let next = calendar.date(byAdding: interval, to: start) else { return false }
        return now >= next
    }

    /// History was cleared: the date is recorded, and When PixelLoupe next relaunches gives way to Never.
    mutating func historyDidClear(at date: Date = .now) {
        lastHistoryCleanup = date
        if historyCleanup == .nextLaunch {
            historyCleanup = .never
            historyCleanupChosen = date
        }
    }

    // MARK: Backups (RAW-269)

    /// Catalog Settings ▸ Backups ▸ Back Up Catalog: when PixelLoupe offers to back the catalog up as it quits.
    enum BackupSchedule: String, Codable, CaseIterable, Identifiable, Sendable {
        case never
        case monthly
        case weekly
        case daily
        case everyExit
        /// Once, the next time PixelLoupe quits; then the schedule chosen before it comes back.
        case nextExit

        var id: Self { self }
        var title: String {
            switch self {
            case .never: "Never"
            case .monthly: "Once a month, when exiting PixelLoupe"
            case .weekly: "Once a week, when exiting PixelLoupe"
            case .daily: "Once a day, when exiting PixelLoupe"
            case .everyExit: "Every time PixelLoupe exits"
            case .nextExit: "When PixelLoupe next exits"
            }
        }
    }

    private(set) var backupSchedule = BackupSchedule.weekly
    /// The schedule to go back to once a When PixelLoupe next exits backup is made.
    private(set) var scheduleBeforeNextExit: BackupSchedule?
    /// Where backups go; nil for a Backups folder next to the catalog.
    var backupFolderPath: String?
    /// Keep the last N backups: older ones are deleted once a new one is made.
    var backupsToKeep = 10
    /// The quit sheet's Test integrity before backing up checkbox, remembered.
    var testsBackupIntegrity = true

    /// Chooses a schedule; When PixelLoupe next exits remembers the one it replaces.
    mutating func chooseBackupSchedule(_ schedule: BackupSchedule) {
        guard schedule != backupSchedule else { return }
        if schedule == .nextExit {
            scheduleBeforeNextExit = backupSchedule
        } else {
            scheduleBeforeNextExit = nil
        }
        backupSchedule = schedule
    }

    /// A backup was made: When PixelLoupe next exits gives way to the schedule chosen before it.
    mutating func backupDidFinish() {
        guard backupSchedule == .nextExit else { return }
        backupSchedule = scheduleBeforeNextExit ?? .weekly
        scheduleBeforeNextExit = nil
    }

    /// The folder backups of the catalog at `package` go to.
    func backupFolder(forCatalogAt package: URL) -> URL {
        if let backupFolderPath { return URL(filePath: backupFolderPath, directoryHint: .isDirectory) }
        return package.deletingLastPathComponent().appending(path: "Backups", directoryHint: .isDirectory)
    }

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
        case historyCleanup, historyCleanupChosen, lastHistoryCleanup
        case backupSchedule, scheduleBeforeNextExit, backupFolderPath, backupsToKeep, testsBackupIntegrity
    }

    /// Missing keys, and values a later version wrote that this one doesn't know, read as the defaults.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        standardPreviewSize = (try? container.decodeIfPresent(PreviewSize.self, forKey: .standardPreviewSize)) ?? .auto
        previewQuality = (try? container.decodeIfPresent(PreviewQuality.self, forKey: .previewQuality)) ?? .medium
        previewCacheLimitGB = try? container.decodeIfPresent(Double.self, forKey: .previewCacheLimitGB)
        includesDevelopSettingsInExports = (try? container.decodeIfPresent(Bool.self, forKey: .includesDevelopSettingsInExports)) ?? false
        detectsDuplicates = (try? container.decodeIfPresent(Bool.self, forKey: .detectsDuplicates)) ?? false
        historyCleanup = (try? container.decodeIfPresent(HistoryCleanup.self, forKey: .historyCleanup)) ?? .never
        historyCleanupChosen = try? container.decodeIfPresent(Date.self, forKey: .historyCleanupChosen)
        lastHistoryCleanup = try? container.decodeIfPresent(Date.self, forKey: .lastHistoryCleanup)
        backupSchedule = (try? container.decodeIfPresent(BackupSchedule.self, forKey: .backupSchedule)) ?? .weekly
        scheduleBeforeNextExit = try? container.decodeIfPresent(BackupSchedule.self, forKey: .scheduleBeforeNextExit)
        backupFolderPath = try? container.decodeIfPresent(String.self, forKey: .backupFolderPath)
        backupsToKeep = max(1, (try? container.decodeIfPresent(Int.self, forKey: .backupsToKeep)) ?? 10)
        testsBackupIntegrity = (try? container.decodeIfPresent(Bool.self, forKey: .testsBackupIntegrity)) ?? true
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
