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
