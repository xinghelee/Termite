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
        Button("下拉终端(⌥Space)") {
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
}
