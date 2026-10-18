import CoreData
import Foundation

/// Imports Lightroom's folder stacks: each stack's photos in order (the first is the top) and
/// whether it is collapsed. Photos that weren't imported are left out, and a stack with fewer than two
/// photos left is skipped. Collection stacks (stacks inside collections) are not imported, and are
/// listed in the report.
nonisolated final class LightroomStacksPhase: LightroomImportPhase {
    let title = "Importing stacks"

    private var stacks: [Int: Bool] = [:]  // Lightroom stack id → collapsed
    private var members: [Int: [(item: LRStackImage, arrival: Int, photo: UUID)]] = [:]
    private var cursor: LightroomRowCursor<LRStackImage>?
    private var made = 0
    private var stacked = 0

    func prepare(_ context: LightroomImportContext) async throws -> Int {
        stacks = Dictionary(try context.catalog.stacks().map { ($0.id, $0.collapsed) }) { first, _ in first }
        guard !stacks.isEmpty else { return 0 }
        cursor = try context.catalog.stackImageCursor()
        return try context.catalog.scalar("SELECT COUNT(*) FROM AgLibraryFolderStackImage", table: "AgLibraryFolderStackImage")
    }

    func importBatch(_ context: LightroomImportContext) async throws -> Int {
        guard let cursor else { return 0 }
        let rows = try cursor.next(2_000)
        for row in rows {
            guard stacks[row.stack] != nil, let photo = context.idMap.photoID(forLightroomID: row.image) else { continue }
            members[row.stack, default: []].append((row, members[row.stack]?.count ?? 0, photo))
        }
        return rows.count
    }

    func finish(_ context: LightroomImportContext) async throws {
        // Order each stack and make it, in one batch.
        let plans: [(collapsed: Bool, photos: [UUID])] = members.compactMap { stack, entries in
            guard entries.count >= 2, let collapsed = stacks[stack] else { return nil }
            let ordered = entries.sorted { LRCollectionImage.isOrdered(($0.item.asCollectionImage, $0.arrival), before: ($1.item.asCollectionImage, $1.arrival)) }
            return (collapsed, ordered.map(\.photo))
        }
        if !plans.isEmpty {
            let managed = context.managedObjectContext
            let (stacksMade, photosStacked): (Int, Int) = await managed.perform {
                let all = Array(Set(plans.flatMap(\.photos)))
                var photosByID: [UUID: Photo] = [:]
                for start in stride(from: 0, to: all.count, by: 1_000) {
                    let request = Photo.fetchRequest()
                    request.predicate = NSPredicate(format: "id IN %@", Array(all[start..<min(start + 1_000, all.count)]))
                    for photo in (try? managed.fetch(request)) ?? [] { photosByID[photo.id] = photo }
                }
                var stacksMade = 0, stacked = 0
                for plan in plans {
                    let photos = plan.photos.compactMap { photosByID[$0] }
                    guard photos.count >= 2 else { continue }
                    let stack = PhotoStack(context: managed)
                    stack.isCollapsed = plan.collapsed
                    for photo in photos { photo.stack = stack }
                    stack.renumber(photos)
                    stacksMade += 1
                    stacked += photos.count
                }
                return (stacksMade, stacked)
            }
            made = stacksMade
            stacked = photosStacked
        }
        context.report.addImported("Stacks", count: made)
        context.report.addImported("Photos in stacks", count: stacked)
        let collectionStacks = (try? context.catalog.scalar("SELECT COUNT(*) FROM AgLibraryCollectionStack", table: "AgLibraryCollectionStack")) ?? 0
        if collectionStacks > 0 {
            context.report.addWarning("\(collectionStacks.formatted()) stack\(collectionStacks == 1 ? "" : "s") inside collections not imported: PixelLoupe stacks belong to photos, not collections.")
        }
    }
}

nonisolated private extension LRStackImage {
    /// The same order key, to share the ordering used for collections.
    var asCollectionImage: LRCollectionImage {
        LRCollectionImage(collection: stack, image: image, position: position, positionNumber: positionNumber)
    }
}
