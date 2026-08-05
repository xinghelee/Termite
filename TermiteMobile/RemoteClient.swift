import Foundation
import Observation

/// 会话摘要(与 Mac 端 RemoteSessionInfo 的 JSON 对应)
struct RemoteSessionSummary: Decodable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let cwd: String?
    let shell: String
    let alive: Bool
    let running: Bool
    let attention: String?
    let cols: Int
    let rows: Int
}

/// Mac 端 WebSocket 协议客户端。
/// 文本帧 = JSON 控制(list/attach/detach/resize/exited/error),二进制帧 = 终端字节流。
/// 断线指数退避重连;重连时若附着着会话则自动重附(服务端回放镜像,画面无缝接上)。
@MainActor
@Observable
final class RemoteClient {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        /// token 被拒(重新生成过/链接失效),不再自动重试
        case denied
    }

    private(set) var phase = Phase.idle
    private(set) var sessions: [RemoteSessionSummary] = []
    /// 当前附着会话的 PTY 网格(Mac 端拥有尺寸,这边只跟随)
    private(set) var gridCols = 80
    private(set) var gridRows = 24
    private(set) var attachedID: UUID?

    /// 附着确认(含重连重附):先重置终端,随后镜像回放帧到达
    var onAttached: (() -> Void)?
    /// 终端输出字节流
    var onOutput: ((Data) -> Void)?
    /// 会话结束/出错,附提示文案
    var onSessionEnded: ((String) -> Void)?

    private var endpoint: Endpoint?
    private var task: URLSessionWebSocketTask?
    /// 连接代际:旧连接的回调凭它作废,避免重连竞态串台
    private var generation = 0
    private var retryDelay: TimeInterval = 0.5
    private var retryTask: Task<Void, Never>?

    // MARK: - 生命周期

    func configure(_ endpoint: Endpoint) {
        self.endpoint = endpoint
        reconnectNow()
    }

    func shutdown() {
        generation += 1
        retryTask?.cancel()
        retryTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        phase = .idle
        attachedID = nil
        sessions = []
    }

    func reconnectNow() {
        guard let endpoint, let url = endpoint.wsURL else { return }
        retryTask?.cancel()
        retryTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        generation += 1
        let gen = generation
        phase = .connecting
        let socket = URLSession.shared.webSocketTask(with: url)
        task = socket
        socket.resume()
        receiveLoop(socket, gen: gen)
        // 首帧 hello 到达才算连上;这里先把待发请求排上
        if let attachedID {
            sendControl(["type": "attach", "id": attachedID.uuidString])
        } else {
            requestList()
        }
    }

    // MARK: - 请求

    func requestList() {
        sendControl(["type": "list"])
    }

    func attach(_ id: UUID) {
        attachedID = id
        sendControl(["type": "attach", "id": id.uuidString])
    }

    func detach() {
        guard attachedID != nil else { return }
        attachedID = nil
        sendControl(["type": "detach"])
    }

    func sendInput(_ text: String) {
        sendInput(Data(text.utf8))
    }

    func sendInput(_ data: Data) {
        guard attachedID != nil else { return }
        task?.send(.data(data)) { _ in }
    }

    private func sendControl(_ dict: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    // MARK: - 接收

    private func receiveLoop(_ socket: URLSessionWebSocketTask, gen: Int) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receiveLoop(socket, gen: gen)
                case .failure:
                    self.connectionDropped(socket)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            onOutput?(data)
        case .string(let text):
            guard let msg = try? JSONDecoder().decode(ServerMsg.self, from: Data(text.utf8)) else { return }
            handleControl(msg)
        @unknown default:
            break
        }
    }

    private struct ServerMsg: Decodable {
        let type: String
        let sessions: [RemoteSessionSummary]?
        let id: UUID?
        let cols: Int?
        let rows: Int?
        let message: String?
    }

    private func handleControl(_ msg: ServerMsg) {
        switch msg.type {
        case "hello":
            phase = .connected
            retryDelay = 0.5
        case "list":
            sessions = msg.sessions ?? []
        case "attached":
            gridCols = msg.cols ?? 80
            gridRows = msg.rows ?? 24
            onAttached?()
        case "resize":
            gridCols = msg.cols ?? gridCols
            gridRows = msg.rows ?? gridRows
        case "exited":
            attachedID = nil
            onSessionEnded?(String(localized: "会话已结束"))
        case "error":
            attachedID = nil
            onSessionEnded?(msg.message ?? String(localized: "会话不存在或已关闭"))
        default:
            break
        }
    }

    // MARK: - 重连

    private func connectionDropped(_ socket: URLSessionWebSocketTask) {
        // 403 = token 不认(重新生成过):停止重试,引导重新配对
        if let response = socket.response as? HTTPURLResponse, response.statusCode == 403 {
            phase = .denied
            return
        }
        phase = .connecting
        let delay = retryDelay
        retryDelay = min(retryDelay * 1.7, 8)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reconnectNow()
        }
    }
}
