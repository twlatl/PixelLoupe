import Foundation

/// How an import brings files into the catalog: copies them into a destination folder, or adds them
/// where they are.
nonisolated enum ImportTransfer: String, Codable, Sendable, CaseIterable {
    case copy, add

    var title: String {
        switch self {
        case .copy: "Copy"
        case .add: "Add"
        }
    }

    /// The import window's line under the Copy / Add control.
    var explanation: String {
        switch self {
        case .copy: "Copy photos to a new location and add to library"
        case .add: "Add photos to library without moving them"
        }
    }

    /// Which duplicate rule applies: a copy of the same shot from anywhere is a duplicate, but a file
    /// added in place is only a duplicate if that very file is already in the catalog.
    var duplicateRule: CatalogInfo.StorageMode {
        switch self {
        case .copy: .managed
        case .add: .referenced
        }
    }
}

/// How copied photos are arranged under the destination folder, by capture date.
nonisolated enum ImportFolderLayout: String, Codable, Sendable, CaseIterable {
    /// `2026/2026-10-15`
    case yearAndDate
    /// `2026/10-15`, what managed catalogs have always used.
    case yearAndMonthDay
    /// `2026/10/15`
    case yearMonthDay
    /// `2026-10-15`
    case date
    /// `2026/October/15`
    case yearMonthNameDay
    /// Everything in the one folder.
    case oneFolder

    var title: String {
        switch self {
        case .yearAndDate: "2026/2026-10-15"
        case .yearAndMonthDay: "2026/10-15"
        case .yearMonthDay: "2026/10/15"
        case .date: "2026-10-15"
        case .yearMonthNameDay: "2026/October/15"
        case .oneFolder: "Into One Folder"
        }
    }

    /// The folder names for a photo taken on `date`.
    func components(for date: Date, calendar: Calendar = .current) -> [String] {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = String(format: "%04d", parts.year ?? 0)
        let month = String(format: "%02d", parts.month ?? 0)
        let day = String(format: "%02d", parts.day ?? 0)
        switch self {
        case .yearAndDate: return [year, "\(year)-\(month)-\(day)"]
        case .yearAndMonthDay: return [year, "\(month)-\(day)"]
        case .yearMonthDay: return [year, month, day]
        case .date: return ["\(year)-\(month)-\(day)"]
        case .yearMonthNameDay:
            let name = calendar.standaloneMonthSymbols[(parts.month ?? 1) - 1]
            return [year, name, day]
        case .oneFolder: return []
        }
    }
}

/// Where an import copies photos: a folder, optionally a named subfolder in it, then date folders.
nonisolated struct ImportDestination: Codable, Equatable, Sendable {
    var root: URL
    /// The subfolder's name, or `nil` to put the date folders straight into `root`.
    var subfolder: String?
    var layout: ImportFolderLayout

    /// The folder date folders go in: `root`, or its subfolder.
    var base: URL {
        guard let name = subfolder?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return root }
        // A slash in the name would make more folders than the user typed.
        return root.appending(path: name.replacingOccurrences(of: "/", with: ":"), directoryHint: .isDirectory)
    }

    /// The folder a photo taken on `date` is copied into.
    func folder(for date: Date, calendar: Calendar = .current) -> URL {
        layout.components(for: date, calendar: calendar).reduce(base) {
            $0.appending(path: $1, directoryHint: .isDirectory)
        }
    }

    /// `folder(for:)` relative to `root`, as the import window lists destination folders.
    func relativePath(for date: Date, calendar: Calendar = .current) -> String {
        let folder = folder(for: date, calendar: calendar).standardizedFileURL.pathComponents
        let rootCount = root.standardizedFileURL.pathComponents.count
        return folder.dropFirst(rootCount).joined(separator: "/")
    }
}

/// The import window's Copy / Add and destination choices, remembered for each catalog.
nonisolated struct ImportSettings: Codable, Equatable, Sendable {
    var transfer: ImportTransfer
    var destination: ImportDestination
    /// File Handling and Apply During Import (keywords aren't remembered). Missing in settings saved
    /// before those existed.
    var handling: ImportHandling? = nil

    private static let key = "ImportSettingsByCatalog"

    /// What a catalog starts with: managed catalogs copy into their storage folder as they always
    /// have; referenced ones add photos where they are (and copy into Pictures if switched to Copy).
    static func defaults(for info: CatalogInfo) -> ImportSettings {
        if info.storageMode == .managed, let storage = info.storageURL {
            return ImportSettings(transfer: .copy, destination: .init(root: storage, subfolder: nil, layout: .yearAndMonthDay))
        }
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Pictures")
        return ImportSettings(transfer: .add, destination: .init(root: pictures, subfolder: nil, layout: .yearAndDate))
    }

    static func load(for catalog: URL, info: CatalogInfo, defaults: UserDefaults = Defaults.store) -> ImportSettings {
        let stored = defaults.dictionary(forKey: key)?[catalog.standardizedFileURL.path(percentEncoded: false)] as? Data
        return stored.flatMap { try? JSONDecoder().decode(ImportSettings.self, from: $0) } ?? Self.defaults(for: info)
    }

    func save(for catalog: URL, defaults: UserDefaults = Defaults.store) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        var all = defaults.dictionary(forKey: Self.key) ?? [:]
        all[catalog.standardizedFileURL.path(percentEncoded: false)] = data
        defaults.set(all, forKey: Self.key)
    }
}

/// The import window's remembered File Handling and Apply During Import choices.
nonisolated struct ImportHandling: Codable, Equatable, Sendable {
    var allowsDuplicates = false
    var skipsRejected = false
    var makesSecondCopy = false
    var secondCopy: URL?
    var addsToCollection = false
    var collectionID: UUID?
    /// The develop preset's file, or `nil` for None.
    var developPresetPath: String?
    var metadataPresetID: UUID?
}
