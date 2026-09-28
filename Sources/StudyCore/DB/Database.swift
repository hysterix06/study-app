import Foundation
import SQLite3

public enum DBError: Error, CustomStringConvertible {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)
    case busy(String)
    case schemaMismatch(found: Int, expected: Int)

    public var description: String {
        switch self {
        case .open(let m): return "Could not open database: \(m)"
        case .prepare(let m, let sql): return "SQL prepare failed: \(m) — \(sql.prefix(160))"
        case .step(let m, let sql): return "SQL failed: \(m) — \(sql.prefix(160))"
        case .busy(let m): return "Database busy: \(m)"
        case .schemaMismatch(let f, let e):
            return "Database schema version \(f) does not match the expected version \(e). Update the Study Tracker app and its Claude connection."
        }
    }
}

/// One row of a query result, addressed by column name.
public struct Row {
    fileprivate var values: [String: SQLValue]

    public subscript(_ column: String) -> SQLValue { values[column] ?? .null }

    public func string(_ c: String) -> String? {
        switch self[c] {
        case .text(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        default: return nil
        }
    }
    public func str(_ c: String) -> String { string(c) ?? "" }
    public func int(_ c: String) -> Int? {
        switch self[c] {
        case .int(let i): return Int(i)
        case .double(let d): return Int(d)
        case .text(let s): return Int(s)
        default: return nil
        }
    }
    public func i(_ c: String) -> Int { int(c) ?? 0 }
    public func double(_ c: String) -> Double? {
        switch self[c] {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .text(let s): return Double(s)
        default: return nil
        }
    }
    public func bool(_ c: String) -> Bool { (int(c) ?? 0) != 0 }
    public var columns: [String] { Array(values.keys) }
    public var dictionary: [String: SQLValue] { values }
}

public enum SQLValue: Equatable {
    case null, int(Int64), double(Double), text(String), blob(Data)

    public var jsonValue: Any {
        switch self {
        case .null: return NSNull()
        case .int(let i): return i
        case .double(let d): return d
        case .text(let s): return s
        case .blob(let d): return d.base64EncodedString()
        }
    }

    init(any: Any?) {
        guard let any else { self = .null; return }
        switch any {
        case let v as SQLValue: self = v
        case let v as Int: self = .int(Int64(v))
        case let v as Int64: self = .int(v)
        case let v as Int32: self = .int(Int64(v))
        case let v as Bool: self = .int(v ? 1 : 0)
        case let v as Double: self = .double(v)
        case let v as Float: self = .double(Double(v))
        case let v as String: self = .text(v)
        case let v as Substring: self = .text(String(v))
        case let v as Data: self = .blob(v)
        case let v as Date: self = .text(ISO.instant(v))
        case let v as LocalDate: self = .text(v.string)
        case let v as LocalTime: self = .text(v.string)
        default:
            // Optional wrapped in Any
            let mirror = Mirror(reflecting: any)
            if mirror.displayStyle == .optional {
                if let child = mirror.children.first { self = SQLValue(any: child.value) } else { self = .null }
            } else {
                self = .text(String(describing: any))
            }
        }
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin, thread-safe wrapper over one SQLite connection. All access is serialized by a recursive lock,
/// so a transaction on one thread cannot interleave with statements from another.
public final class Database: @unchecked Sendable {
    public let path: String
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var txDepth = 0

    public init(path: String, readOnly: Bool = false) throws {
        self.path = path
        if path != ":memory:" {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let flags = (readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) | SQLITE_OPEN_FULLMUTEX
        var h: OpaquePointer?
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            sqlite3_close(h)
            throw DBError.open(msg)
        }
        handle = h
        sqlite3_busy_timeout(h, 5000)
        if !readOnly {
            _ = try? query("PRAGMA journal_mode=WAL")
        }
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA busy_timeout=5000")
    }

    deinit { sqlite3_close_v2(handle) }

    // MARK: Statements

    @discardableResult
    public func execute(_ sql: String, _ params: [Any?] = []) throws -> (changes: Int, lastInsertId: Int) {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
        guard rc == SQLITE_DONE else { throw stepError(rc, sql) }
        return (Int(sqlite3_changes(handle)), Int(sqlite3_last_insert_rowid(handle)))
    }

    /// Runs several statements separated by semicolons (no parameters). Used for migrations.
    public func executeScript(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "code \(rc)"
            sqlite3_free(err)
            throw DBError.step(msg, sql: sql)
        }
    }

    public func query(_ sql: String, _ params: [Any?] = []) throws -> [Row] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, params)
        defer { sqlite3_finalize(stmt) }
        var rows: [Row] = []
        let count = sqlite3_column_count(stmt)
        var names: [String] = []
        for i in 0..<count { names.append(String(cString: sqlite3_column_name(stmt, i))) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw stepError(rc, sql) }
            var values: [String: SQLValue] = [:]
            for i in 0..<count {
                let v: SQLValue
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: v = .int(sqlite3_column_int64(stmt, i))
                case SQLITE_FLOAT: v = .double(sqlite3_column_double(stmt, i))
                case SQLITE_TEXT: v = .text(String(cString: sqlite3_column_text(stmt, i)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, i))
                    if let p = sqlite3_column_blob(stmt, i) { v = .blob(Data(bytes: p, count: n)) } else { v = .blob(Data()) }
                default: v = .null
                }
                values[names[Int(i)]] = v
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    public func first(_ sql: String, _ params: [Any?] = []) throws -> Row? {
        try query(sql, params).first
    }

    public func scalarInt(_ sql: String, _ params: [Any?] = []) throws -> Int {
        guard let row = try first(sql, params), let key = row.columns.first else { return 0 }
        return row.int(key) ?? 0
    }

    public func scalarString(_ sql: String, _ params: [Any?] = []) throws -> String? {
        guard let row = try first(sql, params), let key = row.columns.first else { return nil }
        return row.string(key)
    }

    /// Atomic unit of work. Nested calls become savepoints. BEGIN IMMEDIATE takes the write lock up front
    /// so two processes (app and MCP server) never deadlock on a read-to-write upgrade.
    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let depth = txDepth
        let savepoint = "sp\(depth)"
        if depth == 0 { try execute("BEGIN IMMEDIATE") } else { try execute("SAVEPOINT \(savepoint)") }
        txDepth += 1
        do {
            let result = try body()
            txDepth -= 1
            if depth == 0 { try execute("COMMIT") } else { try execute("RELEASE \(savepoint)") }
            return result
        } catch {
            txDepth -= 1
            if depth == 0 { try? execute("ROLLBACK") } else {
                try? execute("ROLLBACK TO \(savepoint)"); try? execute("RELEASE \(savepoint)")
            }
            throw error
        }
    }

    public var userVersion: Int { (try? scalarInt("PRAGMA user_version")) ?? 0 }

    /// Changes whenever another connection commits. Used by the app to notice writes made by Claude.
    public var dataVersion: Int { (try? scalarInt("PRAGMA data_version")) ?? 0 }

    public func vacuumInto(_ path: String) throws {
        try? FileManager.default.removeItem(atPath: path)
        try execute("VACUUM INTO ?", [path])
    }

    // MARK: Internals

    private func prepare(_ sql: String, _ params: [Any?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK else {
            throw DBError.prepare(String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch SQLValue(any: p) {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            }
        }
        return stmt
    }

    private func stepError(_ rc: Int32, _ sql: String) -> DBError {
        let msg = String(cString: sqlite3_errmsg(handle))
        if rc == SQLITE_BUSY || rc == SQLITE_LOCKED { return .busy(msg) }
        return .step(msg, sql: sql)
    }
}
