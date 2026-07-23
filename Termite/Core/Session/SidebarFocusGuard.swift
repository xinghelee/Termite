import AppKit
import os

/// 焦点守卫:侧边栏(NavigationSplitView 第一列)只有鼠标交互,永远不该持有键盘焦点。
/// SwiftUI 更新中终端视图短暂离窗/重挂时,AppKit 会把 first responder 交给
/// 「下一个合法 key view」——往往正是侧边栏的 outline。此后没有任何事件再触发
/// focusTerminal(),表现为「终端卡住:打字无反应、光标常亮不闪」,且会一直持续
/// 到用户手动点击终端区。这里 KVO 盯住 firstResponder,焦点一落进侧边栏列就还给
/// 当前会话的终端。
@MainActor
final class SidebarFocusGuard {
    private static let log = Logger(subsystem: "com.termite.app", category: "focus")
    private var observation: NSKeyValueObservation?

    init(window: NSWindow) {
        observation = window.observe(\.firstResponder) { window, _ in
            MainActor.assumeIsolated { Self.bounceIfSidebar(window) }
        }
    }

    private static func bounceIfSidebar(_ window: NSWindow) {
        guard let view = window.firstResponder as? NSView, isInSidebarColumn(view) else { return }
        // 推迟一拍:让 AppKit 结束当前 makeFirstResponder 流程,也给点击项目行
        // (openProject → focusTerminal)让路;届时焦点仍在侧边栏才出手
        DispatchQueue.main.async {
            guard let current = window.firstResponder as? NSView, isInSidebarColumn(current),
                  let manager = SessionManagerRegistry.shared.manager(of: window),
                  let session = manager.selected,
                  session.terminalView.window === window else { return }
            log.notice("侧边栏抢到键盘焦点(\(type(of: current), privacy: .public)),已还给终端")
            window.makeFirstResponder(session.terminalView)
        }
    }

    /// view 是否位于最外层 NSSplitView(NavigationSplitView 的分栏容器)的第一列。
    /// 只认最外层:终端区若引入嵌套 split view,其第一个 pane 不会被误伤。
    private static func isInSidebarColumn(_ view: NSView) -> Bool {
        var outermost: NSSplitView?
        var cursor: NSView? = view
        while let v = cursor {
            if let split = v as? NSSplitView { outermost = split }
            cursor = v.superview
        }
        guard let sidebar = outermost?.arrangedSubviews.first else { return false }
        return view.isDescendant(of: sidebar)
    }
}
