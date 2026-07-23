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
                // 关窗前把布局+屏幕内容落盘(含本窗口),然后终止其所有 shell
                registry.persistAllOpenTabs(includeScrollback: true)
                manager.shutdownAll()
                registry.managers.removeAll { $0 === manager }
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
    }

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
        windowMap.setObject(manager, forKey: window)
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

    static let openTabsKey = "session.openTabDirectories" // 旧版迁移用
    static let savedStateKey = "session.savedState"

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
            windows.append(SavedWindowState(
                tabs: manager.tabs.map {
                    manager.encodeTabState($0, scrollbackDirectory: includeScrollback ? dir : nil)
                },
                selectedIndex: manager.tabs.firstIndex { $0.id == manager.selectedTabID },
                frame: frame
            ))
        }
        let state = SavedAppState(windows: windows, activeWindowIndex: activeWindowIndex)
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: Self.savedStateKey)
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
