import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteError: LocalizedError {
    case openFailed(String, code: Int32)
    case prepareFailed(String, code: Int32, sql: String)
    case stepFailed(String, code: Int32, sql: String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let m, let c):     return "DB öffnen fehlgeschlagen (\(c)): \(m)"
        case .prepareFailed(let m, let c, let sql): return "SQL-Vorbereitung fehlgeschlagen (\(c)): \(m)\nSQL: \(sql)"
        case .stepFailed(let m, let c, let sql):    return "SQL-Ausführung fehlgeschlagen (\(c)): \(m)\nSQL: \(sql)"
        }
    }
}

/// Thin Swift wrapper around the C SQLite API.
final class Database {
    private var db: OpaquePointer?
    let path: String

    init(path: String, readOnly: Bool = false) throws {
        self.path = path
        let flags = readOnly
            ? SQLITE_OPEN_READONLY
            : SQLITE_OPEN_READWRITE
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        if rc != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw SQLiteError.openFailed(msg, code: rc)
        }
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw SQLiteError.stepFailed(msg, code: rc, sql: sql)
        }
    }

    /// Run a query and map each row to a value while the statement is still
    /// alive. Returning `Row`s directly would hand the caller a dangling
    /// pointer once `sqlite3_finalize` runs.
    func query<T>(_ sql: String,
                  bindings: [SQLBind] = [],
                  map: (Row) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.prepareFailed(msg, code: rc, sql: sql)
        }
        defer { sqlite3_finalize(stmt) }

        for (i, b) in bindings.enumerated() {
            b.bind(stmt, Int32(i + 1))
        }

        var results: [T] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                results.append(map(Row(stmt: stmt!)))
            } else if step == SQLITE_DONE {
                break
            } else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw SQLiteError.stepFailed(msg, code: step, sql: sql)
            }
        }
        return results
    }

    /// Convenience for "give me the first column of the first row" queries.
    func scalarInt(_ sql: String, bindings: [SQLBind] = []) throws -> Int64? {
        try query(sql, bindings: bindings) { $0.intOrNil(0) }.first.flatMap { $0 }
    }

    @discardableResult
    func run(_ sql: String, bindings: [SQLBind] = []) throws -> Int32 {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.prepareFailed(msg, code: rc, sql: sql)
        }
        defer { sqlite3_finalize(stmt) }
        for (i, b) in bindings.enumerated() {
            b.bind(stmt, Int32(i + 1))
        }
        let step = sqlite3_step(stmt)
        if step != SQLITE_DONE && step != SQLITE_ROW {
            let msg = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.stepFailed(msg, code: step, sql: sql)
        }
        return sqlite3_changes(db)
    }

    func transaction<T>(_ block: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try block()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func lastInsertRowID() -> Int64 {
        sqlite3_last_insert_rowid(db)
    }
}

/// One row returned from a query. Indexes are zero-based.
struct Row {
    let stmt: OpaquePointer

    func int(_ i: Int) -> Int64 {
        sqlite3_column_int64(stmt, Int32(i))
    }

    func intOrNil(_ i: Int) -> Int64? {
        sqlite3_column_type(stmt, Int32(i)) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, Int32(i))
    }

    func text(_ i: Int) -> String {
        guard let cstr = sqlite3_column_text(stmt, Int32(i)) else { return "" }
        return String(cString: cstr)
    }

    func textOrNil(_ i: Int) -> String? {
        sqlite3_column_type(stmt, Int32(i)) == SQLITE_NULL ? nil : text(i)
    }

    func bool(_ i: Int) -> Bool {
        sqlite3_column_int(stmt, Int32(i)) != 0
    }
}

/// Type-safe parameter binding for prepared statements.
enum SQLBind {
    case int(Int64)
    case intOrNull(Int64?)
    case text(String)
    case textOrNull(String?)
    case bool(Bool)
    case null

    func bind(_ stmt: OpaquePointer?, _ idx: Int32) {
        switch self {
        case .int(let v):
            sqlite3_bind_int64(stmt, idx, v)
        case .intOrNull(let v):
            if let v { sqlite3_bind_int64(stmt, idx, v) }
            else     { sqlite3_bind_null(stmt, idx) }
        case .text(let s):
            sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
        case .textOrNull(let s):
            if let s { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) }
            else     { sqlite3_bind_null(stmt, idx) }
        case .bool(let b):
            sqlite3_bind_int(stmt, idx, b ? 1 : 0)
        case .null:
            sqlite3_bind_null(stmt, idx)
        }
    }
}
