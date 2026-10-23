import Foundation
import Synchronization

/// Publishes to a folder: each photo is exported there, re-publishing writes over its file, and
/// removing it moves the file to the Trash. Files are named with the service's File Naming, and a name
/// already taken by another file gets "-2", "-3"….
nonisolated final class HardDrivePublisher: Publisher {
    enum PublishError: LocalizedError {
        case noFolder

        var errorDescription: String? { "The service has no folder to publish to." }
    }

    let settings: PublishSettings
    let watermark: PhotoExporter.Watermark?
    /// What removing a file does with it (tests delete rather than fill the Trash).
    let discard: @Sendable (URL) throws -> Void
    /// Paths given to photos in this publish and not yet written, so two photos published at once with
    /// the same name don't both take it.
    private let reserved = Mutex<Set<String>>([])

    init(settings: PublishSettings, watermark: PhotoExporter.Watermark?,
         discard: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.settings = settings
        self.watermark = watermark
        self.discard = discard
    }

    /// The folder photos are published to: the export settings' folder and subfolder.
    var folder: URL? {
        let path = settings.export.folderPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        var folder = URL(filePath: path, directoryHint: .isDirectory)
        let subfolder = settings.export.subfolderName.trimmingCharacters(in: .whitespaces)
        if settings.export.usesSubfolder, !subfolder.isEmpty {
            folder = folder.appending(path: subfolder, directoryHint: .isDirectory)
        }
        return folder
    }

    @concurrent
    func publish(_ item: PublishItem) async throws -> RemotePhoto {
        guard let folder else { throw PublishError.noFolder }
        let name = ExportNaming.fileName(for: item.export, index: item.index, total: item.total, settings: settings.export)
        let previous = item.remote.map { URL(filePath: $0.id) }
        // A re-publish writes over its own file when it would get the same kind of file in the same folder.
        let url: URL
        if let previous, previous.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
           previous.pathExtension.lowercased() == (name as NSString).pathExtension.lowercased() {
            url = previous
        } else {
            url = reserve(folder.appending(path: name))
        }
        defer { release(url) }
        try await PhotoExporter.export(item.export, to: url, settings: settings.export, watermark: watermark)
        if let previous, previous != url, FileManager.default.fileExists(atPath: previous.path(percentEncoded: false)) {
            try? discard(previous)
        }
        return RemotePhoto(id: url.path(percentEncoded: false), url: url)
    }

    @concurrent
    func remove(_ photo: RemotePhoto) async throws {
        let url = URL(filePath: photo.id)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        try discard(url)
    }

    /// `url`, or the first of "-2", "-3"… that's neither on disk nor being written by this publish.
    private func reserve(_ url: URL) -> URL {
        reserved.withLock { reserved in
            func isTaken(_ url: URL) -> Bool {
                reserved.contains(url.path(percentEncoded: false).lowercased())
                    || FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
            }
            var candidate = url
            var copy = 2
            while isTaken(candidate) {
                candidate = ExportNaming.numbered(url, copy)
                copy += 1
            }
            reserved.insert(candidate.path(percentEncoded: false).lowercased())
            return candidate
        }
    }

    private func release(_ url: URL) {
        _ = reserved.withLock { $0.remove(url.path(percentEncoded: false).lowercased()) }
    }
}
