import AppKit
import SwiftUI

enum SettingsWindow {
    static let id = "settings"
}

/// 设置窗口:左栏分类 + 右栏内容的两栏布局(条目变多后单排 tab 已经装不下)。
/// 内容延伸到标题栏下,左栏底色一路铺到窗口顶部。
struct SettingsView: View {
    @State private var themeStore = ThemeStore.shared
    @State private var section: SettingsSection = .terminal
    @AppStorage(SettingsKeys.translucentChrome) private var translucentChrome = true

    private var theme: TerminalTheme { themeStore.current }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $section)
            Rectangle()
                .fill(theme.borderColor)
                .frame(width: 1)
            VStack(spacing: 0) {
                // 内容不滚到标题栏下面(标题栏透明,滚过去会和标题文字叠在一起)
                Color.clear.frame(height: 38)
                page
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.chromeBackground)
        }
        // 尺寸全可伸:窗口能拉大;高度尤其不能定死 —— 内容延伸到标题栏下之后,
        // 窗口内容区比理想高度多出标题栏那一截,定高会在顶部留一条露出窗口底色的缝
        .frame(
            minWidth: 660, idealWidth: 820, maxWidth: .infinity,
            minHeight: 460, idealHeight: 600, maxHeight: .infinity
        )
        .tint(theme.accentColor)
        // 与主窗口同一套液态玻璃:整窗毛玻璃 + 半透主题 tint 打底,
        // 内容列自己铺不透明底,左栏透出玻璃;跟随同一个「透明毛玻璃窗口」开关
        .background {
            if translucentChrome {
                ZStack {
                    WindowBackdrop()
                    Color(nsColor: theme.backgroundNSColor).opacity(0.45)
                }
                .ignoresSafeArea()
            }
        }
        .background(WindowConfigurator(
            appearanceName: theme.appearanceName,
            backgroundColor: theme.backgroundNSColor,
            translucent: translucentChrome,
            keepsTitle: true,
            fullSizeContent: true
        ))
    }

    @ViewBuilder private var page: some View {
        switch section {
        case .terminal: TerminalSettingsPage()
        case .appearance: AppearanceSettingsPage()
        case .shell: ShellSettingsPage()
        case .session: SessionSettingsPage()
        case .behavior: BehaviorSettingsPage()
        case .remote: RemoteSettingsPage()
        case .general: GeneralSettingsPage()
        }
    }
}

// MARK: - 分类

enum SettingsSection: String, CaseIterable, Identifiable {
    case terminal, appearance, shell, session, behavior, remote, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: return String(localized: "终端")
        case .appearance: return String(localized: "外观")
        case .shell: return String(localized: "Shell")
        case .session: return String(localized: "会话")
        case .behavior: return String(localized: "行为")
        case .remote: return String(localized: "远程")
        case .general: return String(localized: "通用")
        }
    }

    var symbol: String {
        switch self {
        case .terminal: return "terminal"
        case .appearance: return "paintpalette"
        case .shell: return "chevron.left.forwardslash.chevron.right"
        case .session: return "rectangle.stack"
        case .behavior: return "hand.tap"
        case .remote: return "iphone.and.arrow.right.inward"
        case .general: return "gearshape"
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection

    @State private var themeStore = ThemeStore.shared
    @AppStorage(SettingsKeys.translucentChrome) private var translucentChrome = true

    private var theme: TerminalTheme { themeStore.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 标题栏区域(交通灯)让位
            Color.clear.frame(height: 38)
            ForEach(SettingsSection.allCases) { item in
                SettingsSidebarItem(
                    section: item,
                    isSelected: selection == item,
                    action: { selection = item }
                )
            }
            Spacer()
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                Text(verbatim: "Termite \(version)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 194)
        .frame(maxHeight: .infinity, alignment: .top)
        // 玻璃模式左栏不铺底,透出整窗毛玻璃(同主窗口侧边栏);不透明模式照旧
        .background {
            if !translucentChrome {
                theme.sidebarBackground
            }
        }
    }
}

private struct SettingsSidebarItem: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var themeStore = ThemeStore.shared

    private var theme: TerminalTheme { themeStore.current }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? AnyShapeStyle(theme.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 18)
                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? theme.accentSoft : (hovering ? Color.primary.opacity(0.06) : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - 终端

private struct TerminalSettingsPage: View {
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
        SettingsPage {
            SettingsGroup("字体") {
                SettingsRow(title: "字体族") {
                    Picker("", selection: $fontFamily) {
                        Text("系统等宽(SF Mono)").tag("")
                        ForEach(families, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                SettingsRow(title: "字号") {
                    HStack(spacing: 12) {
                        Slider(value: $fontSize, in: 10...22, step: 1)
                            .frame(width: 180)
                        Text(verbatim: "\(Int(fontSize)) pt")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }
            .onChange(of: fontFamily) { _, _ in FontPrefs.applyToAllSessions() }
            .onChange(of: fontSize) { _, _ in FontPrefs.applyToAllSessions() }

            SettingsGroup("光标") {
                SettingsRow(title: "样式") {
                    SettingsSegmented(selection: $cursorShape, options: [
                        .init(CursorPrefs.shapeBlock, "方块"),
                        .init(CursorPrefs.shapeBar, "竖线"),
                        .init(CursorPrefs.shapeUnderline, "下划线"),
                    ])
                }
                SettingsToggleRow(title: "闪烁", isOn: $cursorBlink)
            }
            .onChange(of: cursorShape) { _, _ in CursorPrefs.applyToAllSessions() }
            .onChange(of: cursorBlink) { _, _ in CursorPrefs.applyToAllSessions() }

            SettingsGroup("输入") {
                SettingsToggleRow(
                    title: "鼠标事件上报",
                    caption: "让 vim、htop 等程序接收鼠标;按住 ⌥ 可临时用本地选择",
                    isOn: $mouseReporting
                )
                SettingsToggleRow(
                    title: "⌥ 作为 Meta 键",
                    caption: "发送 ESC 前缀;关闭后 ⌥ 组合键输入特殊字符(如 ⌥3 → #)",
                    isOn: $optionAsMeta
                )
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

            SettingsGroup("显示") {
                SettingsRow(title: "回滚行数", caption: "对新开的标签页生效") {
                    Picker("", selection: $scrollbackLines) {
                        Text(verbatim: "1 000").tag(1_000)
                        Text(verbatim: "10 000").tag(10_000)
                        Text(verbatim: "50 000").tag(50_000)
                        Text(verbatim: "100 000").tag(100_000)
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                SettingsToggleRow(
                    title: "Metal GPU 渲染",
                    caption: "默认开启,遇到显示异常可关闭,切换即时生效",
                    isOn: $metalRenderer
                )
            }
            .onChange(of: metalRenderer) { _, on in
                for session in SessionManagerRegistry.shared.allSessions {
                    try? session.terminalView.setUseMetal(on)
                }
            }
            SettingsFootnote("⌘点击可打开终端里的链接;双击选词、三击选行。")
        }
        .task { families = FontPrefs.monospacedFamilies() }
    }
}

// MARK: - 外观

private struct AppearanceSettingsPage: View {
    @AppStorage(SettingsKeys.translucentChrome) private var translucentChrome = true

    var body: some View {
        SettingsPage {
            SettingsPanel("终端配色") {
                ThemePanelGrid(adaptiveMinimum: 150)
            }
            SettingsFootnote("配色对所有已打开的终端即时生效,窗口 chrome 一并跟随。")

            SettingsGroup("窗口") {
                SettingsToggleRow(
                    title: "透明毛玻璃窗口",
                    caption: "标题栏与侧边栏透出桌面,终端内容区保持不透明",
                    isOn: $translucentChrome
                )
            }
        }
    }
}

// MARK: - Shell

private struct ShellSettingsPage: View {
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
        SettingsPage {
            SettingsGroup("Shell") {
                SettingsRow(title: "启动 Shell", caption: "变更对新开的标签页生效") {
                    Picker("", selection: $shellPath) {
                        Text("登录 Shell(默认)").tag("")
                        ForEach(availableShells, id: \.self) { shell in
                            Text(shell).tag(shell)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
            }
            SettingsFootnote("以登录 shell 方式启动(argv[0] 带 -),读取你原本的配置文件。")

            SettingsGroup("Shell 集成") {
                SettingsToggleRow(
                    title: "自动注入命令标记",
                    caption: "OSC 133 命令标记 + OSC 7 目录上报,无需手动改配置",
                    isOn: $shellIntegration
                )
                SettingsToggleRow(title: "新标签页 / 分屏继承当前工作目录", isOn: $newTabInheritsCwd)
            }
            SettingsFootnote("集成驱动 ⌘↑/⌘↓ 命令跳转、⌘⇧C 复制输出、状态栏退出码与耗时、新标签继承目录。zsh 全功能;bash 降级(无耗时);fish 3.6+ 原生支持。")
        }
    }
}

// MARK: - 会话

private struct SessionSettingsPage: View {
    @AppStorage(SettingsKeys.autoNewTabOnEmpty) private var autoNewTabOnEmpty = false
    @AppStorage(SettingsKeys.confirmBeforeClosingTab) private var confirmBeforeClosingTab = true
    @AppStorage(SettingsKeys.restoreSessions) private var restoreSessions = true
    @AppStorage(SettingsKeys.sessionPersistence) private var sessionPersistence = true
    @AppStorage(SettingsKeys.notifyLongCommand) private var notifyLongCommand = true
    @AppStorage(SettingsKeys.attentionDetection) private var attentionDetection = true
    @AppStorage(SettingsKeys.notifyAttention) private var notifyAttention = true

    var body: some View {
        SettingsPage {
            SettingsGroup("标签与窗口") {
                SettingsToggleRow(
                    title: "空窗口自动新建终端",
                    caption: "跳过「新建标签页」空白引导页",
                    isOn: $autoNewTabOnEmpty
                )
                SettingsToggleRow(
                    title: "关闭前确认",
                    caption: "有命令在跑的分屏 / 窗口(含退出 App)关闭前先问一句",
                    isOn: $confirmBeforeClosingTab
                )
            }

            SettingsGroup("恢复") {
                SettingsToggleRow(title: "启动时恢复上次的标签页", isOn: $restoreSessions)
                SettingsToggleRow(
                    title: "退出后保留会话",
                    caption: "重启无缝接回,命令继续跑;需要开启启动恢复",
                    isOn: $sessionPersistence
                )
                .disabled(!restoreSessions)
            }

            SettingsGroup("通知") {
                SettingsToggleRow(
                    title: "长命令完成时通知",
                    caption: "后台运行 ≥10s 的命令结束时发系统通知",
                    isOn: $notifyLongCommand
                )
                SettingsToggleRow(
                    title: "检测分屏等待输入",
                    caption: "响铃 / 长输出后静默即视为等待输入,点亮橙色提醒",
                    isOn: $attentionDetection
                )
                SettingsToggleRow(title: "等待输入时系统通知", isOn: $notifyAttention)
                    .disabled(!attentionDetection)
            }
        }
    }
}

// MARK: - 行为

private struct BehaviorSettingsPage: View {
    @AppStorage(SettingsKeys.copyOnSelect) private var copyOnSelect = true
    @AppStorage(SettingsKeys.middleClickPaste) private var middleClickPaste = false
    @AppStorage(SettingsKeys.pasteProtection) private var pasteProtection = true
    @AppStorage(SettingsKeys.fileOpenAppPath) private var openAppPath = ""
    @AppStorage(SettingsKeys.editorAppPath) private var editorAppPath = ""

    var body: some View {
        SettingsPage {
            SettingsGroup("剪贴板") {
                SettingsToggleRow(title: "选中即复制", isOn: $copyOnSelect)
                SettingsToggleRow(title: "中键粘贴", isOn: $middleClickPaste)
                SettingsToggleRow(
                    title: "粘贴保护",
                    caption: "多行或危险命令(rm -rf、sudo 等)先确认",
                    isOn: $pasteProtection
                )
            }

            SettingsGroup("打开方式") {
                SettingsRow(title: "打开文件使用", caption: "文件浏览器双击或右键「打开」;留空跟随 macOS 默认关联") {
                    HStack(spacing: 8) {
                        Text(FileOpener.displayName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button("选择…") {
                            FileOpener.chooseApp { openAppPath = $0 }
                        }
                        if !openAppPath.isEmpty {
                            Button("默认") { openAppPath = "" }
                        }
                    }
                }
                SettingsRow(title: "⌘点击 file:line 打开", caption: "VS Code / Cursor / Zed / Xcode 可直达行号") {
                    HStack(spacing: 8) {
                        Text(EditorLauncher.displayName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button("选择…") {
                            EditorLauncher.chooseApp { editorAppPath = $0 }
                        }
                        if !editorAppPath.isEmpty {
                            Button("自动检测") { editorAppPath = "" }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 通用

private struct GeneralSettingsPage: View {
    @AppStorage(SettingsKeys.menuBarExtra) private var menuBarExtraEnabled = true
    @AppStorage(SettingsKeys.autoCheckUpdates) private var autoCheckUpdates = true
    @AppStorage(SettingsKeys.quickTerminal) private var quickTerminalEnabled = true
    @AppStorage(SettingsKeys.quickTerminalHotkey) private var quickTerminalHotkey = QuickTerminalHotkey.ctrlOptCmdSpace.rawValue
    @State private var cliMessage: String?

    var body: some View {
        SettingsPage {
            SettingsGroup("应用") {
                SettingsToggleRow(
                    title: "自动检查更新",
                    caption: "GitHub Release,每日至多一次",
                    isOn: $autoCheckUpdates
                )
                SettingsToggleRow(title: "在菜单栏显示图标", isOn: $menuBarExtraEnabled)
            }

            SettingsGroup("下拉终端") {
                SettingsToggleRow(title: "全局热键唤出下拉终端", isOn: $quickTerminalEnabled)
                    .onChange(of: quickTerminalEnabled) { _, on in
                        if on {
                            QuickTerminalController.shared.registerHotKeyIfEnabled()
                        } else {
                            QuickTerminalController.shared.unregisterHotKey()
                        }
                    }
                if quickTerminalEnabled {
                    SettingsRow(title: "热键") {
                        Picker("", selection: $quickTerminalHotkey) {
                            ForEach(QuickTerminalHotkey.allCases) { hotkey in
                                Text(hotkey.label).tag(hotkey.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                        .onChange(of: quickTerminalHotkey) { _, _ in
                            QuickTerminalController.shared.reregisterHotKey()
                        }
                    }
                }
            }
            if quickTerminalEnabled {
                SettingsFootnote("⌥Space 易与 Raycast / 输入法切换冲突,默认使用 ⌃⌥⌘Space。")
            }

            SettingsGroup("命令行工具") {
                SettingsRow(title: "termite 命令", caption: "termite [目录] 在 Termite 开新标签;也可以把文件夹拖到 Dock 图标上") {
                    HStack(spacing: 8) {
                        if let cliMessage {
                            Text(cliMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Button("安装到 /usr/local/bin") {
                            cliMessage = CLIInstaller.install()
                        }
                    }
                }
            }
            SettingsFootnote("zsh 里已内置 termite 函数(shell 集成),此安装供 bash / fish / 脚本使用。")

            SettingsGroup("关于") {
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    SettingsRow(title: "版本") {
                        Text(verbatim: version)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                SettingsRow(title: "终端引擎") {
                    Text(verbatim: "SwiftTerm")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
