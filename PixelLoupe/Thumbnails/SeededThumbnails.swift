import Foundation

/// Thumbnails that were copied from another program's previews (Lightroom's) rather than drawn by
/// PixelLoupe. They look right but not exactly like PixelLoupe's own rendering, so
/// ``ThumbnailMaintenance`` redraws the ones that PixelLoupe renders with edits. Kept as a list of
/// photo ids, one per line, next to the thumbnails.
nonisolated enum SeededThumbnails {
    static func url(in directory: URL) -> URL {
        directory.appending(path: ".seeded")
    }

    static func load(from directory: URL) -> Set<UUID> {
        guard let text = try? String(contentsOf: url(in: directory), encoding: .utf8) else { return [] }
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

    static func save(_ ids: Set<UUID>, to directory: URL) {
        let url = url(in: directory)
        if ids.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? Data((ids.map(\.uuidString).sorted().joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
        }
    }
}
