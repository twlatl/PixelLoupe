import CoreData
import Foundation

/// Keeps Lightroom's face regions with their photos, and the people named on them.
///
/// Each region becomes a ``FaceRegion`` (its bounding rectangle, in fractions of the photo as Lightroom
/// stores it); a region named with a person keyword points at that keyword, which is marked as a
/// person. The People view that would use them isn't part of PixelLoupe yet.
nonisolated final class LightroomFacesPhase: LightroomImportPhase {
    let title = "Importing face regions"

    private static let batchSize = 1_000

    private var cursor: LightroomRowCursor<LRFaceRow>?
    /// A face can come back once for each keyword linked to it; the first usable link wins.
    private var lastFace = -1
    private var carried: LRFaceRow?
    private var regions = 0
    private var named = 0
    private var people = Set<NSManagedObjectID>()

    func prepare(_ context: LightroomImportContext) async throws -> Int {
        cursor = try context.catalog.facesCursor()
        guard cursor != nil else { return 0 }
        return try context.catalog.scalar("SELECT COUNT(*) FROM AgLibraryFace", table: "AgLibraryFace")
    }

    func importBatch(_ context: LightroomImportContext) async throws -> Int {
        guard let cursor else { return 0 }
        let rows = try cursor.next(Self.batchSize)
        guard !rows.isEmpty else { return 0 }

        // Collapse the keyword links to one row per face: a usable (not rejected) link, else the face alone.
        var faces: [LRFaceRow] = []
        for row in rows {
            if row.id == lastFace, let last = faces.last ?? carried {
                // Another link to the same face: replace a missing or rejected one.
                if (last.keyword == nil || last.isRejected), row.keyword != nil, !row.isRejected {
                    if faces.isEmpty { carried = row } else { faces[faces.count - 1] = row }
                }
                continue
            }
            lastFace = row.id
            carried = nil
            faces.append(row)
        }

        let managed = context.managedObjectContext
        let keywordIDs = context.keywordObjectIDs
        let ids = Dictionary(faces.compactMap { face in context.idMap.photoID(forLightroomID: face.image).map { (face.image, $0) } }) { first, _ in first }
        let batch = faces
        let (made, withPerson, touched): (Int, Int, Set<NSManagedObjectID>) = await managed.perform {
            let request = Photo.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", Array(Set(ids.values)))
            let photos = Dictionary(((try? managed.fetch(request)) ?? []).map { ($0.id, $0) }) { first, _ in first }
            var made = 0, withPerson = 0
            var touched = Set<NSManagedObjectID>()
            for face in batch {
                guard let photoID = ids[face.image], let photo = photos[photoID] else { continue }
                let bounds = face.bounds
                guard bounds.width > 0, bounds.height > 0 else { continue }
                let region = FaceRegion(context: managed)
                region.id = UUID()
                region.x = bounds.x.clamped(to: 0...1)
                region.y = bounds.y.clamped(to: 0...1)
                region.width = min(bounds.width, 1 - region.x)
                region.height = min(bounds.height, 1 - region.y)
                region.clusterID = Int32(face.cluster ?? 0)
                region.photo = photo
                if face.isIgnored {
                    region.status = .ignored
                } else if let keyword = face.keyword, !face.isRejected, let tagID = keywordIDs[keyword],
                          let tag = try? managed.existingObject(with: tagID) as? Tag {
                    tag.isPerson = true
                    region.person = tag
                    region.status = face.isPicked ? .confirmed : .suggested
                    withPerson += 1
                    touched.insert(tagID)
                }
                made += 1
            }
            return (made, withPerson, touched)
        }
        regions += made
        named += withPerson
        people.formUnion(touched)
        return rows.count
    }

    func finish(_ context: LightroomImportContext) async throws {
        if regions > 0 { context.report.addImported("Face regions", count: regions) }
        if people.count > 0 { context.report.addImported("People", count: people.count) }
    }
}
