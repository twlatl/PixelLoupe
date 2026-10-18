import CoreData

/// A collection (photos added by hand), smart collection (photos matching rules) or collection set
/// (a folder of collections), as in Lightroom. Named PhotoCollection to stay clear of Swift's
/// `Collection`.
@objc(PhotoCollection)
nonisolated final class PhotoCollection: NSManagedObject {
    enum Kind: Int16, Sendable, CaseIterable {
        case collection = 0
        case smart = 1
        case set = 2
    }

    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var createdDate: Date
    @NSManaged var kindValue: Int16
    /// A smart collection's rules, as JSON.
    @NSManaged var rulesData: Data?
    /// The photos' custom order, as a JSON array of `Photo.id` strings (model v8). Photos missing from
    /// it come after those in it, in capture order.
    @NSManaged var orderData: Data?
    /// For a smart collection imported from Lightroom with rules PixelLoupe can't express: the original
    /// Lua text, kept so nothing is lost (model v8).
    @NSManaged var luaRules: String?
    /// Why the collection may not match Lightroom's, shown with a warning icon (model v8).
    @NSManaged var importWarning: String?
    @NSManaged var parent: PhotoCollection?
    @NSManaged var children: Set<PhotoCollection>
    @NSManaged var photos: Set<Photo>

    @nonobjc class func fetchRequest() -> NSFetchRequest<PhotoCollection> {
        NSFetchRequest<PhotoCollection>(entityName: "PhotoCollection")
    }

    var kind: Kind {
        get { Kind(rawValue: kindValue) ?? .collection }
        set { kindValue = newValue.rawValue }
    }

    /// The custom order of the collection's photos (see `orderData`).
    var customOrder: [UUID] {
        get { orderData.flatMap { try? JSONDecoder().decode([UUID].self, from: $0) } ?? [] }
        set { orderData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    var rules: SmartCollectionRules {
        get { rulesData.flatMap { try? JSONDecoder().decode(SmartCollectionRules.self, from: $0) } ?? SmartCollectionRules() }
        set { rulesData = try? JSONEncoder().encode(newValue) }
    }

    /// What the Library shows when the collection is selected.
    var content: CollectionContent {
        switch kind {
        case .collection: .members(id)
        case .smart: .rules(rules)
        case .set: .union(children.map(\.content))
        }
    }

    @discardableResult
    static func make(_ kind: Kind, named name: String, in parent: PhotoCollection?, context: NSManagedObjectContext) -> PhotoCollection {
        let collection = PhotoCollection(context: context)
        collection.id = UUID()
        collection.name = name
        collection.kind = kind
        collection.createdDate = Date()
        collection.parent = parent
        return collection
    }

    static func with(id: UUID, in context: NSManagedObjectContext) -> PhotoCollection? {
        let request = fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        request.fetchLimit = 1
        return try? context.fetch(request).first
    }

    /// The collection's name with its sets, for menus: "Family ▸ Holidays".
    var path: String {
        (parent.map { "\($0.path) ▸ " } ?? "") + name
    }
}

/// The photos a selected collection shows, as a value (so the Library's filter stays a value).
nonisolated indirect enum CollectionContent: Equatable, Sendable {
    /// A collection's own photos.
    case members(UUID)
    /// A smart collection's matches.
    case rules(SmartCollectionRules)
    /// A collection set: everything in its collections.
    case union([CollectionContent])

    var predicate: NSPredicate {
        switch self {
        case .members(let id):
            return NSPredicate(format: "ANY collections.id == %@", id as CVarArg)
        case .rules(let rules):
            return rules.predicate
        case .union(let contents):
            guard !contents.isEmpty else { return NSPredicate(value: false) }
            return NSCompoundPredicate(orPredicateWithSubpredicates: contents.map(\.predicate))
        }
    }
}

nonisolated extension Photo {
    @NSManaged var collections: Set<PhotoCollection>
}
