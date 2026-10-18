import AppKit
import CoreData

/// Changes to collections, each saved and undoable as one step.
struct CollectionEditing {
    let store: CatalogStore
    private var context: NSManagedObjectContext { store.viewContext }

    private func commit(_ actionName: String) {
        context.undoManager?.setActionName(actionName)
        store.save()
    }

    func collection(_ id: UUID) -> PhotoCollection? { PhotoCollection.with(id: id, in: context) }

    func photos(_ ids: [NSManagedObjectID]) -> [Photo] {
        ids.compactMap { try? context.existingObject(with: $0) as? Photo }
    }

    @discardableResult
    func create(_ kind: PhotoCollection.Kind, named name: String, in parentID: UUID?,
                photos: [NSManagedObjectID] = [], rules: SmartCollectionRules? = nil) -> PhotoCollection {
        let parent = parentID.flatMap(collection)
        let collection = PhotoCollection.make(kind, named: name, in: parent?.kind == .set ? parent : nil, context: context)
        if let rules { collection.rules = rules }
        if kind == .collection { collection.photos = Set(self.photos(photos)) }
        let actionName = switch kind {
        case .collection: "New Collection"
        case .smart: "New Smart Collection"
        case .set: "New Collection Set"
        }
        commit(actionName)
        return collection
    }

    /// Adds photos to a (regular) collection.
    func add(_ ids: [NSManagedObjectID], to id: UUID) {
        guard let collection = collection(id), collection.kind == .collection else { return }
        let new = Set(photos(ids)).subtracting(collection.photos)
        guard !new.isEmpty else { return }
        collection.photos.formUnion(new)
        commit("Add to Collection")
    }

    func remove(_ ids: [NSManagedObjectID], from id: UUID) {
        guard let collection = collection(id), collection.kind == .collection else { return }
        let leaving = Set(photos(ids)).intersection(collection.photos)
        guard !leaving.isEmpty else { return }
        collection.photos.subtract(leaving)
        commit("Remove from Collection")
    }

    /// B (Lightroom's Add to Target Collection): adds the photos, or removes them when they're all
    /// in it already. Returns whether they were added.
    @discardableResult
    func toggle(_ ids: [NSManagedObjectID], in id: UUID) -> Bool {
        guard let collection = collection(id), collection.kind == .collection else { return false }
        let photos = Set(photos(ids))
        if photos.isSubset(of: collection.photos) {
            remove(ids, from: id)
            return false
        }
        add(ids, to: id)
        return true
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let collection = collection(id), !name.isEmpty, name != collection.name else { return }
        collection.name = name
        commit("Rename Collection")
    }

    func update(_ id: UUID, name: String, parent parentID: UUID?, rules: SmartCollectionRules) {
        guard let collection = collection(id) else { return }
        collection.name = name
        collection.rules = rules
        move(collection, to: parentID)
        commit("Edit Smart Collection")
    }

    private func move(_ collection: PhotoCollection, to parentID: UUID?) {
        let parent = parentID.flatMap(self.collection)
        // A set can't go inside itself or its own sets.
        var ancestor = parent
        while let current = ancestor {
            if current == collection { return }
            ancestor = current.parent
        }
        collection.parent = parent?.kind == .set ? parent : nil
    }

    /// Deletes collections (and, for sets, everything in them). Photos stay in the catalog.
    func delete(_ id: UUID) {
        guard let collection = collection(id) else { return }
        let name = collection.kind == .set ? "Delete Collection Set" : "Delete Collection"
        context.delete(collection)
        commit(name)
    }

    /// Every collection set, as "Set ▸ Subset" paths, for Location menus.
    func sets(excluding excluded: UUID? = nil) -> [(id: UUID, path: String)] {
        let request = PhotoCollection.fetchRequest()
        request.predicate = NSPredicate(format: "kindValue == %d", PhotoCollection.Kind.set.rawValue)
        return ((try? context.fetch(request)) ?? [])
            .filter { set in
                var current: PhotoCollection? = set
                while let item = current { if item.id == excluded { return false }; current = item.parent }
                return true
            }
            .map { ($0.id, $0.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Every regular collection, for Add to Collection menus.
    func collections() -> [(id: UUID, path: String)] {
        let request = PhotoCollection.fetchRequest()
        request.predicate = NSPredicate(format: "kindValue == %d", PhotoCollection.Kind.collection.rawValue)
        return ((try? context.fetch(request)) ?? [])
            .map { ($0.id, $0.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: - Starter smart collections

    /// Lightroom's starter smart collections, in a "Smart Collections" set, made once per catalog
    /// (new ones, and existing ones the first time they're opened with collections). Not undoable:
    /// they're part of the catalog, not an edit.
    func createDefaultSmartCollections() {
        guard !store.viewState.createdDefaultCollections else { return }
        let undoManager = context.undoManager
        undoManager?.disableUndoRegistration()
        defer { undoManager?.enableUndoRegistration() }

        let set = PhotoCollection.make(.set, named: "Smart Collections", in: nil, context: context)
        let defaults: [(String, SmartCollectionRules.Rule)] = [
            ("Five Stars", .init(field: .rating, operator: .is, value: "5")),
            ("Past Month", .init(field: .captureDate, operator: .inTheLast, value: "1", unit: .months)),
            ("Recently Modified", .init(field: .editDate, operator: .inTheLast, value: "2", unit: .days)),
            ("Without Keywords", .init(field: .keywords, operator: .isEmpty, value: "")),
        ]
        for (name, rule) in defaults {
            PhotoCollection.make(.smart, named: name, in: set, context: context).rules = SmartCollectionRules(rules: [rule])
        }
        context.processPendingChanges()
        store.save()
        store.viewState.createdDefaultCollections = true
    }
}
