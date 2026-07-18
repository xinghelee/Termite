import SwiftUI
import UniformTypeIdentifiers

/// 退出确认:有命令在跑时 ⌘Q 先弹确认(设置里的「关闭确认」总开关控制)
final class TermiteAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let confirmEnabled = UserDefaults.standard.object(forKey: SettingsKeys.confirmBeforeClosingTab) as? Bool ?? true
            let running = SessionManagerRegistry.shared.allSessions.filter(\.runningCommand).count
            guard confirmEnabled, running > 0 else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = String(localized: "退出 Termite?")
            alert.informativeText = String(localized: "有 \(running) 个命令正在运行,退出会终止它们。")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "退出"))
            alert.addButton(withTitle: String(localized: "取消"))
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
    }
}

@main
struct TermiteApp: App {
    @NSApplicationDelegateAdaptor(TermiteAppDelegate.self) private var appDelegate

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

        // 会话回放:终端录像机窗口
        WindowGroup("会话回放", id: "cast-replay", for: URL.self) { $fileURL in
            if let fileURL {
                CastReplayView(fileURL: fileURL)
            }
        }
        .defaultSize(width: 960, height: 640)

        // 图形提交历史:独立窗口(可拉伸/缩放/全屏),按仓库根路径区分
        WindowGroup("提交历史", id: "git-history", for: String.self) { $repoRoot in
            if let repoRoot {
                GitHistoryGraphView(repoRoot: repoRoot)
            }
        }
        .defaultSize(width: 1180, height: 780)

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

            Button("跳转目录…") {
                SessionManager.shared.directoryJumper.toggle()
            }
            .keyboardShortcut("o", modifiers: .command)

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
                SessionManager.shared.toggleTimeline()
            }
            .keyboardShortcut("i", modifiers: .command)

            Button("Git 面板") {
                SessionManager.shared.toggleGitPanel()
            }
            .keyboardShortcut("g", modifiers: .command)

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

            Button("聚焦左侧分屏") {
                SessionManager.shared.focusNeighborPane(.left)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

            Button("聚焦右侧分屏") {
                SessionManager.shared.focusNeighborPane(.right)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

            Button("聚焦上方分屏") {
                SessionManager.shared.focusNeighborPane(.up)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])

            Button("聚焦下方分屏") {
                SessionManager.shared.focusNeighborPane(.down)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])

            Divider()

            Button("下拉终端") {
                QuickTerminalController.shared.toggle()
            }
            .keyboardShortcut("`", modifiers: [.command, .option])

            Divider()

            Button(SessionManager.shared.selected?.isLogging == true ? "停止记录会话" : "记录会话到文件…") {
                SessionManager.shared.toggleSessionLogging()
            }

            Button(SessionManager.shared.selected?.isCasting == true ? "停止录制(asciinema)" : "录制会话(asciinema)…") {
                SessionManager.shared.toggleCastRecording()
            }

            Button("回放录制文件…") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                if let castType = UTType(filenameExtension: "cast") {
                    panel.allowedContentTypes = [castType, .json, .plainText]
                }
                guard panel.runModal() == .OK, let url = panel.url else { return }
                openWindow(id: "cast-replay", value: url)
            }
        }
    }
}
