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
    /// File Renaming: how copies are named (`nil` keeps their names).
    var renaming: ImportRenaming?
    /// Build Smart Previews: the imported photos are queued for Smart Previews once they're in.
    var buildsSmartPreviews = false

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
