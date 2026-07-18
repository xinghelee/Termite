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
            if UserDefaults.standard.object(forKey: SettingsKeys.metalRenderer) as? Bool ?? true {
                try? setUseMetal(true)
            }
        }
        // 标签切换时视图此刻才挂进窗口:selectTab 里的 makeFirstResponder 那时 window 还是 nil,
        // 在这里把键盘焦点接过来(修「恢复后切标签无法输入」)
        if window != nil, let session, session.manager?.selected === session {
            window?.makeFirstResponder(self)
        }
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
        guard process?.running == true else { return }
        let terminal = getTerminal()
        guard terminal.cols != lastSyncedGrid.cols || terminal.rows != lastSyncedGrid.rows else { return }
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
        super.send(source: source, data: data)
        session?.didSendUserInput(Array(data))
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
