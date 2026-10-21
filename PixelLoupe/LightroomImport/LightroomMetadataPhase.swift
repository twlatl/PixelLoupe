import CoreData
import Foundation
import ImageIO

/// Brings over the title, caption, creator, copyright, headline, location, contact and IPTC Extension
/// fields (from the XMP packet and IPTC record Lightroom keeps for each photo) and the GPS position.
///
/// Only values that differ from the file's own metadata are stored, in the photo's catalog-only
/// metadata (`Photo.metadata`), so the inspector shows "Has been changed" just as it does for edits
/// made in PixelLoupe. Photos whose file can't be read keep every value, since there is nothing to
/// compare with. The `.xmp` sidecar files are never read: the catalog is authoritative.
nonisolated final class LightroomMetadataPhase: LightroomImportPhase {
    let title = "Importing metadata"

    private static let batchSize = 200
    private static let maximumConcurrentReads = 12

    private var cursor: LightroomRowCursor<LRMetadataRecord>?
    private var changed = 0

    func prepare(_ context: LightroomImportContext) async throws -> Int {
        cursor = try context.catalog.metadataCursor()
        return try context.catalog.scalar("SELECT COUNT(*) FROM Adobe_images")
    }

    func importBatch(_ context: LightroomImportContext) async throws -> Int {
        guard let cursor else { return 0 }
        let records = try cursor.next(Self.batchSize)
        guard !records.isEmpty else { return 0 }

        // What Lightroom has, for the photos that were imported and have anything to bring over.
        var candidates: [UUID: Candidate] = [:]
        for record in records {
            guard let id = context.idMap.photoID(forLightroomID: record.metadata.image) else { continue }
            let values = Self.values(from: record)
            let coordinate = Self.coordinate(of: record)
            if !values.isEmpty || coordinate != nil { candidates[id] = Candidate(values: values, coordinate: coordinate) }
        }
        guard !candidates.isEmpty else { return records.count }

        let managed = context.managedObjectContext
        let ids = Array(candidates.keys)
        let paths: [UUID: String] = await managed.perform {
            let request = Photo.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", ids)
            let photos = (try? managed.fetch(request)) ?? []
            return Dictionary(photos.map { ($0.id, $0.filePath) }) { first, _ in first }
        }
        let files = await Self.readFiles(paths)

        let batch = candidates
        let count: Int = await managed.perform {
            let request = Photo.fetchRequest()
            request.predicate = NSPredicate(format: "id IN %@", ids)
            var changed = 0
            for photo in (try? managed.fetch(request)) ?? [] {
                guard let candidate = batch[photo.id] else { continue }
                var metadata = photo.metadata
                let before = metadata
                Self.apply(candidate, file: files[photo.id] ?? nil, to: &metadata)
                // What searches look at is Lightroom's own text, whether or not the file says the same.
                if let title = candidate.values[.title] { photo.titleText = title }
                if let caption = candidate.values[.caption] { photo.captionText = caption }
                if let creator = candidate.values[.creator] { photo.creatorText = creator }
                if let copyright = candidate.values[.copyright] { photo.copyrightText = copyright }
                if metadata != before {
                    photo.metadata = metadata
                    // Lightroom's location at full precision, not the shown text's tenth of a second.
                    if photo.locationKind == .set, let coordinate = candidate.coordinate,
                       let location = GPSCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude) {
                        photo.setLocationOverride(.set, location)
                    }
                    changed += 1
                }
            }
            return changed
        }
        changed += count
        context.report.addImported("Photos with metadata edited in Lightroom", count: count)
        return records.count
    }

    // MARK: - Mapping

    struct Candidate: Sendable {
        var values: [MetadataField.ID: String]
        var coordinate: (latitude: Double, longitude: Double)?
    }

    /// Fields that aren't carried over from the XMP: the colour label is its own phase, and the
    /// rest are Lightroom's bookkeeping.
    private static let ignoredFields: Set<MetadataField.ID> = [.label, .metadataDate]

    /// The editable metadata fields Lightroom holds for a photo: the XMP packet first, then the
    /// IPTC record for anything the packet lacks.
    static func values(from record: LRMetadataRecord) -> [MetadataField.ID: String] {
        var file = FileMetadata()
        if let packet = record.metadata.compressedXMP.flatMap({ LightroomXMP.decode($0) }),
           let metadata = CGImageMetadataCreateFromXMPData(Data(packet.utf8) as CFData) {
            file.merge(xmp: metadata)
        }
        var values: [MetadataField.ID: String] = [:]
        for (id, value) in file.values where !ignoredFields.contains(id) && MetadataField.field(id).isEditable {
            values[id] = value
        }
        for (id, value) in [(MetadataField.ID.caption, record.metadata.caption), (.copyright, record.metadata.copyright)] {
            if values[id] == nil, let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                values[id] = text
            }
        }
        return values
    }

    static func coordinate(of record: LRMetadataRecord) -> (latitude: Double, longitude: Double)? {
        guard let latitude = record.gpsLatitude, let longitude = record.gpsLongitude,
              abs(latitude) <= 90, abs(longitude) <= 180, latitude != 0 || longitude != 0 else { return nil }
        return (latitude, longitude)
    }

    /// Stores Lightroom's values that differ from the file's (all of them when the file wasn't read).
    static func apply(_ candidate: Candidate, file: FileMetadata?, to metadata: inout PhotoMetadata) {
        for (id, value) in candidate.values {
            if let file, (file[id] ?? "") == value { continue }
            metadata[id] = value
        }
        if let coordinate = candidate.coordinate {
            let same = file?.coordinate.map {
                abs($0.latitude - coordinate.latitude) < 0.00001 && abs($0.longitude - coordinate.longitude) < 0.00001
            } ?? false
            if !same { metadata[.gps] = FileMetadata.formatCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude) }
        }
    }

    // MARK: - Reading files

    /// The files' own metadata, for those that can be reached. `nil` entries mean "not readable".
    @concurrent
    private static func readFiles(_ paths: [UUID: String]) async -> [UUID: FileMetadata?] {
        let entries = Array(paths)
        return await withTaskGroup(of: (UUID, FileMetadata?).self) { group in
            var results: [UUID: FileMetadata?] = [:]
            var next = 0
            func addNext() {
                guard next < entries.count else { return }
                let (id, path) = entries[next]
                next += 1
                group.addTask {
                    guard FileManager.default.fileExists(atPath: path) else { return (id, nil) }
                    return (id, FileMetadata.read(from: URL(filePath: path)))
                }
            }
            for _ in 0..<min(maximumConcurrentReads, entries.count) { addNext() }
            while let (id, metadata) = await group.next() {
                results[id] = metadata
                addNext()
            }
            return results
        }
    }
}
