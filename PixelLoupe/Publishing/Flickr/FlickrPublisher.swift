import Foundation

/// Publishes to a Flickr account. A new photo is rendered and uploaded with its title, description,
/// tags, privacy and safety. A re-published photo is replaced when its pixels changed (keeping its ID,
/// page, comments and favourites), and has its title, description and tags updated; privacy isn't
/// changed after the first upload. A removed photo is deleted from Flickr.
nonisolated struct FlickrPublisher: Publisher {
    let api: FlickrAPI
    let settings: PublishSettings
    let watermark: PhotoExporter.Watermark?

    @concurrent
    func publish(_ item: PublishItem) async throws -> RemotePhoto {
        if let remote = item.remote {
            if item.hasEdits {
                try await withRenderedFile(item) { try await api.replace(remote.id, with: $0) }
            }
            try await updateMetadata(of: remote.id, item)
            return RemotePhoto(id: remote.id, url: pageURL(remote.id))
        }
        let id = try await withRenderedFile(item) { try await api.upload($0, uploadParameters(item)) }
        return RemotePhoto(id: id, url: pageURL(id))
    }

    @concurrent
    func remove(_ photo: RemotePhoto) async throws {
        do {
            try await api.call("flickr.photos.delete", ["photo_id": photo.id])
        } catch FlickrAPI.APIError.photoNotFound {
            // Already gone.
        }
    }

    /// The photo's page: flickr.com/photos/<account>/<photo>/.
    func pageURL(_ id: String) -> URL {
        URL(string: "https://www.flickr.com/photos/\(api.credentials.userID)/\(id)/")!
    }

    // MARK: - Fields

    /// The fields sent with a new photo.
    func uploadParameters(_ item: PublishItem) -> [String: String] {
        let safety = switch settings.safety { case .safe: "1"; case .moderate: "2"; case .restricted: "3" }
        let contentType = switch settings.contentType { case .photo: "1"; case .screenshot: "2"; case .other: "3" }
        var parameters = [
            "description": description(item),
            "tags": Self.tags(item.export.keywords),
            "is_public": settings.isPublic ? "1" : "0",
            "is_family": !settings.isPublic && settings.isVisibleToFamily ? "1" : "0",
            "is_friend": !settings.isPublic && settings.isVisibleToFriends ? "1" : "0",
            "safety_level": safety,
            "content_type": contentType,
            // 1 shows the photo in Flickr's public searches, 2 hides it from them.
            "hidden": settings.hidesFromPublicAreas ? "2" : "1",
        ]
        if let title = item.title { parameters["title"] = title }
        return parameters
    }

    /// Re-publishing: the description and tags, and the title unless the settings keep Flickr's.
    private func updateMetadata(of id: String, _ item: PublishItem) async throws {
        var meta = ["photo_id": id, "description": description(item)]
        if settings.titleUpdate == .replace { meta["title"] = item.title ?? "" }
        try await api.call("flickr.photos.setMeta", meta)
        try await api.call("flickr.photos.setTags", ["photo_id": id, "tags": Self.tags(item.export.keywords)])
    }

    private func description(_ item: PublishItem) -> String {
        item.export.metadata[.caption]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Flickr's tag list: space-separated, with multi-word tags in quotes.
    static func tags(_ keywords: [String]) -> String {
        keywords.map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
    }

    /// Renders the photo to a temporary JPEG, hands it to `body`, and deletes it.
    private func withRenderedFile<T>(_ item: PublishItem, _ body: (URL) async throws -> T) async throws -> T {
        let folder = FileManager.default.temporaryDirectory.appending(path: "PixelLoupe-Flickr-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = ExportNaming.fileName(for: item.export, index: item.index, total: item.total, settings: settings.export)
        let file = folder.appending(path: name)
        try await PhotoExporter.export(item.export, to: file, settings: settings.export, watermark: watermark)
        return try await body(file)
    }
}
