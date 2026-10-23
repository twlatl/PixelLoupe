import CoreData

/// An album in a Flickr publish service (model v20, RAW-185): a group of the service's photos, sent to
/// Flickr as an album (a photoset) when the service is published. Each photo is uploaded once however many
/// albums hold it, so taking a photo out of an album leaves it in the photostream.
///
/// Publish only adds and removes the photos this catalog put in the album. Anything else in it on Flickr
/// (added on flickr.com, or from another catalog) is left alone, and deleting the album here only takes this
/// catalog's photos out of it.
///
/// A smart album holds the photos that match its rules. They join the service at the next Publish, and
/// leave the album (but not the photostream) once they stop matching.
@objc(PublishAlbum)
nonisolated final class PublishAlbum: NSManagedObject {
    enum Kind: Int16, Sendable {
        case album = 0
        case smart = 1
    }

    @NSManaged var id: UUID
    @NSManaged var name: String
    /// Shown on the album's page on Flickr.
    @NSManaged var albumDescription: String
    @NSManaged var kindValue: Int16
    /// A smart album's rules, as JSON.
    @NSManaged var rulesData: Data?
    /// Why a smart album imported from Lightroom may not match Lightroom's, shown with a warning icon.
    @NSManaged var importWarning: String?
    @NSManaged var createdDate: Date
    /// The album's Flickr ID, once it's on Flickr.
    @NSManaged var remoteID: String?
    /// The name, description and photos (Flickr IDs, comma-separated) last sent, to tell what's changed since.
    /// The photos are the ones this catalog put in the album: the only ones Publish ever takes out.
    @NSManaged var publishedName: String?
    @NSManaged var publishedDescription: String?
    @NSManaged var publishedPhotoIDs: String?
    /// Deleted in PixelLoupe, and waiting for the next Publish to take this catalog's photos out of it on Flickr.
    @NSManaged var isDeletionPending: Bool
    @NSManaged var service: PublishService?
    /// A regular album's photos (a smart album's come from its rules).
    @NSManaged var entries: Set<PublishedPhoto>

    @nonobjc class func fetchRequest() -> NSFetchRequest<PublishAlbum> {
        NSFetchRequest<PublishAlbum>(entityName: "PublishAlbum")
    }

    var kind: Kind {
        get { Kind(rawValue: kindValue) ?? .album }
        set { kindValue = newValue.rawValue }
    }

    var rules: SmartCollectionRules {
        get { rulesData.flatMap { try? JSONDecoder().decode(SmartCollectionRules.self, from: $0) } ?? SmartCollectionRules() }
        set { rulesData = try? JSONEncoder().encode(newValue) }
    }

    /// The Library's source for the album.
    var scope: LibraryFilter.Scope? {
        service.map { .publishAlbum(id: id, serviceID: $0.id, rules: kind == .smart ? rules : nil) }
    }

    @discardableResult
    static func make(_ kind: Kind, named name: String, in service: PublishService) -> PublishAlbum {
        let album = PublishAlbum(context: service.managedObjectContext!)
        album.id = UUID()
        album.name = name
        album.kind = kind
        album.createdDate = Date()
        album.service = service
        return album
    }

    static func with(id: UUID, in context: NSManagedObjectContext) -> PublishAlbum? {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    // MARK: - Photos

    /// The catalog's photos in a regular album, or matching a smart album's rules.
    static func predicate(id: UUID, rules: SmartCollectionRules?) -> NSPredicate {
        rules?.predicate ?? NSPredicate(format: "SUBQUERY(publications, $entry, ANY $entry.albums.id == %@).@count > 0", id as CVarArg)
    }

    /// The photos the album holds: a regular album's (those waiting to be removed from the service aside),
    /// or every photo matching a smart album's rules, whether it's in the service yet or not.
    func photos() -> [Photo] {
        switch kind {
        case .album:
            return entries.compactMap { $0.isRemovalPending ? nil : $0.photo }
        case .smart:
            let request = Photo.fetchRequest()
            request.predicate = rules.predicate
            return (try? managedObjectContext?.fetch(request)) ?? []
        }
    }

    /// Adds photos to a regular album, adding them to the service too.
    func add(_ photos: [Photo]) {
        guard kind == .album, let service else { return }
        service.add(photos)
        for photo in photos {
            service.entry(for: photo).map { $0.albums.insert(self) }
        }
    }

    /// Takes photos out of a regular album. They stay in the service.
    func remove(_ photos: [Photo]) {
        guard let service else { return }
        for photo in photos {
            service.entry(for: photo).map { $0.albums.remove(self) }
        }
    }

    /// Deletes the album: at once if it was never on Flickr, otherwise at the next Publish.
    func delete() {
        if remoteID == nil {
            managedObjectContext?.delete(self)
        } else {
            isDeletionPending = true
            entries = []
        }
    }

    // MARK: - Publishing

    /// The Flickr IDs of the album's published photos, in capture order: what Flickr's album should hold.
    func publishedPhotoIDsToSend() -> [String] {
        guard let service else { return [] }
        return photos().compactMap { photo -> (Photo, String)? in
            guard let entry = service.entry(for: photo), !entry.isRemovalPending, let id = entry.remoteID else { return nil }
            return (photo, id)
        }
        .sorted { a, b in
            a.0.captureDate != b.0.captureDate ? a.0.captureDate < b.0.captureDate
                : a.0.fileName.localizedStandardCompare(b.0.fileName) == .orderedAscending
        }
        .map(\.1)
    }

    /// The Flickr IDs of the photos this catalog last put in the album.
    var sentPhotoIDs: Set<String> {
        get { Set((publishedPhotoIDs ?? "").split(separator: ",").map(String.init)) }
        set { publishedPhotoIDs = newValue.isEmpty ? nil : newValue.sorted().joined(separator: ",") }
    }

    /// Whether the next Publish has something to send for the album.
    var hasChangesToPublish: Bool {
        if isDeletionPending { return remoteID != nil }
        let photoIDs = publishedPhotoIDsToSend()
        guard !photoIDs.isEmpty else { return remoteID != nil }
        return remoteID == nil || Set(photoIDs) != sentPhotoIDs
            || name != publishedName || albumDescription != publishedDescription
    }

    /// Forgets the album's copy on Flickr (Reset Export Status).
    func forgetPublished() {
        if isDeletionPending {
            managedObjectContext?.delete(self)
            return
        }
        remoteID = nil
        publishedName = nil
        publishedDescription = nil
        publishedPhotoIDs = nil
    }

    /// The album's page on Flickr, once it's there.
    @MainActor
    func location(credentials: FlickrCredentialStore = KeychainFlickrCredentialStore.shared) -> URL? {
        guard let remoteID, let service, let account = credentials.credentials(for: service.id) else { return nil }
        return URL(string: "https://www.flickr.com/photos/\(account.userID)/albums/\(remoteID)/")
    }
}

nonisolated extension PublishedPhoto {
    /// The albums the photo is in, in its service (model v20).
    @NSManaged var albums: Set<PublishAlbum>
}
