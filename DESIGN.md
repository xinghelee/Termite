# Termite — macOS 原生终端

目标:一款体验对标并在「效率功能」上超越 Ghostty 的 Mac 终端。Ghostty 的强项是渲染速度与极简;
Termite 的差异化打法是 **原生 SwiftUI 质感 + 深度 shell 集成的效率功能**,并直接复用 Berth
(同门 SSH 客户端)已打磨的终端基建。

## 技术栈

- SwiftUI + AppKit(菜单/面板/热键),macOS 15.0+
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.14+:
  - `LocalProcessTerminalView`:内置 PTY fork/exec 本地 shell
  - `setUseMetal(true)`:Metal GPU 渲染后端(设置可开)
  - 内置 scrollback 搜索(高亮/正则/大小写)
- xcodegen 生成工程,无沙箱(终端需要完整文件系统/进程权限)

## 从 Berth 复用(拷贝并适配)

| 文件 | 复用方式 |
|---|---|
| `TerminalTheme.swift` | 20 套主题 + ThemeStore 全窗口主题化,几乎原样(去 iOS 分支,品牌改名) |
| `OSC133Scanner.swift` | 原样:shell 集成标记流解析 |
| `ANSI.swift` | 原样:转义剥离(会话录制用) |
| `FuzzyMatcher.swift` | 原样:命令面板模糊打分 |
| `PaneLayout.swift` | 原样:无限嵌套分屏树 + PaneTab |
| `CursorPrefs.swift` | 原样:光标形状/闪烁 |
| `BerthTerminalView` → `TermiteTerminalView` | 基类改 `LocalProcessTerminalView`;保留粘贴保护/右键菜单/选中即复制/中键粘贴 |
| `TerminalSession` | 重写为本地会话,但 OSC133 命令跟踪、录制、⌘↑⌘↓ 跳转、复制输出等逻辑整段移植 |
| `SessionManager` | 移植标签/分屏/广播/恢复,删 SSH 连接复用 |
| `TerminalTabsView`(chips + PaneTreeView)| 适配 |
| `StatusBarView` | 重做数据源:shell·cwd·git 分支·退出码/耗时·行列·时钟 |
| `TerminalSearch` | 重写:改用 SwiftTerm 内置搜索(真高亮,支持正则) |
| `CommandPalette*` / `PaletteTextField` | 适配:终端动作 + 主题切换 |
| `SettingsView` / `ThemePanelView` / `SettingsKeys` | 适配 |
| `WindowConfigurator` | 原样:主题化窗口 chrome |

## 新增(Berth 没有的)

1. **本地 PTY 会话**:登录 shell(`getpwuid` 解析,argv[0] 带 `-`),TERM_PROGRAM=Termite
2. **Shell 集成自动注入**(免用户配置,Ghostty 同级能力):
   - zsh:ZDOTDIR 包装目录(引导回用户原配置)+ precmd/preexec 挂钩发 OSC 133/7/2
   - bash:环境注入 PROMPT_COMMAND(降级:无 C 标记)
   - fish:3.6+ 原生发 OSC 133/7,无需注入
3. **Quake 下拉终端**:⌥Space 全局热键(Carbon,无需辅助功能权限)+ 非激活浮动面板
4. **git 分支状态栏**:cwd 变化时直读 `.git/HEAD`(零子进程)
5. **长命令完成通知**:OSC133 C→D 耗时 ≥10s 且 App 不在前台/非焦点 pane 时系统通知

## 对 Ghostty 的差异化清单

- ⌘↑/⌘↓ 命令间跳转、⌘⇧C 一键复制上条命令输出、状态栏退出码+耗时
- 粘贴保护(多行/rm -rf/sudo 等高危先确认)
- 广播输入到所有分屏(运维场景)
- ⌘P 命令面板(模糊搜索动作+主题)
- 20 套精调主题驱动整个窗口 chrome(非仅终端区)
- 会话录制到文件(剥转义纯文本)
- 长命令后台完成通知、新标签继承 cwd、启动恢复上次标签

## 结构

```
Termite/
  project.yml
  Termite/
    App/            TermiteApp · MainWindowView · WindowChrome
    Core/
      Terminal/     TermiteTerminalView · TerminalTheme · CursorPrefs · OSC133Scanner · ANSI
      Session/      TerminalSession · SessionManager · PaneLayout · ShellResolver · ShellIntegration
      Parsing/      FuzzyMatcher
    Features/
      Terminal/     TerminalTabsView · TerminalHostView · TerminalSearchBar · StatusBarView
      CommandPalette/  Controller · View · PaletteTextField
      Settings/     SettingsKeys · SettingsView · ThemePanelView
      QuickTerminal/   QuickTerminalController
      MenuBar/      MenuBarExtraView
    Resources/      Assets.xcassets
  TermiteTests/     OSC133Scanner · FuzzyMatcher · PaneLayout 测试
```

## 后续(v1 不做)

- 多窗口(当前单主窗 + 下拉终端;SessionManager 需按窗口实例化)
- iTerm2 主题导入、背景透明/毛玻璃、连字字体控制
- tmux 控制模式、SSH 集成(直接并入 Berth 能力)
