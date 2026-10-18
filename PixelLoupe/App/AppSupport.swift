import Foundation

/// The app's folder in Application Support: `~/Library/Application Support/Pixegen/PixelLoupe`,
/// holding imported presets (`Settings`) and Adobe profiles (`Profiles`).
nonisolated enum AppSupport {
    static let directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")
        let directory = support.appending(path: "Pixegen/PixelLoupe", directoryHint: .isDirectory)
        // Unit tests run inside the app: they must not touch the user's folders.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            migrate(from: support.appending(path: "Pixegen/LightLoupe", directoryHint: .isDirectory), to: directory)
        }
        return directory
    }()

    /// The app was called LightLoupe and kept its presets and profiles in `Pixegen/LightLoupe`. Copies
    /// that folder to the new one the first time, when the new one doesn't exist yet; the old folder is
    /// left as it was. Returns whether it copied.
    @discardableResult
    static func migrate(from old: URL, to new: URL, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: old.path(percentEncoded: false)),
              !fileManager.fileExists(atPath: new.path(percentEncoded: false)) else { return false }
        do {
            try fileManager.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: old, to: new)
            return true
        } catch {
            return false
        }
    }
}
