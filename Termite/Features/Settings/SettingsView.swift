import SwiftUI

/// 设置窗口:终端 / 主题 / Shell / 行为 四页
struct SettingsView: View {
    @State private var themeStore = ThemeStore.shared

    var body: some View {
        TabView {
            TerminalSettingsTab()
                .tabItem { Label("终端", systemImage: "terminal") }
            ThemeSettingsTab()
                .tabItem { Label("主题", systemImage: "paintpalette") }
            ShellSettingsTab()
                .tabItem { Label("Shell", systemImage: "chevron.left.forwardslash.chevron.right") }
            BehaviorSettingsTab()
                .tabItem { Label("行为", systemImage: "slider.horizontal.3") }
        }
        .scrollContentBackground(.hidden)
        .background(themeStore.current.panelBackground)
        .tint(themeStore.current.accentColor)
        .frame(width: 500)
    }
}

private struct TerminalSettingsTab: View {
    @AppStorage(SettingsKeys.terminalFontSize) private var fontSize: Double = 13
    @AppStorage(SettingsKeys.terminalFontFamily) private var fontFamily = ""
    @AppStorage(SettingsKeys.cursorShape) private var cursorShape = CursorPrefs.shapeBlock
    @AppStorage(SettingsKeys.cursorBlink) private var cursorBlink = true
    @AppStorage(SettingsKeys.optionAsMeta) private var optionAsMeta = true
    @AppStorage(SettingsKeys.mouseReporting) private var mouseReporting = true
    @AppStorage(SettingsKeys.scrollbackLines) private var scrollbackLines = 10_000
    @AppStorage(SettingsKeys.metalRenderer) private var metalRenderer = true

    @State private var families: [String] = []

    var body: some View {
        Form {
            Section("字体") {
                Picker("字体族", selection: $fontFamily) {
                    Text("系统等宽(SF Mono)").tag("")
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                HStack {
                    Slider(value: $fontSize, in: 10...22, step: 1) {
                        Text("字号")
                    }
                    Text("\(Int(fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .onChange(of: fontFamily) { _, _ in FontPrefs.applyToAllSessions() }
            .onChange(of: fontSize) { _, _ in FontPrefs.applyToAllSessions() }

            Section("光标") {
                Picker("光标样式", selection: $cursorShape) {
                    Text("方块").tag(CursorPrefs.shapeBlock)
                    Text("竖线").tag(CursorPrefs.shapeBar)
                    Text("下划线").tag(CursorPrefs.shapeUnderline)
                }
                .pickerStyle(.segmented)
                Toggle("光标闪烁", isOn: $cursorBlink)
            }
            .onChange(of: cursorShape) { _, _ in CursorPrefs.applyToAllSessions() }
            .onChange(of: cursorBlink) { _, _ in CursorPrefs.applyToAllSessions() }

            Section("终端") {
                Toggle("鼠标事件上报给终端程序(vim/htop 等)", isOn: $mouseReporting)
                Toggle("⌥ 作为 Meta 键(发 ESC 前缀)", isOn: $optionAsMeta)
                Text("关闭后 ⌥ 组合键输入特殊字符(如 ⌥3 → #)。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("回滚行数", selection: $scrollbackLines) {
                    Text("1 000").tag(1_000)
                    Text("10 000").tag(10_000)
                    Text("50 000").tag(50_000)
                    Text("100 000").tag(100_000)
                }
                Toggle("Metal GPU 渲染", isOn: $metalRenderer)
                Text("Metal 渲染默认开启,遇到显示异常可在此关闭,切换即时生效。回滚行数对新开的标签页生效。⌘点击可打开终端里的链接;双击选词、三击选行。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: metalRenderer) { _, on in
                for session in SessionManagerRegistry.shared.allSessions {
                    try? session.terminalView.setUseMetal(on)
                }
            }
            .onChange(of: optionAsMeta) { _, on in
                for session in SessionManagerRegistry.shared.allSessions {
                    session.terminalView.optionAsMetaKey = on
                }
            }
            .onChange(of: mouseReporting) { _, on in
                for session in SessionManagerRegistry.shared.allSessions {
                    session.terminalView.allowMouseReporting = on
                }
            }
        }
        .formStyle(.grouped)
        .task { families = FontPrefs.monospacedFamilies() }
    }
}

private struct ThemeSettingsTab: View {
    var body: some View {
        ScrollView {
            ThemePanelGrid()
                .padding(16)
        }
    }
}

private struct ShellSettingsTab: View {
    @AppStorage(SettingsKeys.shellPath) private var shellPath = ""
    @AppStorage(SettingsKeys.shellIntegration) private var shellIntegration = true
    @AppStorage(SettingsKeys.newTabInheritsCwd) private var newTabInheritsCwd = true

    /// /etc/shells 里的候选 shell
    private var availableShells: [String] {
        guard let content = try? String(contentsOfFile: "/etc/shells", encoding: .utf8) else {
            return ["/bin/zsh", "/bin/bash"]
        }
        return content.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }

    var body: some View {
        Form {
            Section("Shell") {
                Picker("Shell", selection: $shellPath) {
                    Text("登录 Shell(默认)").tag("")
                    ForEach(availableShells, id: \.self) { shell in
                        Text(shell).tag(shell)
                    }
                }
                Text("变更对新开的标签页生效。以登录 shell 方式启动(argv[0] 带 -)。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shell 集成") {
                Toggle("自动注入命令标记(OSC 133)与目录上报(OSC 7)", isOn: $shellIntegration)
                Text("驱动 ⌘↑/⌘↓ 命令跳转、⌘⇧C 复制输出、状态栏退出码/耗时、新标签继承目录。zsh 全功能;bash 降级(无耗时);fish 3.6+ 原生支持。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("新标签页 / 分屏继承当前工作目录", isOn: $newTabInheritsCwd)
            }
        }
        .formStyle(.grouped)
    }
}

private struct BehaviorSettingsTab: View {
    @AppStorage(SettingsKeys.copyOnSelect) private var copyOnSelect = false
    @AppStorage(SettingsKeys.middleClickPaste) private var middleClickPaste = false
    @AppStorage(SettingsKeys.pasteProtection) private var pasteProtection = true
    @AppStorage(SettingsKeys.confirmBeforeClosingTab) private var confirmBeforeClosingTab = true
    @AppStorage(SettingsKeys.notifyLongCommand) private var notifyLongCommand = true
    @AppStorage(SettingsKeys.restoreSessions) private var restoreSessions = true
    @AppStorage(SettingsKeys.menuBarExtra) private var menuBarExtraEnabled = true
    @AppStorage(SettingsKeys.quickTerminal) private var quickTerminalEnabled = true
    @State private var cliMessage: String?

    var body: some View {
        Form {
            Section("剪贴板") {
                Toggle("选中即复制到剪贴板", isOn: $copyOnSelect)
                Toggle("中键粘贴", isOn: $middleClickPaste)
                Toggle("粘贴保护:多行或危险命令先确认", isOn: $pasteProtection)
            }
            Section("会话") {
                Toggle("关闭有命令运行的分屏 / 窗口前需要确认(含退出 App)", isOn: $confirmBeforeClosingTab)
                Toggle("后台长命令(≥10s)完成时系统通知", isOn: $notifyLongCommand)
                Toggle("启动时恢复上次的标签页(工作目录)", isOn: $restoreSessions)
            }
            Section("通用") {
                Toggle("在菜单栏显示图标", isOn: $menuBarExtraEnabled)
                Toggle("⌥Space 下拉终端(全局热键)", isOn: $quickTerminalEnabled)
                    .onChange(of: quickTerminalEnabled) { _, on in
                        if on {
                            QuickTerminalController.shared.registerHotKeyIfEnabled()
                        } else {
                            QuickTerminalController.shared.unregisterHotKey()
                        }
                    }
            }
            Section("命令行工具") {
                HStack {
                    Button("安装 termite 命令到 /usr/local/bin") {
                        cliMessage = CLIInstaller.install()
                    }
                    if let cliMessage {
                        Text(cliMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("zsh 里已内置 termite 函数(shell 集成);此安装供 bash/fish/脚本使用。termite [目录] 在 Termite 开新标签,也可以直接把文件夹拖到 Dock 图标上。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("关于") {
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    LabeledContent("版本", value: version)
                }
                LabeledContent("终端引擎", value: "SwiftTerm")
            }
        }
        .formStyle(.grouped)
    }
}
