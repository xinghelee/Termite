import Foundation
import Network
import Observation
import UIKit

/// 会话摘要(与 Mac 端 RemoteSessionInfo 的 JSON 对应;分组字段为增量,老服务端缺省容错)
struct RemoteSessionSummary: Decodable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let cwd: String?
    let shell: String
    let alive: Bool
    let running: Bool
    let attention: String?
    /// 进入注意力态多少秒(「已等待 X 分钟」)
    let attentionSeconds: Int?
    let cols: Int
    let rows: Int
    /// 侧边栏语义:项目分组 + 工作空间筛选(对齐 Mac)
    let project: String?
    let projectPath: String?
    let projectColor: String?
    let space: String?
    let spaceID: UUID?
    let window: Int?
    /// 正在接管这个会话的设备名(列表里标一笔「谁在操作」);nil = Mac 自己
    let controller: String?
}

struct RemoteSidebarSpaceSummary: Decodable, Identifiable, Hashable {
    let id: UUID
    let name: String
}

struct RemoteSidebarProjectSummary: Decodable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let path: String
    let accent: String?
    let spaceID: UUID?
}

/// Mac 上转发出来的本机服务(模拟器调试 console、dev server 之类)
struct RemoteForwardSummary: Decodable, Identifiable, Hashable {
    let id: UUID
    let label: String
    let target: Int
    let port: Int
}

/// 会话控制权(Mac 随 attached / viewport 下发;旧服务端不发,按「自由」处理)
struct RemoteControlPayload: Decodable, Equatable {
    var mine: Bool
    var locked: Bool
    var controller: String?
    /// Mac 持有时为 true(可以直接接管);别的远端持有时为 false(不许抢)
    var claimable: Bool?

    static let free = RemoteControlPayload(mine: false, locked: false, controller: nil,
                                           claimable: nil)
}

/// Mac 主题色板(list / attached 下发,远端同款观感)
struct RemoteThemePayload: Decodable, Equatable {
    let background: String
    let foreground: String
    let cursor: String
    let selection: String
    let accent: String
    let isDark: Bool
    let ansi: [String]
}

/// Mac 端 WebSocket 协议客户端。
/// 文本帧 = JSON 控制(list/attach/viewport/exited/error),二进制帧 = 终端字节流。
/// 断线指数退避重连 + 网络路径变化立即重试;重连时自动重附,服务端回放镜像无缝接上。
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
    private(set) var sidebarSpaces: [RemoteSidebarSpaceSummary] = []
    private(set) var sidebarProjects: [RemoteSidebarProjectSummary] = []
    /// Mac 转发出来的本机服务(手机端「本机服务」入口)
    private(set) var forwards: [RemoteForwardSummary] = []
    /// 普通 shell 时为 Mac 网格；TUI 时为进入瞬间冻结的 canonical grid。
    private(set) var gridCols = 80
    private(set) var gridRows = 24
    private(set) var attachedID: UUID?
    /// TUI 共用固定语义网格；所有设备都可以输入，但都不能修改它的列行数。
    private(set) var tuiMode = false
    /// 控制权:mine = PTY 网格归本机(接管中);locked = 被别的设备接管,本机只读
    private(set) var control = RemoteControlPayload.free
    /// Mac 当前主题(attached 到达时更新)
    private(set) var theme: RemoteThemePayload?

    /// 附着确认(含重连重附):先重置终端,随后镜像回放帧到达
    var onAttached: (() -> Void)?
    /// 终端输出字节流
    var onOutput: ((Data) -> Void)?
    /// 会话结束/出错,附提示文案
    var onSessionEnded: ((String) -> Void)?
    /// Mac 本地视口变化；只更新主动选择镜像模式的本地视图。
    var onViewportChange: (() -> Void)?
    var onProjectOpened: ((RemoteSessionSummary) -> Void)?
    var onProjectOpenFailed: ((String) -> Void)?

    private var endpoint: Endpoint?
    private var task: URLSessionWebSocketTask?
    /// 连接代际:旧连接的回调凭它作废,避免重连竞态串台
    private var generation = 0
    private var retryDelay: TimeInterval = 0.5
    private var retryTask: Task<Void, Never>?
    private var attachRetryTask: Task<Void, Never>?
    private var attachRetryCount = 0
    private var pathMonitor: NWPathMonitor?

    // MARK: - 生命周期

    func configure(_ endpoint: Endpoint) {
        self.endpoint = endpoint
        startPathMonitor()
        reconnectNow()
    }

    func shutdown() {
        generation += 1
        retryTask?.cancel()
        retryTask = nil
        attachRetryTask?.cancel()
        attachRetryTask = nil
        attachRetryCount = 0
        pathMonitor?.cancel()
        pathMonitor = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        phase = .idle
        attachedID = nil
        tuiMode = false
        control = .free
        sessions = []
        sidebarSpaces = []
        sidebarProjects = []
        forwards = []
        theme = nil
    }

    /// 回前台 / 网络恢复时调用:没连上就立刻重试(跳过退避等待)
    func kickReconnect() {
        guard endpoint != nil, phase != .connected, phase != .denied else { return }
        reconnectNow()
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

    /// Wi-Fi ↔ 蜂窝 ↔ 网线切换即触发重连,不等退避计时器
    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.kickReconnect() }
        }
        monitor.start(queue: .main)
    }

    // MARK: - 请求

    func requestList() {
        sendControl(["type": "list"])
    }

    func openProject(_ id: UUID) {
        sendControl(["type": "openProject", "id": id.uuidString])
    }

    func attach(_ id: UUID) {
        attachRetryTask?.cancel()
        attachRetryTask = nil
        attachRetryCount = 0
        attachedID = id
        sendControl(["type": "attach", "id": id.uuidString])
    }

    func detach() {
        guard attachedID != nil else { return }
        attachRetryTask?.cancel()
        attachRetryTask = nil
        attachRetryCount = 0
        attachedID = nil
        sendControl(["type": "detach"])
        tuiMode = false
        control = .free
    }

    /// 接管:把本机网格声明成共享 PTY 网格,Mac 与其它设备转只读遮挡。
    /// 被别的设备占着会被拒(远端之间不互相踢),服务端回执当前控制权。
    func claimControl(cols: Int, rows: Int) {
        guard let id = attachedID else { return }
        sendControl(["type": "claim", "id": id.uuidString, "cols": cols, "rows": rows,
                     "device": UIDevice.current.name])
    }

    func releaseControl() {
        guard let id = attachedID else { return }
        sendControl(["type": "release", "id": id.uuidString])
    }

    func sendInput(_ text: String) {
        sendInput(Data(text.utf8))
    }

    func sendInput(_ data: Data) {
        guard attachedID != nil, let task else { return }
        task.send(.data(data)) { _ in }
    }

    private func sendControl(_ dict: [String: Any]) {
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
        let session: RemoteSessionSummary?
        let spaces: [RemoteSidebarSpaceSummary]?
        let projects: [RemoteSidebarProjectSummary]?
        let id: UUID?
        let cols: Int?
        let rows: Int?
        let tuiMode: Bool?
        let message: String?
        let theme: RemoteThemePayload?
        let control: RemoteControlPayload?
        let forwards: [RemoteForwardSummary]?
    }

    private func handleControl(_ msg: ServerMsg) {
        switch msg.type {
        case "hello":
            phase = .connected
            retryDelay = 0.5
        case "list":
            sessions = msg.sessions ?? []
            if let spaces = msg.spaces { sidebarSpaces = spaces }
            if let projects = msg.projects { sidebarProjects = projects }
            if let forwards = msg.forwards { self.forwards = forwards }
            if let theme = msg.theme { self.theme = theme }
        case "projectOpened":
            guard let session = msg.session else { return }
            if let index = sessions.firstIndex(where: { $0.id == session.id }) {
                sessions[index] = session
            } else {
                sessions.append(session)
            }
            onProjectOpened?(session)
        case "projectOpenFailed":
            onProjectOpenFailed?(msg.message ?? String(localized: "无法启动项目"))
        case "attached":
            attachRetryTask?.cancel()
            attachRetryTask = nil
            attachRetryCount = 0
            gridCols = msg.cols ?? 80
            gridRows = msg.rows ?? 24
            tuiMode = msg.tuiMode ?? false
            // 旧服务端不下发 control:按「无人接管」处理,行为退回从前
            control = msg.control ?? .free
            if let theme = msg.theme { self.theme = theme }
            onAttached?()
        case "viewport", "resize":
            gridCols = msg.cols ?? gridCols
            gridRows = msg.rows ?? gridRows
            tuiMode = msg.tuiMode ?? false
            control = msg.control ?? .free
            onViewportChange?()
        case "exited":
            attachedID = nil
            tuiMode = false
            control = .free
            onSessionEnded?(String(localized: "会话已结束"))
        case "error":
            if retryAttachAfterStartupRace() { return }
            attachedID = nil
            tuiMode = false
            control = .free
            onSessionEnded?(msg.message ?? String(localized: "会话不存在或已关闭"))
        default:
            break
        }
    }

    /// Mac 冷启动时 WebSocket 可能先于会话目录恢复完成；短暂重试，真实关闭仍会正常报错。
    private func retryAttachAfterStartupRace() -> Bool {
        guard let sessionID = attachedID, attachRetryCount < 5 else { return false }
        attachRetryCount += 1
        attachRetryTask?.cancel()
        let delay = attachRetryCount * 300
        attachRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled, let self,
                  self.attachedID == sessionID, self.phase == .connected else { return }
            self.sendControl(["type": "attach", "id": sessionID.uuidString])
        }
        return true
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
