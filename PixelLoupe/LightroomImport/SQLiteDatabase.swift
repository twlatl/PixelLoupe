import Foundation
import SQLite3

nonisolated struct SQLiteError: Error, CustomStringConvertible {
    var code: Int32
    var message: String

    var description: String { "SQLite error \(code): \(message)" }
}

/// A minimal read-only wrapper over the libsqlite3 C API. A connection must be used from one task
/// at a time; it is not thread-safe.
nonisolated final class SQLiteDatabase {
    private var handle: OpaquePointer?

    /// Opens `url` for reading only. With `immutable`, SQLite assumes the file cannot change and
    /// never creates or touches `-wal`/`-shm` files next to it.
    init(readingFrom url: URL, immutable: Bool) throws {
        var components = URLComponents()
        components.scheme = "file"
        components.path = url.path(percentEncoded: false)
        components.queryItems = immutable ? [URLQueryItem(name: "immutable", value: "1")] : nil
        let uri = components.string ?? "file:" + url.path(percentEncoded: false)
        var db: OpaquePointer?
        let result = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        guard result == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close(db)
            throw SQLiteError(code: result, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 2_000)
        // Belt and braces: the connection can't write even if a statement tried.
        try execute("PRAGMA query_only = ON")
    }

    deinit {
        close()
    }

    func close() {
        if let handle {
            sqlite3_close_v2(handle)
        }
        handle = nil
    }

    func execute(_ sql: String) throws {
        let statement = try prepare(sql)
        while try statement.step() {}
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "database is closed") }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteError(code: result, message: String(cString: sqlite3_errmsg(handle)))
        }
        return SQLiteStatement(handle: statement, database: handle)
    }

    /// Whether the catalog has a table of this name (older Lightroom versions lack some).
    func hasTable(_ name: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1")
        statement.bind(name, at: 1)
        return try statement.step()
    }

    /// Runs `sql` and returns the first column of the first row as an integer.
    func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        guard try statement.step() else { return 0 }
        return statement.int(at: 0) ?? 0
    }
}

nonisolated final class SQLiteStatement {
    private let handle: OpaquePointer
    private let database: OpaquePointer

    fileprivate init(handle: OpaquePointer, database: OpaquePointer) {
        self.handle = handle
        self.database = database
    }

    deinit {
        sqlite3_finalize(handle)
    }

    func bind(_ value: String, at index: Int32) {
        sqlite3_bind_text(handle, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    func bind(_ value: Int, at index: Int32) {
        sqlite3_bind_int64(handle, index, Int64(value))
    }

    /// Advances to the next row; `false` once the rows are exhausted.
    func step() throws -> Bool {
        let result = sqlite3_step(handle)
        switch result {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(code: result, message: String(cString: sqlite3_errmsg(database)))
        }
    }

    func reset() {
        sqlite3_reset(handle)
    }

    /// Whether the value is stored as a number (an integer or a real).
    func isNumeric(at column: Int32) -> Bool {
        let type = sqlite3_column_type(handle, column)
        return type == SQLITE_INTEGER || type == SQLITE_FLOAT
    }

    func isNull(at column: Int32) -> Bool {
        sqlite3_column_type(handle, column) == SQLITE_NULL
    }

    /// Lightroom columns are loosely typed (an integer column may hold `4.0`), so numbers are read
    /// through whichever storage class is present.
    func int(at column: Int32) -> Int? {
        switch sqlite3_column_type(handle, column) {
        case SQLITE_INTEGER: return Int(sqlite3_column_int64(handle, column))
        case SQLITE_FLOAT:
            let value = sqlite3_column_double(handle, column)
            return value.isFinite && abs(value) < 9e15 ? Int(value) : nil
        case SQLITE_TEXT: return string(at: column).flatMap { Int($0) ?? Double($0).map { Int($0) } }
        default: return nil
        }
    }

    func double(at column: Int32) -> Double? {
        switch sqlite3_column_type(handle, column) {
        case SQLITE_INTEGER, SQLITE_FLOAT: return sqlite3_column_double(handle, column)
        case SQLITE_TEXT: return string(at: column).flatMap { Double($0) }
        default: return nil
        }
    }

    func string(at column: Int32) -> String? {
        switch sqlite3_column_type(handle, column) {
        case SQLITE_NULL: return nil
        case SQLITE_TEXT, SQLITE_BLOB:
            guard let bytes = sqlite3_column_text(handle, column) else { return "" }
            return String(cString: bytes)
        case SQLITE_INTEGER: return String(sqlite3_column_int64(handle, column))
        default: return String(sqlite3_column_double(handle, column))
        }
    }

    func data(at column: Int32) -> Data? {
        guard sqlite3_column_type(handle, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(handle, column))
        guard count > 0, let bytes = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}
