import CoreData
import Foundation
import OSLog

/// One step of a Lightroom import (folders and photos, keywords, collections, develop settings…).
///
/// The importer calls `prepare` once, `importBatch` until it returns 0, then `finish`, saving the
/// catalog after every batch. Phases run one after another in the order the importer is given.
/// Everything is called from one task, so phases may use the catalog and context without locking;
/// they must not hold managed objects between calls (the context is reset after each save to keep
/// memory flat), and look photos up by `Photo.id` through ``LightroomImportContext/idMap``.
nonisolated protocol LightroomImportPhase: AnyObject {
    /// Shown in the progress window ("Importing keywords…").
    var title: String { get }
    /// Gets ready and returns the number of units of work (photos, keywords…) for the progress bar,
    /// or 0 if that isn't known.
    func prepare(_ context: LightroomImportContext) async throws -> Int
    /// Imports the next batch (32 to 500 units; fewer at the end) and returns how many it handled,
    /// or 0 when nothing is left. Insert into ``LightroomImportContext/managedObjectContext``; the
    /// importer saves.
    func importBatch(_ context: LightroomImportContext) async throws -> Int
    func finish(_ context: LightroomImportContext) async throws
}

extension LightroomImportPhase {
    func finish(_ context: LightroomImportContext) async throws {}
}

/// What a phase works with. Confined to the import task.
nonisolated final class LightroomImportContext: @unchecked Sendable {
    /// The Lightroom catalog being read.
    let catalog: LightroomCatalog
    /// A background context of the new catalog, saved by the importer after every batch.
    let managedObjectContext: NSManagedObjectContext
    /// Lightroom `id_local` → `Photo.id`.
    let idMap: LightroomIDMap
    let report = LightroomImportReportBuilder()
    let packageURL: URL
    let importDate = Date()
    /// Lightroom keyword `id_local` → the new `Tag`, filled by the keywords phase for the phases after it.
    var keywordObjectIDs: [Int: NSManagedObjectID] = [:]

    init(catalog: LightroomCatalog, managedObjectContext: NSManagedObjectContext, idMap: LightroomIDMap, packageURL: URL) {
        self.catalog = catalog
        self.managedObjectContext = managedObjectContext
        self.idMap = idMap
        self.packageURL = packageURL
    }
}

nonisolated struct LightroomImportProgress: Sendable, Equatable {
    var phaseIndex: Int
    var phaseCount: Int
    var phaseTitle: String
    var completed: Int
    /// 0 when the phase can't say how much work it has.
    var total: Int

    /// 0...1 across all phases, each weighted equally.
    var fraction: Double {
        guard phaseCount > 0 else { return 0 }
        let within = total > 0 ? min(1, Double(completed) / Double(total)) : 0
        return (Double(phaseIndex) + within) / Double(phaseCount)
    }
}

/// Turns a Lightroom catalog into a new PixelLoupe catalog by running ``LightroomImportPhase``s.
///
/// This is a one-time import: the Lightroom catalog is only read. The work runs off the main thread
/// and can be cancelled at any batch boundary by cancelling the calling task, which throws
/// `CancellationError`; the caller then deletes the partial catalog.
nonisolated enum LightroomImporter {
    private static let logger = Logger(subsystem: "net.pixegen.PixelLoupe", category: "LightroomImport")

    /// The phases of a real import, in order. Each import subtask adds its phase here.
    static let defaultPhases: [@Sendable () -> any LightroomImportPhase] = [
        { LightroomPhotosPhase() },
        { LightroomMetadataPhase() },
        { LightroomDevelopPhase() },
        { LightroomKeywordsPhase() },
        { LightroomFacesPhase() },
        { LightroomStacksPhase() },
        { LightroomCollectionsPhase() },
        { LightroomThumbnailsPhase() },
    ]

    /// The name of the smart collection that gathers photos with import differences.
    static let differencesCollectionName = "Imported with Differences"

    /// Imports into the catalog behind `managedObjectContext` (create it with `newBackgroundContext()`),
    /// and saves the report to `packageURL`.
    @concurrent
    static func run(
        catalog: LightroomCatalog,
        sourceName: String,
        summary: LightroomCatalogSummary,
        into managedObjectContext: NSManagedObjectContext,
        packageURL: URL,
        phases makePhases: [@Sendable () -> any LightroomImportPhase],
        progress: @escaping @Sendable (LightroomImportProgress) -> Void
    ) async throws -> LightroomImportReport {
        let started = Date()
        let context = LightroomImportContext(
            catalog: catalog, managedObjectContext: managedObjectContext, idMap: try LightroomIDMap(), packageURL: packageURL)
        let phases = makePhases.map { $0() }
        progress(LightroomImportProgress(phaseIndex: 0, phaseCount: phases.count, phaseTitle: phases.first?.title ?? "", completed: 0, total: 0))

        for (index, phase) in phases.enumerated() {
            try Task.checkCancellation()
            logger.info("Phase \(index + 1)/\(phases.count): \(phase.title, privacy: .public)")
            func report(_ completed: Int, _ total: Int) {
                progress(LightroomImportProgress(
                    phaseIndex: index, phaseCount: phases.count, phaseTitle: phase.title, completed: completed, total: total))
            }
            let total = try await phase.prepare(context)
            var completed = 0
            report(0, total)
            while true {
                try Task.checkCancellation()
                let handled = try await phase.importBatch(context)
                try await save(context)
                guard handled > 0 else { break }
                completed += handled
                report(completed, total)
            }
            try Task.checkCancellation()
            try await phase.finish(context)
            try await save(context)
        }

        try await makeDifferencesCollection(context)
        try Task.checkCancellation()
        let result = context.report.makeReport(
            sourceName: sourceName, lightroomVersion: summary.lightroomVersion, started: started, summary: summary)
        try result.save(to: packageURL)
        progress(LightroomImportProgress(phaseIndex: phases.count, phaseCount: phases.count, phaseTitle: "", completed: 0, total: 0))
        return result
    }

    /// Saves pending changes and resets the context, so a big import doesn't keep every photo in memory.
    private static func save(_ context: LightroomImportContext) async throws {
        let managed = context.managedObjectContext
        try await managed.perform {
            if managed.hasChanges { try managed.save() }
            managed.reset()
        }
    }

    private static func makeDifferencesCollection(_ context: LightroomImportContext) async throws {
        let managed = context.managedObjectContext
        try await managed.perform {
            let collection = PhotoCollection.make(.smart, named: differencesCollectionName, in: nil, context: managed)
            collection.rules = SmartCollectionRules(
                match: .all, rules: [.init(field: .importedWithDifferences, operator: .is, value: "true")])
            try managed.save()
            managed.reset()
        }
    }
}
