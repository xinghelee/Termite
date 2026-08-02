import AppKit
import SwiftTerm
import SwiftUI

/// 终端视图子类(内嵌本地 PTY):
/// - 粘贴保护:多行或含危险命令(sudo/rm -rf/dd/mkfs 等)先弹预览确认,设置可关
/// - 右键菜单(复制/粘贴/分屏/查找/复制上条输出)
/// - 选中即复制 / 中键粘贴(Unix 习惯,默认关)
/// - 拦截 PTY 输出交给会话做 OSC 133 命令跟踪与录制
final class TermiteTerminalView: LocalProcessTerminalView {
    /// 所属会话(命令跟踪/广播回调);由 TerminalSession 创建时注入
    weak var session: TerminalSession?
    /// 回放视图用:没有子进程,吞掉一切用户输入
    var inputEnabled = true
    /// Metal 只在视图挂进窗口后启用一次(离窗启用会渲染不刷新)
    private var metalConfigured = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureMetalIfReady()
        // 标签切换时视图此刻才挂进窗口:selectTab 里的 makeFirstResponder 那时 window 还是 nil,
        // 在这里把键盘焦点接过来(修「恢复后切标签无法输入」)
        if window != nil, let session, session.manager?.selected === session {
            window?.makeFirstResponder(self)
        }
        observeWindowKeyState()
        syncPtyWindowSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncPtyWindowSize()
        // Metal 下列数重算可能被排到下一渲染帧,补一次延迟同步兜底
        DispatchQueue.main.async { [weak self] in self?.syncPtyWindowSize() }
    }

    override func layout() {
        super.layout()
        configureMetalIfReady()
        syncPtyWindowSize()
    }

    /// Metal 只在「已挂窗 + 拿到真实尺寸」后启用一次:巡视模式滚动容器里
    /// 首挂载的视图初始 frame 可能为零,此刻建 Metal 渲染器绘制层是废的,
    /// 之后标脏也画不出来(表现:缓冲区有内容却永远空白)。没就位就等下一次布局
    private func configureMetalIfReady() {
        guard window != nil, !metalConfigured, bounds.width > 10, bounds.height > 10 else { return }
        metalConfigured = true
        // 默认开;设置可关,切换即时生效
        if UserDefaults.standard.object(forKey: SettingsKeys.metalRenderer) as? Bool ?? true {
            try? setUseMetal(true)
        }
    }

    /// 巡视/最大化布局切换后由 SessionManager 调用:视图在容器间搬家可能让
    /// Metal 渲染器停摆(缓冲区有内容、光标在,正文空白),关开一轮强制重建
    func restartMetalRenderer() {
        guard metalConfigured,
              UserDefaults.standard.object(forKey: SettingsKeys.metalRenderer) as? Bool ?? true else { return }
        try? setUseMetal(false)
        try? setUseMetal(true)
    }

    /// Metal 渲染路径下引擎不再回调 sizeChanged,PTY winsize 滞留在启动值
    /// (表现:视图 126 列而 ls 只看到 84 列 → 单列输出)。尺寸稳定后手动同步,按列行数去重。
    private var lastSyncedGrid = (cols: 0, rows: 0)

    func syncPtyWindowSize() {
        let terminal = getTerminal()
        guard terminal.cols != lastSyncedGrid.cols || terminal.rows != lastSyncedGrid.rows else { return }
        if let session, session.usesHostTransport {
            // 保活模式:LocalProcessTerminalView.sizeChanged 会因 process 未运行直接 return,
            // winsize 经协议发给守护进程
            lastSyncedGrid = (terminal.cols, terminal.rows)
            session.hostResize(cols: terminal.cols, rows: terminal.rows)
            return
        }
        guard process?.running == true else { return }
        lastSyncedGrid = (terminal.cols, terminal.rows)
        sizeChanged(source: self, newCols: terminal.cols, newRows: terminal.rows)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        // SwiftTerm 默认 .overlay:独立 NSScroller 脱离 NSScrollView 后 overlay 滑块
        // 永远不会绘制(显隐动画由 NSScrollView 私有管理),但宽度仍被预留,
        // 表现为右侧空白条且看不到滚动位置。legacy 样式可正常绘制(同 Berth #8)
        scrollerStyle = .legacy
        addGestureRecognizer(NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:))))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
        scrollerStyle = .legacy
        addGestureRecognizer(NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:))))
    }

    // MARK: - 捏合进出巡视模式(Safari 标签概览惯例:捏合=摊平总览,张开=还原)

    /// 一次手势只触发一次(阈值处切换,不等抬手,跟手感更好)
    private var magnifyTriggered = false

    @objc private func handleMagnify(_ recognizer: NSMagnificationGestureRecognizer) {
        switch recognizer.state {
        case .began:
            magnifyTriggered = false
        case .changed:
            guard !magnifyTriggered, let manager = session?.manager, let tab = manager.selectedTab else { return }
            if recognizer.magnification < -0.15, !tab.isCarousel, tab.root.leafIDs().count > 1 {
                magnifyTriggered = true
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { manager.toggleCarousel() }
            } else if recognizer.magnification > 0.15, tab.isCarousel {
                magnifyTriggered = true
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { manager.toggleCarousel() }
            }
        default:
            break
        }
    }

    deinit {
        windowKeyObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - ⌥点击定位光标(iTerm 惯例;issue #3 的 80/20 之一)

    /// 提示符下 ⌥点击把 zle 光标移到点击处:按与当前光标的格距发送 ←/→。
    /// 仅普通缓冲区且无鼠标上报时生效(vim/TUI 不受影响);折行命令按列数折算,
    /// 点过命令边界的多余方向键由 zle 自行截停
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option), event.clickCount == 1,
           inputEnabled, session != nil, moveCursorToClick(event) {
            return
        }
        super.mouseDown(with: event)
    }

    private func moveCursorToClick(_ event: NSEvent) -> Bool {
        let terminal = getTerminal()
        guard !terminal.isCurrentBufferAlternate, terminal.mouseMode == .off,
              terminal.cols > 0, terminal.rows > 0 else { return false }
        let optimal = getOptimalFrameSize()
        let cellWidth = optimal.width / CGFloat(terminal.cols)
        let cellHeight = optimal.height / CGFloat(terminal.rows)
        guard cellWidth > 0, cellHeight > 0 else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let col = max(0, min(terminal.cols - 1, Int(point.x / cellWidth)))
        let row = max(0, min(terminal.rows - 1, Int((bounds.height - point.y) / cellHeight)))
        // buffer.y 是光标在活动屏内的行号;回滚浏览历史时不换算、不动手
        let buffer = terminal.buffer
        let delta = (row - buffer.y) * terminal.cols + (col - buffer.x)
        guard delta != 0 else { return true }
        let arrow = delta > 0
            ? (terminal.applicationCursor ? "\u{1b}OC" : "\u{1b}[C")
            : (terminal.applicationCursor ? "\u{1b}OD" : "\u{1b}[D")
        session?.sendRawInput(Array(String(repeating: arrow, count: min(abs(delta), 500)).utf8))
        return true
    }

    // MARK: - 拖文件进终端:插入 shell 转义后的路径

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else { return false }
        let text = urls.map { Self.shellEscaped($0.path) }.joined(separator: " ")
        session?.sendText(text + " ")
        window?.makeFirstResponder(self)
        return true
    }

    /// 路径 shell 转义:安全字符集内原样,否则单引号包裹(内部 ' → '\'')
    static func shellEscaped(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+=:@%~")
        if path.unicodeScalars.allSatisfy({ safe.contains($0) }) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - PTY 数据拦截

    override func dataReceived(slice: ArraySlice<UInt8>) {
        if let session {
            // 会话负责扫描 OSC 133 标记并分段回喂,保证标记与光标状态对齐
            session.processOutput(slice)
        } else {
            super.dataReceived(slice: slice)
        }
    }

    /// 独立 BEL(SwiftTerm 解析器只在 C0 响铃时回调,OSC 终止符不算):
    /// TUI 主动请求注意 → pane 注意力系统
    override func bell(source: Terminal) {
        super.bell(source: source)
        session?.bellReceived()
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard inputEnabled else { return }
        pauseCursorBlinkForInput()
        if let session {
            // 输入统一交给会话路由:保活走协议、本地走 LocalProcess,
            // 传输未就绪时先缓冲(直接 super.send 会打进未启动的进程丢掉)
            session.sendRawInput(Array(data))
            session.didSendUserInput(Array(data))
        } else {
            super.send(source: source, data: data)
        }
    }

    // MARK: - 输入时暂停光标闪烁

    /// Metal 光标闪烁是渲染器里自由运转的 0.7s 定时器,按键不重置相位:
    /// 左右键移动光标时若恰逢"灭"半周期,光标要过大半秒才在新位置亮起,看着像闪没了。
    /// (打字没这问题,是因为回显重绘常伴随 DECTCEM 隐/显光标,顺带重置了定时器。)
    /// 仿 xterm/iTerm:有输入就把闪烁样式临时换成同形状的稳定样式(常亮),
    /// 停止输入一段时间后换回,闪烁从"亮"相位重启。CG 与 Metal 两条渲染路径同时生效。
    var blinkResumeDelay: TimeInterval = 0.7
    private var blinkRestoreWork: DispatchWorkItem?
    private var blinkStyleToRestore: CursorStyle?

    private func pauseCursorBlinkForInput() {
        let terminal = getTerminal()
        let current = terminal.options.cursorStyle
        if let saved = blinkStyleToRestore, Self.steadyVariant(of: saved) != current {
            // 暂停期间样式被外部改过(TUI 的 DECSCUSR 或设置面板),放弃旧值按当前样式重新判断
            blinkStyleToRestore = nil
        }
        if blinkStyleToRestore == nil {
            guard let steady = Self.steadyVariant(of: current) else {
                blinkRestoreWork?.cancel()
                blinkRestoreWork = nil
                return
            }
            blinkStyleToRestore = current
            terminal.setCursorStyle(steady)
        }
        blinkRestoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.resumeCursorBlink() }
        blinkRestoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + blinkResumeDelay, execute: work)
    }

    private func resumeCursorBlink() {
        blinkRestoreWork = nil
        guard let blink = blinkStyleToRestore else { return }
        blinkStyleToRestore = nil
        let terminal = getTerminal()
        // 只在样式仍是我们换上的稳定样式时才换回;期间被外部改过就不抢
        guard terminal.options.cursorStyle == Self.steadyVariant(of: blink) else { return }
        terminal.setCursorStyle(blink)
    }

    private static func steadyVariant(of style: CursorStyle) -> CursorStyle? {
        switch style {
        case .blinkBlock: return .steadyBlock
        case .blinkUnderline: return .steadyUnderline
        case .blinkBar: return .steadyBar
        default: return nil
        }
    }

    // MARK: - 只有聚焦 pane 的光标闪烁

    /// SwiftTerm 失焦时画空心光标,但闪烁定时器不看焦点,「灭」相位连空心框
    /// 一起消失——多分屏时满屏光标齐闪。失焦把样式换成同形状常亮(Metal 的
    /// 闪烁定时器随样式停掉),聚焦时还原。
    private var focusStyleToRestore: CursorStyle?
    /// becomeFirstResponder 在 SwiftTerm 里是 public 不可再覆写,
    /// 改为 KVO 窗口 firstResponder(SwiftTerm 的 override 先跑,hasFocus 已就绪)
    private var firstResponderObservation: NSKeyValueObservation?

    /// internal 供测试直接驱动(单测里视图不在真实响应者链上)
    func applyFocusCursorStyle(focused: Bool) {
        let terminal = getTerminal()
        // 两套「临时常亮」机制不叠加:焦点切换时先结清输入暂停态,
        // 真正的闪烁样式若被暂停机制存着,从那里取回
        blinkRestoreWork?.cancel()
        blinkRestoreWork = nil
        let pausedBlink = blinkStyleToRestore
        blinkStyleToRestore = nil
        if focused {
            guard let saved = focusStyleToRestore else { return }
            focusStyleToRestore = nil
            // 失焦期间样式被外部(TUI 的 DECSCUSR)改过就不抢
            if terminal.options.cursorStyle == Self.steadyVariant(of: saved) {
                terminal.setCursorStyle(saved)
            }
        } else {
            let current = pausedBlink ?? terminal.options.cursorStyle
            guard let steady = Self.steadyVariant(of: current) else { return }
            focusStyleToRestore = current
            terminal.setCursorStyle(steady)
        }
    }

    /// 光标偏好变更后重新按当前焦点态整形(CursorPrefs.applyToAllSessions 调用)
    func reassertCursorFocusState() {
        focusStyleToRestore = nil
        applyFocusCursorStyle(focused: hasFocus)
    }

    /// 窗口失去/夺回 key 时同样只让聚焦 pane 闪(hasFocus 已含 isKeyWindow 判断)
    private var windowKeyObservers: [NSObjectProtocol] = []

    private func observeWindowKeyState() {
        windowKeyObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowKeyObservers = []
        firstResponderObservation = nil
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applyFocusCursorStyle(focused: self.hasFocus)
                }
            }
            windowKeyObservers.append(token)
        }
        firstResponderObservation = window.observe(\.firstResponder, options: [.old, .new]) { [weak self] _, change in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 只关心涉及本视图的焦点进出
                let old = change.oldValue ?? nil
                let new = change.newValue ?? nil
                guard old === self || new === self else { return }
                self.applyFocusCursorStyle(focused: self.hasFocus)
            }
        }
    }

    // MARK: - 右键菜单

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        // SwiftTerm 未实现菜单校验,自动校验会把自定义项判为禁用;这里手动管理启用态
        menu.autoenablesItems = false

        // 右键点在 file:line 引用上:首项直达编辑器
        if let (path, match) = fileLink(at: event) {
            pendingFileLink = (path, match.line, match.column)
            let display = (path as NSString).lastPathComponent + (match.line.map { ":\($0)" } ?? "")
            let openItem = NSMenuItem(title: String(localized: "在编辑器中打开 \(display)"), action: #selector(termiteOpenFileLink), keyEquivalent: "")
            openItem.target = self
            openItem.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
            menu.addItem(openItem)
            menu.addItem(.separator())
        }

        let copyItem = NSMenuItem(title: String(localized: "复制"), action: #selector(copy(_:)), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: String(localized: "粘贴"), action: #selector(paste(_:)), keyEquivalent: "v")
        pasteItem.target = self
        menu.addItem(pasteItem)

        menu.addItem(.separator())

        let hItem = NSMenuItem(title: String(localized: "左右分屏"), action: #selector(termiteSplitHorizontal), keyEquivalent: "d")
        hItem.target = self
        hItem.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
        menu.addItem(hItem)

        let vItem = NSMenuItem(title: String(localized: "上下分屏"), action: #selector(termiteSplitVertical), keyEquivalent: "d")
        vItem.keyEquivalentModifierMask = [.command, .shift]
        vItem.target = self
        vItem.image = NSImage(systemSymbolName: "rectangle.split.1x2", accessibilityDescription: nil)
        menu.addItem(vItem)

        let worktreeItem = NSMenuItem(title: String(localized: "在新 Worktree 中分屏…"), action: #selector(termiteSplitWorktree), keyEquivalent: "")
        worktreeItem.target = self
        worktreeItem.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        menu.addItem(worktreeItem)

        // cwd 在链接 worktree 里才出现清理项
        if let cwd = session?.workingDirectory, WorktreeService.linkedWorktreeRoot(of: cwd) != nil {
            let cleanupItem = NSMenuItem(title: String(localized: "清理此 Worktree(移除并关闭)…"), action: #selector(termiteCleanupWorktree), keyEquivalent: "")
            cleanupItem.target = self
            cleanupItem.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
            menu.addItem(cleanupItem)
        }

        let renameItem = NSMenuItem(title: String(localized: "重命名分屏…"), action: #selector(termiteRenamePane), keyEquivalent: "")
        renameItem.target = self
        renameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        menu.addItem(renameItem)

        let closePaneItem = NSMenuItem(title: String(localized: "关闭此分屏"), action: #selector(termiteClosePane), keyEquivalent: "")
        closePaneItem.target = self
        closePaneItem.image = NSImage(systemSymbolName: "xmark.rectangle", accessibilityDescription: nil)
        menu.addItem(closePaneItem)

        menu.addItem(.separator())

        let copyOutputItem = NSMenuItem(title: String(localized: "复制上条命令输出"), action: #selector(termiteCopyLastOutput), keyEquivalent: "")
        copyOutputItem.target = self
        copyOutputItem.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)
        menu.addItem(copyOutputItem)

        let revealItem = NSMenuItem(title: String(localized: "在 Finder 中显示"), action: #selector(termiteRevealInFinder), keyEquivalent: "")
        revealItem.target = self
        revealItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(revealItem)

        let findItem = NSMenuItem(title: String(localized: "查找…"), action: #selector(termiteFind), keyEquivalent: "f")
        findItem.target = self
        menu.addItem(findItem)

        menu.items.forEach { $0.isEnabled = true }
        // 无可复制输出时禁用该项
        MainActor.assumeIsolated {
            copyOutputItem.isEnabled = SessionManager.shared.selected?.hasCommandOutput ?? false
            // 不在 git 仓库里没有 worktree 可分
            worktreeItem.isEnabled = session?.gitBranch != nil
        }
        return menu
    }

    @objc private func termiteCopyLastOutput() {
        MainActor.assumeIsolated { _ = SessionManager.shared.selected?.copyLastCommandOutput() }
    }

    @objc private func termiteRevealInFinder() {
        MainActor.assumeIsolated {
            let dir = session?.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
        }
    }

    @objc private func termiteSplitHorizontal() {
        MainActor.assumeIsolated { SessionManager.shared.splitFocused(axis: .horizontal) }
    }

    @objc private func termiteSplitVertical() {
        MainActor.assumeIsolated { SessionManager.shared.splitFocused(axis: .vertical) }
    }

    @objc private func termiteClosePane() {
        MainActor.assumeIsolated { SessionManager.shared.requestCloseCurrent() }
    }

    /// 在新 worktree 中分屏:呼出 pane 内浮层(输入分支名 + 方向,回车即建)
    @objc private func termiteSplitWorktree() {
        MainActor.assumeIsolated {
            guard let session, session.gitBranch != nil else { return }
            session.worktreePromptPresented = true
        }
    }

    /// 清理当前 worktree:确认后 git worktree remove + 关闭分屏(分支保留)
    @objc private func termiteCleanupWorktree() {
        MainActor.assumeIsolated {
            guard let session else { return }
            let alert = NSAlert()
            alert.messageText = String(localized: "移除此 Worktree?")
            alert.informativeText = String(localized: "将运行 git worktree remove 并关闭该分屏;分支保留,合并后可自行删除。有未提交改动时会先失败。")
            alert.addButton(withTitle: String(localized: "移除并关闭"))
            alert.addButton(withTitle: String(localized: "取消"))
            guard alert.runModal() == .alertFirstButtonReturn else {
                window?.makeFirstResponder(self)
                return
            }
            SessionManager.shared.removeWorktreeAndClose(session)
        }
    }

    /// 重命名分屏(reddit 用户建议):同目录多 agent 靠名字区分,
    /// 名字流经 chip / 菜单栏等待列表 / 系统通知 / 巡视徽标所有出口
    @objc private func termiteRenamePane() {
        MainActor.assumeIsolated {
            guard let session else { return }
            let alert = NSAlert()
            alert.messageText = String(localized: "重命名分屏")
            alert.informativeText = String(localized: "留空恢复自动标题(目录 / 程序名)。")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.stringValue = session.customName ?? ""
            field.placeholderString = session.displayTitle
            alert.accessoryView = field
            alert.addButton(withTitle: String(localized: "确定"))
            alert.addButton(withTitle: String(localized: "取消"))
            alert.window.initialFirstResponder = field
            if alert.runModal() == .alertFirstButtonReturn {
                session.setCustomName(field.stringValue)
            }
            window?.makeFirstResponder(self)
        }
    }

    @objc private func termiteFind() {
        MainActor.assumeIsolated { SessionManager.shared.requestSearch() }
    }

    // MARK: - file:line 点击跳转

    private var pendingFileLink: (path: String, line: Int?, column: Int?)?

    @objc private func termiteOpenFileLink() {
        guard let link = pendingFileLink else { return }
        EditorLauncher.open(path: link.path, line: link.line, column: link.column)
    }

    /// 屏幕点 → (终端列, 可视区行)。SwiftTerm 未公开 cellDimension,借 caretFrame 的尺寸(恒等于单元格)
    private func hitCell(_ event: NSEvent) -> (col: Int, row: Int)? {
        let cell = caretFrame.size
        guard cell.width > 0, cell.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let col = Int(point.x / cell.width)
        let row = Int((frame.height - point.y) / cell.height)
        guard col >= 0, row >= 0 else { return nil }
        return (col, row)
    }

    /// 事件位置命中 file:line 且文件真实存在时返回(绝对路径, 匹配)
    private func fileLink(at event: NSEvent) -> (path: String, match: FileLinkDetector.Match)? {
        guard let (col, row) = hitCell(event),
              let line = getTerminal().getLine(row: row) else { return nil }
        let text = line.translateToString(trimRight: true)
        guard let match = FileLinkDetector.match(in: text, column: col) else { return nil }
        let cwd = MainActor.assumeIsolated { session?.workingDirectory }
        return FileLinkDetector.resolve(match, cwd: cwd).map { ($0, match) }
    }

    @discardableResult
    private func handleFileLinkClick(_ event: NSEvent) -> Bool {
        guard let (path, match) = fileLink(at: event) else { return false }
        EditorLauncher.open(path: path, line: match.line, column: match.column)
        return true
    }

    // MARK: - IME 组词期间隐藏光标

    /// 中文等输入法组词时,SwiftTerm 在光标处叠加拼音预览浮层,但光标仍留在原地:
    /// CG 路径是 CaretView 子视图,Metal 路径画在 MTKView 纹理里,TUI(如 Claude Code)
    /// 还会自绘反色块。拼音浮层比单元格矮几像素,光标会从浮层上下两端露出。
    /// 组词期间隐藏 CaretView,并用背景色遮罩盖住整个光标格,提交/取消后恢复。
    private var imeComposing = false

    /// 盖在光标格上的背景色遮罩:Metal 自绘光标和 TUI 反色块不是 AppKit 视图,
    /// 藏不掉,只能在拼音浮层之下压一层背景色,连同浮层盖不到的上下边缘一起遮住
    private lazy var imeCursorCover: NSView = {
        let v = NSView()
        v.identifier = NSUserInterfaceItemIdentifier("imeCursorCover")
        v.wantsLayer = true
        return v
    }()

    /// 只在组词状态切换时对已挂载的 caret 生效;TUI 每帧都会经 DECTCEM 隐藏/显示光标,
    /// caret 被反复 removeFromSuperview/addSubview,组词开始那一刻它可能不在视图树里,
    /// 所以还需要 addSubview 兜底同步。
    private func applyCompositionCaretState() {
        // Metal 渲染时 AppKit caret 本来就是隐藏的(光标由 Metal 画),
        // 组词结束在这里解除隐藏会变成双光标,不能碰
        if !isUsingMetalRenderer {
            for sub in subviews where String(describing: type(of: sub)) == "CaretView" {
                sub.isHidden = imeComposing
            }
        }
        updateCursorCover()
    }

    private func updateCursorCover() {
        guard imeComposing else {
            imeCursorCover.removeFromSuperview()
            return
        }
        imeCursorCover.layer?.backgroundColor = nativeBackgroundColor.cgColor
        imeCursorCover.frame = caretFrame
        // 压在拼音浮层之下、其余一切(MTKView/CaretView/CG 内容)之上
        if let overlay = subviews.first(where: { $0 is NSTextField }) {
            addSubview(imeCursorCover, positioned: .below, relativeTo: overlay)
        } else {
            addSubview(imeCursorCover, positioned: .above, relativeTo: nil)
        }
    }

    override func addSubview(_ view: NSView) {
        super.addSubview(view)
        guard !isUsingMetalRenderer else { return }
        if String(describing: type(of: view)) == "CaretView" {
            view.isHidden = imeComposing
        }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        imeComposing = hasMarkedText()
        applyCompositionCaretState()
        // 拼音浮层默认 90% 透明背景,TUI 自绘的反色块光标会从底下透出来,改成不透明
        if imeComposing,
           let overlay = subviews.first(where: { $0 is NSTextField }) as? NSTextField,
           let bg = overlay.backgroundColor {
            overlay.backgroundColor = bg.withAlphaComponent(1)
        }
    }

    override func unmarkText() {
        super.unmarkText()
        imeComposing = false
        applyCompositionCaretState()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        imeComposing = false
        applyCompositionCaretState()
    }

    // MARK: - 选中即复制 / 中键粘贴

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        // ⌘点击输出里的 file:line(如 src/main.swift:42、traceback)→ 编辑器打开;
        // 放在 super 之后:URL 链接点击已被 SwiftTerm 消费,这里只处理它不认识的文件引用
        if event.modifierFlags.contains(.command), handleFileLinkClick(event) { return }
        // 选中即复制(Unix 习惯,默认关):拖选结束后有选区就写入剪贴板
        let enabled = UserDefaults.standard.bool(forKey: SettingsKeys.copyOnSelect)
        guard enabled, let text = getSelection(), !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    override func otherMouseUp(with event: NSEvent) {
        // 中键粘贴(默认关):粘贴剪贴板内容,仍走粘贴保护
        if event.buttonNumber == 2,
           UserDefaults.standard.bool(forKey: SettingsKeys.middleClickPaste) {
            paste(self)
            return
        }
        super.otherMouseUp(with: event)
    }

    // MARK: - 粘贴保护

    override func paste(_ sender: Any) {
        let enabled = UserDefaults.standard.object(forKey: SettingsKeys.pasteProtection) as? Bool ?? true
        guard enabled,
              let text = NSPasteboard.general.string(forType: .string),
              Self.needsConfirmation(text) else {
            super.paste(sender)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "确认粘贴到终端?")
        alert.informativeText = Self.preview(text)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "粘贴"))
        alert.addButton(withTitle: String(localized: "取消"))
        if alert.runModal() == .alertFirstButtonReturn {
            super.paste(sender)
        }
    }

    /// 多行,或单行但含高危命令片段
    static func needsConfirmation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("\n") { return true }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("sudo ") { return true }
        let dangerous = ["rm -rf", "rm -fr", "mkfs", "dd if=", "shutdown", "reboot", ":(){", "> /dev/sd", "chmod -r 777 /"]
        return dangerous.contains { lower.contains($0) }
    }

    static func preview(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var shown = lines.prefix(12).joined(separator: "\n")
        if lines.count > 12 {
            shown += "\n…"
        }
        let header = lines.count > 1 ? String(localized: "共 \(lines.count) 行:\n\n") : ""
        return String((header + shown).prefix(1200))
    }
}
