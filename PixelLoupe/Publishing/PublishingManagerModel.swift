import CoreData

/// What the Publishing Manager edits: a copy of every publish service, changed freely and written to
/// the catalog only on Save, so Cancel leaves the catalog as it was.
@MainActor
final class PublishingManagerModel {
    struct Draft: Identifiable {
        let id: UUID
        let kind: PublishService.Kind
        var name: String
        var settings: PublishSettings
        var accountName: String?
        /// The saved service; nil for one added since the window opened.
        let objectID: NSManagedObjectID?
        /// How many of its photos are on the service.
        let publishedCount: Int
        /// The settings when the window opened.
        let savedSettings: PublishSettings?

        var isSaved: Bool { objectID != nil }

        var displayName: String {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? kind.title : trimmed
        }

        /// Whether settings that change how photos are rendered, named or titled have changed, so the photos
        /// already published no longer match. Privacy and safety only apply to photos published from now on.
        var changesPublishedPhotos: Bool {
            guard let savedSettings, publishedCount > 0 else { return false }
            func rendering(_ settings: PublishSettings) -> PublishSettings {
                var settings = settings
                let defaults = PublishSettings(kind)
                settings.isPublic = defaults.isPublic
                settings.isVisibleToFamily = defaults.isVisibleToFamily
                settings.isVisibleToFriends = defaults.isVisibleToFriends
                settings.safety = defaults.safety
                settings.hidesFromPublicAreas = defaults.hidesFromPublicAreas
                settings.contentType = defaults.contentType
                return settings
            }
            return rendering(settings) != rendering(savedSettings)
        }
    }

    let context: NSManagedObjectContext
    private(set) var drafts: [Draft]
    /// Saved services removed since the window opened.
    private(set) var removed: [Draft] = []

    init(context: NSManagedObjectContext) {
        self.context = context
        drafts = PublishService.all(in: context).map { service in
            Draft(id: service.id, kind: service.kind, name: service.name, settings: service.settings, accountName: service.accountName,
                  objectID: service.objectID, publishedCount: service.publishedPhotos.count { $0.publishedDate != nil },
                  savedSettings: service.settings)
        }
    }

    /// Whether anything would be saved.
    var hasChanges: Bool {
        !removed.isEmpty || drafts.contains { draft in
            guard let objectID = draft.objectID, let service = try? context.existingObject(with: objectID) as? PublishService else { return true }
            return service.name != draft.name || service.settings != draft.settings
        }
    }

    /// Adds a new, unsaved service and returns its index.
    @discardableResult
    func add(_ kind: PublishService.Kind) -> Int {
        drafts.append(Draft(id: UUID(), kind: kind, name: kind.title, settings: PublishSettings(kind), accountName: nil,
                            objectID: nil, publishedCount: 0, savedSettings: nil))
        return drafts.count - 1
    }

    func remove(at index: Int) {
        let draft = drafts.remove(at: index)
        if draft.isSaved { removed.append(draft) }
    }

    func update(at index: Int, _ change: (inout Draft) -> Void) {
        change(&drafts[index])
    }

    /// Saved services whose changes no longer match their published photos (see `Draft.changesPublishedPhotos`).
    var draftsChangingPublishedPhotos: [Draft] {
        drafts.filter(\.changesPublishedPhotos)
    }

    /// Writes the drafts to the catalog: new services made, changed ones updated, removed ones deleted
    /// (and with them, the record of their published photos; nothing is removed from the services
    /// themselves). Services in `republishing` have every published photo marked Modified. Not undoable.
    func save(republishing: Set<UUID> = []) {
        context.processPendingChanges()
        context.undoManager?.disableUndoRegistration()
        defer {
            context.processPendingChanges()
            context.undoManager?.enableUndoRegistration()
        }
        for draft in removed {
            if let objectID = draft.objectID, let service = try? context.existingObject(with: objectID) { context.delete(service) }
        }
        for (index, draft) in drafts.enumerated() {
            let service: PublishService
            if let objectID = draft.objectID, let saved = try? context.existingObject(with: objectID) as? PublishService {
                service = saved
            } else {
                service = PublishService.make(draft.kind, in: context)
                service.id = draft.id
            }
            if service.name != draft.name { service.name = draft.name }
            if service.settings != draft.settings { service.settings = draft.settings }
            if service.sortOrder != Int32(index) { service.sortOrder = Int32(index) }
            if republishing.contains(draft.id) { service.markAllForRepublish() }
        }
        try? context.save()
    }
}
