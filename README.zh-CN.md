<p align="center">
  <img src="docs/assets/readme-logo.png" alt="Termite Logo" width="1000">
</p>

<h1 align="center">Termite</h1>

<p align="center">
  <strong>为 macOS 打造的原生终端，也是并行 AI 开发工作流的控制台。</strong>
</p>

<p align="center">
  <a href="README.md">English</a>
  ·
  <a href="https://github.com/xinghelee/Termite/releases/latest">下载最新版</a>
  ·
  <a href="#安装">安装</a>
  ·
  <a href="#从源码构建">从源码构建</a>
</p>

<p align="center">
  <a href="https://github.com/xinghelee/Termite/releases/latest"><img src="https://img.shields.io/github/v/release/xinghelee/Termite?display_name=tag&label=release&color=F2A93B" alt="最新发行版"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-111827?logo=apple" alt="需要 macOS 26 或更高版本">
  <img src="https://img.shields.io/badge/iOS%20%2F%20iPadOS-17%2B-111827?logo=apple" alt="移动端支持 iOS 和 iPadOS 17 或更高版本">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-0E8A16" alt="GPL-3.0 许可"></a>
</p>

<p align="center">
  <img src="docs/assets/hero-overview.png" alt="Termite 的四分屏工作区：终端、系统监控与两个 AI 编程 Agent 并行运行" width="1180">
</p>

https://github.com/user-attachments/assets/90299472-69d9-404d-922c-5f0d741ee5c3

> 视频演示 iPhone 通过受信任的局域网或 Tailscale 私有网络连接 Mac，实时查看并操作 Mac 上运行的 iOS 模拟器。兼容性：Mac 端需要 **macOS 26.0 或更高版本**；移动端支持 **iOS / iPadOS 17.0 或更高版本**，兼容 iPhone 与 iPad。

Termite 把终端、可嵌套分屏、Shell 感知的命令历史、Git 工作流与私有网络远程访问整合为一个原生 macOS 工作区。它的重点不是再打开更多终端窗口，而是让并行任务始终可见、可切换、可接管。

适合同时推进规划、实现、测试与审查的个人开发者和团队：给每个 AI Agent 一块独立分屏或一个 `git worktree`，在同一工作区中跟进状态、处理输入并完成 Git 操作。

## 一眼掌握并行工作

Termite 的分屏可以继续嵌套；巡视模式会将当前标签页的所有分屏平铺为等宽列。滑到哪个任务，键盘焦点就跟到哪里。配合输入提醒、广播输入和会话恢复，多任务不会变成一堆失焦的窗口。

- 用 <kbd>⌘D</kbd> / <kbd>⇧⌘D</kbd> 创建左右或上下分屏，再按 <kbd>⇧⌘\</kbd> 进入巡视模式。
- Agent 等待输入时，分屏、菜单栏与系统通知会提示；<kbd>⌘J</kbd> 跳到等待最久的任务。
- 新标签继承当前目录；重启后恢复窗口、标签、分屏布局、焦点与滚动历史。
- 从分屏菜单直接为任务新建或打开独立 `git worktree`，避免并行改动共用工作目录。

## 产品预览

<table>
  <tr>
    <td width="38%" valign="middle">
      <h3>巡视分屏</h3>
      在一个标签页中同时查看终端、运行状态和多个 Agent。巡视时可按触控板手势或 <code>⌘←</code> / <code>⌘→</code> 逐个切换，焦点随观察对象移动。
    </td>
    <td width="62%">
      <img src="docs/assets/panes-overview.png" alt="Termite 四分屏与 Agent 工作区" width="100%">
    </td>
  </tr>
  <tr>
    <td width="38%" valign="middle">
      <h3>终端旁完成 Git 工作</h3>
      独立提交图窗口展示分支泳道、提交记录和文件 Diff。无需切换到另一款客户端，就能在当前任务上下文中检查历史、切换分支、暂存或回退改动。
    </td>
    <td width="62%">
      <img src="docs/assets/git-history.png" alt="Termite Git 提交图与分支泳道" width="100%">
    </td>
  </tr>
  <tr>
    <td width="38%" valign="middle">
      <h3>可信网络中的远程访问</h3>
      在 Mac 的“设置 → 远程访问”中开启服务，通过一次性配对码让 iPhone、iPad 或浏览器接入。局域网地址可见，访问凭据始终应视为终端权限的一部分。
    </td>
    <td width="62%">
      <img src="docs/assets/remote-access.png" alt="Termite 的远程访问设置，显示局域网配对和本地端口转发" width="100%">
    </td>
  </tr>
  <tr>
    <td width="38%" valign="middle">
      <h3>手机上的终端与模拟器</h3>
      连接后，可从 iPhone 或 iPad 浏览会话、接管输入，并查看 Mac 上的模拟器。移动端保留快捷控制键与完整软键盘，离开桌面也能继续处理任务。
    </td>
    <td width="62%" align="center">
      <img src="docs/assets/mobile-pairing.png" alt="Termite iPhone 客户端的 Mac 配对页面" width="43%">
      <img src="docs/assets/mobile-simulator.png" alt="Termite iPhone 客户端上的实时 Mac 会话与模拟器控制" width="43%">
    </td>
  </tr>
</table>

> 以上均为当前版本的真实界面，账户信息、局域网地址和本地演示路径按原图展示。远程访问截图中的二维码与 URL 使用不可用的演示凭据，避免公开可能仍有效的终端访问密钥。

## 终端，不只显示字符

Termite 自动启用或注入 zsh、bash、fish 的 Shell 集成，无需修改 dotfiles。它使用 OSC 133 标记理解每条命令的开始、结束、退出码和输出边界，让终端历史成为可导航、可搜索、可复用的数据。

- <kbd>⌘↑</kbd> / <kbd>⌘↓</kbd> 在命令之间跳转，<kbd>⇧⌘C</kbd> 复制上一条命令的输出。
- 状态栏显示退出码、耗时、当前目录与 Git 分支；后台长命令结束时发送通知。
- 历史记录持久化到 SQLite，可通过 <kbd>⇧⌘H</kbd> 跨会话搜索，或生成日报回顾一天的命令。
- 支持终端内图片、输出 Diff、结构化输出、asciinema 录制与回放、选中即复制及高风险粘贴确认。

## 保持在当前上下文的开发工具

- **Git 面板**：按 <kbd>⌘G</kbd> 打开提交图、词级 Diff、Blame 和单文件历史；支持暂存、取消暂存、丢弃、切换分支、Cherry-pick 与 Revert。
- **工作区导航**：<kbd>⌘P</kbd> 命令面板、<kbd>⌘O</kbd> 目录跳转、<kbd>⇧⌘E</kbd> 文件浏览器、项目侧边栏和端口管理。
- **原生 macOS 体验**：20 套主题覆盖整个窗口；全局下拉终端默认使用 <kbd>⌃⌥⌘Space</kbd>；可安装 `termite` 命令或把文件夹拖到 Dock 图标上打开。

## 远程访问：仅限你信任的网络

远程访问默认关闭，面向局域网、Tailscale 等受信任的私有网络。已配对设备可以实时查看会话；一台移动设备可接管输入，Mac 随时可以收回控制权。也可以把仅监听 `127.0.0.1` 的本机开发服务转发给已配对设备。

访问链接、二维码和配对码都等同于终端访问权。请只在受信任网络中开启；如果凭据可能泄露，请立即在设置中重新生成密钥。

## 常用快捷键

| 操作 | 快捷键 |
| --- | --- |
| 新建标签 / 左右分屏 / 上下分屏 | <kbd>⌘T</kbd> / <kbd>⌘D</kbd> / <kbd>⇧⌘D</kbd> |
| 在分屏间移动焦点 | <kbd>⌥⌘←</kbd> <kbd>⌥⌘→</kbd> <kbd>⌥⌘↑</kbd> <kbd>⌥⌘↓</kbd> |
| 最大化当前分屏 / 巡视分屏 | <kbd>⇧⌘↩</kbd> / <kbd>⇧⌘\</kbd> |
| 聚焦等待输入的分屏 | <kbd>⌘J</kbd> |
| 命令面板 / 目录跳转 / 命令时间线 | <kbd>⌘P</kbd> / <kbd>⌘O</kbd> / <kbd>⌘I</kbd> |
| Git 面板 / 文件浏览器 / 历史搜索 | <kbd>⌘G</kbd> / <kbd>⇧⌘E</kbd> / <kbd>⇧⌘H</kbd> |
| 复制上一条命令输出 / 广播输入 | <kbd>⇧⌘C</kbd> / <kbd>⌥⌘B</kbd> |

更多操作可通过 <kbd>⌘P</kbd> 搜索，或在应用菜单中查看。

## 安装

### 下载发行版

从 [GitHub Releases](https://github.com/xinghelee/Termite/releases/latest) 下载最新 DMG，并将 Termite 拖入“应用程序”文件夹。

### Homebrew

```sh
brew install --cask xinghelee/tap/termite
```

### 从命令行打开目录

在“设置 → 通用 → 命令行工具”中安装 `termite` 后，可从任意位置在 Termite 中打开目录：

```sh
termite ~/Developer/my-project
```

zsh 的 Shell 集成会提供同名函数；安装到 `/usr/local/bin` 后，bash、fish 和脚本环境也可以使用该命令。

## 从源码构建

### 环境要求

- macOS 26.0 或更高版本
- 安装 macOS 26 SDK 的 Xcode
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

```sh
git clone https://github.com/xinghelee/Termite.git
cd Termite

xcodegen generate
xcodebuild -project Termite.xcodeproj -scheme Termite -configuration Debug build
xcodebuild -project Termite.xcodeproj -scheme Termite -destination 'platform=macOS' test
```

也可以运行 `open Termite.xcodeproj`，在 Xcode 中选择 `Termite` scheme 后构建和运行。

## 项目结构

```text
Termite/          macOS 应用：终端、会话、Git、工作区与设置
TermiteMobile/    iPhone 和 iPad 远程客户端
PtyHostDaemon/    PTY 守护进程
PtyHostShared/    应用与守护进程共享的本地 socket 协议
RemoteWeb/        内置远程访问 Web 客户端
TermiteTests/     单元测试
docs/assets/      产品截图与移动端演示
```

Termite 基于 SwiftUI 和 AppKit 构建，使用 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 提供终端与 Metal 渲染能力，并通过 XcodeGen 管理工程。为提供完整的文件系统与进程能力，macOS 应用不使用 App Sandbox。

## 参与贡献

欢迎提交 Issue 和 Pull Request。报告问题时，请提供复现步骤、Termite 版本、macOS 版本、Shell 类型，以及必要时脱敏后的终端输出。提交代码前，请运行与改动相关的测试，并避免提交可由 XcodeGen 重新生成的 `Termite.xcodeproj` 或 `DerivedData` 文件。

产品目标与技术取舍见 [DESIGN.md](DESIGN.md)。

## 许可

本项目以 [GNU GPL v3.0](LICENSE) 发布。你可以自由使用、修改和再分发；分发修改版本时，须以相同许可提供对应源代码。
