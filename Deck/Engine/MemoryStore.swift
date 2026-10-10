import Foundation
import SQLite3

enum StoreError: Error, LocalizedError {
    case open(String)
    case exec(String)

    var errorDescription: String? {
        switch self {
        case .open(let s): return "DB open failed: \(s)"
        case .exec(let s): return "DB error: \(s)"
        }
    }
}

/// SQLite-backed durable memory + tasks. Lives in the app sandbox.
final class MemoryStore: @unchecked Sendable {
    static let shared = MemoryStore()

    private var db: OpaquePointer?

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let path = docs.appendingPathComponent("deck-memory.sqlite").path
        if sqlite3_open(path, &db) != SQLITE_OK {
            db = nil
            return
        }
        try? exec("""
            CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT, updated TEXT);
            CREATE VIRTUAL TABLE IF NOT EXISTS kv_fts USING fts5(key, value);
            CREATE TABLE IF NOT EXISTS tasks(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0,
                created TEXT NOT NULL);
            """)
    }

    deinit { if let db { sqlite3_close(db) } }

    private func exec(_ sql: String) throws {
        guard let db else { throw StoreError.open("no handle") }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            throw StoreError.exec(msg)
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, (value as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    // C2 FIX: sqlite3_column_text returns nil for NULL; String(cString:) traps on nil.
    private func columnText(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: ptr)
    }

    // MARK: - Memory

    func remember(key: String, value: String) throws {
        guard let db, !key.isEmpty else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO kv(key,value,updated) VALUES(?,?,?)", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key); bindText(stmt, 2, value); bindText(stmt, 3, now)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.exec("remember failed") }

        // C1 FIX: FTS5 has no unique constraint, so INSERT OR REPLACE doesn't dedupe.
        // Delete existing entries for this key first, then insert.
        var delFts: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM kv_fts WHERE key = ?", -1, &delFts, nil)
        defer { sqlite3_finalize(delFts) }
        bindText(delFts, 1, key)
        _ = sqlite3_step(delFts)

        var fts: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO kv_fts(key,value) VALUES(?,?)", -1, &fts, nil)
        defer { sqlite3_finalize(fts) }
        bindText(fts, 1, key); bindText(fts, 2, value)
        _ = sqlite3_step(fts)
    }

    func recall(query: String) throws -> [String] {
        guard let db else { return [] }
        var out: [String] = []
        var stmt: OpaquePointer?
        // FTS5 MATCH, with LIKE fallback for weird queries.
        let sql = "SELECT key, value FROM kv_fts WHERE kv_fts MATCH ? LIMIT 10"
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, query)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let k = columnText(stmt, 0)
            let v = columnText(stmt, 1)
            out.append("\(k): \(v)")
        }
        if out.isEmpty {
            var like: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT key, value FROM kv WHERE key LIKE ? OR value LIKE ? LIMIT 10", -1, &like, nil)
            defer { sqlite3_finalize(like) }
            let pat = "%\(query)%"
            bindText(like, 1, pat); bindText(like, 2, pat)
            while sqlite3_step(like) == SQLITE_ROW {
                let k = columnText(like, 0)
                let v = columnText(like, 1)
                out.append("\(k): \(v)")
            }
        }
        return out
    }

    // MARK: - Tasks

    func addTask(title: String) throws -> Int64 {
        guard let db else { throw StoreError.open("no handle") }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO tasks(title,created) VALUES(?,?)", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, title)
        bindText(stmt, 2, ISO8601DateFormatter().string(from: Date()))
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.exec("addTask failed") }
        return sqlite3_last_insert_rowid(db)
    }

    func listTasks() throws -> [String] {
        guard let db else { return [] }
        var out: [String] = []
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT id, title FROM tasks WHERE done=0 ORDER BY id", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let t = columnText(stmt, 1)
            out.append("#\(id): \(t)")
        }
        return out
    }

    func completeTask(id: Int64) throws {
        guard let db else { return }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "UPDATE tasks SET done=1 WHERE id=?", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        _ = sqlite3_step(stmt)
    }

    // C4 FIX: forget API was missing. Removes from both kv and kv_fts.
    func forget(key: String) throws {
        guard let db, !key.isEmpty else { return }
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM kv WHERE key = ?", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        _ = sqlite3_step(stmt)

        var fts: OpaquePointer?
        sqlite3_prepare_v2(db, "DELETE FROM kv_fts WHERE key = ?", -1, &fts, nil)
        defer { sqlite3_finalize(fts) }
        bindText(fts, 1, key)
        _ = sqlite3_step(fts)
    }
}
