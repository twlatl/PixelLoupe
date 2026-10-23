import Foundation

/// A publish service's settings, as the Publishing Manager lays them out: the export settings every
/// published photo is rendered with, plus what only publishing has (the title, and Flickr's privacy and
/// safety). Codable with tolerant decoding, like ``ExportSettings``, so services survive new options.
nonisolated struct PublishSettings: Codable, Equatable, Sendable {
    /// What a published photo's title is set from.
    enum TitleSource: String, Codable, Sendable, CaseIterable {
        case title, caption, headline, filename, filenameWithoutExtension, none

        var title: String {
            switch self {
            case .title: "IPTC Title"
            case .caption: "Caption"
            case .headline: "Headline"
            case .filename: "Filename"
            case .filenameWithoutExtension: "Filename without Extension"
            case .none: "Leave Blank"
            }
        }
    }

    /// What re-publishing does to a title the photo already has on the service.
    enum TitleUpdate: String, Codable, Sendable, CaseIterable {
        case replace, keep

        var title: String { self == .replace ? "Replace Existing Title" : "Leave Existing Title" }
    }

    enum Safety: String, Codable, Sendable, CaseIterable {
        case safe, moderate, restricted

        var title: String { rawValue.capitalized }
    }

    enum ContentType: String, Codable, Sendable, CaseIterable {
        case photo, screenshot, other

        var title: String { rawValue.capitalized }
    }

    var export = ExportSettings()
    var titleSource = TitleSource.title
    var titleUpdate = TitleUpdate.replace
    // Privacy & Safety (Flickr). A private photo can still be shown to family and friends.
    var isPublic = true
    var isVisibleToFamily = false
    var isVisibleToFriends = false
    var safety = Safety.safe
    var hidesFromPublicAreas = false
    var contentType = ContentType.photo

    init() {}

    /// A new service's settings.
    init(_ kind: PublishService.Kind) {
        self.init()
        export.destination = .specificFolder
        export.existingFiles = .overwrite
        switch kind {
        case .hardDrive:
            export.usesSubfolder = true
            export.subfolderName = "Published"
        case .flickr:
            // Lightroom's Flickr defaults: Flickr takes JPEGs, and shows them in sRGB.
            export.format = .jpeg
            export.quality = 60
            export.colorSpace = .sRGB
            export.metadata = .allExceptRaw
        }
    }

    // Tolerant decoding: missing keys keep their defaults.
    init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let decoded = try? container.decodeIfPresent(T.self, forKey: key) { value = decoded }
        }
        read(.export, &export); read(.titleSource, &titleSource); read(.titleUpdate, &titleUpdate)
        read(.isPublic, &isPublic); read(.isVisibleToFamily, &isVisibleToFamily); read(.isVisibleToFriends, &isVisibleToFriends)
        read(.safety, &safety); read(.hidesFromPublicAreas, &hidesFromPublicAreas); read(.contentType, &contentType)
    }

    /// The title to publish a photo with, nil for none. A metadata field that's empty falls back to the
    /// file name, as in Lightroom ("If empty, Filename will be used").
    func title(for item: ExportItem) -> String? {
        let name = item.source.lastPathComponent
        let field: String? = switch titleSource {
        case .title: item.metadata[.title]
        case .caption: item.metadata[.caption]
        case .headline: item.metadata[.headline]
        case .filename: name
        case .filenameWithoutExtension: item.source.deletingPathExtension().lastPathComponent
        case .none: nil
        }
        guard titleSource != .none else { return nil }
        let trimmed = field?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? name : trimmed
    }
}
