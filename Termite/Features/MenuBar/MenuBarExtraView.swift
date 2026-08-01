import SwiftUI

/// 菜单栏常驻菜单:呼出主窗口 / 下拉终端 / 新建标签
struct MenuBarExtraView: View {
    @Environment(\.openWindow) private var openWindow

    /// WindowGroup 下 openWindow 每次都会开新窗;已有主窗时只呼前
    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if SessionManagerRegistry.shared.managers.isEmpty {
            openWindow(id: "main", value: UUID())
        } else if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main", value: UUID())
        }
    }

    var body: some View {
        let waiting = SessionManagerRegistry.shared.awaitingInputSessions
        if !waiting.isEmpty {
            Text("等待输入")
            ForEach(waiting, id: \.id) { session in
                Button(menuTitle(for: session)) {
                    SessionManagerRegistry.shared.focusSession(session.id)
                }
            }
            Divider()
        }
        Button("显示 Termite") {
            showMainWindow()
        }
        Button("新建窗口") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main", value: UUID())
        }
        Button("新建标签页") {
            showMainWindow()
            if !SessionManagerRegistry.shared.managers.isEmpty {
                SessionManager.shared.newTab()
            }
        }
        Button("下拉终端(\(QuickTerminalHotkey.current.label))") {
            QuickTerminalController.shared.toggle()
        }
        Divider()
        SettingsLink {
            Text("设置…")
        }
        Divider()
        Button("退出 Termite") {
            NSApp.terminate(nil)
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
            parts.append(String(localized: "等了 \(Self.compactDuration(Date().timeIntervalSince(since)))"))
        }
        return parts.joined(separator: " · ")
    }

    static func compactDuration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 {
            let rem = seconds % 60
            return rem == 0 ? "\(seconds / 60)m" : "\(seconds / 60)m\(rem)s"
        }
        return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
    }
}

/// 菜单栏图标:有 pane 等待输入时实心图标 + 数字角标。
/// 菜单栏按模板渲染无法上色,只能靠形状与数字表达状态。
/// 纯 Observation 驱动(TimelineView 在 xcodebuild test 的无显示环境下会卡死宿主启动);
/// windowGeneration 补上「新开窗口的会话不在上次观察集」的洞。
struct MenuBarAttentionLabel: View {
    var body: some View {
        let registry = SessionManagerRegistry.shared
        let _ = registry.windowGeneration
        let waiting = registry.awaitingInputSessions.count
        if waiting > 0 {
            Image(systemName: "terminal.fill")
            Text("\(waiting)")
        } else {
            Image(systemName: "terminal")
        }
    }
}
