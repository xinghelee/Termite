import Foundation
import SwiftTerm

/// 发给 Web 客户端的会话摘要(JSON)
struct RemoteSessionInfo: Codable {
    var id: UUID
    var title: String
    var cwd: String?
    var shell: String
    var alive: Bool
    var running: Bool
    /// 等待输入 / 命令刚跑完的注意力状态("input" / "finished" / nil)
    var attention: String?
    var cols: Int
    var rows: Int
}

/// 远程访问的会话中枢:输出镜像 + 订阅分发 + 输入注入。
/// Web 端是 Mac 的「镜像显示器」:PTY 尺寸由 Mac 端拥有,远端只跟随渲染。
/// 全部在 MainActor 上——processOutput / sendRawInput 本就活在主线程,
/// 网络层经 DispatchQueue.main 串行入主线程,保证键入顺序。
@MainActor
final class RemoteSessionHub {
    static let shared = RemoteSessionHub()

    /// 每会话镜像缓冲:新连接 attach 时回放,让远端立刻看到当前画面
    private static let ringCapacity = 512 * 1024

    /// 服务开着才镜像;关闭时 processOutput 里的 tee 一次布尔判断就返回
    private(set) var active = false

    private var rings: [UUID: OutputRing] = [:]
    /// connID → (会话, 推送闭包);推送闭包内部负责跳回连接自己的队列
    private var sinks: [UUID: (sessionID: UUID, push: (Data) -> Void)] = [:]

    func start() {
        active = true
    }

    func stop() {
        active = false
        rings = [:]
        sinks = [:]
    }

    // MARK: - 输出镜像(TerminalSession.processOutput 尾挂)

    func mirror(sessionID: UUID, bytes: ArraySlice<UInt8>) {
        guard active else { return }
        let data = Data(bytes)
        // subscript(_:default:) 走 _modify 就地追加,不复制整个缓冲
        rings[sessionID, default: OutputRing(capacity: Self.ringCapacity)].append(data)
        for (_, sink) in sinks where sink.sessionID == sessionID {
            sink.push(data)
        }
    }

    // MARK: - Web 连接侧

    struct AttachResult {
        var backlog: Data
        /// 镜像缓冲为空(服务刚开/会话早于镜像)时,用屏幕文本快照垫底
        var snapshot: String?
        var cols: Int
        var rows: Int
    }

    /// attach 即订阅:先回放已有镜像,再实时跟流。会话不存在返回 nil。
    func attach(connID: UUID, sessionID: UUID, push: @escaping (Data) -> Void) -> AttachResult? {
        guard active, let session = findSession(sessionID) else { return nil }
        let backlog = rings[sessionID]?.read(from: 0).data ?? Data()
        let snapshot = backlog.isEmpty ? session.scrollbackSnapshot(maxLines: 500) : nil
        sinks[connID] = (sessionID, push)
        let terminal = session.terminalView.getTerminal()
        return AttachResult(backlog: backlog, snapshot: snapshot,
                            cols: terminal.cols, rows: terminal.rows)
    }

    func detach(connID: UUID) {
        sinks[connID] = nil
    }

    func sendInput(sessionID: UUID, bytes: [UInt8]) {
        guard active, !bytes.isEmpty else { return }
        findSession(sessionID)?.sendRawInput(bytes)
    }

    /// 连接层轮询用:尺寸跟随 + 死亡检测(会话被关/退出返回 nil)
    func status(sessionID: UUID) -> (cols: Int, rows: Int, alive: Bool)? {
        guard let session = findSession(sessionID) else { return nil }
        let terminal = session.terminalView.getTerminal()
        let alive = if case .running = session.state { true } else { false }
        return (terminal.cols, terminal.rows, alive)
    }

    func list() -> [RemoteSessionInfo] {
        SessionManagerRegistry.shared.allSessions.map { session in
            let terminal = session.terminalView.getTerminal()
            let alive = if case .running = session.state { true } else { false }
            let attention: String? = switch session.attention {
            case .none: nil
            case .needsInput: "input"
            case .finished: "finished"
            }
            return RemoteSessionInfo(
                id: session.id,
                title: session.displayTitle,
                cwd: session.workingDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath },
                shell: session.shellName,
                alive: alive,
                running: session.runningCommand,
                attention: attention,
                cols: terminal.cols,
                rows: terminal.rows
            )
        }
    }

    private func findSession(_ id: UUID) -> TerminalSession? {
        SessionManagerRegistry.shared.allSessions.first { $0.id == id }
    }
}
