import Foundation

/// A catalog's Smart Previews (RAW-85): small stand-ins for originals, used when the original can't be read. Each is
/// a file in the package's `Smart Previews` folder, named by a photo's ID.
///
/// The folder is the record of which photos have one. It's listed when the catalog opens and kept up to date here as
/// Smart Previews are written and discarded, so views only ever look up a dictionary. A master and its virtual copies
/// share their file's Smart Preview, written under the master's ID.
@MainActor
final class SmartPreviewStore {
    /// Posted (on the main thread, with this object) when photos get or lose a Smart Preview. `userInfo["ids"]` is
    /// the `Set<UUID>` the files are named by.
    nonisolated static let didChangeNotification = Notification.Name("SmartPreviewStoreDidChange")

    let directory: URL
    /// Each Smart Preview file, by the ID it's named with.
    private(set) var files: [UUID: URL] = [:]
    private var loading: Task<Void, Never>?

    init(directory: URL) {
        self.directory = directory
    }

    nonisolated static func url(for id: UUID, fileExtension: String, in directory: URL) -> URL {
        directory.appending(path: "\(id.uuidString).\(fileExtension)")
    }

    /// Lists the folder, off the main thread, when the catalog opens. Later calls wait for the first.
    func load() async {
        if loading == nil {
            let directory = directory
            loading = Task { [weak self] in
                let listed = await Self.list(directory)
                guard let self else { return }
                // Files written while the folder was being listed are already here.
                files.merge(listed) { recorded, _ in recorded }
                post(Set(listed.keys))
            }
        }
        await loading?.value
    }

    /// The Smart Preview of `photo`'s file: its own, or that of a photo sharing the file (its master or a virtual copy).
    func file(for photo: Photo) -> URL? {
        if let own = files[photo.id] { return own }
        return photo.photosSharingFile.lazy.compactMap { self.files[$0.id] }.first
    }

    func contains(_ photo: Photo) -> Bool { file(for: photo) != nil }

    /// Records a Smart Preview just written to `url` for `id`, deleting `replaced` (the one it replaces, when that was
    /// named differently).
    func didWrite(_ url: URL, for id: UUID, replacing replaced: URL? = nil) {
        var changed: Set<UUID> = [id]
        if let replaced, replaced != url, let replacedID = files.first(where: { $0.value == replaced })?.key {
            try? FileManager.default.removeItem(at: replaced)
            files[replacedID] = nil
            changed.insert(replacedID)
        }
        if let previous = files[id], previous != url { try? FileManager.default.removeItem(at: previous) }
        files[id] = url
        post(changed)
    }

    /// Deletes the Smart Previews of `photos`' files. Their edits are untouched, and it isn't undoable (as in
    /// Lightroom).
    func discard(_ photos: [Photo]) {
        var changed = Set<UUID>()
        for id in Set(photos.flatMap { $0.photosSharingFile.map(\.id) }) {
            guard let file = files[id] else { continue }
            try? FileManager.default.removeItem(at: file)
            files[id] = nil
            changed.insert(id)
        }
        if !changed.isEmpty { post(changed) }
    }

    /// Deletes the Smart Previews named by IDs not in `kept`, the catalog's photos. Like thumbnails, a removed
    /// photo's Smart Preview stays while the app runs, so undoing the removal brings it back; this runs when the
    /// catalog opens.
    nonisolated static func pruneOrphans(in directory: URL, keeping kept: Set<UUID>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in names {
            let url = directory.appending(path: name)
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !kept.contains(id) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func post(_ ids: Set<UUID>) {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self, userInfo: ["ids": ids])
    }

    @concurrent
    nonisolated private static func list(_ directory: URL) async -> [UUID: URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        var files: [UUID: URL] = [:]
        // Files being written start with a dot.
        for name in names where !name.hasPrefix(".") {
            let url = directory.appending(path: name)
            if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) { files[id] = url }
        }
        return files
    }
}

/// What a photo can be drawn from right now, shown under the histograms as Lightroom does.
nonisolated enum PhotoSourceStatus: Equatable, Sendable {
    case original
    case originalAndSmartPreview
    /// The original is missing; its Smart Preview stands in.
    case smartPreview
    case missing

    var title: String {
        switch self {
        case .original: "Original"
        case .originalAndSmartPreview: "Original + Smart Preview"
        case .smartPreview: "Smart Preview"
        case .missing: "Original Missing"
        }
    }
}

extension CatalogStore {
    /// Where `photo` can be drawn from, or nil for a video (which has no Smart Preview).
    func sourceStatus(of photo: Photo) -> PhotoSourceStatus? {
        guard !photo.isVideo else { return nil }
        switch (availability.isMissing(photo.id), smartPreviews.contains(photo)) {
        case (false, false): return .original
        case (false, true): return .originalAndSmartPreview
        case (true, true): return .smartPreview
        case (true, false): return .missing
        }
    }
}
