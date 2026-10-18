import CoreData
import Foundation

/// What a Lightroom import did, saved in the catalog package as `LightroomImport.json` so the
/// Library can reopen it (Library ▸ Lightroom Import Report).
///
/// Import phases record anything they could not carry over faithfully through
/// ``LightroomImportReportBuilder/recordDifference(_:title:for:)``. Each such photo remembers the
/// reason keys in `Photo.importDifferences`, which is what "Show Photos" and the "Imported with
/// Differences" smart collection filter on.
nonisolated struct LightroomImportReport: Codable, Equatable, Sendable {
    /// A count of something that was imported, e.g. "Photos" 55,396.
    struct Count: Codable, Equatable, Sendable {
        var title: String
        var count: Int
    }

    /// Photos grouped by why their settings were only partly imported, e.g. "Masks" (14).
    struct Group: Codable, Equatable, Sendable, Identifiable {
        /// Stored in `Photo.importDifferences`; lowercase letters, digits and hyphens.
        var key: String
        var title: String
        var photoCount: Int

        var id: String { key }
    }

    var formatVersion = 1
    var sourceName: String
    var lightroomVersion: String
    var importedAt: Date
    var duration: TimeInterval
    /// What was in the Lightroom catalog.
    var summary: LightroomCatalogSummary
    /// What phases imported, in phase order.
    var imported: [Count] = []
    var groups: [Group] = []
    /// Problems that aren't about one photo's settings (a file that could not be read, a skipped table).
    var warnings: [String] = []

    var photosWithDifferences: Int { groups.map(\.photoCount).max() ?? 0 }

    // MARK: - Storage

    static func load(from package: URL) -> LightroomImportReport? {
        guard let data = try? Data(contentsOf: CatalogPackage.lightroomImportReportURL(in: package)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: data)
    }

    func save(to package: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: CatalogPackage.lightroomImportReportURL(in: package), options: .atomic)
    }

    static func exists(in package: URL) -> Bool {
        FileManager.default.fileExists(atPath: CatalogPackage.lightroomImportReportURL(in: package).path(percentEncoded: false))
    }

    // MARK: - Filtering

    /// Selects photos with the difference `reason`, or with any when `nil`.
    static func predicate(forReason reason: String?) -> NSPredicate {
        guard let reason else { return NSPredicate(format: "importDifferences != nil") }
        return NSPredicate(format: "importDifferences CONTAINS %@", "|\(reason)|")
    }

    /// A group's title for the filmstrip's scope text.
    static func title(forReason reason: String?) -> String {
        reason.map { key in key.replacingOccurrences(of: "-", with: " ").capitalized } ?? "photos imported with differences"
    }
}

/// Collects the report while an import runs. Phases call it from their `importBatch`.
nonisolated final class LightroomImportReportBuilder: @unchecked Sendable {
    private var imported: [(title: String, count: Int)] = []
    private var groups: [String: (title: String, count: Int)] = [:]
    private var groupOrder: [String] = []
    private(set) var warnings: [String] = []

    /// Adds `count` to the line `title` in the "imported" totals.
    func addImported(_ title: String, count: Int) {
        if let index = imported.firstIndex(where: { $0.title == title }) {
            imported[index].count += count
        } else {
            imported.append((title, count))
        }
    }

    /// Notes that something about `photo` was not (or not exactly) carried over. `key` is a short
    /// identifier shared by every photo with the same difference (`masks`, `upright`); `title` is the
    /// user-facing group name, such as "Masks" or "Camera profile ‘Adobe Landscape’ approximated".
    /// Calling it twice for one photo and key counts the photo once.
    func recordDifference(_ key: String, title: String, for photo: Photo) {
        let token = "|\(key)|"
        let existing = photo.importDifferences ?? "|"
        guard !existing.contains(token) else { return }
        photo.importDifferences = existing + key + "|"
        if groups[key] == nil {
            groups[key] = (title, 0)
            groupOrder.append(key)
        }
        groups[key]?.count += 1
    }

    func addWarning(_ text: String) {
        warnings.append(text)
    }

    func makeReport(
        sourceName: String, lightroomVersion: String, started: Date, summary: LightroomCatalogSummary
    ) -> LightroomImportReport {
        LightroomImportReport(
            sourceName: sourceName, lightroomVersion: lightroomVersion,
            // Whole seconds, which is all the JSON keeps.
            importedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
            duration: Date().timeIntervalSince(started), summary: summary,
            imported: imported.map { .init(title: $0.title, count: $0.count) },
            groups: groupOrder.compactMap { key in
                groups[key].map { .init(key: key, title: $0.title, photoCount: $0.count) }
            }
            .sorted { $0.photoCount > $1.photoCount },
            warnings: warnings)
    }
}
