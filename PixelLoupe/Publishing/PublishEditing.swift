import CoreData

/// Adding photos to publish services and taking them out, as undoable edits (dropping on a service in
/// the sidebar, Add to Publish Service, Remove from Publish Service), and making and changing a service's
/// albums (RAW-185).
struct PublishEditing {
    let store: CatalogStore
    private var context: NSManagedObjectContext { store.viewContext }

    private func photos(_ ids: [NSManagedObjectID]) -> [Photo] {
        ids.compactMap { try? context.existingObject(with: $0) as? Photo }
    }

    func add(_ ids: [NSManagedObjectID], to serviceID: UUID) {
        guard let service = PublishService.with(id: serviceID, in: context) else { return }
        let photos = photos(ids)
        guard !photos.isEmpty else { return }
        service.add(photos)
        context.undoManager?.setActionName("Add to \(service.displayName)")
        store.save()
    }

    /// B with a service as the target collection: takes the photos out when they're all in the service
    /// already, otherwise adds them.
    func toggle(_ ids: [NSManagedObjectID], in serviceID: UUID) {
        guard let service = PublishService.with(id: serviceID, in: context) else { return }
        let photos = photos(ids)
        let allIn = !photos.isEmpty && photos.allSatisfy { service.entry(for: $0).map { !$0.isRemovalPending } ?? false }
        allIn ? remove(ids, from: serviceID) : add(ids, to: serviceID)
    }

    /// Takes photos out of a service: those never published go, published ones wait for the next Publish
    /// to remove them.
    func remove(_ ids: [NSManagedObjectID], from serviceID: UUID) {
        guard let service = PublishService.with(id: serviceID, in: context) else { return }
        let photos = photos(ids).filter { service.entry(for: $0) != nil }
        guard !photos.isEmpty else { return }
        service.remove(photos)
        context.undoManager?.setActionName("Remove from \(service.displayName)")
        store.save()
    }

    // MARK: - Albums

    func add(_ ids: [NSManagedObjectID], toAlbum albumID: UUID) {
        guard let album = PublishAlbum.with(id: albumID, in: context), album.kind == .album else { return }
        let photos = photos(ids)
        guard !photos.isEmpty else { return }
        album.add(photos)
        context.undoManager?.setActionName("Add to \(album.name)")
        store.save()
    }

    /// Takes photos out of an album; they stay in its service.
    func remove(_ ids: [NSManagedObjectID], fromAlbum albumID: UUID) {
        guard let album = PublishAlbum.with(id: albumID, in: context) else { return }
        album.remove(photos(ids))
        context.undoManager?.setActionName("Remove from \(album.name)")
        store.save()
    }

    /// B with an album as the target collection.
    func toggle(_ ids: [NSManagedObjectID], inAlbum albumID: UUID) {
        guard let album = PublishAlbum.with(id: albumID, in: context) else { return }
        let photos = photos(ids)
        let allIn = !photos.isEmpty && photos.allSatisfy { photo in album.entries.contains { $0.photo == photo && !$0.isRemovalPending } }
        allIn ? remove(ids, fromAlbum: albumID) : add(ids, toAlbum: albumID)
    }

    @discardableResult
    func createAlbum(_ kind: PublishAlbum.Kind, in serviceID: UUID, named name: String, description: String,
                     rules: SmartCollectionRules? = nil, importWarning: String? = nil, photos ids: [NSManagedObjectID] = []) -> PublishAlbum? {
        guard let service = PublishService.with(id: serviceID, in: context) else { return nil }
        let album = PublishAlbum.make(kind, named: name, in: service)
        album.albumDescription = description
        if let rules { album.rules = rules }
        album.importWarning = importWarning
        album.add(photos(ids))
        context.undoManager?.setActionName(kind == .smart ? "Create Smart Album" : "Create Album")
        store.save()
        return album
    }

    func updateAlbum(_ id: UUID, name: String, description: String, rules: SmartCollectionRules?) {
        guard let album = PublishAlbum.with(id: id, in: context) else { return }
        album.name = name
        album.albumDescription = description
        if let rules, album.kind == .smart {
            album.rules = rules
            album.importWarning = nil
        }
        context.undoManager?.setActionName(album.kind == .smart ? "Edit Smart Album" : "Edit Album")
        store.save()
    }

    func renameAlbum(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let album = PublishAlbum.with(id: id, in: context), album.name != name else { return }
        album.name = name
        context.undoManager?.setActionName("Rename Album")
        store.save()
    }

    func deleteAlbum(_ id: UUID) {
        guard let album = PublishAlbum.with(id: id, in: context) else { return }
        album.delete()
        context.undoManager?.setActionName("Delete Album")
        store.save()
    }
}
