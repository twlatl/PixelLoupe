import CoreData

/// Adding photos to publish services and taking them out, as undoable edits (dropping on a service in
/// the sidebar, Add to Publish Service, Remove from Publish Service).
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
}
