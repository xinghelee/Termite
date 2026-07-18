import AppKit
import Foundation
import Observation

/// 一个主窗口的会话管理:持有该窗口的 TerminalSession(会话池)与标签页(每个标签是一棵可无限嵌套的分屏树)。
/// 会话生命周期跟随本对象(每窗口一个,由 SessionManagerRegistry 跟踪),不跟随视图。
@MainActor
@Observable
final class SessionManager {
    /// 兼容单例调用:定向到 key 窗口的 manager(菜单命令/右键菜单等全局入口)
    static var shared: SessionManager { SessionManagerRegistry.shared.active }

    /// 所有活跃会话(跨全部标签的池)
    private(set) var sessions: [TerminalSession] = []
    /// 标签页(每个是一棵分屏树)
    private(set) var tabs: [PaneTab] = []
    var selectedTabID: PaneTab.ID?

    /// 有命令在跑的 pane 请求关闭时置此值,UI 弹确认框
    var pendingCloseSession: TerminalSession?
    /// 含运行中命令的标签整体请求关闭
    var pendingCloseTab: PaneTab?
    /// ⌘F:请求在当前会话打开搜索条(UI 消费后自增以触发)
    var searchRequestToken = 0
    /// 右侧命令时间线面板
    var isTimelineVisible = false
    /// 右侧 Git 面板(与时间线互斥,右侧只留一个)
    var isGitPanelVisible = false

    func toggleTimeline() {
        isTimelineVisible.toggle()
        if isTimelineVisible { isGitPanelVisible = false }
    }

    func toggleGitPanel() {
        isGitPanelVisible.toggle()
        if isGitPanelVisible { isTimelineVisible = false }
    }
    /// 本窗口的 ⌘P 命令面板状态
    let palette = CommandPaletteController()
    /// 本窗口的 ⌘O 目录跳转器状态
    let directoryJumper = CommandPaletteController()

    /// 窗口已关闭:置位后不再孵新会话(SwiftUI 关窗后仍可能重新求值该窗口的视图树)
    private(set) var isRetired = false

    init(registered: Bool = true) {
        if registered {
            SessionManagerRegistry.shared.register(self)
        }
    }

    /// 窗口关闭:终止本窗口全部 shell,并退役本 manager
    func shutdownAll() {
        isRetired = true
        for session in sessions { session.shutdown() }
        sessions = []
        tabs = []
        selectedTabID = nil
    }

    // MARK: - 后台活动提示

    /// 该会话当前是否「可见」:App 前台 + 本窗口是 key 窗口 + 在选中标签里(可见输出不算未读活动)
    func isSessionVisible(_ id: UUID) -> Bool {
        NSApp.isActive
            && SessionManagerRegistry.shared.active === self
            && selectedTab?.root.leafIDs().contains(id) == true
    }

    func clearActivityForSelectedTab() {
        guard let tab = selectedTab else { return }
        for id in tab.root.leafIDs() {
            session(id)?.hasUnseenActivity = false
        }
    }

    var selectedTab: PaneTab? { tabs.first { $0.id == selectedTabID } }

    /// 当前聚焦会话
    var selected: TerminalSession? {
        guard let focused = selectedTab?.focusedID else { return nil }
        return sessions.first { $0.id == focused }
    }

    var selectedID: TerminalSession.ID? { selectedTab?.focusedID }

    func session(_ id: UUID) -> TerminalSession? { sessions.first { $0.id == id } }

    // MARK: - 新建

    /// ⌘T:新标签页。默认继承当前聚焦会话的工作目录(设置可关)。
    @discardableResult
    func newTab(directory: String? = nil) -> TerminalSession {
        let session = makeSession(directory: directory ?? inheritedDirectory())
        sessions.append(session)
        let tab = PaneTab(sessionID: session.id)
        tabs.append(tab)
        selectedTabID = tab.id
        persistOpenTabs()
        return session
    }

    /// 侧边栏/命令面板打开项目:已有标签正处于该目录 → 切过去;否则在该目录开新标签
    func openProject(path: String) {
        if let tab = tabs.first(where: { session($0.focusedID)?.workingDirectory == path }) {
            selectTab(tab.id)
            return
        }
        newTab(directory: path)
    }

    private func inheritedDirectory() -> String? {
        let inherits = UserDefaults.standard.object(forKey: SettingsKeys.newTabInheritsCwd) as? Bool ?? true
        return inherits ? selected?.workingDirectory : nil
    }

    private func makeSession(directory: String?) -> TerminalSession {
        let session = TerminalSession(workingDirectory: directory)
        session.manager = self
        session.onProcessExit = { [weak self, weak session] in
            guard let self, let session else { return }
            self.closePane(session)
        }
        return session
    }

    // MARK: - 分屏(可无限嵌套)

    /// ⌘D / ⌘⇧D / 右键:在当前聚焦 pane 上再分出一个 pane(继承 cwd)。每次都新增,支持嵌套。
    func splitFocused(axis: SplitAxis) {
        guard let tab = selectedTab, let current = selected else { return }
        let secondary = makeSession(directory: inheritedDirectory())
        sessions.append(secondary)
        tab.root = tab.root.splitting(leaf: current.id, into: secondary.id, axis: axis, branchID: UUID())
        tab.focusedID = secondary.id
    }

    /// ⌘⌥方向键:按几何位置把焦点移到相邻 pane
    func focusNeighborPane(_ direction: PaneDirection) {
        guard let tab = selectedTab else { return }
        guard let next = tab.root.neighborLeaf(of: tab.focusedID, direction: direction) else { return }
        tab.focusedID = next
        session(next)?.focusTerminal()
    }

    /// 标签 chip 拖拽重排:把 id 移到 target 当前的位置
    func moveTab(_ id: PaneTab.ID, before targetID: PaneTab.ID) {
        guard id != targetID,
              let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        let insertAt = tabs.firstIndex(where: { $0.id == targetID }) ?? min(from, tabs.count)
        tabs.insert(tab, at: insertAt)
        persistOpenTabs()
    }

    /// 有命令在跑的会话数(关窗/退出确认用)
    var runningCommandCount: Int {
        sessions.filter(\.runningCommand).count
    }

    /// 点击某个 pane 聚焦它
    func focusPane(_ sessionID: UUID) {
        guard let tab = tabs.first(where: { $0.root.leafIDs().contains(sessionID) }) else { return }
        selectedTabID = tab.id
        tab.focusedID = sessionID
        session(sessionID)?.focusTerminal()
        clearActivityForSelectedTab()
    }

    // MARK: - 关闭

    /// ⌘W:关闭当前聚焦的 pane(有命令在跑需确认)
    func requestCloseCurrent() {
        guard let session = selected else { return }
        requestClose(session)
    }

    func requestClose(_ session: TerminalSession) {
        let needsConfirm = UserDefaults.standard.object(forKey: SettingsKeys.confirmBeforeClosingTab) as? Bool ?? true
        if session.runningCommand, needsConfirm {
            pendingCloseSession = session
        } else {
            closePane(session)
        }
    }

    /// 关闭单个 pane:从其所在标签的树里移除并塌缩;标签空了则整标签移除
    func closePane(_ session: TerminalSession) {
        session.shutdown()
        sessions.removeAll { $0.id == session.id }
        guard let tab = tabs.first(where: { $0.root.leafIDs().contains(session.id) }) else {
            persistOpenTabs(); return
        }
        let neighbor = tab.root.neighborLeaf(of: session.id)
        if let newRoot = tab.root.removing(leaf: session.id) {
            tab.root = newRoot
            if tab.focusedID == session.id { tab.focusedID = neighbor ?? newRoot.firstLeaf }
        } else {
            tabs.removeAll { $0.id == tab.id }
            if selectedTabID == tab.id { selectedTabID = tabs.last?.id }
        }
        persistOpenTabs()
    }

    /// 整个标签关闭(标签 chip 的 ×):有命令在跑时确认后连同其所有 pane 一起关
    func requestCloseTab(_ tab: PaneTab) {
        let needsConfirm = UserDefaults.standard.object(forKey: SettingsKeys.confirmBeforeClosingTab) as? Bool ?? true
        let anyRunning = tab.root.leafIDs().contains { session($0)?.runningCommand == true }
        if anyRunning, needsConfirm {
            pendingCloseTab = tab
        } else {
            closeTab(tab)
        }
    }

    func closeTab(_ tab: PaneTab) {
        for id in tab.root.leafIDs() {
            if let s = session(id) { s.shutdown() }
            sessions.removeAll { $0.id == id }
        }
        tabs.removeAll { $0.id == tab.id }
        if selectedTabID == tab.id { selectedTabID = tabs.last?.id }
        persistOpenTabs()
    }

    // MARK: - 选择

    func selectTab(_ id: PaneTab.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
        selected?.focusTerminal()
        clearActivityForSelectedTab()
    }

    /// ⌘1-9
    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index].id)
    }

    func requestSearch() {
        guard selected != nil else { return }
        searchRequestToken += 1
    }

    /// 记录/停止记录当前会话到文件(记录时弹保存面板选路径)
    func toggleSessionLogging() {
        guard let session = selected else { return }
        if session.isLogging {
            session.stopLogging()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, .log]
        let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        panel.nameFieldStringValue = "termite-\(session.displayTitle)-\(stamp).log"
        panel.message = String(localized: "选择会话录制文件的保存位置")
        if panel.runModal() == .OK, let url = panel.url {
            session.startLogging(to: url)
        }
    }

    // MARK: - 广播输入

    /// 焦点 pane 的键入 → 同步到同标签其它 pane(仅广播开启时)
    func broadcastInput(from sessionID: UUID, bytes: [UInt8]) {
        guard let tab = tabs.first(where: { $0.root.leafIDs().contains(sessionID) }),
              tab.isBroadcasting else { return }
        for id in tab.root.leafIDs() where id != sessionID {
            session(id)?.sendRawInput(bytes)
        }
    }

    /// 切换当前标签的广播输入(需 ≥2 个 pane 才有意义)
    func toggleBroadcast() {
        guard let tab = selectedTab, tab.root.leafIDs().count > 1 else { return }
        tab.isBroadcasting.toggle()
    }

    var isBroadcasting: Bool { selectedTab?.isBroadcasting ?? false }

    // MARK: - 工作区模板

    /// 捕获当前所有标签的布局(分屏树 + 比例 + 各 pane cwd)
    func captureWorkspaceTabs() -> [WorkspaceNode] {
        tabs.map { encodeNode($0.root) }
    }

    private func encodeNode(_ node: PaneNode) -> WorkspaceNode {
        switch node {
        case .leaf(let sid):
            return WorkspaceNode(cwd: session(sid)?.workingDirectory)
        case .branch(_, let axis, let ratio, let a, let b):
            return WorkspaceNode(
                axis: axis == .horizontal ? "h" : "v",
                ratio: ratio,
                first: encodeNode(a),
                second: encodeNode(b)
            )
        }
    }

    /// 打开工作区:逐标签重建分屏布局(目录已不存在的 pane 退回默认目录)
    func openWorkspace(_ workspace: Workspace) {
        for tabNode in workspace.tabs {
            let first = newTab(directory: validDirectory(tabNode.firstLeafCwd))
            guard let tab = tabs.last, tab.root.leafIDs() == [first.id] else { continue }
            buildSplits(tabNode, existingLeaf: first.id, in: tab)
            tab.focusedID = first.id
        }
    }

    /// 递归补分屏:existingLeaf 是 node 的 first-leaf 位置上已存在的会话
    private func buildSplits(_ node: WorkspaceNode, existingLeaf: UUID, in tab: PaneTab) {
        guard let axisRaw = node.axis, let a = node.first, let b = node.second else { return }
        let secondary = makeSession(directory: validDirectory(b.firstLeafCwd))
        sessions.append(secondary)
        tab.root = tab.root.splitting(
            leaf: existingLeaf,
            into: secondary.id,
            axis: axisRaw == "h" ? .horizontal : .vertical,
            branchID: UUID(),
            ratio: node.ratio ?? 0.5
        )
        buildSplits(a, existingLeaf: existingLeaf, in: tab)
        buildSplits(b, existingLeaf: secondary.id, in: tab)
    }

    private func validDirectory(_ path: String?) -> String? {
        guard let path else { return nil }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return (exists && isDirectory.boolValue) ? path : nil
    }

    // MARK: - 会话恢复(每标签记首 pane 的 cwd,跨窗口聚合由注册表负责)

    /// cwd 变化时(OSC 7)顺手刷新持久化
    func workingDirectoryChanged() {
        persistOpenTabs()
    }

    private func persistOpenTabs() {
        SessionManagerRegistry.shared.persistAllOpenTabs()
    }

    /// 窗口首次出现时调用:第一个窗口恢复上次的标签页(设置可关),后续窗口开默认标签
    func restoreOrCreateInitialTabs() {
        guard !isRetired, tabs.isEmpty else { return }
        let enabled = UserDefaults.standard.object(forKey: SettingsKeys.restoreSessions) as? Bool ?? true
        let saved = UserDefaults.standard.stringArray(forKey: SessionManagerRegistry.openTabsKey) ?? []
        if enabled, !saved.isEmpty, SessionManagerRegistry.shared.isFirst(self) {
            for dir in saved {
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory)
                newTab(directory: (exists && isDirectory.boolValue) ? dir : nil)
            }
            selectedTabID = tabs.first?.id
        } else {
            newTab()
        }
    }
}
