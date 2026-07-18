import SwiftUI

@main
struct TermiteApp: App {
    init() {
        // 启动即强制整个 app 跟随主题深浅,避免打开时先闪一下系统浅色
        ThemeStore.shared.applyWindowChrome()
        ShellIntegration.ensureInstalled()
        QuickTerminalController.shared.registerHotKeyIfEnabled()
    }

    var body: some Scene {
        // 每个窗口一个 SessionManager(按窗口 key 幂等获取),⌘N 开新窗口
        WindowGroup(id: "main", for: UUID.self) { $key in
            MainWindowView(windowKey: key ?? SessionManagerRegistry.primaryWindowKey)
        }
        .commands {
            TerminalCommands()
        }

        Settings {
            SettingsView()
        }

        // 菜单栏常驻入口(设置里可关)
        MenuBarExtra(
            "Termite",
            systemImage: "terminal",
            isInserted: .init(
                get: { UserDefaults.standard.object(forKey: SettingsKeys.menuBarExtra) as? Bool ?? true },
                set: { UserDefaults.standard.set($0, forKey: SettingsKeys.menuBarExtra) }
            )
        ) {
            MenuBarExtraView()
        }
    }
}

/// 终端快捷键。绝不占用 Ctrl 组合键(留给 shell),只用 ⌘。
struct TerminalCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建窗口") {
                openWindow(id: "main", value: UUID())
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("新建标签页") {
                // 没有任何窗口时 ⌘T 落到开新窗口,避免在不可见的临时 manager 里孵 shell
                if SessionManagerRegistry.shared.managers.isEmpty {
                    openWindow(id: "main", value: UUID())
                } else {
                    SessionManager.shared.newTab()
                }
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("命令面板…") {
                SessionManager.shared.palette.toggle()
            }
            .keyboardShortcut("p", modifiers: .command)

            Button("关闭分屏 / 标签页") {
                let manager = SessionManager.shared
                if manager.selected != nil {
                    manager.requestCloseCurrent()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)

            Divider()

            ForEach(1..<10) { index in
                Button("标签页 \(index)") {
                    SessionManager.shared.select(index: index - 1)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
            }
        }

        CommandGroup(after: .textEditing) {
            Button("在终端中查找") {
                SessionManager.shared.requestSearch()
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("清空回滚缓冲") {
                SessionManager.shared.selected?.clearBuffer()
            }
            .keyboardShortcut("k", modifiers: .command)

            Button("上一条命令") {
                SessionManager.shared.selected?.jumpToPreviousCommand()
            }
            .keyboardShortcut(.upArrow, modifiers: .command)

            Button("下一条命令") {
                SessionManager.shared.selected?.jumpToNextCommand()
            }
            .keyboardShortcut(.downArrow, modifiers: .command)

            Button("复制上条命令输出") {
                SessionManager.shared.selected?.copyLastCommandOutput()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
        }

        CommandMenu("终端") {
            Button("命令时间线") {
                SessionManager.shared.isTimelineVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: .command)

            Divider()

            Button("左右分屏") {
                SessionManager.shared.splitFocused(axis: .horizontal)
            }
            .keyboardShortcut("d", modifiers: .command)

            Button("上下分屏") {
                SessionManager.shared.splitFocused(axis: .vertical)
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button("广播输入到所有分屏") {
                SessionManager.shared.toggleBroadcast()
            }
            .keyboardShortcut("b", modifiers: [.command, .option])

            Divider()

            Button("下拉终端") {
                QuickTerminalController.shared.toggle()
            }
            .keyboardShortcut("`", modifiers: [.command, .option])

            Divider()

            Button(SessionManager.shared.selected?.isLogging == true ? "停止记录会话" : "记录会话到文件…") {
                SessionManager.shared.toggleSessionLogging()
            }
        }
    }
}
