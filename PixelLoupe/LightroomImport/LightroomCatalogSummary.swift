import Foundation

/// What a Lightroom catalog holds, shown on the import sheet and kept in the import report.
nonisolated struct LightroomCatalogSummary: Codable, Equatable, Sendable {
    var lightroomVersion = ""
    /// Photos, not counting virtual copies.
    var photos = 0
    var virtualCopies = 0
    var folders = 0
    var keywords = 0
    var collections = 0
    var smartCollections = 0
    var collectionSets = 0
    var stacks = 0
    var photosWithEdits = 0
    var photosWithMasksOrHealing = 0
    /// Photos PixelLoupe can't open, by Lightroom file format (`VIDEO`, `PSD`).
    var unsupportedFiles: [String: Int] = [:]
    /// Photos whose file isn't where Lightroom last saw it. `nil` until counted.
    var missingFiles: Int?

    var unsupportedFileCount: Int { unsupportedFiles.values.reduce(0, +) }
}

nonisolated extension LightroomCatalog {
    /// File formats (Lightroom's `fileFormat`) PixelLoupe can open.
    private static let supportedFormats: Set<String> = ["RAW", "DNG", "JPG", "TIFF", "PNG", "HEIC", "HEIF", "PSD", "VIDEO"]

    /// Counts what the catalog holds, with a handful of aggregate queries (no per-photo work).
    func summary() throws -> LightroomCatalogSummary {
        var summary = LightroomCatalogSummary()
        summary.lightroomVersion = version.crsVersion.map { "Lightroom Classic \(version.lightroomMajor) (\($0))" }
            ?? "Lightroom Classic \(version.lightroomMajor)"
        summary.photos = try scalar("SELECT COUNT(*) FROM Adobe_images WHERE masterImage IS NULL OR masterImage = id_local")
        summary.virtualCopies = try scalar("SELECT COUNT(*) FROM Adobe_images WHERE masterImage IS NOT NULL AND masterImage <> id_local")
        summary.folders = try scalar("SELECT COUNT(*) FROM AgLibraryFolder")
        summary.keywords = try scalar("SELECT COUNT(*) FROM AgLibraryKeyword WHERE parent IS NOT NULL")
        for collection in try collections() {
            switch collection.kind {
            case .collection: summary.collections += 1
            case .smartCollection: summary.smartCollections += 1
            case .set: summary.collectionSets += 1
            case .system: break
            }
        }
        summary.stacks = try scalar("SELECT COUNT(*) FROM AgLibraryFolderStack", table: "AgLibraryFolderStack")
        let settings = "Adobe_imageDevelopSettings"
        var edits: [String] = []
        if try hasColumn(settings, "hasDevelopAdjustmentsEx") { edits.append("hasDevelopAdjustmentsEx > 0") }
        if try hasColumn(settings, "hasDevelopAdjustments") { edits.append("hasDevelopAdjustments = 1") }
        summary.photosWithEdits = try scalar(
            "SELECT COUNT(*) FROM \(settings) WHERE \(edits.isEmpty ? "0" : edits.joined(separator: " OR "))", table: settings)
        var local: [String] = []
        if try hasColumn(settings, "hasMasks") { local.append("hasMasks = 1") }
        if try hasColumn(settings, "hasRetouch") { local.append("(hasRetouch IS NOT NULL AND hasRetouch NOT IN ('', '0', 0))") }
        summary.photosWithMasksOrHealing = try scalar(
            "SELECT COUNT(*) FROM \(settings) WHERE \(local.isEmpty ? "0" : local.joined(separator: " OR "))", table: settings)
        for (format, count) in try formatCounts() where !Self.supportedFormats.contains(format.uppercased()) {
            summary.unsupportedFiles[format.uppercased()] = count
        }
        return summary
    }

    /// Counts photos whose original file can't be found where Lightroom last saw it. Checks the
    /// file system, so it can be slow for a catalog on a network volume; it reports progress and
    /// stops early when the task is cancelled.
    func countMissingFiles(progress: (_ checked: Int, _ total: Int) -> Void = { _, _ in }) throws -> Int {
        let roots = Dictionary(uniqueKeysWithValues: try rootFolders().map { ($0.id, $0.absolutePath) })
        let folderPaths = Dictionary(uniqueKeysWithValues: try folders().map { folder in
            (folder.id, (roots[folder.rootFolder] ?? "") + folder.pathFromRoot)
        })
        var folderExists: [Int: Bool] = [:]
        let fileManager = FileManager.default
        let total = try scalar("SELECT COUNT(*) FROM Adobe_images")
        var checked = 0
        var missing = 0
        try fileRows { baseName, fileExtension, folder in
            checked += 1
            if checked % 500 == 0 {
                progress(checked, total)
            }
            guard let directory = folderPaths[folder] else {
                missing += 1
                return !Task.isCancelled
            }
            let exists: Bool
            if let known = folderExists[folder] {
                exists = known
            } else {
                var isDirectory: ObjCBool = false
                exists = fileManager.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue
                folderExists[folder] = exists
            }
            if !exists {
                missing += 1
            } else {
                let name = fileExtension.isEmpty ? baseName : baseName + "." + fileExtension
                if !fileManager.fileExists(atPath: directory + name) { missing += 1 }
            }
            return !Task.isCancelled
        }
        try Task.checkCancellation()
        progress(total, total)
        return missing
    }
}
