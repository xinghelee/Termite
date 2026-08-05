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
    /// 侧边栏语义(远端按项目分组、按工作空间筛选,对齐 Mac 侧边栏)
    var project: String?
    var projectPath: String?
    /// 项目强调色 hex;nil = 跟随主题
    var projectColor: String?
    var space: String?
    /// 多窗口区分(0 起)
    var window: Int
}

/// attached 下发的主题色板:远端终端与 Mac 观感一致
struct RemoteTheme: Codable {
    var background: String
    var foreground: String
    var cursor: String
    var selection: String
    var accent: String
    var isDark: Bool
    var ansi: [String]

    @MainActor
    static func current() -> RemoteTheme {
        let theme = ThemeStore.shared.current
        return RemoteTheme(background: theme.background, foreground: theme.foreground,
                           cursor: theme.cursor, selection: theme.selection,
                           accent: theme.accent, isDark: theme.isDark, ansi: theme.ansi)
    }
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
        if let sessionID = sinks[connID]?.sessionID {
            restoreSizeIfOverridden(sessionID: sessionID)
        }
        sinks[connID] = nil
    }

    func sendInput(sessionID: UUID, bytes: [UInt8]) {
        guard active, !bytes.isEmpty else { return }
        findSession(sessionID)?.sendRawInput(bytes)
    }

    /// 「适配手机宽度」:远端临时接管 PTY 尺寸(tmux 语义——谁在看谁说了算)。
    /// 只打标记不存旧值:恢复时以 Mac 视图**当前**网格为准(期间 Mac 可能已 resize,
    /// hostResize 只动 PTY 不动 Mac 视图模型,视图网格永远是 Mac 侧的真相)。
    /// Mac 端任何一次自己的 resize 都会经视图层夺回主导权,无需协调。
    private var overriddenSessions = Set<UUID>()

    func overrideSize(connID: UUID, sessionID: UUID, cols: Int, rows: Int) {
        guard active, sinks[connID]?.sessionID == sessionID,
              let session = findSession(sessionID),
              (10...500).contains(cols), (4...200).contains(rows) else { return }
        overriddenSessions.insert(sessionID)
        session.hostResize(cols: cols, rows: rows)
    }

    /// 解附时把 PTY 网格还给 Mac 视图(没被接管过则无事)
    func restoreSizeIfOverridden(sessionID: UUID) {
        guard overriddenSessions.remove(sessionID) != nil,
              let session = findSession(sessionID) else { return }
        let terminal = session.terminalView.getTerminal()
        session.hostResize(cols: terminal.cols, rows: terminal.rows)
    }

    /// 连接层轮询用:尺寸跟随 + 死亡检测(会话被关/退出返回 nil)
    func status(sessionID: UUID) -> (cols: Int, rows: Int, alive: Bool)? {
        guard let session = findSession(sessionID) else { return nil }
        let terminal = session.terminalView.getTerminal()
        let alive = if case .running = session.state { true } else { false }
        return (terminal.cols, terminal.rows, alive)
    }

    /// 按「窗口 → 标签 → 分屏」的侧边栏顺序走一遍,带上项目/工作空间归属。
    /// 不在任何标签里的会话(理论不存在)补在末尾,宁多勿漏
    func list() -> [RemoteSessionInfo] {
        var result: [RemoteSessionInfo] = []
        var listed = Set<UUID>()
        for (windowIndex, manager) in SessionManagerRegistry.shared.managers.enumerated() {
            for tab in manager.tabs {
                let projectPath = manager.projectGroup(of: tab)
                let project = projectPath.flatMap { path in
                    ProjectStore.shared.projects.first { $0.path == path }
                }
                let space = manager.spaceID(of: tab).flatMap { id in
                    SpaceStore.shared.spaces.first { $0.id == id }
                }
                for sessionID in tab.root.leafIDs() {
                    guard let session = manager.session(sessionID) else { continue }
                    listed.insert(sessionID)
                    result.append(info(session, project: project, projectPath: projectPath,
                                       space: space?.name, window: windowIndex))
                }
            }
        }
        for session in SessionManagerRegistry.shared.allSessions where !listed.contains(session.id) {
            result.append(info(session, project: nil, projectPath: nil, space: nil, window: 0))
        }
        return result
    }

    private func info(_ session: TerminalSession, project: Project?, projectPath: String?,
                      space: String?, window: Int) -> RemoteSessionInfo {
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
            rows: terminal.rows,
            project: project?.name ?? projectPath.map { ($0 as NSString).lastPathComponent },
            projectPath: projectPath,
            projectColor: project?.accentHex,
            space: space,
            window: window
        )
    }

    private func findSession(_ id: UUID) -> TerminalSession? {
        SessionManagerRegistry.shared.allSessions.first { $0.id == id }
    }
}
