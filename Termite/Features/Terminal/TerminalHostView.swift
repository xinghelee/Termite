import SwiftTerm
import SwiftUI

/// 把 SwiftTerm 的 NSView 包进「每实例独立」的容器再交给 SwiftUI。
/// 终端视图是会话持有的唯一实例,树布局 ⇄ 巡视/最大化切换时会在两个
/// representable 之间搬家;若直接把它交给 SwiftUI,旧容器(退场动画延迟拆除)
/// 拆除时会把已搬进新家的终端视图一并拽下来,pane 随机空白、下次切换才恢复。
/// 容器每次新建、从不共享 —— SwiftUI 拆的永远只是容器,碰不到终端视图。
struct TerminalHostView: NSViewRepresentable {
    let terminalView: TerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // 只认领「完全无主」(superview 为 nil)的终端视图。
        // 不能按「离窗」判断:makeNSView 抢到视图时新容器还没插进窗口,
        // 视图短暂离窗,退场动画中的旧容器若据此抢回,随后连视图一起被拆,全部空白
        if terminalView.superview == nil {
            attach(to: container)
        }
    }

    private func attach(to container: NSView) {
        terminalView.frame = container.bounds
        terminalView.autoresizingMask = [.width, .height]
        container.addSubview(terminalView)
    }
}
