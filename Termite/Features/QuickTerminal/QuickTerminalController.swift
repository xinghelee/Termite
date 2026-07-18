import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Quake 式下拉终端:⌥Space 全局热键(Carbon RegisterEventHotKey,无需辅助功能权限)
/// 从屏幕顶部滑下一块非激活浮动面板,承载一个独立于标签体系的终端会话。
@MainActor
final class QuickTerminalController {
    static let shared = QuickTerminalController()

    private(set) var session: TerminalSession?
    private var panel: NSPanel?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - 全局热键(⌥Space)

    func registerHotKeyIfEnabled() {
        let enabled = UserDefaults.standard.object(forKey: SettingsKeys.quickTerminal) as? Bool ?? true
        guard enabled, hotKeyRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, _ -> OSStatus in
                DispatchQueue.main.async {
                    QuickTerminalController.shared.toggle()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x544D5445), id: 1) // "TMTE"
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    // MARK: - 显隐

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    private func show() {
        let panel = ensurePanel()
        guard let screen = NSScreen.main else { return }
        let width = screen.visibleFrame.width * 0.62
        let height = screen.visibleFrame.height * 0.45
        let x = screen.visibleFrame.midX - width / 2
        let finalFrame = NSRect(x: x, y: screen.visibleFrame.maxY - height, width: width, height: height)
        let startFrame = finalFrame.offsetBy(dx: 0, dy: height * 0.35)

        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }
        if let terminalView = session?.terminalView {
            panel.makeFirstResponder(terminalView)
        }
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        let frame = panel.frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(frame.offsetBy(dx: 0, dy: frame.height * 0.35), display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }

    private func ensurePanel() -> NSPanel {
        // 会话退出过(exit)则重建
        if let session, case .exited = session.state {
            panel?.orderOut(nil)
            panel = nil
            self.session = nil
        }
        if let panel { return panel }

        let session = TerminalSession()
        session.onProcessExit = { [weak self] in
            self?.hide()
        }
        self.session = session

        let panel = QuickPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.backgroundColor = ThemeStore.shared.current.backgroundNSColor
        panel.appearance = NSAppearance(named: ThemeStore.shared.current.appearanceName)
        panel.contentView = NSHostingView(rootView: QuickTerminalContent(session: session))
        self.panel = panel
        return panel
    }

    // MARK: - 主题/字体联动

    func applyTheme() {
        guard let session else { return }
        ThemeStore.shared.apply(to: session.terminalView)
        panel?.backgroundColor = ThemeStore.shared.current.backgroundNSColor
        panel?.appearance = NSAppearance(named: ThemeStore.shared.current.appearanceName)
    }

    func applyFont() {
        session?.terminalView.font = FontPrefs.font()
    }
}

/// 可成为 key window 的非激活面板(borderless/nonactivating 默认不能接收键盘)
private final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 面板内容:终端 + 底部提示条
private struct QuickTerminalContent: View {
    let session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            TerminalHostView(terminalView: session.terminalView)
                .padding(.leading, 8)
                .padding(.top, 6)
            HStack {
                Image(systemName: "rectangle.topthird.inset.filled")
                    .font(.system(size: 9))
                Text("下拉终端 · ⌥Space 收起")
                    .font(.system(size: 10))
                Spacer()
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .background(Color(nsColor: ThemeStore.shared.current.backgroundNSColor))
    }
}
