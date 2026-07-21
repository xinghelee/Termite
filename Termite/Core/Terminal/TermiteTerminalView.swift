import AppKit
import SwiftTerm

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
        if window != nil, !metalConfigured {
            metalConfigured = true
            // 默认开;设置可关,切换即时生效
            if UserDefaults.standard.object(forKey: SettingsKeys.metalRenderer) as? Bool ?? true {
                try? setUseMetal(true)
            }
        }
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
        syncPtyWindowSize()
    }

    /// Metal 渲染路径下引擎不再回调 sizeChanged,PTY winsize 滞留在启动值
    /// (表现:视图 126 列而 ls 只看到 84 列 → 单列输出)。尺寸稳定后手动同步,按列行数去重。
    private var lastSyncedGrid = (cols: 0, rows: 0)

    private func syncPtyWindowSize() {
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
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    deinit {
        windowKeyObservers.forEach { NotificationCenter.default.removeObserver($0) }
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

    @objc private func termiteFind() {
        MainActor.assumeIsolated { SessionManager.shared.requestSearch() }
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
