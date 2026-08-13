import Foundation
import Observation

/// 对话模式的客户端:单开一条 WS 专收转录消息。
///
/// 和镜像同样的理由 —— 不跟终端那条字节流混在一起,随时可停,互不影响。
@MainActor
@Observable
final class ChatClient {
    struct SessionInfo: Decodable, Identifiable, Hashable {
        let id: UUID
        let title: String
        let cwd: String?
        let agent: String
        let lastActivity: Double
        let attention: String?
        /// 绑定的 pane 是否真在跑 agent;false 时输入框禁用
        let canSend: Bool?
        let space: String?
        let spaceID: UUID?
    }

    struct SpaceInfo: Decodable, Identifiable, Hashable {
        let id: UUID
        let name: String
    }

    /// 唤起 agent 时选的项目(和终端 tab 的侧边栏目录同一份)
    struct ProjectInfo: Decodable, Identifiable, Hashable {
        let id: UUID
        let name: String
        let path: String
        let accent: String?
        let spaceID: UUID?
    }

    /// Mac 上装了的 agent。没装的不下发,列表里就不会出现
    struct AgentOption: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
        let command: String
    }

    struct Message: Decodable, Identifiable, Equatable {
        struct ToolCall: Decodable, Equatable, Hashable {
            let name: String
            let summary: String
        }
        let id: String
        let role: String
        let text: String
        let thinking: Bool
        let tools: [ToolCall]
        let time: Double

        var isUser: Bool { role == "user" }
    }

    private(set) var sessions: [SessionInfo] = []
    private(set) var spaces: [SpaceInfo] = []
    private(set) var projects: [ProjectInfo] = []
    private(set) var agents: [AgentOption] = []
    private(set) var messages: [Message] = []
    /// 刚唤起的会话:视图看到它就把页面推进去
    private(set) var launched: SessionInfo?
    private(set) var launching = false
    private(set) var attachedID: UUID?
    private(set) var connected = false
    /// 这个会话没有可读的转录 —— 客户端据此提示「去终端看」
    private(set) var unavailable = false
    /// 附着后、首批消息到达前为 true:界面显示转圈而不是一片空白
    private(set) var loading = false
    /// 服务端拒发时的提示(比如 agent 没在跑)
    private(set) var lastError: String?
    /// 刚唤起、还在等 agent 写出第一份转录 —— 界面显示「正在启动」而不是「读不到转录」
    private(set) var retrying = false
    /// socket 还没就绪时点进来的会话,连上后补发 —— 否则那次 attach 石沉大海,
    /// 表现就是「点进去永远空白」
    private var pendingAttach: UUID?
    private var attachedAt = Date.distantPast
    private var retry: Task<Void, Never>?

    private var task: URLSessionWebSocketTask?
    private var endpoint: Endpoint?
    private var generation = 0

    func connect(_ endpoint: Endpoint) {
        if task != nil, self.endpoint == endpoint { return }
        self.endpoint = endpoint
        shutdown(keepEndpoint: true)
        guard let url = endpoint.wsURL else { return }
        generation += 1
        let gen = generation
        let socket = URLSession.shared.webSocketTask(with: url)
        task = socket
        socket.resume()
        receive(socket, gen: gen)
        connected = true
        refresh()
        if let pending = pendingAttach { attach(pending) }
    }

    func shutdown(keepEndpoint: Bool = false) {
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
        attachedID = nil
        messages = []
        if !keepEndpoint { endpoint = nil }
    }

    func refresh() {
        send(["type": "chatList"])
    }

    func attach(_ id: UUID) {
        attachedID = id
        attachedAt = Date()
        retry?.cancel()
        retrying = false
        messages = []
        unavailable = false
        loading = true
        guard task != nil else { pendingAttach = id; return }
        pendingAttach = nil
        send(["type": "chatAttach", "id": id.uuidString, "limit": 200])
    }

    /// 唤起:Mac 在项目目录开一个新 pane 并敲下命令。
    /// agent 要几秒才写出第一份转录,所以推进页面后还会自动重试附着
    func launch(project: UUID, agent: AgentOption) {
        guard !launching else { return }
        launching = true
        lastError = nil
        send(["type": "chatLaunch", "project": project.uuidString, "agent": agent.command])
    }

    func consumeLaunched() { launched = nil }

    func detach() {
        guard attachedID != nil else { return }
        attachedID = nil
        pendingAttach = nil
        retry?.cancel()
        retrying = false
        loading = false
        messages = []
        send(["type": "chatDetach"])
    }

    /// 发消息 = Mac 端把文字注入回那个 pane 的 PTY,agent 自己会读到
    func send(text: String) {
        guard let id = attachedID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastError = nil
        send(["type": "chatSend", "id": id.uuidString, "text": trimmed])
        // 本地先乐观插一条,别等转录落盘那一秒的空窗
        messages.append(Message(id: "local-\(UUID().uuidString)", role: "user", text: trimmed,
                                thinking: false, tools: [], time: Date().timeIntervalSince1970))
    }

    private func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func receive(_ socket: URLSessionWebSocketTask, gen: Int) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                if case .success(let message) = result {
                    if case .string(let text) = message { self.handle(text) }
                    self.receive(socket, gen: gen)
                } else {
                    self.connected = false
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "chatList":
            if let raw = obj["sessions"],
               let payload = try? JSONSerialization.data(withJSONObject: raw),
               let list = try? JSONDecoder().decode([SessionInfo].self, from: payload) {
                sessions = list
            }
            if let raw = obj["spaces"],
               let payload = try? JSONSerialization.data(withJSONObject: raw),
               let list = try? JSONDecoder().decode([SpaceInfo].self, from: payload) {
                spaces = list
            }
            if let raw = obj["projects"],
               let payload = try? JSONSerialization.data(withJSONObject: raw),
               let list = try? JSONDecoder().decode([ProjectInfo].self, from: payload) {
                projects = list
            }
            if let raw = obj["agents"],
               let payload = try? JSONSerialization.data(withJSONObject: raw),
               let list = try? JSONDecoder().decode([AgentOption].self, from: payload) {
                agents = list
            }
        case "chatLaunched":
            launching = false
            guard let id = (obj["id"] as? String).flatMap(UUID.init) else { return }
            // 转录还没落盘,先造一条乐观的会话信息把页面推进去
            launched = SessionInfo(id: id, title: obj["title"] as? String ?? "新会话",
                                   cwd: nil, agent: "", lastActivity: Date().timeIntervalSince1970,
                                   attention: nil, canSend: true, space: nil, spaceID: nil)
            refresh()
        case "chatError":
            launching = false
            lastError = obj["message"] as? String
        case "chatMessages":
            unavailable = obj["unavailable"] as? Bool ?? false
            if unavailable, let id = attachedID, Date().timeIntervalSince(attachedAt) < 90 {
                // 刚唤起的会话:agent 还没写出转录,过两秒再试
                retry?.cancel()
                retrying = true
                retry = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self, self.attachedID == id else { return }
                    self.send(["type": "chatAttach", "id": id.uuidString, "limit": 200])
                }
            } else {
                retrying = false
            }
            guard let raw = obj["messages"],
                  let payload = try? JSONSerialization.data(withJSONObject: raw),
                  let batch = try? JSONDecoder().decode([Message].self, from: payload) else { return }
            loading = false
            if obj["history"] as? Bool == true {
                messages = batch
            } else {
                // 乐观插入的本地消息在真消息到达后清掉,避免重复
                messages.removeAll { $0.id.hasPrefix("local-") }
                messages.append(contentsOf: batch)
            }
        default:
            break
        }
    }
}
