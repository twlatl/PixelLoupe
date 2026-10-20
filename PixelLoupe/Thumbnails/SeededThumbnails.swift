import Foundation

/// Thumbnails not drawn by PixelLoupe from the photo's original, which ``ThumbnailMaintenance``
/// redraws from it. Kept as lists of photo ids, one per line, next to the thumbnails, by where they
/// came from (see ``Origin``).
nonisolated enum SeededThumbnails {
    enum Origin: String {
        /// Copied from another program's previews (Lightroom's): they look right but not exactly
        /// like PixelLoupe's own rendering, so the ones PixelLoupe renders with edits are redrawn.
        case lightroom = ".seeded"
        /// Drawn from the photo's Smart Preview while the original was missing: redrawn once it's back.
        case smartPreview = ".smart-preview-seeded"
    }

    static func url(in directory: URL, origin: Origin = .lightroom) -> URL {
        directory.appending(path: origin.rawValue)
    }

    static func load(from directory: URL, origin: Origin = .lightroom) -> Set<UUID> {
        guard let text = try? String(contentsOf: url(in: directory, origin: origin), encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { UUID(uuidString: String($0)) })
    }

    static func append(_ ids: [UUID], in directory: URL) {
        guard !ids.isEmpty else { return }
        let url = url(in: directory)
        let data = Data((ids.map(\.uuidString).joined(separator: "\n") + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func save(_ ids: Set<UUID>, to directory: URL, origin: Origin = .lightroom) {
        let url = url(in: directory, origin: origin)
        if ids.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? Data((ids.map(\.uuidString).sorted().joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
        }
    }
}
