import Foundation

/// 手机「对话模式」的数据源:读 agent 自己写的转录文件,而不是解析终端画面。
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
    /// 哪家 agent("Claude Code" 等)
    var agent: String
    /// 最后一条消息的时间,列表按它排序
    var lastActivity: Double
    /// pane 的注意力状态("input" = 正在等你确认/输入);
    /// 权限提示这类纯 TUI 的东西转录里没有,靠它给对话页一个「去终端」的提示
    var attention: String?
    /// 绑定的 pane 是否真在跑 agent(备用屏 TUI)。false 时禁止发消息 ——
    /// 同一目录下常有普通 shell,往它注入文字等于在 bash 里执行了一句你没打算执行的话
    var canSend: Bool
}

/// 各家 agent 的适配器接口。加一家就实现一个,上层与客户端都不用改
protocol AgentTranscriptAdapter {
    /// 展示名
    var agentName: String { get }
    /// 找出这个工作目录对应的、正在写的转录文件;没有返回 nil
    func transcript(forCWD cwd: String) -> URL?
    /// 从指定字节偏移继续解析,返回新消息与新的偏移
    func parse(_ url: URL, from offset: UInt64) -> (messages: [ChatMessage], offset: UInt64)
}

// MARK: - Claude Code

/// `~/.claude/projects/<cwd 转成的 slug>/<sessionId>.jsonl`,每行一条 JSON。
/// 每行都带 cwd,所以绑定 pane 很稳:slug 命中 + 文件在被写 = 就是它。
struct ClaudeCodeAdapter: AgentTranscriptAdapter {
    var agentName: String { "Claude Code" }

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

    func transcript(forCWD cwd: String) -> URL? {
        let dir = projectsRoot.appendingPathComponent(slug(for: cwd))
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        // 同一目录可能有多场会话,取最近写过的那个
        return files
            .filter { $0.pathExtension == "jsonl" }
            .max { a, b in modified(a) < modified(b) }
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    func parse(_ url: URL, from offset: UInt64) -> (messages: [ChatMessage], offset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // 文件被换掉/截断(切换会话)时从头再来
        let start = offset > size ? 0 : offset
        guard size > start else { return ([], size) }
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return ([], size) }

        var messages: [ChatMessage] = []
        var consumed = start
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            // 最后一段可能是半行(正在写),留到下次
            let isLast = line.endIndex == data.endIndex
            if isLast, !line.isEmpty { break }
            consumed += UInt64(line.count) + 1
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            if let message = Self.message(from: obj) { messages.append(message) }
        }
        return (messages, min(consumed, size))
    }

    /// 一行 JSON → 一条展示用消息。子代理(isSidechain)和纯 tool_result 不进对话流
    private static func message(from obj: [String: Any]) -> ChatMessage? {
        guard obj["isSidechain"] as? Bool != true, obj["isMeta"] as? Bool != true else { return nil }
        let type = obj["type"] as? String
        guard type == "user" || type == "assistant" else { return nil }
        let uuid = obj["uuid"] as? String ?? UUID().uuidString
        let time = Self.seconds(obj["timestamp"] as? String)
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
                    summary: Self.toolSummary(block["input"] as? [String: Any] ?? [:])))
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

    /// 工具调用折成一行:优先文件路径/命令,兜底取第一个字符串参数
    private static func toolSummary(_ input: [String: Any]) -> String {
        for key in ["file_path", "path", "command", "pattern", "description", "prompt", "url"] {
            if let value = input[key] as? String, !value.isEmpty {
                return String(value.prefix(120))
            }
        }
        for (_, value) in input {
            if let value = value as? String, !value.isEmpty { return String(value.prefix(120)) }
        }
        return ""
    }

    private static func seconds(_ iso: String?) -> Double {
        guard let iso else { return Date().timeIntervalSince1970 }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
    }
}

// MARK: - 中枢

/// 转录订阅:把某个终端 pane 的 agent 会话变成消息流推给手机。
/// 转录是「消息写完才落盘」,拿不到逐字流 —— 逐字那种观感由 pane 的注意力状态驱动。
@MainActor
final class AgentTranscriptHub {
    static let shared = AgentTranscriptHub()

    private let adapters: [AgentTranscriptAdapter] = [ClaudeCodeAdapter()]
    private var watchers: [UUID: Watcher] = [:]

    private final class Watcher {
        let url: URL
        let adapter: AgentTranscriptAdapter
        var offset: UInt64
        var timer: DispatchSourceTimer?

        init(url: URL, adapter: AgentTranscriptAdapter, offset: UInt64) {
            self.url = url
            self.adapter = adapter
            self.offset = offset
        }
    }

    /// 有 agent 转录的会话(对话 tab 只列这些,普通 shell 归终端 tab)
    /// 标题是不是 agent 的样子:Claude Code 把任务摘要写进终端标题,
    /// 前面带一个转圈状态符(✳ ◑ ✻ ·)。普通命令(git log / vim)不会这样
    private static func titleLooksLikeAgent(_ title: String) -> Bool {
        guard let first = title.unicodeScalars.first else { return false }
        if title.localizedCaseInsensitiveContains("claude") { return true }
        // 首字符是符号且后面还有空格分隔的正文
        let isSymbol = !CharacterSet.alphanumerics.contains(first)
            && !CharacterSet.whitespaces.contains(first)
            && first.value > 0x2000
        return isSymbol && title.contains(" ")
    }

    /// 同一个工作目录下的多个 pane 会指向同一份转录,列表按转录去重 ——
    /// 否则 3 个 pane 就是 3 条一模一样的对话,点进去内容还相同
    func chatSessions() -> [ChatSessionInfo] {
        var byTranscript: [URL: ChatSessionInfo] = [:]
        for session in SessionManagerRegistry.shared.allSessions {
            guard let cwd = session.workingDirectory else { continue }
            for adapter in adapters {
                guard let url = adapter.transcript(forCWD: cwd) else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let attention: String? = switch session.attention {
                case .none: nil
                case .needsInput: "input"
                case .finished: "finished"
                }
                // 「能发消息」= 备用屏 TUI + 看得出是 agent。
                // 只看备用屏会误判:git log 走分页器同样是备用屏,发过去就打进 less 了。
                // 判据一:标题带 agent 的状态符号(Claude Code 会把任务摘要写进标题,
                //   前面跟一个 ✳ ◑ ✻ 之类的转圈字符);判据二:转录刚写过。
                // 两者取或 —— 闲置的 Claude 会话标题还在,而正在跑的即使标题没符号也算
                let fresh = Date().timeIntervalSince(modified) < 15 * 60
                let looksLikeAgent = Self.titleLooksLikeAgent(session.displayTitle)
                let info = ChatSessionInfo(
                    id: session.id, title: session.displayTitle, cwd: cwd,
                    agent: adapter.agentName, lastActivity: modified.timeIntervalSince1970,
                    attention: attention,
                    canSend: session.requiresSharedTUILayout && (looksLikeAgent || fresh))
                // 同一份转录挑「真在跑 agent」的那个 pane —— 同目录下常混着普通 shell。
                // 其次才看谁在等你输入
                if let existing = byTranscript[url] {
                    let better = (info.canSend && !existing.canSend)
                        || (info.canSend == existing.canSend
                            && info.attention == "input" && existing.attention != "input")
                    guard better else { break }
                }
                byTranscript[url] = info
                break
            }
        }
        return byTranscript.values.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// 订阅:先回放历史(最多 maxHistory 条),之后每秒查一次增量。
    /// 用轮询而不是 FSEvents —— 转录是追加写,轮询一次只读增量字节,开销可以忽略,
    /// 而且不用处理文件替换/重建时的事件丢失
    func attach(connID: UUID, sessionID: UUID, maxHistory: Int,
                onMessages: @escaping ([ChatMessage], Bool) -> Void) -> Bool {
        detach(connID: connID)
        guard let session = SessionManagerRegistry.shared.allSessions.first(where: { $0.id == sessionID }),
              let cwd = session.workingDirectory else { return false }
        for adapter in adapters {
            guard let url = adapter.transcript(forCWD: cwd) else { continue }
            let (history, offset) = adapter.parse(url, from: 0)
            let watcher = Watcher(url: url, adapter: adapter, offset: offset)
            watchers[connID] = watcher
            onMessages(Array(history.suffix(maxHistory)), true)

            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let watcher = self.watchers[connID] else { return }
                    let (fresh, offset) = watcher.adapter.parse(watcher.url, from: watcher.offset)
                    watcher.offset = offset
                    if !fresh.isEmpty { onMessages(fresh, false) }
                }
            }
            timer.resume()
            watcher.timer = timer
            return true
        }
        return false
    }

    func detach(connID: UUID) {
        watchers.removeValue(forKey: connID)?.timer?.cancel()
    }
}
