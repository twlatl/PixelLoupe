import Foundation

/// Folders photos were recently imported from, most recent first, listed in the import window.
nonisolated enum RecentImportSources {
    static let maximumCount = 10
    private static let key = "RecentImportSources"

    /// The remembered folders that still exist (a card that's been ejected drops out until it's back).
    static func folders(in defaults: UserDefaults = Defaults.store) -> [URL] {
        (defaults.stringArray(forKey: key) ?? [])
            .map { URL(filePath: $0, directoryHint: .isDirectory) }
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
    }

    /// Moves `folder` to the top of the list.
    static func note(_ folder: URL, in defaults: UserDefaults = Defaults.store) {
        let path = folder.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
        var paths = (defaults.stringArray(forKey: key) ?? []).filter { $0 != path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(maximumCount)), forKey: key)
    }
}
