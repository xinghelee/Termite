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
    /// 进入注意力态多少秒(远端显示「已等待 X 分钟」)
    var attentionSeconds: Int?
    var cols: Int
    var rows: Int
    /// 侧边栏语义(远端按项目分组、按工作空间筛选,对齐 Mac 侧边栏)
    var project: String?
    var projectPath: String?
    /// 项目强调色 hex;nil = 跟随主题
    var projectColor: String?
    var space: String?
    /// 稳定的工作区标识；名称仅用于展示，不能用于区分重名工作区。
    var spaceID: UUID?
    /// 多窗口区分(0 起)
    var window: Int
}

/// 完整侧边栏目录独立于会话下发，空项目/空工作区也不会在移动端消失。
struct RemoteSidebarSpaceInfo: Codable {
    var id: UUID
    var name: String
}

struct RemoteSidebarProjectInfo: Codable {
    var id: UUID
    var name: String
    var path: String
    var accent: String?
    /// 已按 SpaceStore 的回落规则解析后的实际归属。
    var spaceID: UUID?
}

/// list / attached 下发的主题色板:远端列表与终端都和 Mac 观感一致
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
/// 普通 shell 的 PTY 网格属于 Mac，远端各自在自己的网格中渲染；进入 TUI 后冻结
/// 唯一 PTY 网格，所有设备只在本地缩放这块画布，输入、旋转和窗口变化都不再修改它。
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

    private struct Grid: Equatable {
        var cols: Int
        var rows: Int
    }

    private struct TUIState {
        var grid: Grid
    }

    private struct Sink {
        var sessionID: UUID
        var pushOutput: (Data) -> Void
        var pushViewport: (_ cols: Int, _ rows: Int, _ tuiMode: Bool) -> Void
    }

    /// connID → 输出/视口推送。所有回调内部负责跳回连接自己的发送队列。
    private var sinks: [UUID: Sink] = [:]
    /// Mac 视图的自然网格。TUI 期间仅用于退出后的恢复，不参与共享网格更新。
    private var macGrids: [UUID: Grid] = [:]
    private var tuiStates: [UUID: TUIState] = [:]

    func start() {
        active = true
    }

    func stop() {
        for sessionID in tuiStates.keys {
            guard let session = findSession(sessionID) else { continue }
            session.setSharedTUIRenderGrid(nil)
            let local = session.terminalView.localViewportGrid
            session.resizePTY(cols: local.cols, rows: local.rows)
        }
        active = false
        rings = [:]
        sinks = [:]
        macGrids = [:]
        tuiStates = [:]
    }

    // MARK: - 输出镜像(TerminalSession.processOutput 尾挂)

    func mirror(sessionID: UUID, bytes: ArraySlice<UInt8>) {
        guard active else { return }
        let data = Data(bytes)
        // subscript(_:default:) 走 _modify 就地追加,不复制整个缓冲
        rings[sessionID, default: OutputRing(capacity: Self.ringCapacity)].append(data)
        for sink in sinks.values where sink.sessionID == sessionID {
            sink.pushOutput(data)
        }
    }

    // MARK: - Web 连接侧

    struct AttachResult {
        var backlog: Data
        /// 镜像缓冲为空(服务刚开/会话早于镜像)时,用屏幕文本快照垫底
        var snapshot: String?
        var cols: Int
        var rows: Int
        var tuiMode: Bool
        /// 从 Mac 当前 Terminal 模型生成的完整 ANSI 画面，不依赖最后一帧是否全量绘制。
        var screenSnapshot: Data?
    }

    /// attach 即订阅:先回放已有镜像,再实时跟流。会话不存在返回 nil。
    func attach(
        connID: UUID,
        sessionID: UUID,
        pushOutput: @escaping (Data) -> Void,
        pushViewport: @escaping (_ cols: Int, _ rows: Int, _ tuiMode: Bool) -> Void
    ) -> AttachResult? {
        guard active, let session = findSession(sessionID) else { return nil }
        let backlog = rings[sessionID]?.read(from: 0).data ?? Data()
        let snapshot = backlog.isEmpty ? session.scrollbackSnapshot(maxLines: 500) : nil
        let localGrid = session.terminalView.localViewportGrid
        let macGrid = Grid(cols: localGrid.cols, rows: localGrid.rows)
        if tuiStates[sessionID] == nil { macGrids[sessionID] = macGrid }
        observeTerminalMode(sessionID: sessionID, isTUI: session.requiresSharedTUILayout)
        sinks[connID] = Sink(sessionID: sessionID, pushOutput: pushOutput,
                             pushViewport: pushViewport)
        let state = tuiStates[sessionID]
        let grid = state?.grid ?? macGrid
        return AttachResult(backlog: backlog, snapshot: snapshot,
                            cols: grid.cols, rows: grid.rows,
                            tuiMode: state != nil,
                            screenSnapshot: state == nil ? nil : session.terminalScreenSnapshot())
    }

    func detach(connID: UUID) {
        guard let sink = sinks.removeValue(forKey: connID) else { return }
        if !sinks.values.contains(where: { $0.sessionID == sink.sessionID }) {
            // TUI 状态仍要保留到进程退出 TUI，断开观察端不能改变 PTY。
            if tuiStates[sink.sessionID] == nil { macGrids[sink.sessionID] = nil }
        }
    }

    func sendInput(connID: UUID, sessionID: UUID, bytes: [UInt8]) {
        guard active, !bytes.isEmpty,
              sinks[connID]?.sessionID == sessionID else { return }
        findSession(sessionID)?.sendRawInput(bytes)
    }

    /// Mac 自然布局变化。普通 shell 同步 PTY；TUI 期间仅改变本地呈现。
    func macViewportChanged(session: TerminalSession, cols: Int, rows: Int) {
        let sessionID = session.id
        let grid = Grid(cols: max(cols, 1), rows: max(rows, 1))
        if active, tuiStates[sessionID] != nil { return }
        let changed = macGrids[sessionID] != grid
        macGrids[sessionID] = grid
        guard active else {
            session.resizePTY(cols: grid.cols, rows: grid.rows)
            return
        }
        session.resizePTY(cols: grid.cols, rows: grid.rows)
        if changed { broadcastViewport(sessionID: sessionID) }
    }

    /// TerminalSession 每批输出解析后报告真实备用屏状态，状态变更才产生动作。
    func observeTerminalMode(sessionID: UUID, isTUI: Bool) {
        guard active, let session = findSession(sessionID) else { return }
        if isTUI {
            guard tuiStates[sessionID] == nil else { return }
            let localGrid = session.terminalView.localViewportGrid
            let macGrid = macGrids[sessionID] ?? Grid(cols: localGrid.cols, rows: localGrid.rows)
            macGrids[sessionID] = macGrid
            let state = TUIState(grid: macGrid)
            tuiStates[sessionID] = state
            applyTUIState(sessionID: sessionID, state: state)
            broadcastViewport(sessionID: sessionID)
        } else {
            guard tuiStates.removeValue(forKey: sessionID) != nil else { return }
            session.setSharedTUIRenderGrid(nil)
            let local = session.terminalView.localViewportGrid
            let macGrid = Grid(cols: local.cols, rows: local.rows)
            macGrids[sessionID] = macGrid
            session.resizePTY(cols: macGrid.cols, rows: macGrid.rows)
            broadcastViewport(sessionID: sessionID)
            if !sinks.values.contains(where: { $0.sessionID == sessionID }) {
                macGrids[sessionID] = nil
            }
        }
    }

    /// 每秒校验 Mac 自然网格、备用屏状态和进程存活，补足非输出时的布局变化。
    func refreshStatus(sessionID: UUID) -> Bool? {
        guard let session = findSession(sessionID) else { return nil }
        if tuiStates[sessionID] == nil {
            let localGrid = session.terminalView.localViewportGrid
            let currentMacGrid = Grid(cols: localGrid.cols, rows: localGrid.rows)
            if macGrids[sessionID] != currentMacGrid {
                macViewportChanged(session: session, cols: currentMacGrid.cols, rows: currentMacGrid.rows)
            }
        }
        observeTerminalMode(sessionID: sessionID, isTUI: session.requiresSharedTUILayout)
        let alive = if case .running = session.state { true } else { false }
        return alive
    }

    private func canonicalGrid(sessionID: UUID) -> Grid? {
        if let state = tuiStates[sessionID] { return state.grid }
        if let grid = macGrids[sessionID] { return grid }
        guard let session = findSession(sessionID) else { return nil }
        let grid = session.terminalView.localViewportGrid
        return Grid(cols: grid.cols, rows: grid.rows)
    }

    private func broadcastViewport(sessionID: UUID) {
        let state = tuiStates[sessionID]
        for sink in sinks.values where sink.sessionID == sessionID {
            guard let grid = canonicalGrid(sessionID: sessionID) else { continue }
            sink.pushViewport(grid.cols, grid.rows, state != nil)
        }
    }

    private func applyTUIState(sessionID: UUID, state: TUIState) {
        guard let session = findSession(sessionID) else { return }
        session.setSharedTUIRenderGrid((state.grid.cols, state.grid.rows))
        session.resizePTY(cols: state.grid.cols, rows: state.grid.rows)
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

    func sidebarCatalog() -> (spaces: [RemoteSidebarSpaceInfo], projects: [RemoteSidebarProjectInfo]) {
        let spaceStore = SpaceStore.shared
        let spaces = spaceStore.spaces.map {
            RemoteSidebarSpaceInfo(id: $0.id, name: $0.name)
        }
        let projects = ProjectStore.shared.projects.map { project in
            RemoteSidebarProjectInfo(
                id: project.id,
                name: project.name,
                path: project.path,
                accent: project.accentHex,
                spaceID: spaceStore.effectiveSpaceID(of: project)
            )
        }
        return (spaces, projects)
    }

    /// 从移动端打开空项目：沿用 Mac 侧边栏的项目复用/新建语义，并返回可立即附着的会话。
    func openProject(id: UUID) -> RemoteSessionInfo? {
        guard active,
              let project = ProjectStore.shared.projects.first(where: { $0.id == id }) else {
            return nil
        }
        let registry = SessionManagerRegistry.shared
        guard !registry.managers.isEmpty else { return nil }
        let spaceStore = SpaceStore.shared
        if let spaceID = spaceStore.effectiveSpaceID(of: project) {
            spaceStore.select(spaceID)
        }
        let manager = registry.active
        manager.openProject(path: project.path)
        guard let sessionID = manager.selected?.id else { return nil }
        return list().first { $0.id == sessionID }
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
        let attentionSeconds = attention == nil ? nil : session.attentionSince.map {
            max(0, Int(Date().timeIntervalSince($0)))
        }
        return RemoteSessionInfo(
            id: session.id,
            title: session.displayTitle,
            cwd: session.workingDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath },
            shell: session.shellName,
            alive: alive,
            running: session.runningCommand,
            attention: attention,
            attentionSeconds: attentionSeconds,
            cols: terminal.cols,
            rows: terminal.rows,
            project: project?.name ?? projectPath.map { ($0 as NSString).lastPathComponent },
            projectPath: projectPath,
            projectColor: project?.accentHex,
            space: space,
            spaceID: project.flatMap { SpaceStore.shared.effectiveSpaceID(of: $0) },
            window: window
        )
    }

    private func findSession(_ id: UUID) -> TerminalSession? {
        SessionManagerRegistry.shared.allSessions.first { $0.id == id }
    }
}
