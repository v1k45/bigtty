import Foundation
import SQLite3

/// A page in history.
struct BrowserVisit: Equatable, Sendable {
    var url: String
    var machine: String
    var title: String
    var space: String?
    var lastVisit: Date
    var visitCount: Int
    var typedCount: Int
}

/// What may be written down, and how a row ranks, apart from the database.
enum BrowserHistoryRules {
    static let maximumAge: TimeInterval = 90 * 24 * 3600
    static let maximumRows = 50000
    private static let sensitiveKeys = ["token", "code", "secret", "password", "passwd", "auth", "key", "session", "sig"]

    /// The address to keep, or nil for one that isn't worth keeping. Fragments
    /// and logins go, and so does a query holding what looks like a credential.
    static func clean(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.host?.isEmpty == false
        else { return nil }
        components.fragment = nil
        components.user = nil
        components.password = nil
        if components.queryItems?.contains(where: { item in
            let name = item.name.lowercased()
            return sensitiveKeys.contains { name.contains($0) }
        }) == true {
            components.query = nil
        }
        return components.url?.absoluteString
    }

    /// A page counts if you opened it: never with history off, not in a tab
    /// an agent opened, and not right after an agent's command, whose
    /// navigation may still be arriving.
    static let agentGrace: TimeInterval = 15

    static func isYours(enabled: Bool, openedByAgent: Bool, lastAgentAction: Date?, now: Date) -> Bool {
        guard enabled, !openedByAgent else { return false }
        return lastAgentAction.map { now.timeIntervalSince($0) > agentGrace } ?? true
    }

    /// Recent, often visited and typed pages first, and this space's above
    /// the rest. A page's frequency fades with age, so last year's habit
    /// doesn't outrank this week's.
    static func score(_ visit: BrowserVisit, space: String?, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(visit.lastVisit)) / 86400
        let frequency = log2(Double(visit.visitCount) + 1) + 2 * log2(Double(visit.typedCount) + 1)
        let score = (1 + frequency) * pow(0.5, days / 14)
        return visit.space != nil && visit.space == space ? score * 2 : score
    }

    /// `foo_bar%` as itself in a LIKE, with `\` as the escape character.
    static func likePattern(_ word: String) -> String {
        let escaped = word.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }
}

/// Pages you opened, in `browser-history.sqlite`. It stays on this Mac and
/// holds no agent's browsing: `BrowserPage` decides what reaches it, and
/// `btty` has no command that reads it. Everything runs on one queue, so
/// typing never waits for the disk.
final class BrowserHistory: @unchecked Sendable {
    static let shared = BrowserHistory(path: AppPaths.support.appendingPathComponent("browser-history.sqlite").path)

    private let queue = DispatchQueue(label: "bigtty.browser-history")
    private var db: OpaquePointer?
    let path: String
    private var writes = 0
    /// Rows are trimmed every so many writes, not on each.
    private static let pruneEvery = 200

    init(path: String) {
        self.path = path
        queue.async { [self] in
            open()
            prune(now: Date())
        }
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            NSLog("bigtty: can't open browser history")
            db.map { _ = sqlite3_close_v2($0) }
            db = nil
            return
        }
        // SQLite gives its journal the database's permissions.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        execute("PRAGMA journal_mode=WAL")
        execute("""
            CREATE TABLE IF NOT EXISTS visits (
              url TEXT NOT NULL, machine TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', space TEXT,
              last_visit REAL NOT NULL, visit_count INTEGER NOT NULL DEFAULT 1, typed_count INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY (url, machine)) WITHOUT ROWID
            """)
        execute("CREATE INDEX IF NOT EXISTS visits_recent ON visits (machine, last_visit DESC)")
    }

    // MARK: - Writing

    func record(url: String, machine: String, title: String, space: String?, typed: Bool, at date: Date = Date()) {
        queue.async { [self] in
            run("""
                INSERT INTO visits (url, machine, title, space, last_visit, visit_count, typed_count) VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6)
                ON CONFLICT (url, machine) DO UPDATE SET
                  title = CASE WHEN ?3 = '' THEN title ELSE ?3 END, space = coalesce(?4, space), last_visit = ?5,
                  visit_count = visit_count + 1, typed_count = typed_count + ?6
                """, [.text(url), .text(machine), .text(title), space.map(Bind.text) ?? .null, .real(date.timeIntervalSince1970), .int(typed ? 1 : 0)])
            writes += 1
            if writes >= Self.pruneEvery {
                writes = 0
                prune(now: date)
            }
        }
    }

    func setTitle(_ title: String, url: String, machine: String) {
        queue.async { [self] in
            run("UPDATE visits SET title = ?1 WHERE url = ?2 AND machine = ?3", [.text(title), .text(url), .text(machine)])
        }
    }

    func remove(url: String, machine: String) {
        queue.async { [self] in
            run("DELETE FROM visits WHERE url = ?1 AND machine = ?2", [.text(url), .text(machine)])
        }
    }

    /// Everything since `date`, or all of it.
    func clear(since date: Date?) {
        queue.async { [self] in
            if let date {
                run("DELETE FROM visits WHERE last_visit >= ?1", [.real(date.timeIntervalSince1970)])
            } else {
                run("DELETE FROM visits", [])
                execute("VACUUM")
            }
            // What was deleted must not linger in the journal.
            execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    private func prune(now: Date) {
        run("DELETE FROM visits WHERE last_visit < ?1", [.real(now.addingTimeInterval(-BrowserHistoryRules.maximumAge).timeIntervalSince1970)])
        run("""
            DELETE FROM visits WHERE (url, machine) IN
              (SELECT url, machine FROM visits ORDER BY last_visit DESC LIMIT -1 OFFSET ?1)
            """, [.int(BrowserHistoryRules.maximumRows)])
    }

    // MARK: - Reading

    /// Pages matching every word of `text`, best first, off the main thread.
    func search(_ text: String, machine: String, space: String?, limit: Int, now: Date = Date()) async -> [BrowserVisit] {
        let words = text.split(whereSeparator: \.isWhitespace).map { BrowserHistoryRules.likePattern(String($0)) }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                let matches = words.map { _ in "AND (url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\')" }.joined(separator: " ")
                let rows = select(
                    "SELECT url, machine, title, space, last_visit, visit_count, typed_count FROM visits WHERE machine = ? \(matches) ORDER BY last_visit DESC LIMIT 2000",
                    [.text(machine)] + words.flatMap { [Bind.text($0), .text($0)] }
                )
                let ranked = rows.map { ($0, BrowserHistoryRules.score($0, space: space, now: now)) }
                    .sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
                continuation.resume(returning: ranked)
            }
        }
    }

    /// The latest pages, for menus. It waits for the queue, which is one
    /// indexed read, so a menu can open with it.
    func recent(machine: String, limit: Int) -> [BrowserVisit] {
        queue.sync {
            select(
                "SELECT url, machine, title, space, last_visit, visit_count, typed_count FROM visits WHERE machine = ?1 ORDER BY last_visit DESC LIMIT ?2",
                [.text(machine), .int(limit)]
            )
        }
    }

    /// Waits until what came before has been done.
    func flush() { queue.sync {} }

    var fileMode: Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? Int
    }

    // MARK: - SQLite

    private enum Bind {
        case text(String), real(Double), int(Int), null
    }

    private func execute(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String, _ values: [Bind]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard let db, sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        // SQLite's own copy of each string outlives the call.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let .text(text): sqlite3_bind_text(statement, index, text, -1, transient)
            case let .real(number): sqlite3_bind_double(statement, index, number)
            case let .int(number): sqlite3_bind_int64(statement, index, Int64(number))
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ values: [Bind]) {
        guard let statement = prepare(sql, values) else { return }
        sqlite3_step(statement)
        sqlite3_finalize(statement)
    }

    private func select(_ sql: String, _ values: [Bind]) -> [BrowserVisit] {
        guard let statement = prepare(sql, values) else { return [] }
        defer { sqlite3_finalize(statement) }
        var rows: [BrowserVisit] = []
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(BrowserVisit(
                url: text(0) ?? "", machine: text(1) ?? "", title: text(2) ?? "", space: text(3),
                lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                visitCount: Int(sqlite3_column_int64(statement, 5)), typedCount: Int(sqlite3_column_int64(statement, 6))
            ))
        }
        return rows
    }
}
