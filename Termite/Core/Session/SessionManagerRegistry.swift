import AppKit
import Foundation
import Observation

/// 多窗口:每个主窗口一个 SessionManager,注册表跟踪 key 窗口对应的「活跃 manager」。
/// 菜单命令 / 右键菜单 / 全局单例入口(SessionManager.shared)都定向到活跃 manager。
@MainActor
@Observable
final class SessionManagerRegistry {
    static let shared = SessionManagerRegistry()

    /// 首个自动打开的窗口的固定 key(WindowGroup(for:) 的 nil 值场景)
    static let primaryWindowKey = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @ObservationIgnored private(set) var managers: [SessionManager] = []
    @ObservationIgnored private weak var activeManager: SessionManager?
    /// 窗口 key(WindowGroup value)→ manager:视图重建时幂等复用,不产生幽灵 manager
    @ObservationIgnored private var managersByKey: [UUID: SessionManager] = [:]
    /// 窗口 → manager(都弱持有:manager 由 managers 数组持有,窗口由 AppKit 持有)
    @ObservationIgnored private let windowMap = NSMapTable<NSWindow, SessionManager>(
        keyOptions: .weakMemory, valueOptions: .weakMemory
    )
    /// 窗口 → 关闭拦截器(强持有:NSWindow.delegate 是弱引用)
    @ObservationIgnored private let closeInterceptors = NSMapTable<NSWindow, WindowCloseInterceptor>(
        keyOptions: .weakMemory, valueOptions: .strongMemory
    )
    /// 窗口 → 焦点守卫(侧边栏抢到键盘焦点时还给终端)
    @ObservationIgnored private let focusGuards = NSMapTable<NSWindow, SidebarFocusGuard>(
        keyOptions: .weakMemory, valueOptions: .strongMemory
    )

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                let registry = SessionManagerRegistry.shared
                guard let window = note.object as? NSWindow,
                      let manager = registry.windowMap.object(forKey: window) else { return }
                registry.activeManager = manager
                manager.clearActivityForSelectedTab()
            }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                let registry = SessionManagerRegistry.shared
                guard let window = note.object as? NSWindow,
                      let manager = registry.windowMap.object(forKey: window) else { return }
                // 记下关窗时的 frame:Dock 重开在首帧前预放置,不闪旧位置
                registry.pendingFrames[ObjectIdentifier(manager)] = NSStringFromRect(window.frame)
                // 关窗前把布局+屏幕内容落盘(含本窗口),然后终止其所有 shell
                registry.persistAllOpenTabs(includeScrollback: true)
                manager.shutdownAll()
                registry.managers.removeAll { $0 === manager }
                registry.windowGeneration += 1
                // managersByKey 保留退役条目:关窗后 SwiftUI 仍可能求值该窗口视图,
                // 让它拿回退役 manager(不再孵 shell),而不是新建一个
                if registry.activeManager === manager {
                    registry.activeManager = registry.managers.last
                }
            }
        }
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SessionManagerRegistry.shared.persistAllOpenTabs(includeScrollback: true) }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                SessionManagerRegistry.shared.activeManager?.clearActivityForSelectedTab()
            }
        }
        // 窗口挪动/缩放也进存档(frame 恢复的数据源),合并写
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    let registry = SessionManagerRegistry.shared
                    guard let window = note.object as? NSWindow,
                          registry.windowMap.object(forKey: window) != nil else { return }
                    registry.persistAllOpenTabsSoon()
                }
            }
        }
    }

    /// 高频路径(拖分隔条/挪窗口/切焦点/保活票据绑定)的合并持久化:静默 0.5s 后写一次
    @ObservationIgnored private var persistDebounce: DispatchWorkItem?

    func persistAllOpenTabsSoon() {
        persistDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistAllOpenTabs() }
        persistDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func register(_ manager: SessionManager) {
        managers.append(manager)
        if activeManager == nil { activeManager = manager }
        windowGeneration += 1
    }

    /// 窗口(manager)增删的代数计数。managers 数组是 @ObservationIgnored,
    /// 菜单栏徽标等 SwiftUI 消费者读它以便在开/关窗口后重扫会话集
    private(set) var windowGeneration = 0

    /// 按窗口 key 取 manager(没有则建):视图树重建时返回同一实例
    func manager(for key: UUID) -> SessionManager {
        if let existing = managersByKey[key] { return existing }
        let manager = SessionManager()
        managersByKey[key] = manager
        return manager
    }

    /// 窗口出现后由 MainWindowView 绑定(WindowConfigurator 拿到 NSWindow 时)
    func bind(_ manager: SessionManager, to window: NSWindow) {
        // 窗口恢复完全由会话恢复负责:关掉 AppKit 的场景恢复,
        // 否则强退后系统按旧场景多开窗口,和自己的多窗口恢复叠加出重复窗口
        window.isRestorable = false
        // 先入映射:复活读档时 setPendingFrame 能立即应用,不用等 bind 尾部
        windowMap.setObject(manager, forKey: window)
        // Dock 重开:视图层按同 key 拿回退役 manager(防关窗后的幽灵求值),
        // 真窗口出现意味着它要复活——重新注册 + 恢复标签(空存档停在欢迎页)
        if manager.isRetired {
            manager.revive()
            if !managers.contains(where: { $0 === manager }) {
                managers.append(manager)
                windowGeneration += 1
            }
            manager.restoreOrCreateInitialTabs()
        }
        if window.isKeyWindow { activeManager = manager }
        installCloseInterceptor(manager: manager, window: window)
        // bind 会被反复调用,守卫每窗口只装一次
        if focusGuards.object(forKey: window) == nil {
            focusGuards.setObject(SidebarFocusGuard(window: window), forKey: window)
        }
        // 会话恢复:一次性应用上次退出时的窗口位置尺寸(bind 会被反复调用,take 保证只用一次)
        if let frameString = takePendingFrame(for: manager) {
            let frame = NSRectFromString(frameString)
            if !frame.isEmpty { window.setFrame(frame, display: true) }
        }
        // 预放置时隐身的窗口:frame 已最终就位(上面 take 或恢复路径的 setPendingFrame),显形
        if window.alphaValue == 0 {
            window.alphaValue = 1
        }
    }

    /// 挂载瞬间(首帧前、窗口未显示)预放置窗口:Dock 重开用关窗时记下的 frame,
    /// 冷启动首窗口用存档 frame。SwiftUI 随后按自己记忆的位置显示窗口的行为被抢先覆盖,
    /// 旧位置一帧都不露(async 之后再 setFrame 就只能看着它闪)
    func prepareForReveal(_ manager: SessionManager, window: NSWindow) {
        guard !window.isVisible else { return }
        var frameString = pendingFrames[ObjectIdentifier(manager)]
        // 冷启动首窗口:关窗 stash 不存在,预读存档里首窗口的 frame
        //(仅限将要走恢复路径的场景,⌘N 新窗保持系统默认摆放)
        if frameString == nil,
           manager.tabs.isEmpty, !manager.isRetired, isFirst(manager),
           (UserDefaults.standard.object(forKey: SettingsKeys.restoreSessions) as? Bool ?? true),
           ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            frameString = Self.loadSavedState()?.windows.first?.frame
        }
        guard let frameString else { return }
        let frame = NSRectFromString(frameString)
        guard !frame.isEmpty else { return }
        window.setFrame(frame, display: false)
        // SwiftUI 在挂载后、orderFront 前还会把 frame 盖回它记忆的旧值,
        // 这里的预放置会被踩掉。先隐身:窗口带着旧位置显示也看不见,
        // bind(async 一拍后)重新应用正确 frame 再显形,旧位置零帧曝光
        window.alphaValue = 0
    }

    /// 用 delegate 代理拦 windowShouldClose(有命令在跑先确认);其余消息原样转发给 SwiftUI 的 delegate。
    /// bind 会被反复调用:SwiftUI 若换回自己的 delegate,这里重新包一层。
    private func installCloseInterceptor(manager: SessionManager, window: NSWindow) {
        if let existing = closeInterceptors.object(forKey: window), window.delegate === existing {
            return
        }
        let interceptor = WindowCloseInterceptor(original: window.delegate, manager: manager)
        closeInterceptors.setObject(interceptor, forKey: window)
        window.delegate = interceptor
    }

    /// key 窗口的 manager;兜底:最早注册的,再兜底临时实例(冷路径如无窗口时的菜单标题求值,不注册不留痕)
    var active: SessionManager {
        if let activeManager { return activeManager }
        if let first = managers.first {
            activeManager = first
            return first
        }
        return SessionManager(registered: false)
    }

    /// 是否是最早创建的 manager(只有它做启动恢复,后续窗口开默认标签)
    func isFirst(_ manager: SessionManager) -> Bool {
        managers.first === manager
    }

    var allSessions: [TerminalSession] { managers.flatMap(\.sessions) }

    /// 侧边栏移除项目:所有窗口里绑定该项目的标签一起关(侧边栏是全局列表,标签栏得跟上)
    func closeProjectTabs(path: String) {
        for manager in managers { manager.closeProjectTabs(path: path) }
    }

    /// 所有窗口里该项目绑定标签中正在跑命令的会话数
    func runningCommandCount(inProject path: String) -> Int {
        managers.reduce(0) { $0 + $1.runningCommandCount(inProject: path) }
    }

    // MARK: - pane 注意力汇总(侧边栏提醒点、⌘J 跳转)

    /// 项目级注意力(跨窗口):等待输入 > 命令完成 > 无
    enum ProjectAttention {
        case none, finished, needsInput
    }

    /// 会话算入项目:所在标签绑定了该项目,或其 cwd 落在项目目录下
    func attention(inProject path: String) -> ProjectAttention {
        var level = ProjectAttention.none
        for manager in managers {
            for tab in manager.tabs {
                let bound = tab.projectPath == path
                for sid in tab.root.leafIDs() {
                    guard let session = manager.session(sid) else { continue }
                    let cwd = session.workingDirectory
                    guard bound || cwd == path || cwd?.hasPrefix(path + "/") == true else { continue }
                    switch session.attention {
                    case .needsInput: return .needsInput
                    case .finished: level = .finished
                    case .none: break
                    }
                }
            }
        }
        return level
    }

    /// 是否存在带注意力的 pane(菜单/命令面板可用态)
    var hasAttentionSessions: Bool {
        managers.contains { $0.sessions.contains { $0.attention.isActive } }
    }

    /// ⌘J:跳到最需要处理的 pane(等待输入优先于完成,同级按进入注意力态最早优先;跨窗口)
    func focusNextAttention() {
        var best: (manager: SessionManager, session: TerminalSession, rank: Int, since: Date)?
        for manager in managers {
            for session in manager.sessions {
                let rank: Int
                switch session.attention {
                case .needsInput: rank = 2
                case .finished: rank = 1
                case .none: continue
                }
                let since = session.attentionSince ?? .distantFuture
                if best == nil || rank > best!.rank || (rank == best!.rank && since < best!.since) {
                    best = (manager, session, rank, since)
                }
            }
        }
        guard let best else { return }
        window(of: best.manager)?.makeKeyAndOrderFront(nil)
        // focusPane 会选中所在标签并清掉该 pane 的注意力,连按 ⌘J 即遍历所有待处理 pane
        best.manager.focusPane(best.session.id)
    }

    /// 等待输入的 pane(菜单栏徽标与列表用),最久等待的在前
    var awaitingInputSessions: [TerminalSession] {
        managers.flatMap { manager in manager.sessions.filter { $0.attention.needsInput } }
            .sorted { ($0.attentionSince ?? .distantFuture) < ($1.attentionSince ?? .distantFuture) }
    }

    /// 快速回复:不切换焦点,把文本直接发进指定会话并消解其注意力
    /// (菜单栏子菜单 / 通知动作 / pane 徽标右键共用)
    func quickReply(_ sessionID: UUID, text: String) {
        guard let session = managers.lazy.compactMap({ $0.session(sessionID) }).first else { return }
        session.sendText(text)
        session.clearAttention()
    }

    /// 菜单栏列表点击跳转到指定 pane:激活 App(点菜单栏时 App 多半不在前台)→ 其窗口 → 聚焦
    func focusSession(_ sessionID: UUID) {
        guard let manager = managers.first(where: { $0.session(sessionID) != nil }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        window(of: manager)?.makeKeyAndOrderFront(nil)
        manager.focusPane(sessionID)
    }

    /// 「移到新窗口」的待领养标签(一次性,新窗口 manager 恢复时消费)
    @ObservationIgnored var pendingAdoptTab: (tab: PaneTab, sessions: [TerminalSession])?

    /// 冷启动时经 Dock 拖放 / termite CLI 送进来的目录(窗口就绪后消费)
    @ObservationIgnored var pendingOpenDirectories: [String] = []

    func takePendingOpenDirectories() -> [String] {
        defer { pendingOpenDirectories = [] }
        return pendingOpenDirectories
    }

    func takePendingAdoptTab() -> (tab: PaneTab, sessions: [TerminalSession])? {
        defer { pendingAdoptTab = nil }
        return pendingAdoptTab
    }

    /// Dock 角标:全局运行中命令数(含下拉终端)——暂时停用,恢复时启用注释里的计数
    func updateDockBadge() {
        NSApp.dockTile.badgeLabel = nil
        // var count = allSessions.filter(\.runningCommand).count
        // if QuickTerminalController.shared.session?.runningCommand == true { count += 1 }
        // NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    // MARK: - 打开标签持久化(按窗口分组:布局树 + 可选 scrollback 快照)

    static let savedStateKey = "session.savedState"
    /// 旧版(纯目录列表)存档 key:迁移分支已删,但要持续清除。
    /// 教训:关窗后 app 退出会以空 managers 覆写 v2 存档,恢复曾掉进这个化石列表,
    /// 把早已删掉的目录复活成标签(目录失效还会经"继承 cwd"克隆出重复标签)
    static let legacyOpenTabsKey = "session.openTabDirectories"

    static var restoreDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Termite/restore", isDirectory: true)
    }

    /// 窗口 → manager(焦点守卫等窗口级组件用)
    func manager(of window: NSWindow) -> SessionManager? {
        windowMap.object(forKey: window)
    }

    /// manager → 其窗口(windowMap 的反查)
    func window(of manager: SessionManager) -> NSWindow? {
        for case let window as NSWindow in windowMap.keyEnumerator()
        where windowMap.object(forKey: window) === manager {
            return window
        }
        return nil
    }

    /// 常规变化只存布局(cwd/分屏/比例);退出与关窗时带上 scrollback 快照
    func persistAllOpenTabs(includeScrollback: Bool = false) {
        // 单测宿主与正式 app 共用同一份存档:宿主退出时的回写会覆盖用户真实会话
        // (本地会话无保活票据,窗口内容也是测试现场),跑一次测试就污染一次,禁写
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // 即时写让挂起的合并写作废,防止迟到的布局写覆盖带 scrollback 的完整存档
        persistDebounce?.cancel()
        let dir = Self.restoreDirectory
        if includeScrollback {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var windows: [SavedWindowState] = []
        var activeWindowIndex: Int?
        for manager in managers where !manager.tabs.isEmpty {
            if manager === activeManager { activeWindowIndex = windows.count }
            let frame = window(of: manager).map { NSStringFromRect($0.frame) }
            // 纯串口标签不进快照(无 shell 可恢复),选中序号也按过滤后的列表算
            let snapshotTabs = manager.snapshotTabs
            windows.append(SavedWindowState(
                tabs: snapshotTabs.map {
                    manager.encodeTabState($0, scrollbackDirectory: includeScrollback ? dir : nil)
                },
                selectedIndex: snapshotTabs.firstIndex { $0.id == manager.selectedTabID },
                frame: frame
            ))
        }
        let state = SavedAppState(windows: windows, activeWindowIndex: activeWindowIndex)
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: Self.savedStateKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyOpenTabsKey)
    }

    static func loadSavedState() -> SavedAppState? {
        guard let data = UserDefaults.standard.data(forKey: savedStateKey),
              let state = try? JSONDecoder().decode(SavedAppState.self, from: data) else { return nil }
        return state
    }

    // MARK: - 多窗口恢复(首窗口读档后,其余窗口经 openWindow 逐个开出并认领各自状态)

    /// 待恢复的后续窗口状态:key = 新窗口的 WindowGroup value
    @ObservationIgnored private var pendingWindowStates: [UUID: SavedWindowState] = [:]
    /// 窗口 frame 恢复(bind 拿到 NSWindow 时一次性应用)
    @ObservationIgnored private var pendingFrames: [ObjectIdentifier: String] = [:]

    /// 把一个待恢复窗口挂起,返回其窗口 key(视图层用它 openWindow)
    func stashPendingWindowState(_ state: SavedWindowState) -> UUID {
        let key = UUID()
        pendingWindowStates[key] = state
        return key
    }

    func takePendingWindowState(for key: UUID) -> SavedWindowState? {
        defer { pendingWindowStates[key] = nil }
        return pendingWindowStates[key]
    }

    func setPendingFrame(_ frame: String?, for manager: SessionManager) {
        guard let frame else { return }
        // 窗口已绑定(首窗口先 bind 后读档)就直接应用,否则挂起等 bind
        if let window = window(of: manager) {
            let rect = NSRectFromString(frame)
            if !rect.isEmpty { window.setFrame(rect, display: true) }
            return
        }
        pendingFrames[ObjectIdentifier(manager)] = frame
    }

    fileprivate func takePendingFrame(for manager: SessionManager) -> String? {
        defer { pendingFrames[ObjectIdentifier(manager)] = nil }
        return pendingFrames[ObjectIdentifier(manager)]
    }

    /// 恢复完成后把上次的 key 窗口找回来(等后续窗口都开出来再聚焦,600ms 足够本机开窗)
    func scheduleActiveWindowFocus(managerIndex: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.managers.indices.contains(managerIndex) else { return }
            let manager = self.managers[managerIndex]
            self.window(of: manager)?.makeKeyAndOrderFront(nil)
            manager.selected?.focusTerminal()
        }
    }
}
