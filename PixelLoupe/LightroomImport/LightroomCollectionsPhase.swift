import CoreData
import Foundation

/// Imports Lightroom's collection sets, collections (with their photos in Lightroom's custom
/// order) and smart collections (with their rules translated, see ``LightroomSmartRules``).
///
/// The Quick Collection becomes a collection called "Quick Collection". Collections made by other
/// modules (print, slideshow, web gallery, book) are skipped and listed in the report. A smart
/// collection with a rule PixelLoupe can't express keeps the rule's Lua text and carries a warning.
nonisolated final class LightroomCollectionsPhase: LightroomImportPhase {
    let title = "Importing collections"

    private static let batchSize = 2_000

    private var cursor: LightroomRowCursor<LRCollectionImage>?
    private var collectionIDs: [Int: NSManagedObjectID] = [:]
    private var order: [Int: [(item: LRCollectionImage, arrival: Int, photo: UUID)]] = [:]
    private var members = 0
    private var importedKinds: [PhotoCollection.Kind: Int] = [:]
    private var skipped: [String: Int] = [:]
    private var warned = 0

    func prepare(_ context: LightroomImportContext) async throws -> Int {
        try await makeCollections(context)
        guard !collectionIDs.isEmpty else { return 0 }
        cursor = try context.catalog.collectionImageCursor()
        return try context.catalog.scalar("SELECT COUNT(*) FROM AgLibraryCollectionImage", table: "AgLibraryCollectionImage")
    }

    func importBatch(_ context: LightroomImportContext) async throws -> Int {
        guard let cursor else { return 0 }
        let rows = try cursor.next(Self.batchSize)
        guard !rows.isEmpty else { return 0 }

        var byCollection: [Int: [UUID]] = [:]
        for row in rows {
            guard collectionIDs[row.collection] != nil, let photo = context.idMap.photoID(forLightroomID: row.image) else { continue }
            byCollection[row.collection, default: []].append(photo)
            order[row.collection, default: []].append((row, order[row.collection]?.count ?? 0, photo))
        }
        guard !byCollection.isEmpty else { return rows.count }

        let managed = context.managedObjectContext
        let ids = collectionIDs
        let batch = byCollection
        let added: Int = await managed.perform {
            var all = Set<UUID>()
            for photos in batch.values { all.formUnion(photos) }
            let request = Photo.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", Array(all))
            let photos = Dictionary(((try? managed.fetch(request)) ?? []).map { ($0.id, $0) }) { first, _ in first }
            var added = 0
            for (collectionID, uuids) in batch {
                guard let objectID = ids[collectionID], let collection = try? managed.existingObject(with: objectID) as? PhotoCollection else { continue }
                for uuid in uuids {
                    if let photo = photos[uuid] {
                        collection.photos.insert(photo)
                        added += 1
                    }
                }
            }
            return added
        }
        members += added
        return rows.count
    }

    func finish(_ context: LightroomImportContext) async throws {
        // Lightroom's custom order, as each collection's order list.
        let managed = context.managedObjectContext
        let ids = collectionIDs
        let orders = order.mapValues { entries in
            entries.sorted { LRCollectionImage.isOrdered(($0.item, $0.arrival), before: ($1.item, $1.arrival)) }.map(\.photo)
        }
        await managed.perform {
            for (collectionID, photos) in orders {
                guard let objectID = ids[collectionID], let collection = try? managed.existingObject(with: objectID) as? PhotoCollection else { continue }
                collection.customOrder = photos
            }
        }

        let report = context.report
        let kinds = importedKinds
        if let count = kinds[.collection] { report.addImported("Collections", count: count) }
        if let count = kinds[.smart] { report.addImported("Smart collections", count: count) }
        if let count = kinds[.set] { report.addImported("Collection sets", count: count) }
        report.addImported("Photos in collections", count: members)
        for (kind, count) in skipped.sorted(by: { $0.key < $1.key }) {
            report.addWarning("\(count.formatted()) \(kind) collection\(count == 1 ? "" : "s") not imported: PixelLoupe has no \(kind) module.")
        }
    }

    // MARK: - Making the collections

    private func makeCollections(_ context: LightroomImportContext) async throws {
        let all = try context.catalog.collections()
        let contents = Dictionary(try context.catalog.collectionContents().map { ($0.collection, $0) }) { first, _ in first }
        var names: [Int: String] = [:]
        for collection in all { names[collection.id] = Self.displayName(of: collection) }
        let translationContext = LightroomSmartRules.Context(collectionNames: names)

        struct Plan {
            var collection: LRCollection
            var kind: PhotoCollection.Kind
            var name: String
            var rules: SmartCollectionRules?
            var lua: String?
            var warning: String?
        }
        var plans: [Plan] = []
        var skipped: [String: Int] = [:]
        var kept = Set<Int>()
        for collection in all {
            switch collection.kind {
            case .collection:
                plans.append(Plan(collection: collection, kind: .collection, name: Self.displayName(of: collection)))
            case .set:
                plans.append(Plan(collection: collection, kind: .set, name: collection.name))
            case .smartCollection:
                var plan = Plan(collection: collection, kind: .smart, name: collection.name)
                if let content = contents[collection.id], let parsed = try? content.parsed() {
                    let translation = LightroomSmartRules.translate(parsed, context: translationContext)
                    plan.rules = translation.rules
                    if !translation.unmapped.isEmpty {
                        plan.lua = content.text
                        plan.warning = "Not imported (PixelLoupe can't match these): " + translation.unmapped.joined(separator: "; ")
                    }
                } else {
                    plan.rules = SmartCollectionRules(rules: [])
                    plan.lua = contents[collection.id]?.text
                    plan.warning = "The rules couldn't be read."
                }
                plans.append(plan)
            case .system(let creationID):
                if Self.isQuickCollection(collection) {
                    plans.append(Plan(collection: collection, kind: .collection, name: Self.displayName(of: collection)))
                } else {
                    skipped[Self.module(of: creationID), default: 0] += 1
                    continue
                }
            }
            kept.insert(collection.id)
        }
        self.skipped = skipped

        let managed = context.managedObjectContext
        let planned = plans
        let keptIDs = kept
        let (ids, kinds, warned): ([Int: NSManagedObjectID], [PhotoCollection.Kind: Int], Int) = try await managed.perform {
            var created: [Int: PhotoCollection] = [:]
            var kinds: [PhotoCollection.Kind: Int] = [:]
            var warned = 0
            for plan in planned {
                let collection = PhotoCollection.make(plan.kind, named: plan.name, in: nil, context: managed)
                if let rules = plan.rules { collection.rules = rules }
                collection.luaRules = plan.lua
                collection.importWarning = plan.warning
                if plan.warning != nil { warned += 1 }
                created[plan.collection.id] = collection
                kinds[plan.kind, default: 0] += 1
            }
            // Sets nest; a collection whose set wasn't imported goes to the top level.
            for plan in planned {
                if let parentID = plan.collection.parent, keptIDs.contains(parentID), let parent = created[parentID], parent.kind == .set {
                    created[plan.collection.id]?.parent = parent
                }
            }
            try managed.save()
            return (created.mapValues(\.objectID), kinds, warned)
        }
        collectionIDs = ids
        importedKinds = kinds
        self.warned = warned
        for plan in plans where plan.warning != nil {
            context.report.addWarning("Smart collection “\(plan.name)”: \(plan.warning ?? "")")
        }
    }

    static func isQuickCollection(_ collection: LRCollection) -> Bool {
        collection.creationID == "com.adobe.ag.library.collection" && collection.name.lowercased() == "quick collection"
    }

    static func displayName(of collection: LRCollection) -> String {
        isQuickCollection(collection) ? "Quick Collection" : collection.name
    }

    /// `com.adobe.ag.slideshow.unsaved` → "slideshow".
    static func module(of creationID: String) -> String {
        let parts = creationID.split(separator: ".")
        guard parts.count >= 4 else { return "other" }
        return String(parts[3])
    }
}
