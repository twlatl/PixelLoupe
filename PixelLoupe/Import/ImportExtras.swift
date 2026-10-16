import Foundation

/// What an import does besides bringing files in: the import window's File Handling and Apply During
/// Import choices.
nonisolated struct ImportExtras: Sendable {
    /// Don't Import Suspected Duplicates off: files the catalog already has are imported again.
    var allowsDuplicates = false
    /// Don't Import Rejected Images: files rated -1 (rejected in the camera or another app) are left out.
    var skipsRejected = false
    /// Make a Second Copy: the folder that gets a backup of each copied file, in an "Imported on" folder.
    var secondCopy: URL?
    /// Keywords added to every imported photo.
    var keywords: [String] = []
    /// Text fields filled in on every imported photo.
    var metadata: MetadataPreset?
    /// A develop preset applied to every photo it suits.
    var developPreset: DevelopPreset?
    /// The collection the imported photos are added to.
    var collection: CollectionChoice?

    enum CollectionChoice: Sendable, Equatable {
        case existing(UUID)
        case new(name: String)
    }

    /// The folder in `secondCopy` for an import on `date`: "Imported on 2026-10-15".
    static func secondCopyFolder(in root: URL, on date: Date, calendar: Calendar = .current) -> URL {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let name = String(format: "Imported on %04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return root.appending(path: name, directoryHint: .isDirectory)
    }
}

/// A named set of text fields filled in on photos as they're imported (Apply During Import ▸
/// Metadata): who made them and the copyright, and optionally a title and caption. Empty fields are
/// left as the file has them.
nonisolated struct MetadataPreset: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var name: String
    var creator = ""
    var copyright = ""
    var title = ""
    var caption = ""

    /// The presets, in the order they were made.
    static func all(in defaults: UserDefaults = Defaults.store) -> [MetadataPreset] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([MetadataPreset].self, from: $0) } ?? []
    }

    static func save(_ presets: [MetadataPreset], in defaults: UserDefaults = Defaults.store) {
        defaults.set(try? JSONEncoder().encode(presets), forKey: key)
    }

    private static let key = "MetadataPresets"

    /// Fills in the preset's non-empty fields on `photo`.
    func apply(to photo: Photo) {
        func value(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let creator = value(creator) { photo.creatorText = creator }
        if let copyright = value(copyright) { photo.copyrightText = copyright }
        if let title = value(title) { photo.titleText = title }
        if let caption = value(caption) { photo.captionText = caption }
    }
}
