import CoreData

/// A place photos are published to and kept up to date, as in Lightroom's Publish Services: a folder on
/// a hard drive, or a Flickr account (model v18). Each one has its own settings and its own published
/// photos, so two Flickr accounts are two services.
@objc(PublishService)
nonisolated final class PublishService: NSManagedObject {
    enum Kind: String, Sendable, CaseIterable {
        case hardDrive, flickr

        var title: String {
            switch self {
            case .hardDrive: "Hard Drive"
            case .flickr: "Flickr"
            }
        }

        /// How many photos are published at once: Flickr throttles busy API keys.
        var concurrency: Int {
            switch self {
            case .hardDrive: max(1, min(3, ProcessInfo.processInfo.activeProcessorCount / 3))
            case .flickr: 2
            }
        }

        /// What publishes for this kind of service.
        func publisher(settings: PublishSettings, watermark: PhotoExporter.Watermark?) -> any Publisher {
            switch self {
            case .hardDrive: HardDrivePublisher(settings: settings, watermark: watermark)
            case .flickr: UnavailablePublisher(reason: "Publishing to Flickr isn’t available yet.")
            }
        }
    }

    @NSManaged var id: UUID
    /// The Description shown in the sidebar and the Publishing Manager; empty for the kind's title.
    @NSManaged var name: String
    @NSManaged var kindValue: String
    /// The account the service publishes to ("Theodore Lee" on Flickr), once signed in.
    @NSManaged var accountName: String?
    /// ``PublishSettings`` as JSON.
    @NSManaged var settingsData: Data?
    @NSManaged var createdDate: Date
    /// The service's place in the sidebar and the Publishing Manager.
    @NSManaged var sortOrder: Int32
    @NSManaged var publishedPhotos: Set<PublishedPhoto>

    @nonobjc class func fetchRequest() -> NSFetchRequest<PublishService> {
        NSFetchRequest<PublishService>(entityName: "PublishService")
    }

    var kind: Kind {
        get { Kind(rawValue: kindValue) ?? .hardDrive }
        set { kindValue = newValue.rawValue }
    }

    var settings: PublishSettings {
        get { settingsData.flatMap { try? JSONDecoder().decode(PublishSettings.self, from: $0) } ?? PublishSettings(kind) }
        set { settingsData = try? JSONEncoder().encode(newValue) }
    }

    /// The name shown for the service: its Description, else the kind's title.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? kind.title : trimmed
    }

    @discardableResult
    static func make(_ kind: Kind, in context: NSManagedObjectContext) -> PublishService {
        let service = PublishService(context: context)
        service.id = UUID()
        service.kind = kind
        service.name = kind.title
        service.createdDate = Date()
        service.sortOrder = (all(in: context).map(\.sortOrder).max() ?? -1) + 1
        service.settings = PublishSettings(kind)
        return service
    }

    /// Every service, in sidebar order.
    static func all(in context: NSManagedObjectContext) -> [PublishService] {
        let request = fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true), NSSortDescriptor(key: "createdDate", ascending: true)]
        return (try? context.fetch(request)) ?? []
    }

    static func with(id: UUID, in context: NSManagedObjectContext) -> PublishService? {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    // MARK: - Photos

    /// The service's entry for a photo, if it's been added.
    func entry(for photo: Photo) -> PublishedPhoto? {
        photo.publications.first { $0.service == self }
    }

    /// Adds photos to publish. A photo already here stays as it is, except that one waiting to be removed
    /// is kept instead.
    func add(_ photos: some Sequence<Photo>) {
        guard let context = managedObjectContext else { return }
        for photo in photos {
            if let entry = entry(for: photo) {
                entry.isRemovalPending = false
            } else {
                let entry = PublishedPhoto(context: context)
                entry.addedDate = Date()
                entry.fileName = photo.fileName
                entry.photo = photo
                entry.service = self
            }
        }
    }

    /// Takes photos out of the service. Those never published just go; published ones wait in Deleted
    /// Photos to Remove until the next Publish removes them from the service.
    func remove(_ photos: some Sequence<Photo>) {
        for photo in photos {
            guard let entry = entry(for: photo) else { continue }
            if entry.publishedDate == nil {
                managedObjectContext?.delete(entry)
            } else {
                entry.isRemovalPending = true
            }
        }
    }

    /// Drops entries whose photo was deleted from the catalog before it was ever published: there's
    /// nothing to remove from the service.
    func pruneUnpublishedOrphans() {
        for entry in publishedPhotos where entry.photo == nil && entry.publishedDate == nil {
            managedObjectContext?.delete(entry)
        }
    }

    /// The service's entries in a state, in the order they were added.
    @MainActor
    func entries(in state: PublishedPhoto.State) -> [PublishedPhoto] {
        publishedPhotos.filter { !$0.isDeleted && $0.state == state }.sorted { $0.addedDate < $1.addedDate }
    }
}
