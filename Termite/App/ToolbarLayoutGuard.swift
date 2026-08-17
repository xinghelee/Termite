import AppKit
import os

/// 标题栏版面守卫:冷启动首帧 NSToolbar 的分段 inset 会停在侧边栏定宽之前的旧值上。
///
/// 症状(1.28 实测):标题栏 leading 段——侧边栏切换按钮 + 标签轨道——整条钻进侧边栏
/// 色带里,右侧按钮岛同时贴到窗口右缘;用户随手在终端里点一下就自己归位。
/// 量到的事实是 leading 段的 x 恒等于「侧边栏列宽 + 4」,而错位那一帧用的列宽是 164,
/// 真实列宽 228 —— 侧边栏本身、交通灯、chrome 带都在正确位置,只有工具栏的分段没跟上。
///
/// 不去猜 macOS 的 inset 公式(跨版本会变),只守一条不变量:**leading 段不该压进侧边栏列**。
/// 显形后核对若干次,压进去了才补一次版面重排,把用户那一下点替他点掉;对得上则什么都不做。
@MainActor
final class ToolbarLayoutGuard {
    private static let log = Logger(subsystem: "com.termite.app", category: "chrome")
    /// 窗口显形、标签从存档里长出来都晚于首帧,分几拍核对;补救次数另有上限
    private static let checkpoints: [TimeInterval] = [0, 0.15, 0.5, 1.2]
    private static let maxRealigns = 2

    private weak var window: NSWindow?
    private var realignCount = 0

    init(window: NSWindow) {
        self.window = window
        for delay in Self.checkpoints {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.checkAndRealign()
            }
        }
    }

    private func checkAndRealign() {
        guard let window, window.isVisible, realignCount < Self.maxRealigns else { return }
        // 留 4pt 余量:健康态实测 leading 段离列缘只有 8pt 出头,错位时则差 60pt 上下,
        // 余量足够把舍入噪声挡在外面,又不至于漏判
        guard let sidebarWidth = Self.visibleSidebarWidth(of: window),
              let leadingX = Self.leadingToolbarItemMinX(of: window),
              leadingX < sidebarWidth - 4 else { return }
        realignCount += 1
        Self.log.notice("标题栏 leading 段压进侧边栏(x=\(Int(leadingX), privacy: .public) < 列宽 \(Int(sidebarWidth), privacy: .public)),补一次重排")
        Self.forceTitlebarLayout(window)
    }

    /// 最外层 NSSplitView(NavigationSplitView 的分栏容器)第一列的宽度;
    /// 侧边栏收起时返回 nil —— 那时 leading 段本就该顶到左边,不设防
    private static func visibleSidebarWidth(of window: NSWindow) -> CGFloat? {
        guard let split = outermostSplitView(in: window.contentView),
              let sidebar = split.arrangedSubviews.first,
              !split.isSubviewCollapsed(sidebar),
              sidebar.frame.width > 1 else { return nil }
        return sidebar.frame.width
    }

    private static func outermostSplitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView { return split }
        for child in view.subviews {
            if let found = outermostSplitView(in: child) { return found }
        }
        return nil
    }

    /// 最靠左的工具栏 item 在窗口坐标里的左缘(交通灯不是 toolbar item,不参与)
    private static func leadingToolbarItemMinX(of window: NSWindow) -> CGFloat? {
        let origins = window.toolbar?.visibleItems?.compactMap { item -> CGFloat? in
            guard let view = item.view, view.window === window, view.frame.width > 1 else { return nil }
            return view.convert(view.bounds, to: nil).minX
        }
        return origins?.min()
    }

    /// 让 AppKit 重跑一次标题栏版面。只置 needsLayout 不够(错的 inset 存在工具栏的
    /// 分段信息里),再补一次同 runloop 内的 1pt 尺寸抖动 —— 等价于用户那一下点击,
    /// 中间态与最终态在同一次提交里,画不出来
    private static func forceTitlebarLayout(_ window: NSWindow) {
        window.contentView?.superview?.needsLayout = true
        let frame = window.frame
        window.setFrame(frame.insetBy(dx: -1, dy: 0), display: true)
        window.setFrame(frame, display: true)
    }
}
