# Termite

[English](README.en.md)

**为 macOS 而写的原生终端。**

界面从头用 SwiftUI 写,不是套壳;shell 集成把每条命令变成可跳转、可回看的单元;Git 面板、无限分屏、命令面板、20 套主题,开箱即用。

![Termite 演示](docs/termite-demo.gif)

**[⬇️ 下载最新版](https://github.com/xinghelee/Termite/releases/latest)** — DMG 已过 Apple 公证,拖进 Applications 即用;或用 Homebrew:

```sh
brew install --cask xinghelee/tap/termite
```

- 系统要求:macOS 15.0+
- 技术栈:SwiftUI + AppKit,终端引擎 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)(Metal GPU 渲染)
- 无沙箱、完整文件系统与进程权限,和你习惯的终端行为完全一致

## 核心特性

### 巡视模式 

![巡视模式](docs/carousel-demo.gif)

- **⇧⌘\ 或双指捏合**:所有分屏等宽横排,触控板横滑逐个检阅;滑到哪个分屏,键盘焦点就在哪个,⌘←→ 键盘翻页
- **等待输入提醒**:agent 停下来等你时,pane 橙色呼吸边框、菜单栏角标、系统通知;⌘J 一键跳到等最久的
- **原地快速回复**:直接在系统通知上输入回复,或 pane 徽标右键「回车确认 / 发送 y」,不打断手头的事

### Worktree 分屏:每个 agent 一个工作树(1.15 新增)

并行 agent 共用一个工作树会把 diff 混成一锅——把 `git worktree` 做成一次右键:

- **右键 →「在新 Worktree 中分屏…」**:输入名字新建分支,或模糊搜索几千个已有分支(本地 + 远程)直接检出;已被检出的分支一键打开其现有 worktree
- 新分支基于当前分支;目录在仓库同级(`仓库名-分支名`);**分屏名自动 = 分支名**
- **右键 →「清理此 Worktree」**:未提交改动先拦截(可强制),分支保留供合并

### 会话恢复

- **多窗口完整恢复**:重新打开 App,窗口 frame、焦点、最大化状态、标签与分屏结构、scrollback 全量找回
- 新标签继承当前目录

### Shell 集成(自动注入,零配置)

zsh / bash / fish 自动挂钩 OSC 133 命令标记,带来一整套命令级能力:

- ⌘↑ / ⌘↓ 在命令之间跳转,⌘⇧C 一键复制上条命令输出
- 状态栏实时显示退出码与命令耗时
- 长命令(≥10s)后台完成时发系统通知
- 命令历史 SQLite 落盘,⌘⇧H 全局搜索,自动生成日报

### Git 集成

- ⌘G Git 面板:SourceTree 式图形历史泳道、词级高亮 diff、blame、单文件修改历史
- 暂存 / 取消暂存 / 丢弃、分支切换、cherry-pick / revert
- 状态栏常驻当前分支(直读 `.git/HEAD`,零子进程)与提交身份,点击即可编辑

### 面板与导航

- ⌘P 命令面板:模糊搜索所有动作与主题
- ⌘O 目录跳转器,⇧⌘E 文件浏览器(支持新建文件夹),侧边栏项目切换
- Quake 下拉终端:全局热键 ⌃⌥⌘Space(可自定义),无需辅助功能权限
- 端口管理面板;`termite` CLI;Dock 图标拖入文件夹直接开标签

### 终端手感

- 无限嵌套分屏:⌘⌥方向键导航、⇧⌘↩ 分屏最大化、广播输入到所有分屏
- 标签拖拽重排、标签移到新窗口
- 粘贴保护:多行 / `rm -rf` / `sudo` 等高危内容先确认
- 选中即复制、中键粘贴,仅聚焦 pane 光标闪烁
- 20 套精调主题,主题化整个窗口 chrome(不只终端区)
- 内置 `imgcat` 终端内联看图;asciinema 格式会话录制与回放
- 输出 Diff 对比、结构化输出查看器

## 从源码构建

依赖 [xcodegen](https://github.com/yonaskolb/XcodeGen):

```sh
xcodegen generate
xcodebuild -project Termite.xcodeproj -scheme Termite -configuration Release build
```

或直接 `open Termite.xcodeproj` 用 Xcode 跑。工程包含三个 target:

| Target | 说明 |
|---|---|
| `Termite` | 主 App |
| `PtyHostDaemon` | `termite-ptyhost` PTY 守护进程(构建后拷入 App bundle) |
| `TermiteTests` | 单元测试 |

## 项目结构

```
Termite/
  App/         入口、主窗口、窗口 chrome
  Core/        Terminal(渲染/主题/OSC133) · Session(会话/分屏/shell 集成) · Git · Parsing
  Features/    Terminal · Git · CommandPalette · FileBrowser · Sidebar
               DirectoryJumper · HistorySearch · Ports · QuickTerminal · Replay · Settings · MenuBar
PtyHostDaemon/ 守护进程
PtyHostShared/ App 与守护进程共享的 socket 协议
TermiteTests/  单元测试
```

设计文档见 [DESIGN.md](DESIGN.md)。

## 许可

[GPL-3.0](LICENSE)。自由使用、修改与再分发;分发修改版需以同一许可开放源码。
