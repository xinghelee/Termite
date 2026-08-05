import SwiftTerm
import SwiftUI

/// 把 SwiftTerm 的 NSView 包进「每实例独立」的容器再交给 SwiftUI。
/// 终端视图是会话持有的唯一实例,树布局 ⇄ 巡视/最大化切换时会在多个
/// representable 之间搬家;若直接把它交给 SwiftUI,旧容器(退场动画延迟拆除)
/// 拆除时会把已搬进新家的终端视图一并拽下来,pane 随机空白、下次切换才恢复。
/// 容器每次新建、从不共享 —— SwiftUI 拆的永远只是容器,碰不到终端视图。
///
/// 孤儿回收:SwiftUI 的转场副本容器也会走 makeNSView 把视图偷走,随后
/// 连容器一起被拆——视图落成「无主」(superview nil),而活着的容器不再收到
/// updateNSView,pane 从此空白(巡视模式焦点页必现)。注册表记录每个终端
/// 视图的存活容器,容器拆除时立刻把孤儿转交给任一「有窗口」的容器,不等 SwiftUI
struct TerminalHostView: NSViewRepresentable {
    let terminalView: TerminalView

    func makeNSView(context: Context) -> TerminalHostContainer {
        let container = TerminalHostContainer()
        container.terminalView = terminalView
        TerminalHostRegistry.register(container, for: terminalView)
        container.attachTerminal()
        return container
    }

    func updateNSView(_ container: TerminalHostContainer, context: Context) {
        // 只认领「完全无主」(superview 为 nil)的终端视图。
        // 不能按「离窗」判断:makeNSView 抢到视图时新容器还没插进窗口,
        // 视图短暂离窗,退场动画中的旧容器若据此抢回,随后连视图一起被拆,全部空白
        if terminalView.superview == nil {
            container.attachTerminal()
        }
    }

    static func dismantleNSView(_ container: TerminalHostContainer, coordinator: ()) {
        // 死前若还抱着终端视图,先放生再转交,别拽着一起进坟
        if let terminal = container.terminalView, terminal.superview === container {
            terminal.removeFromSuperview()
        }
        TerminalHostRegistry.unregister(container)
        if let terminal = container.terminalView {
            // 下一拍再转交:等 SwiftUI 本轮增删视图落定,新容器(若有)已注册
            DispatchQueue.main.async {
                TerminalHostRegistry.reclaimIfOrphaned(terminal)
            }
        }
    }
}

/// 终端宿主容器:知道自己伺候哪个终端视图,挂窗/布局时主动收养孤儿
final class TerminalHostContainer: NSView {
    weak var terminalView: TerminalView?

    func attachTerminal() {
        guard let terminal = terminalView else { return }
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reclaimIfOrphaned()
    }

    override func layout() {
        super.layout()
        reclaimIfOrphaned()
    }

    private func reclaimIfOrphaned() {
        guard window != nil, let terminal = terminalView, terminal.superview == nil else { return }
        attachTerminal()
    }
}

/// 每个终端视图的存活容器注册表(弱引用):孤儿视图的确定性归宿。
/// 主线程独占访问(所有容器生命周期事件都在主线程)
@MainActor
enum TerminalHostRegistry {
    private static var hosts: [ObjectIdentifier: NSHashTable<TerminalHostContainer>] = [:]

    static func register(_ container: TerminalHostContainer, for terminal: NSView) {
        let key = ObjectIdentifier(terminal)
        let table = hosts[key] ?? {
            let table = NSHashTable<TerminalHostContainer>.weakObjects()
            hosts[key] = table
            return table
        }()
        table.add(container)
    }

    static func unregister(_ container: TerminalHostContainer) {
        guard let terminal = container.terminalView else { return }
        hosts[ObjectIdentifier(terminal)]?.remove(container)
    }

    /// 视图无主时,转交给任一「有窗口」的存活容器(优先挂窗的,保证画得出来)
    static func reclaimIfOrphaned(_ terminal: TerminalView) {
        guard terminal.superview == nil,
              let table = hosts[ObjectIdentifier(terminal)] else { return }
        let candidates = table.allObjects
        guard let host = candidates.first(where: { $0.window != nil }) ?? candidates.first else { return }
        host.attachTerminal()
    }
}
