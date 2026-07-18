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
                // 关窗前把布局落盘(含本窗口),然后终止其所有 shell
                registry.persistAllOpenTabs()
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
            MainActor.assumeIsolated { SessionManagerRegistry.shared.persistAllOpenTabs() }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                SessionManagerRegistry.shared.activeManager?.clearActivityForSelectedTab()
            }
        }
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
        windowMap.setObject(manager, forKey: window)
        if window.isKeyWindow { activeManager = manager }
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

    // MARK: - 打开标签持久化(跨窗口聚合)

    static let openTabsKey = "session.openTabDirectories"

    func persistAllOpenTabs() {
        let dirs = managers.flatMap { manager in
            manager.tabs.compactMap { manager.session($0.root.firstLeaf)?.workingDirectory }
        }
        UserDefaults.standard.set(dirs, forKey: Self.openTabsKey)
    }
}
