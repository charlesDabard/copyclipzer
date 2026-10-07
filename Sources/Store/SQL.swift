import Foundation
import SQLite3

/// SQLite exige que les chaînes liées soient copiées, sinon elles peuvent
/// disparaître avant l'exécution. C'est ce que signifie ce -1 magique.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLValue: Equatable {
    case text(String), int(Int64), double(Double), blob(Data), null
}

enum SQLError: Error, CustomStringConvertible {
    case open(String), prepare(String), step(String)
    var description: String {
        switch self {
        case .open(let m): return "ouverture : \(m)"
        case .prepare(let m): return "préparation : \(m)"
        case .step(let m): return "exécution : \(m)"
        }
    }
}

/// Enveloppe mince de l'API C de SQLite. Aucune dépendance externe : SQLite est
/// fourni par le système, en 3.51 avec FTS5 activé (mesuré le 2026-08-25).
final class Database {
    private var handle: OpaquePointer?

    init(path: String) throws {
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, h != nil else {
            throw SQLError.open(h.map { String(cString: sqlite3_errmsg($0)) } ?? "inconnu")
        }
        handle = h
        try exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=3000;")
    }

    deinit { if let handle { sqlite3_close_v2(handle) } }

    private var lastError: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "pas de base"
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLError.step(lastError)
        }
    }

    func run(_ sql: String, _ binds: [SQLValue] = []) throws {
        _ = try query(sql, binds)
    }

    func query(_ sql: String, _ binds: [SQLValue] = []) throws -> [[String: SQLValue]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLError.prepare(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        for (i, value) in binds.enumerated() {
            let p = Int32(i + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(stmt, p, s, -1, SQLITE_TRANSIENT)
            case .int(let n): sqlite3_bind_int64(stmt, p, n)
            case .double(let d): sqlite3_bind_double(stmt, p, d)
            case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, p, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
            case .null: sqlite3_bind_null(stmt, p)
            }
        }

        var rows: [[String: SQLValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLError.step(lastError) }
            var row: [String: SQLValue] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    row[name] = .blob(n > 0 ? Data(bytes: sqlite3_column_blob(stmt, c), count: n) : Data())
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    var userVersion: Int32 {
        get {
            guard case .int(let v)? = try? query("PRAGMA user_version").first?["user_version"] else { return 0 }
            return Int32(v)
        }
        set { try? exec("PRAGMA user_version=\(newValue)") }
    }
}
