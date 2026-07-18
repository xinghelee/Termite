import AppKit
import Foundation
import Observation
import SwiftTerm

/// 本地终端会话:持有一个 TermiteTerminalView(内嵌 PTY 子进程)。
/// 负责 shell 启动、OSC 133 命令跟踪(⌘↑/⌘↓ 跳转、复制输出、退出码/耗时)、
/// OSC 7 工作目录、标题、git 分支探测、会话录制与退出处理。
/// 生命周期跟随 SessionManager,不跟随视图 —— 切换标签不丢 scrollback。
@MainActor
@Observable
final class TerminalSession: Identifiable {
    enum State: Equatable {
        case running
        case exited(Int32?)
    }

    let id = UUID()
    let terminalView: TermiteTerminalView

    private(set) var state: State = .running
    private(set) var startedAt = Date()
    /// OSC 0/2 标题(shell 集成或程序设置)
    private(set) var title = ""
    /// 当前工作目录(OSC 7 上报)
    private(set) var workingDirectory: String?
    /// 当前 cwd 的 git 分支(直读 .git/HEAD,零子进程)
    private(set) var gitBranch: String?
    /// 未提交文件数(状态栏 ●n;非仓库为 nil)
    private(set) var gitDirtyCount: Int?
    /// 输出里检测到的最近一个本机服务 URL(dev server 场景,状态栏一键打开)
    private(set) var detectedLocalURL: String?
    /// 最近一条命令的退出码(需 OSC 133 shell 集成)
    private(set) var lastExitCode: Int?
    /// 最近一条命令的耗时(OSC 133 C→D)
    private(set) var lastCommandDuration: TimeInterval?
    /// 当前是否正在执行命令(OSC 133 C..D 之间)
    private(set) var runningCommand = false
    /// 当前命令开始执行的时间(驱动状态栏实时计时)
    private(set) var commandRunningSince: Date?
    /// 是否有可复制的命令输出(驱动菜单可用态)
    private(set) var hasCommandOutput = false
    /// 后台标签活动:非可见会话有新输出时点亮,聚焦后由 SessionManager 清除
    var hasUnseenActivity = false
    /// 命令时间线(OSC 133 完整周期的记录,新在后)
    private(set) var commandHistory: [CommandRecord] = []
    /// 当前正在录制到的文件 URL(nil = 未录制)
    private(set) var logURL: URL?
    var isLogging: Bool { logURL != nil }
    /// asciinema 录制中的 .cast 文件(nil = 未录制)
    private(set) var castURL: URL?
    var isCasting: Bool { castURL != nil }

    let shellPath: String
    var shellName: String { (shellPath as NSString).lastPathComponent }

    /// 标签 chip / 标题胶囊显示名:OSC 标题(压缩为最后一段目录)> cwd 目录名 > shell 名
    var displayTitle: String {
        if !title.isEmpty { return Self.compactTitle(title) }
        if let dir = workingDirectory {
            let short = (dir as NSString).abbreviatingWithTildeInPath
            return short == "~" ? "~" : (short as NSString).lastPathComponent
        }
        return shellName
    }

    /// shell 默认标题形如 "user@host:/full/path" 或纯路径 → 只留最后一段目录;
    /// 程序自定义标题(vim README.md 等)原样保留
    static func compactTitle(_ title: String) -> String {
        let path: Substring
        if let colon = title.lastIndex(of: ":"),
           let first = title[title.index(after: colon)...].first, first == "/" || first == "~" {
            path = title[title.index(after: colon)...]
        } else if title.hasPrefix("/") || title.hasPrefix("~") {
            path = title[...]
        } else {
            return title
        }
        let last = (String(path) as NSString).lastPathComponent
        return last.isEmpty ? String(path) : last
    }

    /// shell 进程退出时回调,由 SessionManager 设为关闭该 pane
    @ObservationIgnored var onProcessExit: (() -> Void)?
    /// 所属窗口的会话管理器(下拉终端会话为 nil)
    @ObservationIgnored weak var manager: SessionManager?

    @ObservationIgnored private var commandStartedAt: Date?
    /// 提示符位置标记(scroll-invariant 行号),⌘↑/⌘↓ 在命令间跳转
    @ObservationIgnored private var commandMarks: [Int] = []
    @ObservationIgnored private var pendingOutputStart: Int?
    @ObservationIgnored private var pendingPromptRow: Int?
    @ObservationIgnored private var pendingCommandText = ""
    /// scroll-invariant 行号的已知边界(增量探测,避免每个提示符全量扫描)
    @ObservationIgnored private var siLower = 0
    @ObservationIgnored private var siUpper = 0
    @ObservationIgnored private var osc133 = OSC133Scanner()
    @ObservationIgnored private var logHandle: FileHandle?
    @ObservationIgnored private var castHandle: FileHandle?
    @ObservationIgnored private var castStartedAt: Date?
    @ObservationIgnored private var gitProbeTask: Task<Void, Never>?
    @ObservationIgnored private var gitDirtyTask: Task<Void, Never>?
    @ObservationIgnored private var lastGitDirtyProbeAt = Date.distantPast

    init(workingDirectory directory: String? = nil, restoreScrollback: String? = nil) {
        shellPath = ShellResolver.loginShell()
        let view = TermiteTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        terminalView = view
        view.session = self
        view.font = FontPrefs.font()
        view.optionAsMetaKey = UserDefaults.standard.object(forKey: SettingsKeys.optionAsMeta) as? Bool ?? true
        view.allowMouseReporting = UserDefaults.standard.object(forKey: SettingsKeys.mouseReporting) as? Bool ?? true
        let scrollback = UserDefaults.standard.object(forKey: SettingsKeys.scrollbackLines) as? Int ?? 10_000
        view.getTerminal().changeScrollback(scrollback)
        ThemeStore.shared.apply(to: view)
        CursorPrefs.apply(to: view)
        // Metal 由 TermiteTerminalView 在挂进窗口后启用:
        // 离窗初始化 Metal 会导致恢复的会话渲染不刷新/光标异常
        view.processDelegate = self
        // 上次会话的屏幕内容:起 shell 之前灰字回灌,像 iTerm2 一样"从上次的位置继续"
        if let restoreScrollback, !restoreScrollback.isEmpty {
            let normalized = restoreScrollback.replacingOccurrences(of: "\n", with: "\r\n")
            let stamp = Date().formatted(date: .omitted, time: .shortened)
            view.feed(text: "\u{1b}[2m" + normalized + "\r\n─── 以上为上次会话内容 · \(stamp) 恢复 ───\u{1b}[0m\r\n")
        }
        start(in: directory)
    }

    private func start(in directory: String?) {
        var env = ShellResolver.environmentDict()
        let integrationEnabled = UserDefaults.standard.object(forKey: SettingsKeys.shellIntegration) as? Bool ?? true
        if integrationEnabled {
            ShellIntegration.apply(to: &env, shellPath: shellPath)
        }
        let cwd = directory ?? FileManager.default.homeDirectoryForCurrentUser.path
        workingDirectory = cwd
        probeGitBranch(cwd)
        terminalView.startProcess(
            executable: shellPath,
            args: [],
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: "-" + shellName,   // argv[0] 带 "-":登录 shell(与 Terminal.app 一致)
            currentDirectory: cwd
        )
    }

    /// 关闭 pane 时终止 shell 子进程。
    /// 交互式 zsh 默认忽略 SIGTERM(SwiftTerm terminate 只发 SIGTERM),
    /// 这里像 Terminal.app 一样先对整个进程组发 SIGHUP,连同前台命令一起挂断。
    func shutdown() {
        stopLogging()
        stopCasting()
        gitProbeTask?.cancel()
        if case .running = state {
            let pid = terminalView.process.shellPid
            if pid > 0 {
                kill(-pid, SIGHUP)
                kill(pid, SIGHUP)
                // SwiftTerm terminate 会先取消子进程监视器,没人收尸会留僵尸;后台阻塞 waitpid 收掉
                DispatchQueue.global(qos: .utility).async {
                    var status: Int32 = 0
                    waitpid(pid, &status, 0)
                }
            }
            terminalView.terminate()
        }
    }

    func focusTerminal() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    func sendText(_ text: String) {
        sendRawInput(Array(text.utf8))
    }

    func sendRawInput(_ bytes: [UInt8]) {
        terminalView.process.send(data: bytes[...])
    }

    /// 焦点 pane 的用户键入(TermiteTerminalView.send 回调)→ 广播到同标签其它 pane
    func didSendUserInput(_ bytes: [UInt8]) {
        manager?.broadcastInput(from: id, bytes: bytes)
    }

    /// ⌘K:清空回滚缓冲与屏幕(ED2 + ED3 + 归位),shell 下次重绘提示符
    func clearBuffer() {
        terminalView.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
        // 让 shell 重绘当前提示符(等价按下 ^L 的重绘,不产生新命令)
        sendRawInput([0x0c])
    }

    // MARK: - PTY 输出处理(OSC 133 标记流)

    /// 处理原始 PTY 输出:录制、扫描 OSC 133 事件,分段喂给终端,使标记与光标状态对齐
    func processOutput(_ bytes: ArraySlice<UInt8>) {
        // 下拉终端会话(manager nil)不参与活动提示
        if !hasUnseenActivity, let manager, !manager.isSessionVisible(id) {
            hasUnseenActivity = true
        }
        appendToLog(bytes)
        appendToCast(bytes)
        scanForLocalURL(bytes)
        let events = osc133.scan(bytes)
        if events.isEmpty {
            terminalView.feed(byteArray: bytes)
            return
        }
        var fed = bytes.startIndex
        for (event, offset) in events {
            let cut = bytes.startIndex + offset
            if cut > fed {
                terminalView.feed(byteArray: bytes[fed..<cut])
                fed = cut
            }
            handle(event)
        }
        if fed < bytes.endIndex {
            terminalView.feed(byteArray: bytes[fed...])
        }
    }

    private func handle(_ event: OSC133Scanner.Event) {
        switch event {
        case .promptStart:
            runningCommand = false
            recordCommandMark()
        case .commandStart:
            break
        case .outputStart:
            runningCommand = true
            commandStartedAt = Date()
            commandRunningSince = commandStartedAt
            SessionManagerRegistry.shared.updateDockBadge()
            let outputRow = currentScrollInvariantRow()
            pendingOutputStart = outputRow
            pendingPromptRow = commandMarks.last
            // 命令行文本 = 提示符行..输出起始行(含提示符前缀,原样展示)
            let textStart = pendingPromptRow ?? max(outputRow - 1, siLower)
            pendingCommandText = extractText(from: textStart, to: outputRow)
        case .commandEnd(let code):
            let duration = commandStartedAt.map { Date().timeIntervalSince($0) }
            commandStartedAt = nil
            commandRunningSince = nil
            runningCommand = false
            lastExitCode = code
            lastCommandDuration = duration
            recordCommand(code: code, duration: duration)
            notifyIfLongCommand(code: code, duration: duration)
            SessionManagerRegistry.shared.updateDockBadge()
            // 命令可能改了仓库状态(git/编辑器/构建都会),节流刷新脏计数
            if gitBranch != nil, let dir = workingDirectory {
                probeGitDirty(dir)
            }
        }
    }

    /// 后台长命令完成 → 系统通知(App 不活跃,或不是当前聚焦 pane)
    private func notifyIfLongCommand(code: Int?, duration: TimeInterval?) {
        let enabled = UserDefaults.standard.object(forKey: SettingsKeys.notifyLongCommand) as? Bool ?? true
        guard enabled, let duration, duration >= 10 else { return }
        let inForeground: Bool
        if let manager {
            inForeground = NSApp.isActive
                && SessionManagerRegistry.shared.active === manager
                && manager.selected === self
        } else {
            inForeground = NSApp.isActive // 下拉终端:App 前台即视为可见
        }
        guard !inForeground else { return }
        NotificationService.postCommandFinished(exitCode: code, duration: duration, title: displayTitle)
    }

    // MARK: - 命令位置标记(⌘↑/⌘↓ 跳转、复制输出)

    /// 增量刷新 scroll-invariant 行号边界:上界随输出前进,下界随 scrollback 修剪上移
    private func refreshScrollInvariantBounds() {
        let terminal = terminalView.getTerminal()
        while terminal.getScrollInvariantLine(row: siUpper) != nil { siUpper += 1 }
        while siLower < siUpper, terminal.getScrollInvariantLine(row: siLower) == nil { siLower += 1 }
        while terminal.getScrollInvariantLine(row: siLower - 1) != nil { siLower -= 1 }
    }

    /// 光标当前所在的 scroll-invariant 行号
    private func currentScrollInvariantRow() -> Int {
        refreshScrollInvariantBounds()
        let terminal = terminalView.getTerminal()
        let viewportTop = max(siLower, siUpper - terminal.rows)
        return viewportTop + terminal.buffer.y
    }

    private func recordCommandMark() {
        let row = currentScrollInvariantRow()
        if commandMarks.last != row {
            commandMarks.append(row)
            if commandMarks.count > 1000 { commandMarks.removeFirst(commandMarks.count - 1000) }
        }
    }

    /// 命令结束(OSC 133 D):落一条时间线记录
    private func recordCommand(code: Int?, duration: TimeInterval?) {
        guard let start = pendingOutputStart else { return }
        pendingOutputStart = nil
        let end = currentScrollInvariantRow()
        let record = CommandRecord(
            commandText: pendingCommandText,
            promptRow: pendingPromptRow,
            outputStart: start,
            outputEnd: end,
            exitCode: code,
            duration: duration,
            finishedAt: Date(),
            structured: detectStructured(start: start, end: end)
        )
        pendingPromptRow = nil
        pendingCommandText = ""
        commandHistory.append(record)
        if commandHistory.count > 200 { commandHistory.removeFirst(commandHistory.count - 200) }
        if end > start { hasCommandOutput = true }
        // 跨会话历史落盘(⌘⇧H 搜索与日报的数据源)
        CommandHistoryStore.shared.record(
            command: record.commandText,
            cwd: workingDirectory,
            exitCode: code,
            duration: duration,
            branch: gitBranch
        )
    }

    /// 嗅探输出是否结构化数据:只看首尾几行,避免大输出全量扫描。
    /// JSON:首行以 {/[ 起、末行以 }/] 收;CSV/TSV:前两行分隔符列数一致且 ≥2 列。
    private func detectStructured(start: Int, end: Int) -> StructuredOutputFormat? {
        guard end > start else { return nil }
        let terminal = terminalView.getTerminal()
        func text(_ row: Int) -> String {
            terminal.getScrollInvariantLine(row: row)?.translateToString(trimRight: true) ?? ""
        }
        var firstIndex = start
        while firstIndex < end, text(firstIndex).isEmpty { firstIndex += 1 }
        guard firstIndex < end else { return nil }
        let first = text(firstIndex).trimmingCharacters(in: .whitespaces)

        if first.hasPrefix("{") || first.hasPrefix("[") {
            var lastIndex = end - 1
            while lastIndex > firstIndex, text(lastIndex).isEmpty { lastIndex -= 1 }
            let last = text(lastIndex).trimmingCharacters(in: .whitespaces)
            return (last.hasSuffix("}") || last.hasSuffix("]")) ? .json : nil
        }

        guard firstIndex + 1 < end else { return nil }
        let second = text(firstIndex + 1)
        guard !second.isEmpty else { return nil }
        for (separator, format) in [("\t", StructuredOutputFormat.tsv), (",", .csv)] {
            let columns = first.components(separatedBy: separator).count
            if columns >= 2, second.components(separatedBy: separator).count == columns {
                return format
            }
        }
        return nil
    }

    /// 提取 scroll-invariant 行区间的纯文本(空行保留,尾部空行去掉)
    private func extractText(from start: Int, to end: Int) -> String {
        let terminal = terminalView.getTerminal()
        var lines: [String] = []
        for row in start..<end {
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            lines.append(line.translateToString(trimRight: true))
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// 某条命令的完整输出文本(scrollback 修剪后可能已不可用 → nil)
    func outputText(of record: CommandRecord) -> String? {
        refreshScrollInvariantBounds()
        let start = max(record.outputStart, siLower)
        guard record.outputEnd > start else { return nil }
        let text = extractText(from: start, to: record.outputEnd)
        return text.isEmpty ? nil : text
    }

    /// 同一条命令上一次运行的记录(输出 Diff 用)
    func previousRun(of record: CommandRecord) -> CommandRecord? {
        guard !record.commandText.isEmpty,
              let index = commandHistory.firstIndex(where: { $0.id == record.id }) else { return nil }
        return commandHistory[..<index].last { $0.commandText == record.commandText && $0.hasOutput }
    }

    /// 复制某条命令的完整输出;返回是否成功
    @discardableResult
    func copyOutput(of record: CommandRecord) -> Bool {
        guard let text = outputText(of: record) else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    /// 复制上一条有输出的命令的输出到剪贴板
    @discardableResult
    func copyLastCommandOutput() -> Bool {
        guard let last = commandHistory.last(where: { $0.outputEnd > $0.outputStart }) else { return false }
        return copyOutput(of: last)
    }

    /// 时间线点击:滚动到该命令的提示符处
    func scrollTo(record: CommandRecord) {
        refreshScrollInvariantBounds()
        let terminal = terminalView.getTerminal()
        let row = record.promptRow ?? record.outputStart
        guard row >= siLower else { return }
        let maxScrollback = max((siUpper - siLower) - terminal.rows, 1)
        let position = Double(row - siLower) / Double(maxScrollback)
        terminalView.scroll(toPosition: min(max(position, 0), 1))
    }

    /// ⌘↑:跳到当前视口上方最近的提示符
    func jumpToPreviousCommand() { jumpToCommand(direction: -1) }
    /// ⌘↓:跳到当前视口下方最近的提示符;没有更多则回到底部
    func jumpToNextCommand() { jumpToCommand(direction: 1) }

    private func jumpToCommand(direction: Int) {
        guard !commandMarks.isEmpty else { return }
        refreshScrollInvariantBounds()
        let terminal = terminalView.getTerminal()
        // 修剪后已失效的旧标记一并清掉
        commandMarks.removeAll { $0 < siLower }
        let currentTop = siLower + terminal.buffer.yDisp
        let target = direction < 0
            ? commandMarks.last(where: { $0 < currentTop })
            : commandMarks.first(where: { $0 > currentTop })
        guard let target else {
            if direction > 0 { terminalView.scroll(toPosition: 1) }
            return
        }
        let maxScrollback = max((siUpper - siLower) - terminal.rows, 1)
        let position = Double(target - siLower) / Double(maxScrollback)
        terminalView.scroll(toPosition: min(max(position, 0), 1))
    }

    // MARK: - 会话录制

    /// 开始把输出录制到文件(剥离颜色码,追加写)。写入头部一行元信息。
    @discardableResult
    func startLogging(to url: URL) -> Bool {
        stopLogging()
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        handle.seekToEndOfFile()
        let header = "# Termite session log · \(shellName) · \(Date().formatted())\n"
        handle.write(Data(header.utf8))
        logHandle = handle
        logURL = url
        return true
    }

    func stopLogging() {
        try? logHandle?.close()
        logHandle = nil
        logURL = nil
    }

    private func appendToLog(_ bytes: ArraySlice<UInt8>) {
        guard let logHandle, let text = String(bytes: bytes, encoding: .utf8) else { return }
        logHandle.write(Data(ANSI.strip(text).utf8))
    }

    // MARK: - asciinema 录制(.cast v2,原始转义流 + 时间戳)

    @discardableResult
    func startCasting(to url: URL) -> Bool {
        stopCasting()
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        let terminal = terminalView.getTerminal()
        handle.write(Data((CastFile.headerLine(width: terminal.cols, height: terminal.rows, timestamp: Date()) + "\n").utf8))
        castHandle = handle
        castStartedAt = Date()
        castURL = url
        return true
    }

    func stopCasting() {
        try? castHandle?.close()
        castHandle = nil
        castStartedAt = nil
        castURL = nil
    }

    private func appendToCast(_ bytes: ArraySlice<UInt8>) {
        guard let castHandle, let castStartedAt,
              let text = String(bytes: bytes, encoding: .utf8),
              let line = CastFile.eventLine(time: Date().timeIntervalSince(castStartedAt), data: text) else { return }
        castHandle.write(Data((line + "\n").utf8))
    }

    /// 会话缓冲区尾部快照(scrollback 恢复用)
    func scrollbackSnapshot(maxLines: Int = 2000) -> String? {
        refreshScrollInvariantBounds()
        let start = max(siLower, siUpper - maxLines)
        guard siUpper > start else { return nil }
        let text = extractText(from: start, to: siUpper)
        return text.isEmpty ? nil : text
    }

    // MARK: - 本机服务 URL 检测(dev server 输出里的 localhost 链接)

    @ObservationIgnored private var urlScanBuffer = ""
    private static let localURLRegex = try? NSRegularExpression(
        pattern: #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0)(?::\d+)?(?:/[^\s"'<>\)\]]*)?"#
    )

    private func scanForLocalURL(_ bytes: ArraySlice<UInt8>) {
        guard let regex = Self.localURLRegex,
              let text = String(bytes: bytes, encoding: .utf8) else { return }
        urlScanBuffer += text
        while let newline = urlScanBuffer.firstIndex(of: "\n") {
            let line = ANSI.strip(String(urlScanBuffer[..<newline]))
            urlScanBuffer.removeSubrange(urlScanBuffer.startIndex...newline)
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let matchRange = Range(match.range, in: line) {
                // 0.0.0.0 监听地址浏览器打不开,换成 localhost
                detectedLocalURL = String(line[matchRange])
                    .replacingOccurrences(of: "0.0.0.0", with: "localhost")
            }
        }
        if urlScanBuffer.count > 4096 {
            urlScanBuffer = String(urlScanBuffer.suffix(2048))
        }
    }

    // MARK: - git 分支探测

    private func probeGitBranch(_ path: String) {
        gitProbeTask?.cancel()
        gitProbeTask = Task { [weak self] in
            let branch = await Task.detached { GitProbe.branch(at: path) }.value
            guard !Task.isCancelled else { return }
            self?.gitBranch = branch
            if branch != nil {
                self?.probeGitDirty(path, force: true)
            } else {
                self?.gitDirtyCount = nil
            }
        }
    }

    /// 外部(分支切换等)触发的 git 信息强刷
    func refreshGitInfo() {
        guard let dir = workingDirectory else { return }
        probeGitBranch(dir)
        probeGitDirty(dir, force: true)
    }

    /// 未提交文件数探测(节流;命令结束/目录变化时刷)
    func probeGitDirty(_ path: String, force: Bool = false) {
        guard force || Date().timeIntervalSince(lastGitDirtyProbeAt) > 3 else { return }
        lastGitDirtyProbeAt = Date()
        gitDirtyTask?.cancel()
        gitDirtyTask = Task { [weak self] in
            let output = await GitService.run(["status", "--porcelain"], in: path)
            guard !Task.isCancelled else { return }
            guard let output else {
                self?.gitDirtyCount = nil
                return
            }
            self?.gitDirtyCount = output.components(separatedBy: "\n").filter { !$0.isEmpty }.count
        }
    }
}

// MARK: - LocalProcessTerminalViewDelegate

extension TerminalSession: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        self.title = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        // OSC 7 是 file:// URL;解析失败按原文处理
        let path: String
        if let url = URL(string: directory), url.scheme == "file" {
            path = url.path
        } else {
            path = directory
        }
        guard path != workingDirectory else { return }
        workingDirectory = path
        probeGitBranch(path)
        DirectoryHistory.shared.record(path: path)
        manager?.workingDirectoryChanged()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        state = .exited(exitCode)
        stopLogging()
        onProcessExit?()
    }
}

/// 一条完整的命令周期记录(OSC 133 C→D):驱动命令时间线面板
struct CommandRecord: Identifiable, Equatable {
    let id = UUID()
    /// 命令行文本(提示符行..输出起始行的原样内容,含提示符前缀)
    let commandText: String
    /// 提示符所在 scroll-invariant 行(跳转定位用)
    let promptRow: Int?
    /// 输出区间 [outputStart, outputEnd)
    let outputStart: Int
    let outputEnd: Int
    let exitCode: Int?
    let duration: TimeInterval?
    let finishedAt: Date
    /// 输出嗅探出的结构化格式(驱动状态栏「查看」按钮)
    var structured: StructuredOutputFormat?

    var hasOutput: Bool { outputEnd > outputStart }
    var succeeded: Bool { (exitCode ?? 0) == 0 }
}

/// 结构化输出格式
enum StructuredOutputFormat: String {
    case json, csv, tsv

    var separator: String { self == .tsv ? "\t" : "," }
    var label: String { self == .json ? "JSON" : String(localized: "表格") }
    var symbol: String { self == .json ? "curlybraces" : "tablecells" }
}

/// 直读 .git/HEAD 拿当前分支(零子进程):从 path 逐级向上找 .git。
/// 向上不越过家目录,减少对受 TCC 保护目录(文稿/桌面等)的主动触碰。
enum GitProbe {
    static func branch(at path: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dir = URL(fileURLWithPath: path)
        for _ in 0..<24 {
            if let branch = probeRepo(at: dir) { return branch }
            // 家目录和根目录是遍历上界(家目录本身极少是仓库,其下受保护目录不再触碰)
            if dir.path == home || dir.path == "/" { return nil }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
        return nil
    }

    private static func probeRepo(at dir: URL) -> String? {
        let gitPath = dir.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath.path, isDirectory: &isDirectory) else { return nil }
        let headURL: URL
        if isDirectory.boolValue {
            headURL = gitPath.appendingPathComponent("HEAD")
        } else {
            // worktree/submodule:.git 是一个 "gitdir: <path>" 文件
            guard let content = try? String(contentsOf: gitPath, encoding: .utf8),
                  let gitdir = content.split(separator: ":").dropFirst().first?
                      .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            let resolved = gitdir.hasPrefix("/")
                ? URL(fileURLWithPath: gitdir)
                : dir.appendingPathComponent(gitdir)
            headURL = resolved.appendingPathComponent("HEAD")
        }
        guard let head = try? String(contentsOf: headURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if head.hasPrefix("ref: refs/heads/") {
            return String(head.dropFirst("ref: refs/heads/".count))
        }
        return String(head.prefix(8)) // detached HEAD:短 hash
    }
}
