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
    private(set) var messages: [Message] = []
    private(set) var attachedID: UUID?
    private(set) var connected = false
    /// 这个会话没有可读的转录 —— 客户端据此提示「去终端看」
    private(set) var unavailable = false

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
        messages = []
        unavailable = false
        send(["type": "chatAttach", "id": id.uuidString, "limit": 200])
    }

    func detach() {
        guard attachedID != nil else { return }
        attachedID = nil
        messages = []
        send(["type": "chatDetach"])
    }

    /// 发消息 = Mac 端把文字注入回那个 pane 的 PTY,agent 自己会读到
    func send(text: String) {
        guard let id = attachedID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
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
        case "chatMessages":
            unavailable = obj["unavailable"] as? Bool ?? false
            guard let raw = obj["messages"],
                  let payload = try? JSONSerialization.data(withJSONObject: raw),
                  let batch = try? JSONDecoder().decode([Message].self, from: payload) else { return }
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
