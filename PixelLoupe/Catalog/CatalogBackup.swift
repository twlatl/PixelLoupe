import Foundation
import OSLog
import SQLite3

/// Catalog backups (Catalog Settings ▸ Backups, RAW-269). A backup is the catalog database, copied with `VACUUM INTO`
/// (a consistent, compacted copy, not a plain file copy) and optionally checked with `PRAGMA integrity_check`, plus the
/// package's `Catalog.plist`, `Settings.plist` and `ViewState.plist`, packed as a `.pixelloupe` package and zipped to
/// `<backup folder>/YYYY-MM-DD HHMM/<catalog>.zip`. Unzipped, it opens with File ▸ Open Catalog. Previews, thumbnails
/// and Smart Previews are left out, since they can be built again.
///
/// What the Backups pane shows (how many, the last, their size) comes from looking in the folder each time, so it stays
/// right when backups are deleted in the Finder. Several catalogs can share a folder; each sees only its own backups,
/// the zips named after it.
nonisolated enum CatalogBackup {
    /// One backup on disk.
    struct Entry: Identifiable, Equatable, Hashable, Sendable {
        /// The zip.
        var url: URL
        var date: Date
        var size: Int64

        var id: URL { url }
    }

    /// What a backup in progress is doing, for the quit sheet's progress.
    enum Phase: Int, Sendable, CaseIterable {
        case copying, checkingIntegrity, compressing

        var title: String {
            switch self {
            case .copying: "Copying the catalog…"
            case .checkingIntegrity: "Testing integrity…"
            case .compressing: "Compressing…"
            }
        }
    }

    enum Failure: LocalizedError {
        /// `PRAGMA integrity_check` found problems in the copy; the copy was discarded.
        case integrityCheckFailed([String])
        case database(String)
        case zip(Int32)

        var errorDescription: String? {
            switch self {
            case .integrityCheckFailed: "The catalog failed its integrity check, so it wasn't backed up."
            case .database(let message): "The catalog couldn't be copied: \(message)"
            case .zip(let status): "The backup couldn't be compressed (ditto exited with \(status))."
            }
        }

        var failureReason: String? {
            guard case .integrityCheckFailed(let problems) = self else { return nil }
            let shown = problems.prefix(5).joined(separator: "\n")
            return problems.count > 5 ? shown + "\n…and \(problems.count - 5) more." : shown
        }
    }

    private static let logger = Logger(subsystem: "net.pixegen.PixelLoupe", category: "Backup")

    /// The name the backup's package and zip take: the catalog's file name without its extension.
    static func catalogName(of package: URL) -> String { package.deletingPathExtension().lastPathComponent }

    // MARK: - Schedule

    /// Whether a backup is due as PixelLoupe quits, given when the last one was made.
    static func isDue(_ schedule: CatalogSettings.BackupSchedule, lastBackup: Date?, now: Date = .now,
                      calendar: Calendar = .current) -> Bool {
        let interval: DateComponents
        switch schedule {
        case .never: return false
        case .everyExit, .nextExit: return true
        case .daily: interval = DateComponents(day: 1)
        case .weekly: interval = DateComponents(day: 7)
        case .monthly: interval = DateComponents(month: 1)
        }
        guard let lastBackup, let next = calendar.date(byAdding: interval, to: lastBackup) else { return true }
        return now >= next
    }

    // MARK: - Listing

    /// The catalog's backups in `folder`, newest first.
    static func backups(of catalogName: String, in folder: URL) -> [Entry] {
        let fileManager = FileManager.default
        let zipName = catalogName + ".zip"
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .creationDateKey]
        guard let folders = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)
        else { return [] }
        let found = folders.compactMap { dated -> (entry: Entry, sequence: Int)? in
            guard (try? dated.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let zip = dated.appending(path: zipName)
            guard let values = try? zip.resourceValues(forKeys: [.fileSizeKey, .creationDateKey]), let size = values.fileSize
            else { return nil }
            let name = dated.lastPathComponent
            let date = folderDate(name) ?? values.creationDate ?? .distantPast
            return (Entry(url: zip, date: date, size: Int64(size)), sequence(of: name))
        }
        // Within a minute, `… 2` came after the unnumbered one.
        return found.sorted { ($0.entry.date, $0.sequence) > ($1.entry.date, $1.sequence) }.map(\.entry)
    }

    /// 1 for `YYYY-MM-DD HHMM`, n for `YYYY-MM-DD HHMM n`.
    private static func sequence(of folderName: String) -> Int {
        Int(folderName.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 1
    }

    /// `YYYY-MM-DD HHMM`, as a backup's folder is named (a later one in the same minute adds ` 2`, ` 3`…).
    static func folderName(for date: Date) -> String {
        folderFormatter().string(from: date)
    }

    private static func folderDate(_ name: String) -> Date? {
        folderFormatter().date(from: String(name.prefix(15)))
    }

    private static func folderFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter
    }

    // MARK: - Backing up

    /// Backs up the catalog package at `package` into `folder`, then keeps only the newest `keeping` backups. With
    /// `testsIntegrity`, a copy that fails `PRAGMA integrity_check` is discarded and `Failure.integrityCheckFailed` thrown.
    @concurrent
    static func backUp(
        _ package: URL, to folder: URL, testsIntegrity: Bool, keeping: Int, now: Date = .now,
        onPhase: @escaping @Sendable (Phase) -> Void = { _ in }
    ) async throws -> Entry {
        let fileManager = FileManager.default
        let name = catalogName(of: package)
        let scratch = fileManager.temporaryDirectory.appending(path: "PixelLoupe Backup \(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: scratch) }
        let copy = scratch.appending(path: name + "." + CatalogPackage.fileExtension, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: copy, withIntermediateDirectories: true)

        onPhase(.copying)
        let database = CatalogPackage.databaseURL(in: copy)
        try vacuum(CatalogPackage.databaseURL(in: package), into: database)
        for file in [CatalogPackage.infoURL, CatalogPackage.settingsURL, CatalogPackage.viewStateURL] {
            let source = file(package)
            if fileManager.fileExists(atPath: source.path(percentEncoded: false)) {
                try fileManager.copyItem(at: source, to: file(copy))
            }
        }

        if testsIntegrity {
            onPhase(.checkingIntegrity)
            let problems = try integrityProblems(of: database)
            if !problems.isEmpty {
                logger.error("Integrity check failed: \(problems.prefix(5).joined(separator: "; "), privacy: .public)")
                throw Failure.integrityCheckFailed(problems)
            }
        }

        onPhase(.compressing)
        let zip = scratch.appending(path: name + ".zip")
        try await ditto(["-c", "-k", "--sequesterRsrc", "--keepParent", copy.path(percentEncoded: false), zip.path(percentEncoded: false)])

        // Only now does the backup appear in the folder, so a failed one never shows as a backup.
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        var dated = folder.appending(path: folderName(for: now), directoryHint: .isDirectory)
        var suffix = 2
        while fileManager.fileExists(atPath: dated.appending(path: name + ".zip").path(percentEncoded: false)) {
            dated = folder.appending(path: "\(folderName(for: now)) \(suffix)", directoryHint: .isDirectory)
            suffix += 1
        }
        try fileManager.createDirectory(at: dated, withIntermediateDirectories: true)
        let destination = dated.appending(path: name + ".zip")
        try fileManager.moveItem(at: zip, to: destination)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init) ?? 0
        logger.info("Backed up \(name, privacy: .public) to \(destination.path(percentEncoded: false), privacy: .public)")

        prune(of: name, in: folder, keeping: keeping)
        return Entry(url: destination, date: now, size: size)
    }

    /// Deletes all but the newest `keeping` backups of the catalog.
    @discardableResult
    static func prune(of catalogName: String, in folder: URL, keeping: Int) -> [Entry] {
        let old = Array(backups(of: catalogName, in: folder).dropFirst(max(1, keeping)))
        delete(old)
        return old
    }

    /// Deletes backups, and their dated folders once nothing else is in them.
    static func delete(_ entries: [Entry]) {
        let fileManager = FileManager.default
        for entry in entries {
            do {
                try fileManager.removeItem(at: entry.url)
            } catch {
                logger.error("Couldn't delete \(entry.url.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
                continue
            }
            let dated = entry.url.deletingLastPathComponent()
            if let rest = try? fileManager.contentsOfDirectory(atPath: dated.path(percentEncoded: false)),
               rest.allSatisfy({ $0 == ".DS_Store" }) {
                try? fileManager.removeItem(at: dated)
            }
        }
    }

    // MARK: - SQLite

    /// `VACUUM INTO`: a consistent, compacted copy of the database, read alongside Core Data's own connection.
    static func vacuum(_ source: URL, into destination: URL) throws {
        let db = try open(source, flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "VACUUM INTO ?1", -1, &statement, nil) == SQLITE_OK else {
            throw Failure.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, destination.path(percentEncoded: false), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Failure.database(String(cString: sqlite3_errmsg(db))) }
    }

    /// What `PRAGMA integrity_check` finds wrong with the database; empty when it's sound.
    static func integrityProblems(of database: URL) throws -> [String] {
        let db = try open(database, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close_v2(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK else {
            return [String(cString: sqlite3_errmsg(db))]
        }
        defer { sqlite3_finalize(statement) }
        var rows: [String] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { return rows + [String(cString: sqlite3_errmsg(db))] }
            rows.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
        }
        return rows == ["ok"] ? [] : rows
    }

    private static func open(_ url: URL, flags: Int32) throws -> OpaquePointer {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(url.path(percentEncoded: false), &db, flags | SQLITE_OPEN_NOMUTEX, nil)
        guard result == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open the database"
            sqlite3_close_v2(db)
            throw Failure.database(message)
        }
        sqlite3_busy_timeout(db, 5_000)
        return db
    }

    // MARK: - Zip

    private static func ditto(_ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = arguments
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else { throw Failure.zip(status) }
    }
}
