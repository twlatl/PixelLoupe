import Foundation
import OSLog

nonisolated enum LightroomCatalogError: Error, Equatable {
    case notFound(URL)
    /// The catalog isn't a Lightroom Classic catalog (or can't be read as SQLite).
    case notACatalog(URL)
    /// Lightroom has the catalog open (`.lrcat.lock` exists). Quit Lightroom, or open a snapshot.
    case openInLightroom(lockFile: URL)
    /// The catalog was last saved by a Lightroom older than Classic 13.
    case unsupportedVersion(dbVersion: Int, crsVersion: String?)
    case snapshotFailed(String)
    case readFailed(String)
}

extension LightroomCatalogError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notFound(let url):
            "The Lightroom catalog “\(url.lastPathComponent)” could not be found."
        case .notACatalog(let url):
            "“\(url.lastPathComponent)” is not a Lightroom Classic catalog."
        case .openInLightroom:
            "This catalog is open in Lightroom Classic."
        case .unsupportedVersion(let dbVersion, _):
            "This catalog was saved by Lightroom Classic \(dbVersion / LightroomCatalog.versionUnit) or earlier. "
                + "Open it in Lightroom Classic 13 or later and upgrade it, then try again."
        case .snapshotFailed(let reason):
            "A copy of the catalog could not be made: \(reason)"
        case .readFailed(let reason):
            "The catalog could not be read: \(reason)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .openInLightroom:
            "Quit Lightroom Classic and try again, or import a snapshot copy of the catalog as it is now."
        default: nil
        }
    }
}

/// How ``LightroomCatalog`` reads the catalog file.
nonisolated enum LightroomCatalogAccess: Sendable {
    /// Read the catalog in place. Throws ``LightroomCatalogError/openInLightroom(lockFile:)`` if
    /// Lightroom has it open.
    case direct
    /// Copy the catalog (and its write-ahead log) to a temporary folder and read the copy. Works
    /// while Lightroom has the catalog open, and picks up changes Lightroom has not yet checkpointed.
    case snapshot
}

/// A read-only view of a Lightroom Classic catalog (`.lrcat`).
///
/// The catalog and the files next to it (`-wal`, `-shm`, `-data`, previews) are never written to:
/// the SQLite connection is read-only, and a catalog that might be changing is copied first.
/// Rows are streamed in batches in `id_local` order, so a catalog of 50,000+ photos is never held in
/// memory. An instance owns a SQLite connection and must be used from one task at a time; make one
/// per import phase or per concurrent reader.
nonisolated final class LightroomCatalog {
    /// Lightroom writes `Adobe_DBVersion` as `major × 100000 + minor × 1000 + patch`
    /// (`1504001` is Classic 15.4).
    static let versionUnit = 100_000
    /// The oldest catalog we accept: saved by Lightroom Classic 13.0.
    static let minimumDBVersion = 13 * versionUnit

    struct Version: Sendable, Equatable {
        var dbVersion: Int
        var crsVersion: String?

        /// The Lightroom Classic major version (13, 14, 15…).
        var lightroomMajor: Int { dbVersion / LightroomCatalog.versionUnit }
    }

    /// The `.lrcat` file the user chose (not the snapshot).
    let url: URL
    let version: Version
    /// Whether this instance reads a temporary copy.
    let isSnapshot: Bool

    private static let logger = Logger(subsystem: "net.pixegen.PixelLoupe", category: "LightroomImport")

    private let database: SQLiteDatabase
    private let snapshotDirectory: URL?
    private var columnCache: [String: Set<String>] = [:]

    /// Opens the catalog. Throws a ``LightroomCatalogError`` describing why it can't be read.
    init(url: URL, access: LightroomCatalogAccess = .direct) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw LightroomCatalogError.notFound(url)
        }
        self.url = url

        let lock = Self.lockFile(for: url)
        let isLocked = fileManager.fileExists(atPath: lock.path(percentEncoded: false))
        if isLocked, case .direct = access {
            throw LightroomCatalogError.openInLightroom(lockFile: lock)
        }
        // A write-ahead log with content holds changes the main file doesn't have yet. Reading the
        // original in place would miss them (or need to write to recover them), so copy instead.
        // A write-ahead log with content holds changes the main file doesn't have yet. Reading the
        // original in place would miss them (or need to write to recover them), so copy instead.
        let readCopy = (access == .snapshot) || Self.hasPendingChanges(url)

        let database: SQLiteDatabase
        var directory: URL?
        if readCopy {
            let copyDirectory = try Self.makeSnapshot(of: url)
            directory = copyDirectory
            do {
                database = try SQLiteDatabase(readingFrom: copyDirectory.appending(path: "catalog.lrcat"), immutable: false)
            } catch {
                try? fileManager.removeItem(at: copyDirectory)
                throw LightroomCatalogError.notACatalog(url)
            }
        } else {
            do {
                database = try SQLiteDatabase(readingFrom: url, immutable: true)
            } catch {
                throw LightroomCatalogError.notACatalog(url)
            }
        }

        do {
            version = try Self.readVersion(database, url: url)
        } catch {
            database.close()
            if let directory { try? fileManager.removeItem(at: directory) }
            throw error
        }
        isSnapshot = readCopy
        snapshotDirectory = directory
        self.database = database
    }

    deinit {
        close()
    }

    /// Closes the connection and deletes the snapshot copy, if there is one.
    func close() {
        database.close()
        if let snapshotDirectory {
            try? FileManager.default.removeItem(at: snapshotDirectory)
        }
    }

    // MARK: - Opening

    static func lockFile(for catalog: URL) -> URL {
        URL(fileURLWithPath: catalog.path(percentEncoded: false) + ".lock")
    }

    /// Whether Lightroom has the catalog open.
    static func isOpenInLightroom(_ catalog: URL) -> Bool {
        FileManager.default.fileExists(atPath: lockFile(for: catalog).path(percentEncoded: false))
    }

    private static func sidecar(_ catalog: URL, _ suffix: String) -> URL {
        URL(fileURLWithPath: catalog.path(percentEncoded: false) + suffix)
    }

    private static func hasPendingChanges(_ catalog: URL) -> Bool {
        let path = sidecar(catalog, "-wal").path(percentEncoded: false)
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int
        return (size ?? 0) > 0
    }

    private static func makeSnapshot(of catalog: URL) throws -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appending(path: "PixelLoupe-LightroomSnapshot-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: catalog, to: directory.appending(path: "catalog.lrcat"))
            for suffix in ["-wal", "-shm"] {
                let source = sidecar(catalog, suffix)
                if fileManager.fileExists(atPath: source.path(percentEncoded: false)) {
                    try fileManager.copyItem(at: source, to: sidecar(directory.appending(path: "catalog.lrcat"), suffix))
                }
            }
        } catch {
            try? fileManager.removeItem(at: directory)
            throw LightroomCatalogError.snapshotFailed(error.localizedDescription)
        }
        return directory
    }

    private static func readVersion(_ database: SQLiteDatabase, url: URL) throws -> Version {
        let values: [String: String]
        do {
            guard try database.hasTable("Adobe_variablesTable") else { throw LightroomCatalogError.notACatalog(url) }
            let statement = try database.prepare(
                "SELECT name, value FROM Adobe_variablesTable WHERE name IN ('Adobe_DBVersion', 'Adobe_CrsVersion')")
            var found: [String: String] = [:]
            while try statement.step() {
                if let name = statement.string(at: 0), let value = statement.string(at: 1) { found[name] = value }
            }
            values = found
        } catch let error as LightroomCatalogError {
            throw error
        } catch {
            throw LightroomCatalogError.notACatalog(url)
        }
        guard let dbVersion = values["Adobe_DBVersion"].flatMap({ Int($0) ?? Double($0).map { Int($0) } }) else {
            throw LightroomCatalogError.notACatalog(url)
        }
        guard dbVersion >= minimumDBVersion else {
            throw LightroomCatalogError.unsupportedVersion(dbVersion: dbVersion, crsVersion: values["Adobe_CrsVersion"])
        }
        return Version(dbVersion: dbVersion, crsVersion: values["Adobe_CrsVersion"])
    }

    // MARK: - Counts

    /// The number of rows in a catalog table, for progress reporting.
    func rowCount(of table: Table) throws -> Int {
        guard try database.hasTable(table.rawValue) else { return 0 }
        return try database.scalarInt("SELECT COUNT(*) FROM \(table.rawValue)")
    }

    enum Table: String, Sendable {
        case images = "Adobe_images"
        case files = "AgLibraryFile"
        case folders = "AgLibraryFolder"
        case keywords = "AgLibraryKeyword"
        case collections = "AgLibraryCollection"
        case developSettings = "Adobe_imageDevelopSettings"
        case historySteps = "Adobe_libraryImageDevelopHistoryStep"
        case snapshots = "Adobe_libraryImageDevelopSnapshot"
        case stacks = "AgLibraryFolderStack"
        case faces = "AgLibraryFace"
    }

    // MARK: - Small tables

    func rootFolders() throws -> [LRRootFolder] {
        try collect("""
            SELECT id_local, id_global, absolutePath, name, relativePathFromCatalog FROM AgLibraryRootFolder ORDER BY id_local
            """) { row in
            LRRootFolder(
                id: row.int(at: 0) ?? 0, globalID: row.string(at: 1) ?? "", absolutePath: row.string(at: 2) ?? "",
                name: row.string(at: 3) ?? "", relativePathFromCatalog: row.string(at: 4))
        }
    }

    func folders() throws -> [LRFolder] {
        try collect("""
            SELECT id_local, id_global, parentId, pathFromRoot, rootFolder, \(try column("AgLibraryFolder", "visibility"))
            FROM AgLibraryFolder ORDER BY id_local
            """) { row in
            LRFolder(
                id: row.int(at: 0) ?? 0, globalID: row.string(at: 1) ?? "", parentID: row.int(at: 2),
                pathFromRoot: row.string(at: 3) ?? "", rootFolder: row.int(at: 4) ?? 0, visibility: row.string(at: 5))
        }
    }

    /// The `id_local` of every folder that holds at least one photo's original file.
    func foldersWithPhotos() throws -> Set<Int> {
        Set(try collect("""
            SELECT DISTINCT f.folder FROM AgLibraryFile f JOIN Adobe_images i ON i.rootFile = f.id_local
            """) { $0.int(at: 0) ?? 0 })
    }

    /// The photos of the most recent import that still has any (Lightroom's Previous Import), by
    /// image `id_local`. Lightroom numbers rows as it creates them, so the newest import has the
    /// highest id. Empty when the catalog keeps no import records.
    func previousImportImages() throws -> Set<Int> {
        guard try database.hasTable("AgLibraryImportImage") else { return [] }
        return Set(try collect("""
            SELECT image FROM AgLibraryImportImage WHERE import = (SELECT MAX(import) FROM AgLibraryImportImage)
            """) { $0.int(at: 0) ?? 0 })
    }

    func keywords() throws -> [LRKeyword] {
        let type = try column("AgLibraryKeyword", "keywordType")
        let onExport = try column("AgLibraryKeyword", "includeOnExport", fallback: "1")
        let parents = try column("AgLibraryKeyword", "includeParents", fallback: "1")
        let synonyms = try column("AgLibraryKeyword", "includeSynonyms", fallback: "1")
        return try collect("""
            SELECT id_local, id_global, name, parent, genealogy, \(type), \(onExport), \(parents), \(synonyms)
            FROM AgLibraryKeyword ORDER BY id_local
            """) { row in
            LRKeyword(
                id: row.int(at: 0) ?? 0, globalID: row.string(at: 1) ?? "", name: row.string(at: 2) ?? "",
                parent: row.int(at: 3), genealogy: row.string(at: 4) ?? "", keywordType: row.string(at: 5),
                includeOnExport: (row.int(at: 6) ?? 1) != 0, includeParents: (row.int(at: 7) ?? 1) != 0,
                includeSynonyms: (row.int(at: 8) ?? 1) != 0)
        }
    }

    func keywordSynonyms() throws -> [LRKeywordSynonym] {
        guard try database.hasTable("AgLibraryKeywordSynonym") else { return [] }
        return try collect("SELECT keyword, name FROM AgLibraryKeywordSynonym ORDER BY keyword, id_local") { row in
            LRKeywordSynonym(keyword: row.int(at: 0) ?? 0, name: row.string(at: 1) ?? "")
        }
    }

    func collections() throws -> [LRCollection] {
        try collect("""
            SELECT id_local, creationId, name, parent, genealogy, systemOnly FROM AgLibraryCollection ORDER BY id_local
            """) { row in
            LRCollection(
                id: row.int(at: 0) ?? 0, creationID: row.string(at: 1) ?? "", name: row.string(at: 2) ?? "",
                parent: row.int(at: 3), genealogy: row.string(at: 4) ?? "",
                systemOnly: !(row.string(at: 5) ?? "").isEmpty && (row.double(at: 5) ?? 1) != 0)
        }
    }

    /// The Lua `content` records of collections (smart collection rules and the like).
    func collectionContents() throws -> [LRCollectionContent] {
        guard try database.hasTable("AgLibraryCollectionContent") else { return [] }
        return try collect("""
            SELECT collection, owningModule, content FROM AgLibraryCollectionContent ORDER BY collection, id_local
            """) { row in
            LRCollectionContent(collection: row.int(at: 0) ?? 0, owningModule: row.string(at: 1), text: row.string(at: 2) ?? "")
        }
    }

    // MARK: - Streams

    /// Photos and virtual copies, in `id_local` order.
    func images(batchSize: Int = 500, _ body: ([LRImage]) throws -> Void) throws {
        try stream("""
            SELECT id_local, id_global, rootFile, captureTime, orientation, rating, pick, colorLabels, masterImage,
                   copyName, fileFormat, fileWidth, fileHeight, touchTime
            FROM Adobe_images ORDER BY id_local
            """, batchSize: batchSize, body: body) { row in
            LRImage(
                id: row.int(at: 0) ?? 0, globalID: row.string(at: 1) ?? "", rootFile: row.int(at: 2) ?? 0,
                captureTime: row.string(at: 3), orientation: row.string(at: 4), rating: row.int(at: 5),
                pick: row.int(at: 6) ?? 0, colorLabels: row.string(at: 7) ?? "", masterImage: row.int(at: 8),
                copyName: row.string(at: 9), fileFormat: row.string(at: 10) ?? "", fileWidth: row.int(at: 11),
                fileHeight: row.int(at: 12), touchTime: row.double(at: 13) ?? 0)
        }
    }

    func files(batchSize: Int = 500, _ body: ([LRFile]) throws -> Void) throws {
        try stream("""
            SELECT id_local, id_global, baseName, extension, originalFilename, folder, md5, sidecarExtensions, modTime
            FROM AgLibraryFile ORDER BY id_local
            """, batchSize: batchSize, body: body) { row in
            LRFile(
                id: row.int(at: 0) ?? 0, globalID: row.string(at: 1) ?? "", baseName: row.string(at: 2) ?? "",
                fileExtension: row.string(at: 3) ?? "", originalFilename: row.string(at: 4) ?? "",
                folder: row.int(at: 5) ?? 0, md5: row.string(at: 6), sidecarExtensions: row.string(at: 7),
                modTime: row.double(at: 8))
        }
    }

    func keywordAssignments(batchSize: Int = 2_000, _ body: ([LRKeywordAssignment]) throws -> Void) throws {
        try stream("SELECT image, tag FROM AgLibraryKeywordImage ORDER BY image, id_local", batchSize: batchSize, body: body) { row in
            LRKeywordAssignment(image: row.int(at: 0) ?? 0, keyword: row.int(at: 1) ?? 0)
        }
    }

    func collectionImages(batchSize: Int = 2_000, _ body: ([LRCollectionImage]) throws -> Void) throws {
        try stream("""
            SELECT collection, image, positionInCollection FROM AgLibraryCollectionImage ORDER BY collection, id_local
            """, batchSize: batchSize, body: body) { row in
            LRCollectionImage(
                collection: row.int(at: 0) ?? 0, image: row.int(at: 1) ?? 0,
                position: row.isNumeric(at: 2) ? nil : row.string(at: 2), positionNumber: row.isNumeric(at: 2) ? row.double(at: 2) : nil)
        }
    }

    func stacks() throws -> [LRStack] {
        guard try database.hasTable("AgLibraryFolderStack") else { return [] }
        return try collect("SELECT id_local, id_global, collapsed FROM AgLibraryFolderStack ORDER BY id_local") { row in
            LRStack(id: row.int(at: 0) ?? 0, globalID: row.string(at: 1) ?? "", collapsed: (row.int(at: 2) ?? 0) != 0)
        }
    }

    func stackImages(batchSize: Int = 2_000, _ body: ([LRStackImage]) throws -> Void) throws {
        guard try database.hasTable("AgLibraryFolderStackImage") else { return }
        try stream("""
            SELECT stack, image, position FROM AgLibraryFolderStackImage ORDER BY stack, id_local
            """, batchSize: batchSize, body: body) { row in
            LRStackImage(
                stack: row.int(at: 0) ?? 0, image: row.int(at: 1) ?? 0,
                position: row.isNumeric(at: 2) ? nil : row.string(at: 2), positionNumber: row.isNumeric(at: 2) ? row.double(at: 2) : nil)
        }
    }

    /// Photos of stacks in each stack's rows (positions are compared by the caller).
    func stackImageCursor() throws -> LightroomRowCursor<LRStackImage>? {
        guard try database.hasTable("AgLibraryFolderStackImage") else { return nil }
        return try cursor("SELECT stack, image, position FROM AgLibraryFolderStackImage ORDER BY stack, id_local") { row in
            LRStackImage(
                stack: row.int(at: 0) ?? 0, image: row.int(at: 1) ?? 0,
                position: row.isNumeric(at: 2) ? nil : row.string(at: 2), positionNumber: row.isNumeric(at: 2) ? row.double(at: 2) : nil)
        }
    }

    /// Develop settings, one record per photo that has been developed, in photo order.
    func developSettings(batchSize: Int = 200, _ body: ([LRDevelopSettings]) throws -> Void) throws {
        let table = "Adobe_imageDevelopSettings"
        let masks = try column(table, "hasMasks", fallback: "0")
        let aiMasks = try column(table, "hasAIMasks", fallback: "0")
        let pointColor = try column(table, "hasPointColor", fallback: "0")
        let lensBlur = try column(table, "hasLensBlur", fallback: "0")
        let bigData = try column(table, "hasBigData", fallback: "0")
        try stream("""
            SELECT image, processVersion, whiteBalance, grayscale, \(masks), \(aiMasks), \(pointColor), \(lensBlur),
                   \(bigData), text
            FROM \(table) WHERE image IS NOT NULL ORDER BY image
            """, batchSize: batchSize, body: body) { row in
            LRDevelopSettings(
                image: row.int(at: 0) ?? 0, processVersion: row.string(at: 1), whiteBalance: row.string(at: 2),
                grayscale: (row.int(at: 3) ?? 0) != 0, hasMasks: (row.int(at: 4) ?? 0) != 0,
                hasAIMasks: (row.int(at: 5) ?? 0) != 0, hasPointColor: (row.int(at: 6) ?? 0) != 0,
                hasLensBlur: (row.int(at: 7) ?? 0) != 0, hasBigData: (row.int(at: 8) ?? 0) != 0, text: row.string(at: 9))
        }
    }

    /// The same records as ``developSettings(batchSize:_:)``, pulled a batch at a time by import phases.
    func developSettingsCursor() throws -> LightroomRowCursor<LRDevelopSettings> {
        let table = "Adobe_imageDevelopSettings"
        let masks = try column(table, "hasMasks", fallback: "0")
        let aiMasks = try column(table, "hasAIMasks", fallback: "0")
        let pointColor = try column(table, "hasPointColor", fallback: "0")
        let lensBlur = try column(table, "hasLensBlur", fallback: "0")
        let bigData = try column(table, "hasBigData", fallback: "0")
        return try cursor("""
            SELECT image, processVersion, whiteBalance, grayscale, \(masks), \(aiMasks), \(pointColor), \(lensBlur),
                   \(bigData), text
            FROM \(table) WHERE image IS NOT NULL ORDER BY image
            """) { row in
            LRDevelopSettings(
                image: row.int(at: 0) ?? 0, processVersion: row.string(at: 1), whiteBalance: row.string(at: 2),
                grayscale: (row.int(at: 3) ?? 0) != 0, hasMasks: (row.int(at: 4) ?? 0) != 0,
                hasAIMasks: (row.int(at: 5) ?? 0) != 0, hasPointColor: (row.int(at: 6) ?? 0) != 0,
                hasLensBlur: (row.int(at: 7) ?? 0) != 0, hasBigData: (row.int(at: 8) ?? 0) != 0, text: row.string(at: 9))
        }
    }

    /// Face regions, each with the keyword it was named with (if any), a face at a time.
    func facesCursor() throws -> LightroomRowCursor<LRFaceRow>? {
        guard try database.hasTable("AgLibraryFace") else { return nil }
        let hasLinks = try database.hasTable("AgLibraryKeywordFace")
        let link = hasLinks ? "LEFT JOIN AgLibraryKeywordFace k ON k.face = f.id_local" : ""
        let linkColumns = hasLinks ? "k.tag, k.userPick, k.userReject" : "NULL, NULL, NULL"
        return try cursor("""
            SELECT f.id_local, f.image, f.tl_x, f.tl_y, f.tr_x, f.tr_y, f.bl_x, f.bl_y, f.br_x, f.br_y, f.cluster, f.ignored, \(linkColumns)
            FROM AgLibraryFace f \(link) WHERE f.image IS NOT NULL
            ORDER BY f.image, f.id_local\(hasLinks ? ", k.rankOrder, k.id_local" : "")
            """) { row in
            LRFaceRow(
                id: row.int(at: 0) ?? 0, image: row.int(at: 1) ?? 0,
                topLeft: (row.double(at: 2) ?? 0, row.double(at: 3) ?? 0), topRight: (row.double(at: 4) ?? 0, row.double(at: 5) ?? 0),
                bottomLeft: (row.double(at: 6) ?? 0, row.double(at: 7) ?? 0), bottomRight: (row.double(at: 8) ?? 0, row.double(at: 9) ?? 0),
                cluster: row.int(at: 10), isIgnored: (row.int(at: 11) ?? 0) != 0,
                keyword: row.int(at: 12), isPicked: (row.int(at: 13) ?? 0) != 0, isRejected: (row.int(at: 14) ?? 0) != 0)
        }
    }

    /// History steps pulled a batch at a time (empty when the catalog has none).
    func historyStepsCursor() throws -> LightroomRowCursor<LRHistoryStep>? {
        guard try database.hasTable("Adobe_libraryImageDevelopHistoryStep") else { return nil }
        let bigData = try column("Adobe_libraryImageDevelopHistoryStep", "hasBigData", fallback: "0")
        return try cursor("""
            SELECT id_local, image, name, dateCreated, \(bigData), text
            FROM Adobe_libraryImageDevelopHistoryStep WHERE image IS NOT NULL ORDER BY image, id_local
            """) { row in
            LRHistoryStep(
                id: row.int(at: 0) ?? 0, image: row.int(at: 1) ?? 0, name: row.string(at: 2),
                dateCreated: row.double(at: 3), hasBigData: (row.int(at: 4) ?? 0) != 0, text: row.string(at: 5))
        }
    }

    func snapshotsCursor() throws -> LightroomRowCursor<LRSnapshot>? {
        guard try database.hasTable("Adobe_libraryImageDevelopSnapshot") else { return nil }
        let bigData = try column("Adobe_libraryImageDevelopSnapshot", "hasBigData", fallback: "0")
        return try cursor("""
            SELECT id_local, image, name, locked, \(bigData), text
            FROM Adobe_libraryImageDevelopSnapshot WHERE image IS NOT NULL ORDER BY image, id_local
            """) { row in
            LRSnapshot(
                id: row.int(at: 0) ?? 0, image: row.int(at: 1) ?? 0, name: row.string(at: 2),
                locked: (row.int(at: 3) ?? 0) != 0, hasBigData: (row.int(at: 4) ?? 0) != 0, text: row.string(at: 5))
        }
    }

    func historySteps(batchSize: Int = 200, _ body: ([LRHistoryStep]) throws -> Void) throws {
        guard try database.hasTable("Adobe_libraryImageDevelopHistoryStep") else { return }
        let bigData = try column("Adobe_libraryImageDevelopHistoryStep", "hasBigData", fallback: "0")
        try stream("""
            SELECT id_local, image, name, dateCreated, \(bigData), text
            FROM Adobe_libraryImageDevelopHistoryStep ORDER BY image, id_local
            """, batchSize: batchSize, body: body) { row in
            LRHistoryStep(
                id: row.int(at: 0) ?? 0, image: row.int(at: 1) ?? 0, name: row.string(at: 2),
                dateCreated: row.double(at: 3), hasBigData: (row.int(at: 4) ?? 0) != 0, text: row.string(at: 5))
        }
    }

    func snapshots(batchSize: Int = 200, _ body: ([LRSnapshot]) throws -> Void) throws {
        guard try database.hasTable("Adobe_libraryImageDevelopSnapshot") else { return }
        let bigData = try column("Adobe_libraryImageDevelopSnapshot", "hasBigData", fallback: "0")
        try stream("""
            SELECT id_local, image, name, locked, \(bigData), text
            FROM Adobe_libraryImageDevelopSnapshot ORDER BY image, id_local
            """, batchSize: batchSize, body: body) { row in
            LRSnapshot(
                id: row.int(at: 0) ?? 0, image: row.int(at: 1) ?? 0, name: row.string(at: 2),
                locked: (row.int(at: 3) ?? 0) != 0, hasBigData: (row.int(at: 4) ?? 0) != 0, text: row.string(at: 5))
        }
    }

    /// IPTC caption and copyright plus the XMP packet, one record per photo.
    func metadata(batchSize: Int = 200, _ body: ([LRMetadata]) throws -> Void) throws {
        let hasIPTC = try database.hasTable("AgLibraryIPTC")
        let hasXMP = try database.hasTable("Adobe_AdditionalMetadata")
        let iptcJoin = hasIPTC ? "LEFT JOIN AgLibraryIPTC p ON p.image = i.id_local" : ""
        let xmpJoin = hasXMP ? "LEFT JOIN Adobe_AdditionalMetadata m ON m.image = i.id_local" : ""
        try stream("""
            SELECT i.id_local, \(hasIPTC ? "p.caption, p.copyright" : "NULL, NULL"), \(hasXMP ? "m.xmp" : "NULL")
            FROM Adobe_images i \(iptcJoin) \(xmpJoin) ORDER BY i.id_local
            """, batchSize: batchSize, body: body) { row in
            LRMetadata(
                image: row.int(at: 0) ?? 0, caption: row.string(at: 1), copyright: row.string(at: 2),
                compressedXMP: row.data(at: 3))
        }
    }

    func exif(batchSize: Int = 500, _ body: ([LRExif]) throws -> Void) throws {
        guard try database.hasTable("AgHarvestedExifMetadata") else { return }
        try stream("""
            SELECT e.image, m.value, s.value, l.value, e.aperture, e.shutterSpeed, e.isoSpeedRating, e.focalLength,
                   e.flashFired, e.gpsLatitude, e.gpsLongitude
            FROM AgHarvestedExifMetadata e
            LEFT JOIN AgInternedExifCameraModel m ON m.id_local = e.cameraModelRef
            LEFT JOIN AgInternedExifCameraSN s ON s.id_local = e.cameraSNRef
            LEFT JOIN AgInternedExifLens l ON l.id_local = e.lensRef
            ORDER BY e.image
            """, batchSize: batchSize, body: body) { row in
            LRExif(
                image: row.int(at: 0) ?? 0, cameraModel: row.string(at: 1), cameraSerial: row.string(at: 2),
                lens: row.string(at: 3), aperture: row.double(at: 4), shutterSpeed: row.double(at: 5),
                isoSpeed: row.double(at: 6), focalLength: row.double(at: 7), flashFired: row.int(at: 8).map { $0 != 0 },
                gpsLatitude: row.double(at: 9), gpsLongitude: row.double(at: 10))
        }
    }

    func faces(batchSize: Int = 500, _ body: ([LRFace]) throws -> Void) throws {
        guard try database.hasTable("AgLibraryFace") else { return }
        try stream("""
            SELECT id_local, image, cluster, ignored, regionType, tl_x, tl_y, tr_x, tr_y, bl_x, bl_y, br_x, br_y
            FROM AgLibraryFace ORDER BY image, id_local
            """, batchSize: batchSize, body: body) { row in
            func point(_ x: Int32, _ y: Int32) -> LRPoint { LRPoint(x: row.double(at: x) ?? 0, y: row.double(at: y) ?? 0) }
            return LRFace(
                id: row.int(at: 0) ?? 0, image: row.int(at: 1) ?? 0, cluster: row.int(at: 2),
                ignored: (row.int(at: 3) ?? 0) != 0, regionType: row.int(at: 4) ?? 0, topLeft: point(5, 6),
                topRight: point(7, 8), bottomLeft: point(9, 10), bottomRight: point(11, 12))
        }
    }

    func videoInfo(batchSize: Int = 500, _ body: ([LRVideoInfo]) throws -> Void) throws {
        guard try database.hasTable("AgVideoInfo") else { return }
        try stream("""
            SELECT image, duration, frame_rate, has_audio FROM AgVideoInfo ORDER BY image
            """, batchSize: batchSize, body: body) { row in
            LRVideoInfo(
                image: row.int(at: 0) ?? 0, duration: row.double(at: 1), frameRate: row.double(at: 2),
                hasAudio: (row.int(at: 3) ?? 1) != 0)
        }
    }

    // MARK: - Cursors

    /// Photos (not virtual copies) with their file, import and harvested camera details, ordered by
    /// folder then id, so a batch mostly shares a folder.
    func photoCursor(virtualCopies: Bool = false) throws -> LightroomRowCursor<LRPhotoRecord> {
        let original = try column("Adobe_images", "originalCaptureTime")
        let hasHarvest = try database.hasTable("AgHarvestedExifMetadata")
        let hasImports = try database.hasTable("AgLibraryImportImage") && database.hasTable("AgLibraryImport")
        let harvestJoin = hasHarvest ? """
            LEFT JOIN AgHarvestedExifMetadata e ON e.image = i.id_local
            LEFT JOIN AgInternedExifCameraModel em ON em.id_local = e.cameraModelRef
            LEFT JOIN AgInternedExifLens el ON el.id_local = e.lensRef
            """ : ""
        func harvestColumn(_ name: String) -> String {
            hasHarvest ? ((try? column("AgHarvestedExifMetadata", name)) == name ? "e.\(name)" : "NULL") : "NULL"
        }
        let hasSettings = try database.hasTable("Adobe_imageDevelopSettings") && column("Adobe_imageDevelopSettings", "grayscale") != "NULL"
        let settingsJoin = hasSettings ? "LEFT JOIN Adobe_imageDevelopSettings s ON s.image = i.id_local" : ""
        let hasVideo = try database.hasTable("AgVideoInfo")
        let videoJoin = hasVideo ? "LEFT JOIN AgVideoInfo v ON v.image = i.id_local" : ""
        let importDate = hasImports ? """
            (SELECT MIN(imp.importDate) FROM AgLibraryImportImage ii JOIN AgLibraryImport imp ON imp.id_local = ii.import
             WHERE ii.image = i.id_local)
            """ : "NULL"
        return try cursor("""
            SELECT i.id_local, i.id_global, i.rootFile, i.captureTime, i.orientation, i.rating, i.pick, i.colorLabels,
                   i.masterImage, i.copyName, i.fileFormat, i.fileWidth, i.fileHeight, i.touchTime,
                   f.idx_filename, f.extension, f.folder, f.sidecarExtensions, \(importDate), \(original == "NULL" ? "NULL" : "i." + original),
                   \(hasHarvest ? "em.value, el.value" : "NULL, NULL"),
                   \(hasHarvest ? "\(harvestColumn("isoSpeedRating")), \(harvestColumn("focalLength")), \(harvestColumn("aperture")), \(harvestColumn("shutterSpeed")), \(harvestColumn("hasGPS"))" : "NULL, NULL, NULL, NULL, NULL"),
                   \(hasSettings ? "s.grayscale" : "NULL"),
                   \(hasVideo ? "v.duration, v.poster_frame, v.trim_start, v.trim_end" : "NULL, NULL, NULL, NULL")
            FROM Adobe_images i JOIN AgLibraryFile f ON f.id_local = i.rootFile \(harvestJoin) \(settingsJoin) \(videoJoin)
            WHERE \(virtualCopies ? "i.masterImage IS NOT NULL AND i.masterImage <> i.id_local" : "i.masterImage IS NULL OR i.masterImage = i.id_local")
            ORDER BY f.folder, i.id_local
            """) { row in
            LRPhotoRecord(
                image: LRImage(
                    id: row.int(at: 0) ?? 0, globalID: row.string(at: 1) ?? "", rootFile: row.int(at: 2) ?? 0,
                    captureTime: row.string(at: 3), orientation: row.string(at: 4), rating: row.int(at: 5),
                    pick: row.int(at: 6) ?? 0, colorLabels: row.string(at: 7) ?? "", masterImage: row.int(at: 8),
                    copyName: row.string(at: 9), fileFormat: row.string(at: 10) ?? "", fileWidth: row.int(at: 11),
                    fileHeight: row.int(at: 12), touchTime: row.double(at: 13) ?? 0),
                fileName: row.string(at: 14) ?? "", fileExtension: row.string(at: 15) ?? "", folder: row.int(at: 16) ?? 0,
                sidecarExtensions: row.string(at: 17), importDate: row.string(at: 18), originalCaptureTime: row.string(at: 19),
                harvestedCameraModel: row.string(at: 20), harvestedLens: row.string(at: 21),
                harvestedISO: row.int(at: 22) ?? 0, harvestedFocalLength: row.double(at: 23) ?? 0,
                // Lightroom keeps aperture and shutter speed as APEX values: f = 2^(Av/2), t = 2^-Tv.
                harvestedAperture: row.double(at: 24).map { $0 > 0 ? pow(2, $0 / 2) : 0 } ?? 0,
                harvestedShutterSpeed: row.double(at: 25).map { pow(2, -$0) } ?? 0,
                hasGPS: (row.int(at: 26) ?? 0) != 0, isGrayscale: (row.int(at: 27) ?? 0) != 0,
                videoDuration: row.double(at: 28) ?? 0, videoPoster: row.string(at: 29),
                videoTrimStart: row.string(at: 30), videoTrimEnd: row.string(at: 31))
        }
    }

    /// Collection memberships in Lightroom's order.
    func collectionImageCursor() throws -> LightroomRowCursor<LRCollectionImage> {
        try cursor("""
            SELECT collection, image, positionInCollection FROM AgLibraryCollectionImage ORDER BY collection, id_local
            """) { row in
            LRCollectionImage(
                collection: row.int(at: 0) ?? 0, image: row.int(at: 1) ?? 0,
                position: row.isNumeric(at: 2) ? nil : row.string(at: 2), positionNumber: row.isNumeric(at: 2) ? row.double(at: 2) : nil)
        }
    }

    /// IPTC caption/copyright, the XMP packet and the harvested GPS position of every photo, in photo order.
    func metadataCursor() throws -> LightroomRowCursor<LRMetadataRecord> {
        let hasIPTC = try database.hasTable("AgLibraryIPTC")
        let hasXMP = try database.hasTable("Adobe_AdditionalMetadata")
        let hasGPS = try database.hasTable("AgHarvestedExifMetadata")
        return try cursor("""
            SELECT i.id_local, \(hasIPTC ? "p.caption, p.copyright" : "NULL, NULL"), \(hasXMP ? "m.xmp" : "NULL"),
                   \(hasGPS ? "CASE WHEN e.hasGPS = 1 THEN e.gpsLatitude END, CASE WHEN e.hasGPS = 1 THEN e.gpsLongitude END" : "NULL, NULL")
            FROM Adobe_images i
            \(hasIPTC ? "LEFT JOIN AgLibraryIPTC p ON p.image = i.id_local" : "")
            \(hasXMP ? "LEFT JOIN Adobe_AdditionalMetadata m ON m.image = i.id_local" : "")
            \(hasGPS ? "LEFT JOIN AgHarvestedExifMetadata e ON e.image = i.id_local" : "")
            ORDER BY i.id_local
            """) { row in
            LRMetadataRecord(
                metadata: LRMetadata(
                    image: row.int(at: 0) ?? 0, caption: row.string(at: 1), copyright: row.string(at: 2),
                    compressedXMP: row.data(at: 3)),
                gpsLatitude: row.double(at: 4), gpsLongitude: row.double(at: 5))
        }
    }

    /// A pull-based stream of rows, for import phases that take a batch at a time.
    func cursor<Row>(_ sql: String, row: @escaping (SQLiteStatement) -> Row) throws -> LightroomRowCursor<Row> {
        do {
            return LightroomRowCursor(statement: try database.prepare(sql), row: row)
        } catch let error as SQLiteError {
            throw LightroomCatalogError.readFailed(error.message)
        }
    }

    // MARK: - Aggregates

    /// The first column of the first row of `sql`. With `table`, 0 when the catalog doesn't have it.
    func scalar(_ sql: String, table: String? = nil) throws -> Int {
        if let table, !(try database.hasTable(table)) { return 0 }
        do {
            return try database.scalarInt(sql)
        } catch let error as SQLiteError {
            throw LightroomCatalogError.readFailed(error.message)
        }
    }

    func hasColumn(_ table: String, _ column: String) throws -> Bool {
        try self.column(table, column) != "NULL"
    }

    /// Photo counts by Lightroom file format (`RAW`, `JPG`, `VIDEO`…).
    func formatCounts() throws -> [(format: String, count: Int)] {
        try collect("SELECT fileFormat, COUNT(*) FROM Adobe_images GROUP BY fileFormat") { row in
            (row.string(at: 0) ?? "", row.int(at: 1) ?? 0)
        }
    }

    /// Calls `body` with the name parts and folder of each photo's original file, until it returns `false`.
    func fileRows(_ body: (_ baseName: String, _ fileExtension: String, _ folder: Int) -> Bool) throws {
        do {
            let statement = try database.prepare("""
                SELECT f.baseName, f.extension, f.folder FROM Adobe_images i
                JOIN AgLibraryFile f ON f.id_local = i.rootFile ORDER BY f.folder
                """)
            while try statement.step() {
                if !body(statement.string(at: 0) ?? "", statement.string(at: 1) ?? "", statement.int(at: 2) ?? 0) { return }
            }
        } catch let error as SQLiteError {
            throw LightroomCatalogError.readFailed(error.message)
        }
    }

    // MARK: - Helpers

    /// The SQL expression for `column` of `table`, or `fallback` where this catalog version lacks it.
    private func column(_ table: String, _ column: String, fallback: String = "NULL") throws -> String {
        if columnCache[table] == nil {
            let statement = try database.prepare("PRAGMA table_info(\(table))")
            var names = Set<String>()
            while try statement.step() {
                if let name = statement.string(at: 1) { names.insert(name) }
            }
            columnCache[table] = names
        }
        return columnCache[table]?.contains(column) == true ? column : fallback
    }

    private func collect<Row>(_ sql: String, row: (SQLiteStatement) -> Row) throws -> [Row] {
        var rows: [Row] = []
        do {
            let statement = try database.prepare(sql)
            while try statement.step() { rows.append(row(statement)) }
        } catch let error as SQLiteError {
            throw LightroomCatalogError.readFailed(error.message)
        }
        return rows
    }

    /// Steps `sql` and hands rows to `body` in batches, so only one batch is in memory at a time.
    private func stream<Row>(
        _ sql: String, batchSize: Int, body: ([Row]) throws -> Void, row: (SQLiteStatement) -> Row
    ) throws {
        do {
            let statement = try database.prepare(sql)
            var batch: [Row] = []
            batch.reserveCapacity(batchSize)
            while try statement.step() {
                batch.append(row(statement))
                if batch.count >= batchSize {
                    try body(batch)
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if !batch.isEmpty { try body(batch) }
        } catch let error as SQLiteError {
            throw LightroomCatalogError.readFailed(error.message)
        }
    }
}

/// A query being read a batch at a time. Use it from the task that created it, and don't close the
/// catalog while rows remain.
nonisolated final class LightroomRowCursor<Row> {
    private let statement: SQLiteStatement
    private let row: (SQLiteStatement) -> Row
    private(set) var isFinished = false

    init(statement: SQLiteStatement, row: @escaping (SQLiteStatement) -> Row) {
        self.statement = statement
        self.row = row
    }

    /// Up to `count` more rows; empty when there are none left.
    func next(_ count: Int) throws -> [Row] {
        var batch: [Row] = []
        batch.reserveCapacity(count)
        do {
            while batch.count < count, !isFinished {
                if try statement.step() {
                    batch.append(row(statement))
                } else {
                    isFinished = true
                }
            }
        } catch let error as SQLiteError {
            throw LightroomCatalogError.readFailed(error.message)
        }
        return batch
    }
}
