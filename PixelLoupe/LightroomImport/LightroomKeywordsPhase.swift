import CoreData
import Foundation

/// Recreates Lightroom's keyword tree (with synonyms, export flags and People) and assigns the
/// keywords to the imported photos.
///
/// The tree is small (hundreds of keywords), so it is made in one go; the assignments (tens of
/// thousands) are then added in batches, a batch of photos fetched at a time.
nonisolated final class LightroomKeywordsPhase: LightroomImportPhase {
    let title = "Importing keywords"

    private static let batchSize = 2_000

    private var cursor: LightroomRowCursor<LRKeywordAssignment>?
    private var tagIDs: [Int: NSManagedObjectID] = [:]
    private var assigned = 0

    func prepare(_ context: LightroomImportContext) async throws -> Int {
        try await makeTree(context)
        cursor = try context.catalog.cursor("SELECT image, tag FROM AgLibraryKeywordImage ORDER BY image, id_local") { row in
            LRKeywordAssignment(image: row.int(at: 0) ?? 0, keyword: row.int(at: 1) ?? 0)
        }
        return try context.catalog.scalar("SELECT COUNT(*) FROM AgLibraryKeywordImage", table: "AgLibraryKeywordImage")
    }

    func importBatch(_ context: LightroomImportContext) async throws -> Int {
        guard let cursor, !tagIDs.isEmpty else { return 0 }
        let assignments = try cursor.next(Self.batchSize)
        guard !assignments.isEmpty else { return 0 }

        // Group by photo: (photo uuid) -> keywords to add.
        var byPhoto: [UUID: [NSManagedObjectID]] = [:]
        for assignment in assignments {
            guard let photoID = context.idMap.photoID(forLightroomID: assignment.image),
                  let tagID = tagIDs[assignment.keyword] else { continue }
            byPhoto[photoID, default: []].append(tagID)
        }
        guard !byPhoto.isEmpty else { return assignments.count }

        let managed = context.managedObjectContext
        let batch = byPhoto
        let added: Int = await managed.perform {
            let request = Photo.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", Array(batch.keys))
            request.returnsObjectsAsFaults = false
            var added = 0
            for photo in (try? managed.fetch(request)) ?? [] {
                for tagID in batch[photo.id] ?? [] {
                    guard let tag = try? managed.existingObject(with: tagID) as? Tag else { continue }
                    photo.tags.insert(tag)
                    added += 1
                }
            }
            return added
        }
        assigned += added
        return assignments.count
    }

    func finish(_ context: LightroomImportContext) async throws {
        context.report.addImported("Keyword assignments", count: assigned)
    }

    // MARK: - The tree

    /// Creates a `Tag` for each Lightroom keyword with the same parents, flags and synonyms. The
    /// hidden root row (no name, no parent) isn't a keyword: the keywords under it are top level.
    private func makeTree(_ context: LightroomImportContext) async throws {
        let keywords = try context.catalog.keywords()
        let rootIDs = Set(keywords.filter { $0.parent == nil }.map(\.id))
        let synonyms = Dictionary(grouping: try context.catalog.keywordSynonyms(), by: \.keyword)
            .mapValues { $0.map(\.name) }
        let real = keywords.filter { !rootIDs.contains($0.id) }

        let managed = context.managedObjectContext
        let ids: [Int: NSManagedObjectID] = try await managed.perform {
            var created: [Int: Tag] = [:]
            for keyword in real {
                let tag = Tag(context: managed)
                tag.name = keyword.name.trimmingCharacters(in: .whitespacesAndNewlines)
                tag.includeOnExport = keyword.includeOnExport
                tag.includeParents = keyword.includeParents
                tag.includeSynonyms = keyword.includeSynonyms
                tag.isPerson = keyword.keywordType == "person"
                tag.synonyms = synonyms[keyword.id] ?? []
                created[keyword.id] = tag
            }
            for keyword in real {
                if let parentID = keyword.parent, let parent = created[parentID] { created[keyword.id]?.parent = parent }
            }
            for tag in created.values where tag.parent == nil { tag.refreshPath() }
            try managed.save()
            return created.mapValues(\.objectID)
        }
        tagIDs = ids
        context.keywordObjectIDs = ids
        context.report.addImported("Keywords", count: ids.count)
    }
}
