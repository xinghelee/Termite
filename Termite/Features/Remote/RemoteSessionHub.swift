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
    /// 正在接管这个会话的设备名;nil = Mac 自己在控制
    var controller: String?
}

/// 本机端口转发条目:手机端列出来一点就能在内置浏览器里打开
struct RemoteForwardInfo: Codable {
    var id: UUID
    var label: String
    /// 本机服务端口(展示用)
    var target: Int
    /// 对外端口,手机按 http://<连接用的 host>:<port>/?t=<token> 打开
    var port: Int
}

/// 控制权状态,随 attached / viewport 逐连接下发(增量字段,旧客户端忽略)。
/// 控制权永远有主人:没有远端接管时归 Mac,所以远端默认就是遮挡的监视器。
struct RemoteControlInfo: Codable {
    /// 本端就是当前操作端
    var mine: Bool
    /// 不是本端在操作 → 遮挡、不接受输入
    var locked: Bool
    /// 当前操作端的名字(Mac 持有时是这台 Mac 的名字)
    var controller: String?
    /// 本端能不能接管:Mac 持有时可以直接拿;别的远端持有时不许抢
    var claimable: Bool

    static let free = RemoteControlInfo(mine: false, locked: false, controller: nil,
                                        claimable: false)
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

    /// 远端接管:同一会话同一时刻只有一个「操作端」,PTY 网格归它,
    /// 其余端(含 Mac)转为只读监视器。这样设备才敢按自己的宽度要网格。
    private struct ControlState {
        var connID: UUID
        var grid: Grid
        var device: String
    }

    private struct Sink {
        var sessionID: UUID
        var pushOutput: (Data) -> Void
        var pushViewport: (_ cols: Int, _ rows: Int, _ tuiMode: Bool, _ control: RemoteControlInfo) -> Void
    }

    /// connID → 输出/视口推送。所有回调内部负责跳回连接自己的发送队列。
    private var sinks: [UUID: Sink] = [:]
    /// Mac 视图的自然网格。TUI/接管期间仅用于退出后的恢复，不参与共享网格更新。
    private var macGrids: [UUID: Grid] = [:]
    private var tuiStates: [UUID: TUIState] = [:]
    private var controls: [UUID: ControlState] = [:]

    func start() {
        active = true
    }

    func stop() {
        // 关服务先把接管的会话还给 Mac,否则 PTY 会卡在某台手机的网格上
        for sessionID in controls.keys {
            findSession(sessionID)?.setRemoteController(nil)
        }
        for sessionID in Set(controls.keys).union(tuiStates.keys) {
            guard let session = findSession(sessionID) else { continue }
            let grid = restoreMacGrid(session)
            session.resizePTY(cols: grid.cols, rows: grid.rows)
        }
        controls = [:]
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
        var control: RemoteControlInfo
    }

    /// attach 即订阅:先回放已有镜像,再实时跟流。会话不存在返回 nil。
    func attach(
        connID: UUID,
        sessionID: UUID,
        pushOutput: @escaping (Data) -> Void,
        pushViewport: @escaping (_ cols: Int, _ rows: Int, _ tuiMode: Bool, _ control: RemoteControlInfo) -> Void
    ) -> AttachResult? {
        guard active, let session = findSession(sessionID) else { return nil }
        let backlog = rings[sessionID]?.read(from: 0).data ?? Data()
        let snapshot = backlog.isEmpty ? session.scrollbackSnapshot(maxLines: 500) : nil
        let localGrid = session.terminalView.localViewportGrid
        let macGrid = Grid(cols: localGrid.cols, rows: localGrid.rows)
        if tuiStates[sessionID] == nil, controls[sessionID] == nil { macGrids[sessionID] = macGrid }
        // 先登记 sink 再判 TUI:冻结的前提是「有人在看」,顺序反了就永远冻不上
        sinks[connID] = Sink(sessionID: sessionID, pushOutput: pushOutput,
                             pushViewport: pushViewport)
        observeTerminalMode(sessionID: sessionID, isTUI: session.requiresSharedTUILayout)
        let state = tuiStates[sessionID]
        // 接管中的会话按接管端的网格下发,新来的端照样看得到正确画面(只是不能动)
        let grid = canonicalGrid(sessionID: sessionID) ?? state?.grid ?? macGrid
        // 画面被冻结在非 Mac 自然网格上时(TUI 或接管),必须补一张全量快照校正
        let pinned = state != nil || controls[sessionID] != nil
        return AttachResult(backlog: backlog, snapshot: snapshot,
                            cols: grid.cols, rows: grid.rows,
                            tuiMode: state != nil,
                            screenSnapshot: pinned ? session.terminalScreenSnapshot() : nil,
                            control: controlInfo(sessionID: sessionID, connID: connID))
    }

    func detach(connID: UUID) {
        guard let sink = sinks.removeValue(forKey: connID) else { return }
        let sessionID = sink.sessionID
        // 操作端断开/切走 = 自动交还,不能让 Mac 一直被锁在离线设备的网格里
        if controls[sessionID]?.connID == connID {
            releaseControl(sessionID: sessionID, from: connID)
        }
        guard !hasWatchers(sessionID), controls[sessionID] == nil else { return }
        // 最后一个观察端也走了:解冻,网格还给 Mac。留着冻结只会让这个 pane
        // 一直按旧网格渲染(窗口一变就靠缩放字号硬凑),没人看时毫无意义
        if tuiStates.removeValue(forKey: sessionID) != nil, let session = findSession(sessionID) {
            let grid = restoreMacGrid(session)
            session.resizePTY(cols: grid.cols, rows: grid.rows)
        }
        macGrids[sessionID] = nil
    }

    private func hasWatchers(_ sessionID: UUID) -> Bool {
        sinks.values.contains { $0.sessionID == sessionID }
    }

    func sendInput(connID: UUID, sessionID: UUID, bytes: [UInt8]) {
        guard active, !bytes.isEmpty,
              sinks[connID]?.sessionID == sessionID else { return }
        // 只有操作端能打字。没有远端接管时控制权归 Mac,远端一律是只读监视器
        guard controls[sessionID]?.connID == connID else { return }
        findSession(sessionID)?.sendRawInput(bytes)
    }

    // MARK: - 控制权(独占接管)

    /// 这台 Mac 的名字:远端遮罩上显示「谁在操作」
    private static let macName = Host.current().localizedName ?? String(localized: "这台 Mac")

    func controlInfo(sessionID: UUID, connID: UUID) -> RemoteControlInfo {
        // 没有远端接管 = Mac 持有:远端一律遮挡,但可以直接接管过去
        guard let state = controls[sessionID] else {
            return RemoteControlInfo(mine: false, locked: true,
                                     controller: Self.macName, claimable: true)
        }
        let mine = state.connID == connID
        return RemoteControlInfo(mine: mine, locked: !mine,
                                 controller: mine ? nil : state.device,
                                 claimable: false)
    }

    /// 设备请求接管:PTY 网格改归这台设备,Mac 与其它设备转为只读遮挡。
    /// 同一端重复 claim 只是更新网格(旋转/改字号),不产生额外动作。
    @discardableResult
    func claimControl(connID: UUID, sessionID: UUID, cols: Int, rows: Int, device: String) -> Bool {
        guard active, sinks[connID]?.sessionID == sessionID,
              let session = findSession(sessionID) else { return false }
        // 被别人占着就不给抢:远端之间不互相踢,只有 Mac 有夺回权
        if let state = controls[sessionID], state.connID != connID { return false }
        let grid = Grid(cols: max(cols, 20), rows: max(rows, 5))
        if controls[sessionID]?.grid == grid { return true }
        if controls[sessionID] == nil, tuiStates[sessionID] == nil {
            let local = session.terminalView.localViewportGrid
            macGrids[sessionID] = Grid(cols: local.cols, rows: local.rows)
        }
        controls[sessionID] = ControlState(connID: connID, grid: grid, device: device)
        session.setRemoteController(device)
        applyCanonicalGrid(sessionID: sessionID)
        broadcastViewport(sessionID: sessionID)
        return true
    }

    /// 交还控制权。from 非空时只有该端能还(防止旧连接的迟到消息把新接管掀掉);
    /// Mac 夺回走 reclaimControl,不带 from。
    func releaseControl(sessionID: UUID, from connID: UUID? = nil) {
        guard let state = controls[sessionID] else { return }
        if let connID, state.connID != connID { return }
        controls[sessionID] = nil
        guard let session = findSession(sessionID) else { return }
        session.setRemoteController(nil)
        let macGrid = restoreMacGrid(session)
        if tuiStates[sessionID] != nil {
            // 仍在 TUI:语义网格回到 Mac 当前自然网格,和没被接管过时一致
            tuiStates[sessionID] = TUIState(grid: macGrid)
            applyCanonicalGrid(sessionID: sessionID)
        } else {
            session.resizePTY(cols: macGrid.cols, rows: macGrid.rows)
        }
        broadcastViewport(sessionID: sessionID)
    }

    /// Mac 单方面夺回(点遮罩或直接键入)。Mac 是主人,不需要对端同意。
    func reclaimControl(sessionID: UUID) {
        releaseControl(sessionID: sessionID)
    }

    func isControlledRemotely(sessionID: UUID) -> Bool {
        controls[sessionID] != nil
    }

    /// 单连接的当前视口 + 控制权(claim 被拒时回执用,别让客户端干等)
    func viewportInfo(sessionID: UUID, connID: UUID)
        -> (cols: Int, rows: Int, tuiMode: Bool, control: RemoteControlInfo)? {
        guard let grid = canonicalGrid(sessionID: sessionID) else { return nil }
        return (grid.cols, grid.rows, tuiStates[sessionID] != nil,
                controlInfo(sessionID: sessionID, connID: connID))
    }

    /// Mac 自然布局变化。普通 shell 同步 PTY；TUI 期间仅改变本地呈现。
    func macViewportChanged(session: TerminalSession, cols: Int, rows: Int) {
        let sessionID = session.id
        let grid = Grid(cols: max(cols, 1), rows: max(rows, 1))
        if active, tuiStates[sessionID] != nil || controls[sessionID] != nil { return }
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
            // 没有设备在看就不冻结。视口隔离是为了保护正附着的设备,没人看时 Mac
            // 该按自己的窗口正常伸缩 —— 否则开着远程开关,每个 TUI 会话都会被冻在
            // 当时的网格(app 重启后是排版前的 80×31),切回那个项目时 pane 把窄画布
            // 放大填满窗口,字大得离谱
            guard hasWatchers(sessionID) || controls[sessionID] != nil else { return }
            let localGrid = session.terminalView.localViewportGrid
            let macGrid = macGrids[sessionID] ?? Grid(cols: localGrid.cols, rows: localGrid.rows)
            macGrids[sessionID] = macGrid
            // 接管中进入 TUI:语义网格已经归操作端,冻结它而不是 Mac 的
            tuiStates[sessionID] = TUIState(grid: controls[sessionID]?.grid ?? macGrid)
            applyCanonicalGrid(sessionID: sessionID)
            broadcastViewport(sessionID: sessionID)
        } else {
            guard tuiStates.removeValue(forKey: sessionID) != nil else { return }
            // 接管仍在,网格照旧归操作端,不能借退出 TUI 把它抢回 Mac
            guard controls[sessionID] == nil else {
                applyCanonicalGrid(sessionID: sessionID)
                broadcastViewport(sessionID: sessionID)
                return
            }
            let macGrid = restoreMacGrid(session)
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
        if tuiStates[sessionID] == nil, controls[sessionID] == nil {
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

    /// 语义网格的归属顺序:接管端 > TUI 冻结 > Mac 自然网格。
    private func canonicalGrid(sessionID: UUID) -> Grid? {
        if let state = controls[sessionID] { return state.grid }
        if let state = tuiStates[sessionID] { return state.grid }
        if let grid = macGrids[sessionID] { return grid }
        guard let session = findSession(sessionID) else { return nil }
        let grid = session.terminalView.localViewportGrid
        return Grid(cols: grid.cols, rows: grid.rows)
    }

    private func broadcastViewport(sessionID: UUID) {
        guard let grid = canonicalGrid(sessionID: sessionID) else { return }
        let tui = tuiStates[sessionID] != nil
        for (connID, sink) in sinks where sink.sessionID == sessionID {
            sink.pushViewport(grid.cols, grid.rows, tui,
                              controlInfo(sessionID: sessionID, connID: connID))
        }
    }

    /// 网格不归 Mac 时(接管或 TUI),Mac 只按语义网格渲染,靠临时字号装进窗口。
    private func applyCanonicalGrid(sessionID: UUID) {
        guard controls[sessionID] != nil || tuiStates[sessionID] != nil,
              let session = findSession(sessionID),
              let grid = canonicalGrid(sessionID: sessionID) else { return }
        session.setSharedTUIRenderGrid((grid.cols, grid.rows))
        session.resizePTY(cols: grid.cols, rows: grid.rows)
    }

    /// 退出共享网格并读回 Mac 视图**当前**的自然网格。
    /// 必须先退出再读:共享期间 naturalGrid 冻结在进入那一刻,窗口若变过就是旧值,
    /// 拿旧值回填正是「恢复后尺寸卡死」的来源。
    @discardableResult
    private func restoreMacGrid(_ session: TerminalSession) -> Grid {
        session.setSharedTUIRenderGrid(nil)
        let local = session.terminalView.localViewportGrid
        let grid = Grid(cols: local.cols, rows: local.rows)
        macGrids[session.id] = grid
        return grid
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

    /// 从手机唤起 agent:在项目目录开一个新标签,然后把命令敲进去。
    ///
    /// 刻意不复用已有标签 —— 那里可能正跑着编译或另一个 agent,
    /// 注入一行命令等于从你手里抢键盘。新开一个永远是安全的。
    func launchAgent(projectID: UUID, command: String) -> RemoteSessionInfo? {
        guard active,
              let project = ProjectStore.shared.projects.first(where: { $0.id == projectID })
        else { return nil }
        let registry = SessionManagerRegistry.shared
        guard !registry.managers.isEmpty else { return nil }
        let spaceStore = SpaceStore.shared
        if let spaceID = spaceStore.effectiveSpaceID(of: project) {
            spaceStore.select(spaceID)
        }
        let manager = registry.active
        let session = manager.newTab(directory: project.path)
        manager.tabs.last?.projectPath = project.path
        // 等 shell 起来再敲:PTY 刚建好那一下 zsh 还在读配置,
        // 这时候写进去会被 shell 集成的输出冲掉,看着就像「没反应」
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            session.sendText(command + "\r")
        }
        return list().first { $0.id == session.id }
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
            window: window,
            controller: controls[session.id]?.device
        )
    }

    private func findSession(_ id: UUID) -> TerminalSession? {
        SessionManagerRegistry.shared.allSessions.first { $0.id == id }
    }
}
