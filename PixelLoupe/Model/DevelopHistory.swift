import CoreData
import Foundation

/// One step in a photo's Develop history: the adjustments after an edit, named for what was done
/// ("Adjust Exposure"). A step from a Lightroom catalog keeps Lightroom's settings text until it is
/// first looked at; then it is converted and the text dropped. Both are stored LZFSE-compressed,
/// because a history can run to hundreds of steps a photo.
@objc(DevelopHistoryStep)
nonisolated final class DevelopHistoryStep: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var date: Date
    @NSManaged var name: String
    /// Orders a photo's steps; later edits have larger numbers.
    @NSManaged var sequence: Int32
    @NSManaged var data: Data?
    @NSManaged var lightroomData: Data?
    @NSManaged var processVersion: String?
    @NSManaged var photo: Photo?

    @nonobjc class func fetchRequest() -> NSFetchRequest<DevelopHistoryStep> {
        NSFetchRequest<DevelopHistoryStep>(entityName: "DevelopHistoryStep")
    }
}

/// A named, saved set of Develop settings for one photo.
@objc(DevelopSnapshot)
nonisolated final class DevelopSnapshot: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var date: Date
    @NSManaged var name: String
    @NSManaged var data: Data?
    @NSManaged var lightroomData: Data?
    @NSManaged var processVersion: String?
    @NSManaged var photo: Photo?

    @nonobjc class func fetchRequest() -> NSFetchRequest<DevelopSnapshot> {
        NSFetchRequest<DevelopSnapshot>(entityName: "DevelopSnapshot")
    }
}

/// Recording, reading and converting Develop history and snapshots.
nonisolated enum DevelopHistory {
    /// The most steps kept for a photo; the oldest go first.
    static let maximumSteps = 500

    // MARK: Compression

    static func compress(_ data: Data) -> Data {
        (try? (data as NSData).compressed(using: .lzfse) as Data) ?? data
    }

    static func decompress(_ data: Data) -> Data {
        // Data that was never compressed (or is empty) reads as it is.
        (try? (data as NSData).decompressed(using: .lzfse) as Data) ?? data
    }

    /// The settings as compressed JSON, leaving out every section still at its default (a typical step
    /// changes one or two), so a step is a few hundred bytes. Default settings are `{}`.
    static func store(_ adjustments: PhotoAdjustments) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let full = try? encoder.encode(adjustments),
              let baseline = try? encoder.encode(PhotoAdjustments.default),
              var sections = (try? JSONSerialization.jsonObject(with: full)) as? [String: Any],
              let defaults = (try? JSONSerialization.jsonObject(with: baseline)) as? [String: Any] else {
            return compress(adjustments.encoded ?? Data("{}".utf8))
        }
        for (key, value) in defaults where (sections[key] as? NSObject)?.isEqual(value) == true { sections[key] = nil }
        let data = (try? JSONSerialization.data(withJSONObject: sections, options: [.sortedKeys])) ?? Data("{}".utf8)
        return compress(data)
    }

    // MARK: Steps

    static func steps(for photo: Photo) -> [DevelopHistoryStep] {
        photo.historySteps.filter { !$0.isDeleted }.sorted { $0.sequence < $1.sequence }
    }

    /// Adds a step for the photo's current settings. Nothing is recorded when they match the latest
    /// step. With `after`, the steps beyond it are dropped first, as after going back in the history.
    @discardableResult
    static func record(_ adjustments: PhotoAdjustments, name: String, for photo: Photo, after cursor: DevelopHistoryStep? = nil, date: Date = Date()) -> DevelopHistoryStep? {
        guard let context = photo.managedObjectContext else { return nil }
        var existing = steps(for: photo)
        if let cursor, let index = existing.firstIndex(of: cursor) {
            for step in existing[(index + 1)...] { context.delete(step) }
            existing = Array(existing[...index])
        }
        let data = store(adjustments)
        if let last = existing.last, last.data == data { return nil }
        let step = DevelopHistoryStep(context: context)
        step.id = UUID()
        step.date = date
        step.name = name
        step.sequence = (existing.last?.sequence ?? 0) + 1
        step.data = data
        step.photo = photo
        // The oldest steps go when there are too many.
        if existing.count + 1 > maximumSteps {
            for old in existing.prefix(existing.count + 1 - maximumSteps) { context.delete(old) }
        }
        return step
    }

    static func clearHistory(for photo: Photo) {
        guard let context = photo.managedObjectContext else { return }
        for step in photo.historySteps { context.delete(step) }
    }

    // MARK: Snapshots

    static func snapshots(for photo: Photo) -> [DevelopSnapshot] {
        photo.snapshots.filter { !$0.isDeleted }.sorted { ($0.date, $0.name) < ($1.date, $1.name) }
    }

    @discardableResult
    static func createSnapshot(named name: String, adjustments: PhotoAdjustments, for photo: Photo, date: Date = Date()) -> DevelopSnapshot? {
        guard let context = photo.managedObjectContext else { return nil }
        let snapshot = DevelopSnapshot(context: context)
        snapshot.id = UUID()
        snapshot.date = date
        snapshot.name = name
        snapshot.data = store(adjustments)
        snapshot.photo = photo
        return snapshot
    }

    // MARK: Reading

    /// The settings a step holds, converting a Lightroom step the first time it is read.
    static func adjustments(of step: DevelopHistoryStep) -> PhotoAdjustments? {
        resolve(data: &step.data, lightroomData: &step.lightroomData, processVersion: step.processVersion, photo: step.photo)
    }

    static func adjustments(of snapshot: DevelopSnapshot) -> PhotoAdjustments? {
        resolve(data: &snapshot.data, lightroomData: &snapshot.lightroomData, processVersion: snapshot.processVersion, photo: snapshot.photo)
    }

    private static func resolve(data: inout Data?, lightroomData: inout Data?, processVersion: String?, photo: Photo?) -> PhotoAdjustments? {
        if let data { return PhotoAdjustments(data: decompress(data)) }
        guard let stored = lightroomData, let photo else { return nil }
        let converted = convert(lightroomText: String(decoding: decompress(stored), as: UTF8.self), processVersion: processVersion, photo: photo)
        data = converted.map(store)
        if converted != nil { lightroomData = nil }
        return converted
    }

    /// Lightroom's settings text as PixelLoupe adjustments for `photo`, starting from the photo's own
    /// orientation (which isn't part of the develop settings).
    static func convert(lightroomText: String, processVersion: String?, photo: Photo) -> PhotoAdjustments? {
        guard let table = (try? LuaTableParser.parse(lightroomText))?.table else { return nil }
        var adjustments = PhotoAdjustments()
        adjustments.orientation = photo.adjustments.orientation
        let input = LightroomDevelopMapper.Input(
            settings: table, processVersion: processVersion, whiteBalance: nil,
            isRaw: SupportedImageTypes.isRaw(URL(filePath: "/x/" + photo.fileName)), seed: LightroomDevelopPhase.seed(for: photo.id),
            imageSize: photo.displayedPixelSize)
        _ = LightroomDevelopMapper.apply(input, to: &adjustments)
        return adjustments
    }
}
