import Foundation
import SQLite3

/// 跨会话命令历史(SQLite 落盘):⌘⇧H 全局搜索与日报的数据地基。
/// 串行队列上同步读写(库很小),线程安全。
final class CommandHistoryStore: @unchecked Sendable {
    static let shared = CommandHistoryStore()

    struct Entry: Identifiable, Equatable {
        let id: Int64
        let timestamp: Date
        let cwd: String
        let command: String
        let exitCode: Int?
        let duration: Double?
        let branch: String?
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "termite.command-history")

    convenience init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Termite", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.init(path: dir.appendingPathComponent("history.sqlite").path)
    }

    init(path: String) {
        queue.sync {
            guard sqlite3_open(path, &db) == SQLITE_OK else {
                db = nil
                return
            }
            execute("""
            CREATE TABLE IF NOT EXISTS commands(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                cwd TEXT NOT NULL DEFAULT '',
                command TEXT NOT NULL,
                exit_code INTEGER,
                duration REAL,
                branch TEXT
            )
            """)
            execute("CREATE INDEX IF NOT EXISTS idx_commands_ts ON commands(ts DESC)")
        }
    }

    deinit {
        sqlite3_close(db)
    }

    /// 命令结束时落一笔(命令文本已剥提示符;空文本不记)
    func record(command: String, cwd: String?, exitCode: Int?, duration: Double?, branch: String?) {
        let cleaned = Self.stripPrompt(command)
        guard !cleaned.isEmpty else { return }
        queue.async { [self] in
            guard let db else { return }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "INSERT INTO commands(ts, cwd, command, exit_code, duration, branch) VALUES(?,?,?,?,?,?)",
                -1, &statement, nil
            ) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
            sqlite3_bind_text(statement, 2, cwd ?? "", -1, transient)
            sqlite3_bind_text(statement, 3, cleaned, -1, transient)
            if let exitCode {
                sqlite3_bind_int(statement, 4, Int32(exitCode))
            } else {
                sqlite3_bind_null(statement, 4)
            }
            if let duration {
                sqlite3_bind_double(statement, 5, duration)
            } else {
                sqlite3_bind_null(statement, 5)
            }
            if let branch {
                sqlite3_bind_text(statement, 6, branch, -1, transient)
            } else {
                sqlite3_bind_null(statement, 6)
            }
            sqlite3_step(statement)
        }
    }

    /// 模糊搜索(命令/目录 contains),按时间倒序
    func search(_ query: String, limit: Int = 60) -> [Entry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let sql: String
        if trimmed.isEmpty {
            sql = "SELECT id, ts, cwd, command, exit_code, duration, branch FROM commands ORDER BY ts DESC LIMIT \(limit)"
        } else {
            sql = "SELECT id, ts, cwd, command, exit_code, duration, branch FROM commands WHERE command LIKE ?1 OR cwd LIKE ?1 ORDER BY ts DESC LIMIT \(limit)"
        }
        return queue.sync { [self] in
            fetch(sql: sql, like: trimmed.isEmpty ? nil : "%\(trimmed)%")
        }
    }

    /// 今天 0 点以来的全部记录(日报)
    func today() -> [Entry] {
        let midnight = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        return queue.sync { [self] in
            fetch(sql: "SELECT id, ts, cwd, command, exit_code, duration, branch FROM commands WHERE ts >= \(midnight) ORDER BY ts ASC LIMIT 5000", like: nil)
        }
    }

    /// 只留最近 5 万条
    func prune(keep: Int = 50_000) {
        queue.async { [self] in
            execute("DELETE FROM commands WHERE id NOT IN (SELECT id FROM commands ORDER BY ts DESC LIMIT \(keep))")
        }
    }

    // MARK: - 内部

    private func fetch(sql: String, like: String?) -> [Entry] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        if let like {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, like, -1, transient)
        }
        var result: [Entry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(Entry(
                id: sqlite3_column_int64(statement, 0),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                cwd: String(cString: sqlite3_column_text(statement, 2)),
                command: String(cString: sqlite3_column_text(statement, 3)),
                exitCode: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int(statement, 4)),
                duration: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 5),
                branch: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(statement, 6))
            ))
        }
        return result
    }

    private func execute(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// 剥提示符前缀:命令文本来自缓冲区提示符行,取最后一个提示符号后的内容
    static func stripPrompt(_ text: String) -> String {
        let firstLine = text.components(separatedBy: "\n").first ?? text
        var best: String?
        for marker in ["❯ ", "➜ ", "» ", "✗ ", "$ ", "% ", "# "] {
            if let range = firstLine.range(of: marker, options: .backwards) {
                let candidate = String(firstLine[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty, best == nil || candidate.count < best!.count {
                    best = candidate
                }
            }
        }
        let rest = text.components(separatedBy: "\n").dropFirst().joined(separator: " ")
        let head = best ?? firstLine.trimmingCharacters(in: .whitespaces)
        let combined = rest.isEmpty ? head : head + " " + rest.trimmingCharacters(in: .whitespaces)
        return String(combined.prefix(500))
    }
}
