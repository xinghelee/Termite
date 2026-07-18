import AppKit

/// NSWindow delegate 代理:只拦 windowShouldClose(该窗口有命令在跑时先确认),
/// 其余所有 delegate 消息通过消息转发交还给 SwiftUI 原本的 delegate,不干扰其窗口管理。
final class WindowCloseInterceptor: NSObject, NSWindowDelegate {
    private weak var original: NSWindowDelegate?
    private weak var manager: SessionManager?

    init(original: NSWindowDelegate?, manager: SessionManager) {
        self.original = original
        self.manager = manager
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) {
            return original
        }
        return super.forwardingTarget(for: aSelector)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let allowed = MainActor.assumeIsolated { () -> Bool in
            let confirmEnabled = UserDefaults.standard.object(forKey: SettingsKeys.confirmBeforeClosingTab) as? Bool ?? true
            let running = manager?.runningCommandCount ?? 0
            guard confirmEnabled, running > 0 else { return true }
            let alert = NSAlert()
            alert.messageText = String(localized: "关闭窗口?")
            alert.informativeText = String(localized: "该窗口有 \(running) 个命令正在运行,关闭会终止它们。")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "终止并关闭"))
            alert.addButton(withTitle: String(localized: "取消"))
            return alert.runModal() == .alertFirstButtonReturn
        }
        guard allowed else { return false }
        // 用户放行后仍尊重原 delegate 的决定(SwiftUI 状态收尾)
        if let original, original.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))) {
            return original.windowShouldClose?(sender) ?? true
        }
        return true
    }
}
