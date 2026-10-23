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

        /// The service's icon (an SF Symbol).
        var symbolName: String {
            switch self {
            case .hardDrive: "externaldrive"
            case .flickr: "globe"
            }
        }

        /// How many photos are published at once: Flickr throttles busy API keys.
        var concurrency: Int {
            switch self {
            case .hardDrive: max(1, min(3, ProcessInfo.processInfo.activeProcessorCount / 3))
            case .flickr: 2
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
    /// Its color label in the sidebar (model v19, RAW-184); see `label`.
    @NSManaged var colorLabel: Int16
    @NSManaged var publishedPhotos: Set<PublishedPhoto>

    @nonobjc class func fetchRequest() -> NSFetchRequest<PublishService> {
        NSFetchRequest<PublishService>(entityName: "PublishService")
    }

    var kind: Kind {
        get { Kind(rawValue: kindValue) ?? .hardDrive }
        set { kindValue = newValue.rawValue }
    }

    var label: ColorLabel {
        get { ColorLabel(rawValue: colorLabel) ?? .none }
        set { colorLabel = newValue.rawValue }
    }

    var settings: PublishSettings {
        get { settingsData.flatMap { try? JSONDecoder().decode(PublishSettings.self, from: $0) } ?? PublishSettings(kind) }
        set { settingsData = try? JSONEncoder().encode(newValue) }
    }

    /// What publishes this service, with its settings and (for Flickr) its sign-in.
    @MainActor
    func publisher(credentials: FlickrCredentialStore = KeychainFlickrCredentialStore.shared) -> any Publisher {
        var settings = settings
        let watermark = PhotoExporter.Watermark(settings.export)
        switch kind {
        case .hardDrive:
            return HardDrivePublisher(settings: settings, watermark: watermark)
        case .flickr:
            guard Secrets.hasFlickr else { return UnavailablePublisher(reason: FlickrError.notConfigured.errorDescription ?? "") }
            guard let account = credentials.credentials(for: id) else {
                return UnavailablePublisher(reason: "Sign in to Flickr for “\(displayName)” in the Publishing Manager first.", stopsPublishing: true)
            }
            // Flickr takes JPEGs (the Publishing Manager doesn't offer anything else).
            settings.export.format = .jpeg
            return FlickrPublisher(api: FlickrAPI(credentials: account), settings: settings, watermark: watermark)
        }
    }

    /// Where the service's photos can be seen: its folder, or the Flickr account's photostream. Nil for a
    /// Flickr service nobody has signed in to.
    @MainActor
    func location(credentials: FlickrCredentialStore = KeychainFlickrCredentialStore.shared) -> URL? {
        switch kind {
        case .hardDrive:
            HardDrivePublisher(settings: settings, watermark: nil).folder
        case .flickr:
            credentials.credentials(for: id).flatMap { URL(string: "https://www.flickr.com/photos/\($0.userID)/") }
        }
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

    /// Marks every published photo Modified, so the next Publish sends them all again: after settings
    /// that change how they're rendered, named or titled.
    func markAllForRepublish() {
        for entry in publishedPhotos where entry.publishedDate != nil {
            // Earlier than any edit, so each counts as edited since it was published.
            entry.publishedDate = .distantPast
        }
    }

    /// Whether any photo has been published, so there's something for Mark to Republish to mark.
    var hasPublishedPhotos: Bool {
        publishedPhotos.contains { $0.publishedDate != nil && !$0.isDeleted }
    }

    /// Reset Export Status: forgets what was published, so every photo is New again. Nothing changes on
    /// the service itself, and photos waiting to be removed are dropped, since there's no longer a
    /// published copy to remove.
    func resetPublishStatus() {
        for entry in publishedPhotos {
            if entry.photo == nil || entry.isRemovalPending {
                managedObjectContext?.delete(entry)
                continue
            }
            entry.publishedDate = nil
            entry.remoteID = nil
            entry.remoteURL = nil
            entry.metadataFingerprint = nil
            entry.lastError = nil
        }
    }

    /// The service's entries in a state, in the order they were added.
    @MainActor
    func entries(in state: PublishedPhoto.State) -> [PublishedPhoto] {
        publishedPhotos.filter { !$0.isDeleted && $0.state == state }.sorted { $0.addedDate < $1.addedDate }
    }
}
