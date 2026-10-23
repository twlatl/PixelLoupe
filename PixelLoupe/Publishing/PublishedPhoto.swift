import CoreData
import CryptoKit

/// A photo's place in a publish service (model v18): added and waiting, published (where to, and when),
/// or waiting to be removed. The photo itself is nil once it's been deleted from the catalog, so its
/// published copy can still be removed.
@objc(PublishedPhoto)
nonisolated final class PublishedPhoto: NSManagedObject {
    /// The four groups the Library shows for a service, as in Lightroom.
    enum State: Int, Sendable, CaseIterable {
        case new, modified, published, deleted

        var title: String {
            switch self {
            case .new: "New Photos to Publish"
            case .modified: "Modified Photos to Re-Publish"
            case .published: "Published Photos"
            case .deleted: "Deleted Photos to Remove"
            }
        }
    }

    @NSManaged var addedDate: Date
    /// The photo's file name when it was added, for a photo since deleted from the catalog.
    @NSManaged var fileName: String
    /// When the photo was last published (when that publish started); nil until it has been.
    @NSManaged var publishedDate: Date?
    /// Where the service keeps the photo: a Flickr photo ID, or the published file's path.
    @NSManaged var remoteID: String?
    /// The published photo's page, or file URL.
    @NSManaged var remoteURL: String?
    /// ``fingerprint(_:)`` of the metadata last published, to see when it changes.
    @NSManaged var metadataFingerprint: String?
    /// Whether the photo was taken out of the service and is waiting for Publish to remove it.
    @NSManaged var isRemovalPending: Bool
    /// Why the last Publish couldn't publish or remove the photo; nil when it could.
    @NSManaged var lastError: String?
    @NSManaged var photo: Photo?
    @NSManaged var service: PublishService?

    @nonobjc class func fetchRequest() -> NSFetchRequest<PublishedPhoto> {
        NSFetchRequest<PublishedPhoto>(entityName: "PublishedPhoto")
    }

    @MainActor
    var state: State {
        guard let photo, !isRemovalPending else { return .deleted }
        guard let publishedDate else { return .new }
        return hasEditsSincePublished(photo, publishedDate) || hasMetadataChangesSincePublished ? .modified : .published
    }

    /// Whether the photo's pixels changed since it was published (its Develop settings were edited),
    /// so it has to be rendered and sent again rather than only have its metadata updated.
    var hasEditsSincePublished: Bool {
        guard let photo, let publishedDate else { return false }
        return hasEditsSincePublished(photo, publishedDate)
    }

    /// Whether the metadata that's published (title, caption, keywords, rating, location…) changed since
    /// the photo was published.
    @MainActor
    var hasMetadataChangesSincePublished: Bool {
        guard let photo, publishedDate != nil else { return false }
        return metadataFingerprint != Self.fingerprint(photo)
    }

    private func hasEditsSincePublished(_ photo: Photo, _ publishedDate: Date) -> Bool {
        photo.editDate > publishedDate
    }

    var remote: RemotePhoto? {
        remoteID.map { RemotePhoto(id: $0, url: remoteURL.flatMap(URL.init(string:))) }
    }

    /// A digest of the metadata a published photo carries, which changes when any of it does.
    static func fingerprint(_ item: ExportItem) -> String {
        fingerprint(metadata: item.metadata, keywords: item.keywords, rating: item.rating, gps: item.gps)
    }

    /// The same as the photo's ``ExportItem`` would give, without reading its Develop settings.
    @MainActor
    static func fingerprint(_ photo: Photo) -> String {
        fingerprint(metadata: photo.metadata, keywords: Tag.exportNames(for: photo.tags), rating: Int(photo.rating), gps: ExportGPS(photo))
    }

    private static func fingerprint(metadata: PhotoMetadata, keywords: [String], rating: Int, gps: ExportGPS) -> String {
        var text = metadata.values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        text.append("keywords=\(keywords.sorted().joined(separator: "|"))")
        text.append("rating=\(rating)")
        text.append("gps=\(gps)")
        let digest = SHA256.hash(data: Data(text.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
