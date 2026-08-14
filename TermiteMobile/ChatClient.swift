import Foundation
import Observation

/// 应答模式的客户端:单开一条 WS 专收转录和「它在等什么」。
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
        /// 已经等了多久。列表上「等了 12 分钟」比「在等」有用得多
        let attentionSeconds: Int?
        /// 它在问什么(Mac 从画面提炼的一句)。有这句才谈得上不点进去就知道该不该管
        let question: String?
        /// 绑定的 pane 是否真在跑 agent;false 时输入框禁用
        let canSend: Bool?
        let project: String?
        let projectColor: String?
        let space: String?
        let spaceID: UUID?

        var isWaiting: Bool { attention == "input" }
    }

    /// 「它在等什么」:Mac 直接读 pane 当前画面的结果。
    /// 权限确认框只活在画面上,转录里查无此事 —— 应答界面的问题原文只能从这儿来
    struct Prompt: Decodable, Equatable {
        struct Option: Decodable, Equatable, Identifiable, Hashable {
            /// 要按的那个键
            let id: String
            let label: String
            /// agent 的光标正指着它
            let selected: Bool
        }
        let id: UUID
        /// 画面原文(已剥掉方框线)。提炼不出选项时,它就是界面的全部
        let screen: String
        let question: String?
        let options: [Option]
        let attention: String?
        let attentionSeconds: Int?
        let canSend: Bool

        var isWaiting: Bool { attention == "input" }
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
    /// 当前附着会话在等什么。应答界面每两秒问一次,按完键立刻会收到新的一份
    private(set) var prompt: Prompt?
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

    /// 正在等你回复的会话。角标、通知、列表置顶都读这一份
    var waiting: [SessionInfo] {
        sessions.filter(\.isWaiting)
    }

    func attach(_ id: UUID) {
        attachedID = id
        attachedAt = Date()
        retry?.cancel()
        retrying = false
        messages = []
        prompt = nil
        unavailable = false
        loading = true
        guard task != nil else { pendingAttach = id; return }
        pendingAttach = nil
        send(["type": "chatAttach", "id": id.uuidString, "limit": 200])
        requestPrompt()
    }

    /// 问一次「它在等什么」。应答界面开着就每两秒问一次 ——
    /// 不依赖 chatList 那三秒一轮的节奏,按下选项后的反馈才跟得上手
    func requestPrompt() {
        guard let id = attachedID else { return }
        send(["type": "chatPrompt", "id": id.uuidString])
    }

    /// 按下一个选项。Mac 那边过同一道闸门(pane 底下没挂 agent 就不注入),
    /// 按完会立刻回一份新画面
    func sendKey(_ key: String) {
        guard let id = attachedID else { return }
        lastError = nil
        send(["type": "chatKey", "id": id.uuidString, "key": key])
    }

    /// 唤起:Mac 在项目目录开一个新 pane 并敲下命令。
    /// agent 要几秒才写出第一份转录,所以推进页面后还会自动重试附着
    func launch(project: UUID, agent: AgentOption) {
        guard !launching else { return }
        launching = true
        lastError = nil
        send(["type": "chatLaunch", "project": project.uuidString, "agent": agent.command])
    }

    /// 按目录唤起:对话页看到「agent 没在运行」时就地重开一个,
    /// 目录不一定是注册过的项目,所以不走 projectID
    func launch(cwd: String, agent: AgentOption) {
        guard !launching else { return }
        launching = true
        lastError = nil
        send(["type": "chatLaunch", "cwd": cwd, "agent": agent.command])
    }

    func consumeLaunched() { launched = nil }

    /// 传 id 就只在「离开的正是当前附着的那个」时才断。
    /// 唤起后会把栈顶换成新会话,SwiftUI 有可能先 onAppear 新页再 onDisappear 旧页 ——
    /// 不带这道守卫,旧页的退出会把新页刚建立的订阅拆掉,表现是「点进去一片空白」
    func detach(_ id: UUID? = nil) {
        if let id, attachedID != id { return }
        guard attachedID != nil else { return }
        attachedID = nil
        pendingAttach = nil
        retry?.cancel()
        retrying = false
        loading = false
        messages = []
        prompt = nil
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
                                   attention: nil, attentionSeconds: nil, question: nil,
                                   canSend: true, project: nil, projectColor: nil,
                                   space: nil, spaceID: nil)
            refresh()
        case "chatPrompt":
            guard let raw = obj["prompt"],
                  let payload = try? JSONSerialization.data(withJSONObject: raw),
                  let value = try? JSONDecoder().decode(Prompt.self, from: payload) else { return }
            // 迟到的回包可能属于上一个会话,别让它盖住当前这个
            guard value.id == attachedID else { return }
            prompt = value
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
