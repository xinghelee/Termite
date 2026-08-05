import AppKit
import SwiftUI

/// 抓到承载视图的 NSWindow,套用主题外观并把标题栏并入内容区,得到统一的深色边到边观感。
/// backgroundColor 钉死为主题底色:macOS 深色模式默认会把壁纸颜色渗进窗口材质(desktop tinting),
/// 与主题冷色底冲突,表现为顶部/空白区一条不搭的暖灰。主窗口与独立窗口(密钥)共用。
struct WindowConfigurator: NSViewRepresentable {
    let appearanceName: NSAppearance.Name
    let backgroundColor: NSColor
    /// 透明 chrome:窗口非不透明 + 清空底色,让 WindowBackdrop 的 behind-window
    /// 毛玻璃透出桌面;backgroundColor 仅在不透明模式下钉死(挡 desktop tinting)
    var translucent = false
    /// 独立小窗保留标题文字,主窗口隐藏
    var keepsTitle = false
    /// 内容延伸到标题栏之下(设置窗口:左栏底色一路铺到窗口顶)
    var fullSizeContent = false
    /// 挂载瞬间(窗口尚未显示)的同步回调:预放置 frame 等必须赶在首帧前的事。
    /// SwiftUI 会先按自己记忆的位置显示窗口,任何 async 后的 setFrame 都会闪现旧位置一帧
    var onWindowEarly: ((NSWindow) -> Void)?
    /// 拿到 NSWindow 时回调(多窗口:把窗口绑定到它的 SessionManager)。
    /// 延后一拍:bind 会改 @Observable 状态与视图树,不能在视图更新事务里同步做
    var onWindow: ((NSWindow) -> Void)?

    /// 视图挂进窗口的确切时机由 viewDidMoveToWindow 给出(此时窗口还未 orderFront);
    /// 原先 makeNSView 里 DispatchQueue.main.async 等窗口,所有配置都落在首帧之后
    final class AttachView: NSView {
        var onAttach: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onAttach?(window) }
        }
    }

    func makeNSView(context: Context) -> AttachView {
        let view = AttachView()
        view.onAttach = attachHandler
        return view
    }

    func updateNSView(_ nsView: AttachView, context: Context) {
        nsView.onAttach = attachHandler
        // 参数变化(主题切换)时窗口已在:即时重配外观,bind 仍延后一拍
        guard let window = nsView.window else { return }
        configureChrome(window)
        DispatchQueue.main.async { onWindow?(window) }
    }

    private var attachHandler: (NSWindow) -> Void {
        { window in
            // 早配一次让首帧尽量正确;SwiftUI 的窗口初始化会在挂载后盖掉
            // 外观设置(标题栏变回系统灰),async 一拍后必须再补一次
            configureChrome(window)
            onWindowEarly?(window)
            DispatchQueue.main.async {
                configureChrome(window)
                onWindow?(window)
            }
        }
    }

    private func configureChrome(_ window: NSWindow) {
        window.appearance = NSAppearance(named: appearanceName)
        window.titlebarAppearsTransparent = true
        if fullSizeContent {
            window.styleMask.insert(.fullSizeContentView)
        }
        window.titleVisibility = keepsTitle ? .visible : .hidden
        window.isOpaque = !translucent
        window.backgroundColor = translucent ? .clear : backgroundColor
    }
}

/// behind-window 毛玻璃:采样窗口后方(桌面/其他窗口)做模糊,透明 chrome 的最底层。
/// .sidebar 材质 = 原生侧边栏同款,深浅外观都有明显的透出感;
/// followsWindowActiveState:失焦时退成平底,与系统窗口行为一致
struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .sidebar
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
