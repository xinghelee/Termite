import Foundation

/// @AppStorage / UserDefaults 键名统一定义
enum SettingsKeys {
    static let terminalFontSize = "terminal.fontSize"
    /// 等宽字体名(空 = 系统等宽 SF Mono)
    static let terminalFontFamily = "terminal.fontFamily"
    static let terminalTheme = "terminal.theme"
    static let cursorShape = "terminal.cursorShape"
    static let cursorBlink = "terminal.cursorBlink"
    static let copyOnSelect = "terminal.copyOnSelect"
    static let middleClickPaste = "terminal.middleClickPaste"
    static let pasteProtection = "terminal.pasteProtection"
    /// ⌥ 作为 Meta 键(发 ESC 前缀;关闭则输入特殊字符)
    static let optionAsMeta = "terminal.optionAsMeta"
    static let scrollbackLines = "terminal.scrollbackLines"
    /// Metal GPU 渲染(实验性)
    static let metalRenderer = "terminal.metalRenderer"
    static let confirmBeforeClosingTab = "terminal.confirmBeforeClosingTab"
    /// 自定义 shell 路径(空 = 用户登录 shell)
    static let shellPath = "shell.path"
    /// 自动注入 OSC 133/7 shell 集成(zsh/bash)
    static let shellIntegration = "shell.integration"
    /// 新标签/分屏继承当前会话的工作目录
    static let newTabInheritsCwd = "shell.newTabInheritsCwd"
    /// 后台长命令完成时系统通知
    static let notifyLongCommand = "session.notifyLongCommand"
    /// 启动时恢复上次的标签页(工作目录)
    static let restoreSessions = "session.restoreOnLaunch"
    /// 退出后保留会话:shell 活在 termite-ptyhost 守护进程里,重启无缝接回(依赖启动恢复开启)
    static let sessionPersistence = "session.keepAlive"
    /// 菜单栏常驻图标
    static let menuBarExtra = "app.menuBarExtra"
    /// 下拉终端(全局热键)
    static let quickTerminal = "app.quickTerminal"
    /// 下拉终端热键选择(QuickTerminalHotkey.rawValue)
    static let quickTerminalHotkey = "app.quickTerminalHotkey"
    /// diff 视图自动换行(关闭则横向滚动看原始排版)
    static let diffWrapLines = "diff.wrapLines"
    /// 鼠标事件上报给终端程序(vim/htop 等;按住 ⌥ 可临时用本地选择)
    static let mouseReporting = "terminal.mouseReporting"
    /// 文件浏览器「打开」用的 .app 路径(空 = 跟随系统默认程序)
    static let fileOpenAppPath = "fileBrowser.openAppPath"
}
