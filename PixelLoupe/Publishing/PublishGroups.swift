import CoreData

/// A publish service's photos as the Library shows them: grouped into New, Modified, Published and
/// Deleted, in the grid's order within each.
@MainActor
struct PublishGroups {
    struct Group: Equatable {
        let state: PublishedPhoto.State
        var photoIDs: [NSManagedObjectID]
    }

    /// The groups that have photos, in ``PublishedPhoto/State`` order.
    let groups: [Group]
    /// Published photos since deleted from the catalog: still to be removed from the service, but with
    /// no photo left to show.
    let deletedFromCatalog: Int
    /// Why the last Publish couldn't publish or remove each photo that failed.
    let errors: [NSManagedObjectID: String]

    /// `photoIDs` (the photos in the service, in grid order) grouped by state.
    init(service: PublishService, photoIDs: [NSManagedObjectID], context: NSManagedObjectContext) {
        var byState: [PublishedPhoto.State: [NSManagedObjectID]] = [:]
        var errors: [NSManagedObjectID: String] = [:]
        for id in photoIDs {
            guard let photo = try? context.existingObject(with: id) as? Photo else { continue }
            // A smart album's match that hasn't joined the service yet is new to it.
            guard let entry = service.entry(for: photo) else {
                byState[.new, default: []].append(id)
                continue
            }
            byState[entry.state, default: []].append(id)
            if let error = entry.lastError { errors[id] = error }
        }
        groups = PublishedPhoto.State.allCases.compactMap { state in byState[state].map { Group(state: state, photoIDs: $0) } }
        deletedFromCatalog = service.publishedPhotos.count { $0.photo == nil && $0.publishedDate != nil && !$0.isDeleted }
        self.errors = errors
        hasAlbumWork = service.hasAlbumWork
    }

    /// Whether the service's albums have changes for Publish to send (RAW-185).
    let hasAlbumWork: Bool

    func count(of state: PublishedPhoto.State) -> Int {
        (groups.first { $0.state == state }?.photoIDs.count ?? 0) + (state == .deleted ? deletedFromCatalog : 0)
    }

    /// Whether Publish has anything to do.
    var hasWork: Bool {
        count(of: .new) + count(of: .modified) + count(of: .deleted) > 0 || hasAlbumWork
    }
}
