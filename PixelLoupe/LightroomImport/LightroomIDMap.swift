import Foundation
import SQLite3

/// Maps Lightroom `id_local` values to the PixelLoupe `Photo.id` created for them (and back to
/// nothing else: later phases only ever look up by Lightroom id).
///
/// Kept in a temporary SQLite file rather than a dictionary: a 55,000-photo catalog would otherwise
/// hold the whole mapping in memory for the entire import. The file is deleted when the map is
/// released. Not thread-safe; use it from one task at a time.
nonisolated final class LightroomIDMap {
    private var db: OpaquePointer?
    private var insert: OpaquePointer?
    private var lookup: OpaquePointer?
    /// The folder holding the map's scratch file.
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "PixelLoupe-LightroomIDMap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appending(path: "map.sqlite").path(percentEncoded: false)
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            throw SQLiteError(code: SQLITE_CANTOPEN, message: "cannot create the Lightroom ID map")
        }
        // It's scratch data: no journal, no fsync.
        try run("PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF; CREATE TABLE map (lr INTEGER PRIMARY KEY, id TEXT NOT NULL) WITHOUT ROWID")
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO map (lr, id) VALUES (?1, ?2)", -1, &insert, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "SELECT id FROM map WHERE lr = ?1", -1, &lookup, nil) == SQLITE_OK else {
            throw SQLiteError(code: SQLITE_ERROR, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    deinit {
        sqlite3_finalize(insert)
        sqlite3_finalize(lookup)
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: directory)
    }

    private func run(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(message)
            throw SQLiteError(code: SQLITE_ERROR, message: text)
        }
    }

    /// Records the photos created for a batch of Lightroom images, in one transaction.
    func record(_ pairs: [(lightroomID: Int, photoID: UUID)]) throws {
        try run("BEGIN")
        for pair in pairs {
            sqlite3_reset(insert)
            sqlite3_bind_int64(insert, 1, Int64(pair.lightroomID))
            sqlite3_bind_text(insert, 2, pair.photoID.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(insert) == SQLITE_DONE else {
                try? run("ROLLBACK")
                throw SQLiteError(code: SQLITE_ERROR, message: String(cString: sqlite3_errmsg(db)))
            }
        }
        try run("COMMIT")
    }

    /// The `Photo.id` created for a Lightroom image, or `nil` if it wasn't imported.
    func photoID(forLightroomID id: Int) -> UUID? {
        sqlite3_reset(lookup)
        sqlite3_bind_int64(lookup, 1, Int64(id))
        guard sqlite3_step(lookup) == SQLITE_ROW, let text = sqlite3_column_text(lookup, 0) else { return nil }
        return UUID(uuidString: String(cString: text))
    }

    var count: Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM map", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
