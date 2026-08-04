import AppKit
import Observation
import SwiftUI

/// 菜单栏图标(NSStatusItem 手工管理)。
///
/// **为什么不用 SwiftUI 的 `MenuBarExtra(isInserted:)`**:那条路走不通。
/// 用手搓的 UserDefaults Binding,值不可观察,设置里关掉图标照样在,而且 SwiftUI
/// 会把自己认定的插入态经 set 写回来,把 false 覆盖回 true(关不掉 + 重开设置又是开着的);
/// 换成 @AppStorage 绑定,插入态的写回与场景失效叠成死循环——启动即卡死,
/// 内存十几秒涨到几百 MB 一路上 GB。把 @AppStorage 单独装进一个 Scene 也一样循环。
/// NSStatusItem 完全不参与 SwiftUI 的 scene 图,开关即时生效,也不会有写回。
@MainActor
final class MenuBarItemController {
    static let shared = MenuBarItemController()

    private var statusItem: NSStatusItem?
    private var defaultsObserver: NSObjectProtocol?
    /// 当前菜单是否正在展开:展开期间不重建图标,免得点开的瞬间条目被抽换
    private var isMenuOpen = false

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.menuBarExtra) as? Bool ?? true
    }

    func start() {
        syncPresence()
        // 设置页改开关后立刻生效(@AppStorage 写 UserDefaults 会发这个通知)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { MenuBarItemController.shared.syncPresence() }
        }
        observeAttention()
    }

    /// 按开关插入/移除状态项
    private func syncPresence() {
        if isEnabled {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            menu.delegate = MenuBuilder.shared
            item.menu = menu
            statusItem = item
            refreshIcon()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// 等待输入的会话数变化时换图标:实心 + 数字角标。
    /// 菜单栏按模板渲染无法上色,只能靠形状与数字表达状态。
    /// 用 Observation 递归订阅,不用 TimelineView —— 后者在无显示环境下会卡死测试宿主
    private func observeAttention() {
        withObservationTracking {
            let registry = SessionManagerRegistry.shared
            _ = registry.windowGeneration
            _ = registry.awaitingInputSessions.count
        } onChange: {
            Task { @MainActor in
                MenuBarItemController.shared.refreshIcon()
                MenuBarItemController.shared.observeAttention()
            }
        }
    }

    private func refreshIcon() {
        guard let button = statusItem?.button, !isMenuOpen else { return }
        let waiting = SessionManagerRegistry.shared.awaitingInputSessions.count
        let symbol = waiting > 0 ? "terminal.fill" : "terminal"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Termite")
        button.image?.isTemplate = true
        button.title = waiting > 0 ? " \(waiting)" : ""
        button.imagePosition = waiting > 0 ? .imageLeading : .imageOnly
    }

    fileprivate func menuWillOpen() { isMenuOpen = true }

    fileprivate func menuDidClose() {
        isMenuOpen = false
        refreshIcon()
    }
}

/// 菜单内容在每次展开时现搭(NSMenuDelegate 的标准做法):
/// 等待输入的会话是动态的,不能用静态菜单
@MainActor
private final class MenuBuilder: NSObject, NSMenuDelegate {
    static let shared = MenuBuilder()

    func menuWillOpen(_ menu: NSMenu) {
        MenuBarItemController.shared.menuWillOpen()
        menu.removeAllItems()
        let registry = SessionManagerRegistry.shared

        if let update = UpdateChecker.shared.available {
            add(to: menu, title: String(localized: "升级到 Termite \(update.version)…")) {
                UpdateChecker.shared.openDownload()
            }
            menu.addItem(.separator())
        }

        let waiting = registry.awaitingInputSessions
        if !waiting.isEmpty {
            let header = NSMenuItem(title: String(localized: "等待输入"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for session in waiting {
                // 点击 = 跳转过去;子菜单里给快速回复,不离开当前上下文打发掉 agent 的打断
                let item = NSMenuItem(title: menuTitle(for: session), action: nil, keyEquivalent: "")
                let sub = NSMenu()
                add(to: sub, title: String(localized: "回车确认")) {
                    registry.quickReply(session.id, text: "\r")
                }
                add(to: sub, title: String(localized: "发送 y")) {
                    registry.quickReply(session.id, text: "y\r")
                }
                sub.addItem(.separator())
                add(to: sub, title: String(localized: "跳转过去")) {
                    registry.focusSession(session.id)
                }
                item.submenu = sub
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        add(to: menu, title: String(localized: "显示 Termite")) { Self.showMainWindow() }
        add(to: menu, title: String(localized: "新建窗口")) {
            NSApp.activate(ignoringOtherApps: true)
            AppWindows.openMain()
        }
        add(to: menu, title: String(localized: "新建标签页")) {
            Self.showMainWindow()
            if !SessionManagerRegistry.shared.managers.isEmpty {
                SessionManager.shared.newTab()
            }
        }
        add(to: menu, title: String(localized: "下拉终端(\(QuickTerminalHotkey.current.label))")) {
            QuickTerminalController.shared.toggle()
        }
        menu.addItem(.separator())
        add(to: menu, title: String(localized: "设置…")) {
            NSApp.activate(ignoringOtherApps: true)
            AppWindows.openSettings()
        }
        menu.addItem(.separator())
        add(to: menu, title: String(localized: "退出 Termite")) {
            NSApp.terminate(nil)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        MenuBarItemController.shared.menuDidClose()
    }

    private func add(to menu: NSMenu, title: String, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(ActionBox.fire), keyEquivalent: "")
        let box = ActionBox(action)
        item.target = box
        item.representedObject = box // 菜单条目持有 box,免得闭包被回收
        menu.addItem(item)
    }

    /// 已有主窗时只呼前,没有才开新的(openWindow 每次都会开新窗)
    private static func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if SessionManagerRegistry.shared.managers.isEmpty {
            AppWindows.openMain()
        } else if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            AppWindows.openMain()
        }
    }

    /// 「项目名 · 会话标题 · 等了 1m12s」;标题与项目名重复时只留一个
    private func menuTitle(for session: TerminalSession) -> String {
        var parts: [String] = []
        if let cwd = session.workingDirectory,
           let project = ProjectStore.shared.projects.first(where: { cwd == $0.path || cwd.hasPrefix($0.path + "/") }),
           project.name != session.displayTitle {
            parts.append(project.name)
        }
        parts.append(session.displayTitle)
        if let since = session.attentionSince {
            parts.append(String(localized: "等了 \(MenuBarDuration.compact(Date().timeIntervalSince(since)))"))
        }
        return parts.joined(separator: " · ")
    }
}

/// 状态项活在 AppKit 侧,拿不到 SwiftUI 的 `openWindow`。主菜单里那几条命令本来
/// 就接着 openWindow,按**快捷键**定位并触发它们即可 —— 快捷键不随语言变,
/// 比匹配菜单标题稳
@MainActor
enum AppWindows {
    /// ⌘N:新窗口
    static func openMain() { perform(keyEquivalent: "n") }
    /// ⌘,:设置
    static func openSettings() { perform(keyEquivalent: ",") }

    private static func perform(keyEquivalent: String) {
        guard let mainMenu = NSApp.mainMenu else { return }
        for top in mainMenu.items {
            guard let submenu = top.submenu else { continue }
            for (index, item) in submenu.items.enumerated()
            where item.keyEquivalent == keyEquivalent && item.keyEquivalentModifierMask == .command {
                submenu.performActionForItem(at: index)
                return
            }
        }
    }
}

/// NSMenuItem 只认 target/action,这个盒子把闭包包成一个可被调用的对象
private final class ActionBox: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func fire() { action() }
}

enum MenuBarDuration {
    static func compact(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 {
            let rem = seconds % 60
            return rem == 0 ? "\(seconds / 60)m" : "\(seconds / 60)m\(rem)s"
        }
        return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
    }
}
