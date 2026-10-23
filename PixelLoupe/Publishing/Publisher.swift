import Foundation

/// Where a service keeps a published photo: a Flickr photo ID and its page, or a published file.
nonisolated struct RemotePhoto: Sendable, Equatable {
    var id: String
    var url: URL?
}

/// A photo to publish, captured on the main actor so publishing never touches Core Data.
nonisolated struct PublishItem: Sendable {
    let export: ExportItem
    let title: String?
    /// Where the photo was published before, for a re-publish.
    let remote: RemotePhoto?
    /// Whether the photo's pixels changed since it was published, rather than only its metadata.
    let hasEdits: Bool
    /// The photo's place in this publish, for file naming's sequence numbers.
    let index: Int
    let total: Int
}

/// What sends photos to one kind of publish service, and takes them off it again (any thread).
/// Implementations do their heavy work off the main actor.
nonisolated protocol Publisher: Sendable {
    /// Publishes a photo, or re-publishes it over `item.remote`, and says where it went.
    func publish(_ item: PublishItem) async throws -> RemotePhoto
    /// Removes a published photo from the service. A photo that's already gone isn't an error.
    func remove(_ photo: RemotePhoto) async throws
}

/// A publisher whose service has albums (Flickr's, RAW-185). Albums are sent after the photos, with their
/// photos' IDs on the service.
///
/// Photos are added and removed one at a time, never by setting an album's whole list, so photos put in an
/// album by anyone else (on flickr.com, or from another catalog) are left where they are.
nonisolated protocol AlbumPublisher: Publisher {
    /// Makes an album holding `coverID`, and returns its ID.
    func createAlbum(title: String, description: String, coverID: String) async throws -> String
    func editAlbum(_ id: String, title: String, description: String) async throws
    /// Adds a photo to the end of an album. One that's already there isn't an error.
    func addAlbumPhoto(_ id: String, photoID: String) async throws
    /// Takes a photo out of an album. One that's already gone, or an album that's gone, isn't an error.
    func removeAlbumPhoto(_ id: String, photoID: String) async throws
}

/// The publisher for a service that can't publish (no API key in this build, or not signed in).
nonisolated struct UnavailablePublisher: Publisher {
    struct Unavailable: LocalizedError {
        let errorDescription: String?
    }

    struct StoppingUnavailable: LocalizedError, PublishStoppingError {
        let errorDescription: String?
    }

    let reason: String
    /// Whether Publish stops at the first photo, rather than failing each the same way.
    var stopsPublishing = false

    private var error: Error { stopsPublishing ? StoppingUnavailable(errorDescription: reason) : Unavailable(errorDescription: reason) }

    func publish(_ item: PublishItem) async throws -> RemotePhoto { throw error }
    func remove(_ photo: RemotePhoto) async throws { throw error }
}
