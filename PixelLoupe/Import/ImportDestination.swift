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

/// How copied photos are arranged in the destination folder (the Destination section's Organize).
nonisolated enum ImportOrganization: String, Codable, Sendable, CaseIterable {
    /// The folders they're in on the source, from the folder chosen ("DCIM/100MSDCF" on a card).
    case byOriginalFolders
    /// Folders for the day they were taken, in the Date Format.
    case byDate
    /// Everything in the one folder.
    case intoOneFolder

    var title: String {
        switch self {
        case .byOriginalFolders: "By Original Folders"
        case .byDate: "By Date"
        case .intoOneFolder: "Into One Folder"
        }
    }
}

/// The folders for a photo's capture date when organizing By Date (the Destination's Date Format).
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

    var title: String {
        switch self {
        case .yearAndDate: "2026/2026-10-15"
        case .yearAndMonthDay: "2026/10-15"
        case .yearMonthDay: "2026/10/15"
        case .date: "2026-10-15"
        case .yearMonthNameDay: "2026/October/15"
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
        }
    }
}

/// Where an import copies photos: a folder, optionally a named subfolder in it, then folders by the
/// photos' original folders or their dates, or none.
nonisolated struct ImportDestination: Equatable, Sendable {
    var root: URL
    /// The subfolder's name, or `nil` to put the photos' folders straight into `root`.
    var subfolder: String?
    /// The Date Format, when organizing By Date.
    var layout: ImportFolderLayout
    var organize: ImportOrganization = .byDate

    /// The folder the photos' folders go in: `root`, or its subfolder.
    var base: URL {
        guard let name = subfolder?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return root }
        // A slash in the name would make more folders than the user typed.
        return root.appending(path: name.replacingOccurrences(of: "/", with: ":"), directoryHint: .isDirectory)
    }

    /// The folder a photo taken on `date`, in `originalFolder` on the source, is copied into.
    func folder(for date: Date, originalFolder: [String] = [], calendar: Calendar = .current) -> URL {
        let components = switch organize {
        case .byDate: layout.components(for: date, calendar: calendar)
        case .byOriginalFolders: originalFolder
        case .intoOneFolder: [String]()
        }
        return components.reduce(base) { $0.appending(path: $1, directoryHint: .isDirectory) }
    }

    /// `folder(for:originalFolder:)` relative to `root`, as the import window lists destination folders.
    func relativePath(for date: Date, originalFolder: [String] = [], calendar: Calendar = .current) -> String {
        let folder = folder(for: date, originalFolder: originalFolder, calendar: calendar).standardizedFileURL.pathComponents
        let rootCount = root.standardizedFileURL.pathComponents.count
        return folder.dropFirst(rootCount).joined(separator: "/")
    }

    /// The folders a source file is in below the folder chosen as the source (for By Original
    /// Folders): `DCIM/100MSDCF` for a file on a card chosen as a whole.
    static func originalFolder(of source: ImportService.ImportSource) -> [String] {
        let folder = source.url.deletingLastPathComponent().standardizedFileURL.pathComponents
        let anchor = source.anchor.standardizedFileURL.pathComponents
        guard folder.starts(with: anchor) else { return [] }
        // The anchor is the chosen folder's parent; the chosen folder itself isn't recreated.
        return Array(folder.dropFirst(anchor.count + 1))
    }
}

extension ImportDestination: Codable {
    private enum CodingKeys: String, CodingKey {
        case root, subfolder, layout, organize
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        root = try container.decode(URL.self, forKey: .root)
        subfolder = try container.decodeIfPresent(String.self, forKey: .subfolder)
        // Saved before Organize existed, "oneFolder" was one of the date layouts.
        let layoutName = try container.decode(String.self, forKey: .layout)
        layout = ImportFolderLayout(rawValue: layoutName) ?? .yearAndDate
        organize = try container.decodeIfPresent(ImportOrganization.self, forKey: .organize)
            ?? (layoutName == "oneFolder" ? .intoOneFolder : .byDate)
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(root, forKey: .root)
        try container.encodeIfPresent(subfolder, forKey: .subfolder)
        try container.encode(layout, forKey: .layout)
        try container.encode(organize, forKey: .organize)
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
    var renaming: ImportRenaming?
    /// Build Smart Previews: the imported photos get Smart Previews in the background once they're in.
    var buildsSmartPreviews = false
}

nonisolated extension ImportHandling {
    /// Each choice as saved, and the default for any saved before it existed (settings and presets
    /// from older versions keep the rest).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowsDuplicates = try container.decodeIfPresent(Bool.self, forKey: .allowsDuplicates) ?? false
        skipsRejected = try container.decodeIfPresent(Bool.self, forKey: .skipsRejected) ?? false
        makesSecondCopy = try container.decodeIfPresent(Bool.self, forKey: .makesSecondCopy) ?? false
        secondCopy = try container.decodeIfPresent(URL.self, forKey: .secondCopy)
        addsToCollection = try container.decodeIfPresent(Bool.self, forKey: .addsToCollection) ?? false
        collectionID = try container.decodeIfPresent(UUID.self, forKey: .collectionID)
        developPresetPath = try container.decodeIfPresent(String.self, forKey: .developPresetPath)
        metadataPresetID = try container.decodeIfPresent(UUID.self, forKey: .metadataPresetID)
        renaming = try container.decodeIfPresent(ImportRenaming.self, forKey: .renaming)
        buildsSmartPreviews = try container.decodeIfPresent(Bool.self, forKey: .buildsSmartPreviews) ?? false
    }
}
