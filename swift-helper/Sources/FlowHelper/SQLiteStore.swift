// Minimal SQLite wrappers for snippets + dictionary databases.
// Uses the C API directly via `import SQLite3` — no third-party deps.

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func dbPath(_ filename: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let dir = home.appendingPathComponent(".local/share/Witzper")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(filename).path
}

// MARK: - Snippets

struct Snippet: Identifiable, Hashable {
    let trigger: String
    let expansion: String
    var id: String { trigger }
}

@MainActor
final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()
    @Published var snippets: [Snippet] = []
    @Published var lastError: String? = nil

    private var db: OpaquePointer?

    init() {
        open()
        ensureSchema()
        reload()
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    private func open() {
        let path = dbPath("snippets.db")
        if sqlite3_open(path, &db) != SQLITE_OK {
            lastError = "Failed to open snippets.db"
        }
    }

    private func ensureSchema() {
        let sql = "CREATE TABLE IF NOT EXISTS snippet (trigger TEXT PRIMARY KEY, expansion TEXT NOT NULL, added_at REAL DEFAULT (strftime('%s','now')));"
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func reload() {
        var rows: [Snippet] = []
        let sql = "SELECT trigger, expansion FROM snippet ORDER BY trigger ASC;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let t = String(cString: sqlite3_column_text(stmt, 0))
                let e = String(cString: sqlite3_column_text(stmt, 1))
                rows.append(Snippet(trigger: t, expansion: e))
            }
        }
        sqlite3_finalize(stmt)
        snippets = rows
    }

    @discardableResult
    func add(trigger: String, expansion: String) -> Bool {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !expansion.isEmpty, t.count <= 60, expansion.count <= 4000 else {
            lastError = "Invalid input"
            return false
        }
        let sql = "INSERT OR REPLACE INTO snippet (trigger, expansion) VALUES (?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); lastError = "Prepare failed"; return false
        }
        sqlite3_bind_text(stmt, 1, t, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, expansion, -1, SQLITE_TRANSIENT)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        if ok { lastError = nil; reload() }
        return ok
    }

    @discardableResult
    func delete(trigger: String) -> Bool {
        let sql = "DELETE FROM snippet WHERE trigger = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); return false
        }
        sqlite3_bind_text(stmt, 1, trigger, -1, SQLITE_TRANSIENT)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        if ok { reload() }
        return ok
    }
}

// MARK: - Dictionary (boost + replacement)

struct BoostTerm: Identifiable, Hashable {
    let term: String
    var id: String { term }
}

struct Replacement: Identifiable, Hashable {
    let wrong: String
    let right: String
    var id: String { wrong }
}

@MainActor
final class DictStore: ObservableObject {
    static let shared = DictStore()
    @Published var boosts: [BoostTerm] = []
    @Published var replacements: [Replacement] = []
    @Published var lastError: String? = nil

    private var db: OpaquePointer?

    init() {
        open()
        ensureSchema()
        reload()
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    private func open() {
        let path = dbPath("dictionary.db")
        if sqlite3_open(path, &db) != SQLITE_OK {
            lastError = "Failed to open dictionary.db"
        }
    }

    private func ensureSchema() {
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS boost (term TEXT PRIMARY KEY, added_at REAL DEFAULT (strftime('%s','now')));", nil, nil, nil)
        sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS replacement (wrong TEXT PRIMARY KEY, right TEXT NOT NULL, added_at REAL DEFAULT (strftime('%s','now')));", nil, nil, nil)
    }

    func reload() {
        var b: [BoostTerm] = []
        var r: [Replacement] = []
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT term FROM boost ORDER BY term ASC;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                b.append(BoostTerm(term: String(cString: sqlite3_column_text(stmt, 0))))
            }
        }
        sqlite3_finalize(stmt)
        stmt = nil
        if sqlite3_prepare_v2(db, "SELECT wrong, right FROM replacement ORDER BY wrong ASC;", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let w = String(cString: sqlite3_column_text(stmt, 0))
                let rt = String(cString: sqlite3_column_text(stmt, 1))
                r.append(Replacement(wrong: w, right: rt))
            }
        }
        sqlite3_finalize(stmt)
        boosts = b
        replacements = r
    }

    @discardableResult
    func addBoost(_ term: String) -> Bool {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 200 else { lastError = "Invalid term"; return false }
        let sql = "INSERT OR REPLACE INTO boost (term) VALUES (?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); return false
        }
        sqlite3_bind_text(stmt, 1, t, -1, SQLITE_TRANSIENT)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        if ok { lastError = nil; reload() }
        return ok
    }

    @discardableResult
    func deleteBoost(_ term: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM boost WHERE term = ?;", -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); return false
        }
        sqlite3_bind_text(stmt, 1, term, -1, SQLITE_TRANSIENT)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        if ok { reload() }
        return ok
    }

    @discardableResult
    func addReplacement(wrong: String, right: String) -> Bool {
        let w = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !r.isEmpty, w.count <= 200, r.count <= 200 else {
            lastError = "Invalid replacement"; return false
        }
        let sql = "INSERT OR REPLACE INTO replacement (wrong, right) VALUES (?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); return false
        }
        sqlite3_bind_text(stmt, 1, w, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, r, -1, SQLITE_TRANSIENT)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        if ok { lastError = nil; reload() }
        return ok
    }

    @discardableResult
    func deleteReplacement(_ wrong: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM replacement WHERE wrong = ?;", -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt); return false
        }
        sqlite3_bind_text(stmt, 1, wrong, -1, SQLITE_TRANSIENT)
        let ok = sqlite3_step(stmt) == SQLITE_DONE
        sqlite3_finalize(stmt)
        if ok { reload() }
        return ok
    }
}
