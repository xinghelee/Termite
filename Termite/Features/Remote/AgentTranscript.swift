import Foundation
import SQLite3

/// 手机「对话模式」的数据源:读 agent 自己写的转录,而不是解析终端画面。
///
/// 为什么不解析 TUI:它一直重绘、有转圈动画和折行,解析必碎,而且 agent 一升级就废。
/// 转录是结构化的真相,还带 cwd/时间戳,能稳稳地和某个 pane 对上。
///
/// 各家格式没有稳定契约,所以这里的原则是:**解析失败就当没有转录**,
/// 客户端退回终端视图,绝不因为格式变动而崩。

/// 归一化后的一条消息,手机端只认这个结构,不知道背后是哪个 agent
struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable {
        case user, assistant
    }

    struct ToolCall: Codable, Equatable {
        var name: String
        /// 一行摘要(文件路径 / 命令),列表里折叠成一行显示
        var summary: String
    }

    var id: String
    var role: Role
    var text: String
    /// 思考块单独标记,客户端默认折叠
    var thinking: Bool
    var tools: [ToolCall]
    /// 秒级时间戳
    var time: Double
}

/// 一个可对话的会话:终端 pane ↔ agent 转录的绑定结果
struct ChatSessionInfo: Codable, Identifiable {
    /// 终端会话 ID(和终端 tab 里的一致,方便两个视图互跳)
    var id: UUID
    var title: String
    var cwd: String?
    /// 哪家 agent("Claude Code" / "Codex" / "OpenCode")
    var agent: String
    /// 最后一条消息的时间,列表按它排序
    var lastActivity: Double
    /// pane 的注意力状态("input" = 正在等你确认/输入);
    /// 权限提示这类纯 TUI 的东西转录里没有,靠它给对话页一个「去终端」的提示
    var attention: String?
    /// 绑定的 pane 是否真在跑 agent(备用屏 TUI)。false 时禁止发消息 ——
    /// 同一目录下常有普通 shell,往它注入文字等于在 bash 里执行了一句你没打算执行的话
    var canSend: Bool
    /// 工作空间归属:对话列表和终端列表用同一套筛选语义
    var space: String?
    var spaceID: UUID?
}

/// 手机端「唤起 agent」能选的一家。命令在 Mac 上确实存在才下发
struct ChatAgentOption: Codable, Identifiable {
    var id: String
    var name: String
    /// 敲进新 pane 的命令
    var command: String
}

/// 一份转录的定位结果。文件型 agent 是路径,数据库型是会话 ID ——
/// 上层只拿它当不透明标识用(去重、订阅)
struct AgentTranscriptRef: Hashable {
    var key: String
    var modified: Date
}

/// 各家 agent 的适配器接口。加一家就实现一个,上层与客户端都不用改
protocol AgentTranscriptAdapter {
    /// 展示名
    var agentName: String { get }
    /// 手机端「唤起」时敲的命令
    var launchCommand: String { get }
    /// 终端标题里出现这些词,就认定这个 pane 跑的是它
    var titleKeywords: [String] { get }
    /// 找出这个工作目录对应的、最近在写的转录;没有返回 nil
    func transcript(forCWD cwd: String) -> AgentTranscriptRef?
    /// 从游标处继续解析,返回新消息与新游标。游标为空串 = 从头(取历史)
    func parse(_ ref: AgentTranscriptRef, from cursor: String) -> (messages: [ChatMessage], cursor: String)
}

extension AgentTranscriptAdapter {
    func matchesTitle(_ title: String) -> Bool {
        titleKeywords.contains { title.localizedCaseInsensitiveContains($0) }
    }
}

// MARK: - 行式 JSONL 的公共部分

/// Claude Code 和 Codex 都是「一行一条 JSON、只追加」,读法完全一样:
/// 游标就是字节偏移,每次只读增量。差别只在一行 JSON 怎么翻译成消息
enum JSONLTranscript {
    /// 取历史时最多回读这么多字节。几个月的会话能到几十 MB,
    /// 全量解析会把主线程卡住,而手机只展示最后 200 条
    static let historyWindow: UInt64 = 1_500_000

    static func parse(
        path: String,
        from cursor: String,
        translate: ([String: Any], String) -> ChatMessage?
    ) -> (messages: [ChatMessage], cursor: String) {
        let offset = UInt64(cursor) ?? 0
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], cursor) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // 文件被换掉/截断(切换会话)时从头再来
        var start = offset > size ? 0 : offset
        var skipPartialFirstLine = false
        if start == 0, size > historyWindow {
            start = size - historyWindow
            skipPartialFirstLine = true
        }
        guard size > start else { return ([], String(size)) }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return ([], String(size)) }

        var messages: [ChatMessage] = []
        var consumed = start
        var first = true
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            // 最后一段可能是半行(正在写),留到下次
            let isLast = line.endIndex == data.endIndex
            if isLast, !line.isEmpty { break }
            consumed += UInt64(line.count) + 1
            defer { first = false }
            if first, skipPartialFirstLine { continue }
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            // 没有自带 id 的记录用偏移兜底,保证同一条消息 id 稳定
            if let message = translate(obj, "\(path)#\(consumed)") { messages.append(message) }
        }
        return (messages, String(min(consumed, size)))
    }

    /// 工具调用折成一行:优先文件路径/命令,兜底取第一个字符串参数
    static func toolSummary(_ input: [String: Any]) -> String {
        for key in ["file_path", "path", "command", "cmd", "pattern", "description", "prompt", "url", "query"] {
            if let value = input[key] as? String, !value.isEmpty {
                return String(value.prefix(120))
            }
            // codex 的 shell 调用是 ["bash","-lc","..."]
            if let list = input[key] as? [String], !list.isEmpty {
                return String(list.joined(separator: " ").prefix(120))
            }
        }
        for (_, value) in input {
            if let value = value as? String, !value.isEmpty { return String(value.prefix(120)) }
        }
        return ""
    }

    static func seconds(_ iso: String?) -> Double {
        guard let iso else { return Date().timeIntervalSince1970 }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }
}

// MARK: - Claude Code

/// `~/.claude/projects/<cwd 转成的 slug>/<sessionId>.jsonl`,每行一条 JSON。
/// 每行都带 cwd,所以绑定 pane 很稳:slug 命中 + 文件在被写 = 就是它。
struct ClaudeCodeAdapter: AgentTranscriptAdapter {
    var agentName: String { "Claude Code" }
    var launchCommand: String { "claude" }
    var titleKeywords: [String] { ["claude"] }

    private var projectsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    }

    /// Claude Code 把 cwd 里的 `/` 和 `.` 都换成 `-` 作为目录名
    private func slug(for cwd: String) -> String {
        var out = ""
        for ch in cwd {
            out.append(ch == "/" || ch == "." || ch == "_" ? "-" : ch)
        }
        return out
    }

    func transcript(forCWD cwd: String) -> AgentTranscriptRef? {
        let dir = projectsRoot.appendingPathComponent(slug(for: cwd))
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        // 同一目录可能有多场会话,取最近写过的那个
        guard let newest = files
            .filter({ $0.pathExtension == "jsonl" })
            .max(by: { JSONLTranscript.modified($0) < JSONLTranscript.modified($1) })
        else { return nil }
        return AgentTranscriptRef(key: newest.path, modified: JSONLTranscript.modified(newest))
    }

    func parse(_ ref: AgentTranscriptRef, from cursor: String) -> (messages: [ChatMessage], cursor: String) {
        JSONLTranscript.parse(path: ref.key, from: cursor) { obj, fallbackID in
            Self.message(from: obj, fallbackID: fallbackID)
        }
    }

    /// 一行 JSON → 一条展示用消息。子代理(isSidechain)和纯 tool_result 不进对话流
    private static func message(from obj: [String: Any], fallbackID: String) -> ChatMessage? {
        guard obj["isSidechain"] as? Bool != true, obj["isMeta"] as? Bool != true else { return nil }
        let type = obj["type"] as? String
        guard type == "user" || type == "assistant" else { return nil }
        let uuid = obj["uuid"] as? String ?? fallbackID
        let time = JSONLTranscript.seconds(obj["timestamp"] as? String)
        guard let message = obj["message"] as? [String: Any] else { return nil }

        if type == "user" {
            // content 可能是纯字符串,也可能是块数组(其中 tool_result 不展示)
            if let text = message["content"] as? String, !text.isEmpty {
                return ChatMessage(id: uuid, role: .user, text: text,
                                   thinking: false, tools: [], time: time)
            }
            let blocks = message["content"] as? [[String: Any]] ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            guard !text.isEmpty else { return nil }
            return ChatMessage(id: uuid, role: .user, text: text,
                               thinking: false, tools: [], time: time)
        }

        let blocks = message["content"] as? [[String: Any]] ?? []
        var text = "", thinkingText = ""
        var tools: [ChatMessage.ToolCall] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                text += (block["text"] as? String ?? "")
            case "thinking":
                thinkingText += (block["thinking"] as? String ?? "")
            case "tool_use":
                tools.append(ChatMessage.ToolCall(
                    name: block["name"] as? String ?? "tool",
                    summary: JSONLTranscript.toolSummary(block["input"] as? [String: Any] ?? [:])))
            default:
                break
            }
        }
        // 只有思考没有正文:单独作为一条折叠的思考消息
        if text.isEmpty, tools.isEmpty {
            guard !thinkingText.isEmpty else { return nil }
            return ChatMessage(id: uuid, role: .assistant, text: thinkingText,
                               thinking: true, tools: [], time: time)
        }
        return ChatMessage(id: uuid, role: .assistant, text: text,
                           thinking: false, tools: tools, time: time)
    }
}

// MARK: - Codex

/// `~/.codex/sessions/<年>/<月>/<日>/rollout-<时间>-<uuid>.jsonl`。
///
/// 和 Claude 的差别在于:cwd 不在每一行里,只在首行的 `session_meta`。
/// 所以得反过来找 —— 按修改时间从新到旧翻文件,读首行看 cwd 对不对。
/// 路径→cwd 是不变的,认过一次就永久缓存,一秒一次的轮询不会真的去读盘。
struct CodexAdapter: AgentTranscriptAdapter {
    var agentName: String { "Codex" }
    var launchCommand: String { "codex" }
    var titleKeywords: [String] { ["codex"] }

    /// 只在最近这些天的目录里找 —— 再往前的会话不可能是「当前正在聊的那场」
    private static let lookbackDays = 14
    /// 单次最多探查多少个文件,防止历史目录巨大时卡住
    private static let scanLimit = 240

    private static var cwdCache: [String: String] = [:]

    private var sessionsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    func transcript(forCWD cwd: String) -> AgentTranscriptRef? {
        let cutoff = Date().addingTimeInterval(-Double(Self.lookbackDays) * 86400)
        var candidates: [(URL, Date)] = []
        let fm = FileManager.default
        guard let years = try? fm.contentsOfDirectory(at: sessionsRoot, includingPropertiesForKeys: nil)
        else { return nil }
        for year in years.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard let months = try? fm.contentsOfDirectory(at: year, includingPropertiesForKeys: nil)
            else { continue }
            for month in months.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                guard let days = try? fm.contentsOfDirectory(at: month, includingPropertiesForKeys: nil)
                else { continue }
                for day in days.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                    guard let files = try? fm.contentsOfDirectory(
                        at: day, includingPropertiesForKeys: [.contentModificationDateKey]
                    ) else { continue }
                    for file in files where file.pathExtension == "jsonl" {
                        let modified = JSONLTranscript.modified(file)
                        guard modified > cutoff else { continue }
                        candidates.append((file, modified))
                    }
                }
                if candidates.count > Self.scanLimit { break }
            }
            if candidates.count > Self.scanLimit { break }
        }
        // 新的在前:第一个 cwd 命中的就是这个 pane 正在聊的那场
        for (file, modified) in candidates.sorted(by: { $0.1 > $1.1 }).prefix(Self.scanLimit) {
            guard Self.cwd(of: file) == cwd else { continue }
            return AgentTranscriptRef(key: file.path, modified: modified)
        }
        return nil
    }

    /// 读首行的 session_meta 取 cwd。首行含完整系统提示,可能几十 KB,
    /// 所以只读前 128KB 找第一个换行
    private static func cwd(of url: URL) -> String? {
        if let hit = cwdCache[url.path] { return hit.isEmpty ? nil : hit }
        var result = ""
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            if let chunk = try? handle.read(upToCount: 128 * 1024),
               let newline = chunk.firstIndex(of: UInt8(ascii: "\n")),
               let obj = try? JSONSerialization.jsonObject(
                   with: chunk[chunk.startIndex..<newline]) as? [String: Any],
               let payload = obj["payload"] as? [String: Any],
               let cwd = payload["cwd"] as? String {
                result = cwd
            }
        }
        cwdCache[url.path] = result
        return result.isEmpty ? nil : result
    }

    func parse(_ ref: AgentTranscriptRef, from cursor: String) -> (messages: [ChatMessage], cursor: String) {
        JSONLTranscript.parse(path: ref.key, from: cursor) { obj, fallbackID in
            Self.message(from: obj, fallbackID: fallbackID)
        }
    }

    private static func message(from obj: [String: Any], fallbackID: String) -> ChatMessage? {
        // 只认 response_item(真正的对话内容);event_msg 是 TUI 事件,内容重复
        guard obj["type"] as? String == "response_item",
              let payload = obj["payload"] as? [String: Any] else { return nil }
        let time = JSONLTranscript.seconds(obj["timestamp"] as? String)
        let id = payload["id"] as? String ?? fallbackID

        switch payload["type"] as? String {
        case "message":
            let role = payload["role"] as? String
            // developer 是注入的规则/技能清单,不是人说的话
            guard role == "user" || role == "assistant" else { return nil }
            let blocks = payload["content"] as? [[String: Any]] ?? []
            let text = blocks.compactMap { $0["text"] as? String }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // codex 每轮都往用户消息里塞 <environment_context> 这类包裹块,不是人打的字
            if role == "user", text.hasPrefix("<") { return nil }
            return ChatMessage(id: id, role: role == "user" ? .user : .assistant,
                               text: text, thinking: false, tools: [], time: time)

        case "reasoning":
            // summary 常常是空的(内容加密),那就没什么可展示的
            let summary = payload["summary"] as? [[String: Any]] ?? []
            let text = summary.compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard !text.isEmpty else { return nil }
            return ChatMessage(id: id, role: .assistant, text: text,
                               thinking: true, tools: [], time: time)

        case "function_call", "custom_tool_call", "local_shell_call":
            let name = payload["name"] as? String
                ?? (payload["action"] as? [String: Any]).map { _ in "shell" }
                ?? "tool"
            return ChatMessage(id: id, role: .assistant, text: "", thinking: false,
                               tools: [ChatMessage.ToolCall(name: name, summary: Self.callSummary(payload))],
                               time: time)

        default:
            return nil
        }
    }

    /// 参数可能是 JSON 字符串(function_call.arguments)、
    /// 自由文本(custom_tool_call.input)或结构体(local_shell_call.action)
    private static func callSummary(_ payload: [String: Any]) -> String {
        if let action = payload["action"] as? [String: Any] {
            return JSONLTranscript.toolSummary(action)
        }
        for key in ["arguments", "input"] {
            guard let raw = payload[key] as? String, !raw.isEmpty else { continue }
            if let data = raw.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let summary = JSONLTranscript.toolSummary(obj)
                if !summary.isEmpty { return summary }
            }
            return String(raw.prefix(120))
        }
        return ""
    }
}

// MARK: - OpenCode

/// OpenCode 新版把会话搬进了 SQLite(`~/.local/share/opencode/opencode.db`),
/// 老版本那套 `storage/session/message/*.json` 已经不写了。
///
/// 只读打开、每次查询单独开连接:它在 WAL 模式下一直有写入,
/// 长连接反而要处理快照过期;开一次连接的代价对一秒一次的轮询可以忽略。
struct OpenCodeAdapter: AgentTranscriptAdapter {
    var agentName: String { "OpenCode" }
    var launchCommand: String { "opencode" }
    var titleKeywords: [String] { ["opencode"] }

    private var dbPath: String {
        NSHomeDirectory() + "/.local/share/opencode/opencode.db"
    }

    func transcript(forCWD cwd: String) -> AgentTranscriptRef? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        var result: AgentTranscriptRef?
        SQLiteReader.open(dbPath) { db in
            db.query("""
                SELECT id, time_updated FROM session
                WHERE directory = ?1 AND time_archived IS NULL
                ORDER BY time_updated DESC LIMIT 1
                """, text: [cwd]) { row in
                let id = row.text(0)
                let updated = row.int(1)
                guard !id.isEmpty else { return }
                result = AgentTranscriptRef(key: id,
                                            modified: Date(timeIntervalSince1970: Double(updated) / 1000))
            }
        }
        return result
    }

    /// 游标 = 已读到的最后一个 part 的创建时间(毫秒)。
    /// 一个 part 直接对应一条展示消息(正文/思考/工具各一条),
    /// id 用 part 自己的 —— 不会因为一条消息分多次写而重复。
    func parse(_ ref: AgentTranscriptRef, from cursor: String) -> (messages: [ChatMessage], cursor: String) {
        let since = Int64(cursor) ?? 0
        var messages: [ChatMessage] = []
        var newest = since
        SQLiteReader.open(dbPath) { db in
            db.query("""
                SELECT p.id, p.time_created, p.data, json_extract(m.data, '$.role')
                FROM part p JOIN message m ON m.id = p.message_id
                WHERE p.session_id = ?1 AND p.time_created > ?2
                ORDER BY p.time_created ASC, p.id ASC LIMIT 4000
                """, text: [ref.key], int: [since]) { row in
                let time = row.int(1)
                guard let data = row.text(2).data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { newest = max(newest, time); return }
                let role: ChatMessage.Role = row.text(3) == "user" ? .user : .assistant
                if let message = Self.message(from: obj, id: row.text(0), role: role,
                                              time: Double(time) / 1000) {
                    messages.append(message)
                }
                newest = max(newest, time)
            }
        }
        return (messages, String(newest))
    }

    private static func message(from obj: [String: Any], id: String,
                                role: ChatMessage.Role, time: Double) -> ChatMessage? {
        switch obj["type"] as? String {
        case "text":
            let text = (obj["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ChatMessage(id: id, role: role, text: text, thinking: false, tools: [], time: time)
        case "reasoning":
            let text = (obj["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ChatMessage(id: id, role: .assistant, text: text,
                               thinking: true, tools: [], time: time)
        case "tool":
            let state = obj["state"] as? [String: Any] ?? [:]
            // 还在跑的工具先不展示:input 可能只写了一半
            guard let status = state["status"] as? String,
                  status == "completed" || status == "error" else { return nil }
            let name = obj["tool"] as? String ?? "tool"
            let summary = (state["title"] as? String)
                ?? JSONLTranscript.toolSummary(state["input"] as? [String: Any] ?? [:])
            return ChatMessage(id: id, role: .assistant, text: "", thinking: false,
                               tools: [ChatMessage.ToolCall(name: name, summary: String(summary.prefix(120)))],
                               time: time)
        default:
            // step-start / step-finish / file / patch 之类不进对话流
            return nil
        }
    }
}

/// 极简 SQLite 读封装 —— 只为读 OpenCode 那一个库,不做通用抽象
private final class SQLiteReader {
    struct Row {
        let statement: OpaquePointer

        func text(_ index: Int32) -> String {
            guard let raw = sqlite3_column_text(statement, index) else { return "" }
            return String(cString: raw)
        }

        func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
    }

    private let db: OpaquePointer
    /// 语句没准备起来(通常是只读连接开不了 WAL)
    private var failed = false

    private init?(path: String, readOnly: Bool) {
        var handle: OpaquePointer?
        let uri = readOnly ? "file:\(path)?mode=ro" : "file:\(path)"
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_URI
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        sqlite3_busy_timeout(handle, 300)
        db = handle
    }

    deinit { sqlite3_close(db) }

    /// 先试只读;开不起来再退回读写。
    ///
    /// WAL 库要有 `-shm` 才能读,而 `-shm` 只有写连接能创建 ——
    /// OpenCode 没在跑的时候(库已 checkpoint、-shm 被删),只读连接
    /// 在第一条语句上就 SQLITE_CANTOPEN。退回读写不会改数据:这里只跑 SELECT。
    ///
    /// body 只允许跑**一条**查询:失败发生在 prepare,还没吐过行,重试才不会重复。
    static func open(_ path: String, _ body: (SQLiteReader) -> Void) {
        if let readOnly = SQLiteReader(path: path, readOnly: true) {
            body(readOnly)
            if !readOnly.failed { return }
        }
        if let readWrite = SQLiteReader(path: path, readOnly: false) { body(readWrite) }
    }

    func query(_ sql: String, text: [String] = [], int: [Int64] = [], row: (Row) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            failed = true
            return
        }
        defer { sqlite3_finalize(statement) }
        // SQLITE_TRANSIENT:让 sqlite 自己拷一份,免得 Swift 字符串先被回收
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in text.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        for (index, value) in int.enumerated() {
            sqlite3_bind_int64(statement, Int32(text.count + index + 1), value)
        }
        while sqlite3_step(statement) == SQLITE_ROW {
            row(Row(statement: statement))
        }
    }
}

// MARK: - 中枢

/// 转录订阅:把某个终端 pane 的 agent 会话变成消息流推给手机。
/// 转录是「消息写完才落盘」,拿不到逐字流 —— 逐字那种观感由 pane 的注意力状态驱动。
@MainActor
final class AgentTranscriptHub {
    static let shared = AgentTranscriptHub()

    private let adapters: [AgentTranscriptAdapter] = [
        ClaudeCodeAdapter(), CodexAdapter(), OpenCodeAdapter(),
    ]
    private var watchers: [UUID: Watcher] = [:]
    /// chatList 会被反复调用,而 Codex 的定位要翻目录 —— 短缓存把开销摊平
    private var lookupCache: [String: (result: (name: String, ref: AgentTranscriptRef)?, at: Date)] = [:]

    private final class Watcher {
        let ref: AgentTranscriptRef
        let adapter: AgentTranscriptAdapter
        var cursor: String
        var timer: DispatchSourceTimer?

        init(ref: AgentTranscriptRef, adapter: AgentTranscriptAdapter, cursor: String) {
            self.ref = ref
            self.adapter = adapter
            self.cursor = cursor
        }
    }

    /// 有 agent 转录的会话(对话 tab 只列这些,普通 shell 归终端 tab)
    /// 标题是不是 agent 的样子:Claude Code 把任务摘要写进终端标题,
    /// 前面带一个转圈状态符(✳ ◑ ✻ ·)。普通命令(git log / vim)不会这样
    private static func titleLooksLikeAgent(_ title: String) -> Bool {
        guard let first = title.unicodeScalars.first else { return false }
        // 首字符是符号且后面还有空格分隔的正文
        let isSymbol = !CharacterSet.alphanumerics.contains(first)
            && !CharacterSet.whitespaces.contains(first)
            && first.value > 0x2000
        return isSymbol && title.contains(" ")
    }

    /// 一个目录可能同时有几家 agent 的历史转录(先用 Claude 后用 Codex)。
    /// 谁在这个 pane 里跑就选谁:标题点名的优先,否则挑转录写得最新的那家
    private func locate(cwd: String, title: String) -> (adapter: AgentTranscriptAdapter, ref: AgentTranscriptRef)? {
        var found: [(AgentTranscriptAdapter, AgentTranscriptRef)] = []
        for adapter in adapters {
            let key = "\(adapter.agentName)|\(cwd)"
            if let cached = lookupCache[key], Date().timeIntervalSince(cached.at) < 3 {
                if let hit = cached.result, hit.name == adapter.agentName {
                    found.append((adapter, hit.ref))
                }
                continue
            }
            let ref = adapter.transcript(forCWD: cwd)
            lookupCache[key] = (ref.map { (adapter.agentName, $0) }, Date())
            if let ref { found.append((adapter, ref)) }
        }
        guard !found.isEmpty else { return nil }
        if let named = found.first(where: { $0.0.matchesTitle(title) }) { return named }
        return found.max { $0.1.modified < $1.1.modified }
    }

    /// 同一个工作目录下的多个 pane 会指向同一份转录,列表按转录去重 ——
    /// 否则 3 个 pane 就是 3 条一模一样的对话,点进去内容还相同
    /// 会话 → 工作空间。归属挂在标签上,得走一遍 窗口→标签→分屏(和侧边栏同一套语义)
    private func spaceBinding() -> [UUID: (name: String?, id: UUID?)] {
        var result: [UUID: (String?, UUID?)] = [:]
        for manager in SessionManagerRegistry.shared.managers {
            for tab in manager.tabs {
                let spaceID = manager.spaceID(of: tab)
                let name = spaceID.flatMap { id in
                    SpaceStore.shared.spaces.first { $0.id == id }?.name
                }
                for sessionID in tab.root.leafIDs() {
                    result[sessionID] = (name, spaceID)
                }
            }
        }
        return result
    }

    func chatSessions() -> [ChatSessionInfo] {
        let spaces = spaceBinding()
        var byTranscript: [String: ChatSessionInfo] = [:]
        for session in SessionManagerRegistry.shared.allSessions {
            guard let cwd = session.workingDirectory,
                  let (adapter, ref) = locate(cwd: cwd, title: session.displayTitle) else { continue }
            let attention: String? = switch session.attention {
            case .none: nil
            case .needsInput: "input"
            case .finished: "finished"
            }
            // 「能发消息」= 备用屏 TUI + 看得出是 agent。
            // 只看备用屏会误判:git log 走分页器同样是备用屏,发过去就打进 less 了。
            // 判据一:标题点名了这家 agent;判据二:标题带 agent 的状态符号
            // (Claude Code 把任务摘要写进标题,前面跟一个 ✳ ◑ ✻ 之类的转圈字符);
            // 判据三:转录刚写过。三者取或 —— 闲置的会话标题还在,
            // 而正在跑的即使标题没符号也算
            let fresh = Date().timeIntervalSince(ref.modified) < 15 * 60
            let looksLikeAgent = adapter.matchesTitle(session.displayTitle)
                || Self.titleLooksLikeAgent(session.displayTitle)
            let info = ChatSessionInfo(
                id: session.id, title: session.displayTitle, cwd: cwd,
                agent: adapter.agentName, lastActivity: ref.modified.timeIntervalSince1970,
                attention: attention,
                canSend: session.requiresSharedTUILayout && (looksLikeAgent || fresh),
                space: spaces[session.id]?.name, spaceID: spaces[session.id]?.id)
            // 同一份转录挑「真在跑 agent」的那个 pane —— 同目录下常混着普通 shell。
            // 其次才看谁在等你输入
            if let existing = byTranscript[ref.key] {
                let better = (info.canSend && !existing.canSend)
                    || (info.canSend == existing.canSend
                        && info.attention == "input" && existing.attention != "input")
                guard better else { continue }
            }
            byTranscript[ref.key] = info
        }
        return byTranscript.values.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Mac 上装了哪几家 agent(手机端「唤起」列表)。
    /// 用登录 shell 查一次 —— PATH 里的 nvm/homebrew 路径只有登录 shell 才齐
    private var availableAgents: [ChatAgentOption]?
    private var probing = false

    /// 探测放后台:`zsh -lc` 要跑完整套 profile,在主线程上够卡一下界面。
    /// 首次调用返回空,手机三秒后的下一次 chatList 就拿到了
    func agentOptions() -> [ChatAgentOption] {
        if let availableAgents { return availableAgents }
        guard !probing else { return [] }
        probing = true
        let commands = adapters.map(\.launchCommand)
        let named = adapters.map { ($0.launchCommand, $0.agentName) }
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "command -v " + commands.joined(separator: " ")]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var found = ""
            if (try? process.run()) != nil {
                found = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                               encoding: .utf8) ?? ""
                process.waitUntilExit()
            }
            let lines = found.split(separator: "\n")
            let options = named.compactMap { command, name -> ChatAgentOption? in
                // command -v 打出的是绝对路径,按结尾匹配
                let installed = lines.contains {
                    $0.hasSuffix("/" + command) || $0 == Substring(command)
                }
                guard installed else { return nil }
                return ChatAgentOption(id: command, name: name, command: command)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.availableAgents = options
                    self.probing = false
                }
            }
        }
        return []
    }

    /// 订阅:先回放历史(最多 maxHistory 条),之后每秒查一次增量。
    /// 用轮询而不是 FSEvents —— 转录是追加写,轮询一次只读增量,开销可以忽略,
    /// 而且不用处理文件替换/重建时的事件丢失
    func attach(connID: UUID, sessionID: UUID, maxHistory: Int,
                onMessages: @escaping ([ChatMessage], Bool) -> Void) -> Bool {
        detach(connID: connID)
        guard let session = SessionManagerRegistry.shared.allSessions.first(where: { $0.id == sessionID }),
              let cwd = session.workingDirectory,
              let (adapter, ref) = locate(cwd: cwd, title: session.displayTitle) else { return false }
        let (history, cursor) = adapter.parse(ref, from: "")
        let watcher = Watcher(ref: ref, adapter: adapter, cursor: cursor)
        watchers[connID] = watcher
        onMessages(Array(history.suffix(maxHistory)), true)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let watcher = self.watchers[connID] else { return }
                let (fresh, cursor) = watcher.adapter.parse(watcher.ref, from: watcher.cursor)
                watcher.cursor = cursor
                if !fresh.isEmpty { onMessages(fresh, false) }
            }
        }
        timer.resume()
        watcher.timer = timer
        return true
    }

    func detach(connID: UUID) {
        watchers.removeValue(forKey: connID)?.timer?.cancel()
    }
}
