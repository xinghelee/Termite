import SwiftTerm
import SwiftUI
import UIKit

/// SwiftTerm TerminalView 的持有者与代理。
/// 关键事实:iOS 的 TerminalView 本身是 UIScrollView(自管滚回滚动),
/// 外面绝不能再包滚动视图——手势必打架。两种布局模式:
/// - 适配(默认):frame = 容器,SwiftTerm 自算网格,经 sizeChanged 上报给屏幕层去 resize PTY
/// - 镜像:frame = Mac 网格实际尺寸,整体 transform 缩放到容器宽度(看全貌,无手势冲突)
@MainActor
final class TerminalBridge: NSObject {
    let terminalView: SwiftTerm.TerminalView
    weak var client: RemoteClient?
    /// 响铃触感开关(设置页)
    var hapticsEnabled = true
    /// 适配模式:SwiftTerm 按 bounds 自算的网格变化时上报(屏幕层防抖后发 resize)
    var fitMode = true
    var onGridChange: ((Int, Int) -> Void)?
    /// 捏合调字号(UIKit 手势,SwiftUI 手势在 UIScrollView 上不可靠)
    var onPinchScale: ((CGFloat, Bool) -> Void)?

    override init() {
        terminalView = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        super.init()
        terminalView.terminalDelegate = self
        // 触屏铁直觉:单指滑动=滚动。开着它,vim/claude 这类鼠标模式 TUI 会把
        // 滑动当鼠标拖拽上报,表现为「一滑就选中」;本地选择走长按菜单,不受影响
        terminalView.allowMouseReporting = false
        // SwiftTerm 自带键盘 accessory 和我们的常驻按键条功能重叠,俩条叠着太挤
        terminalView.inputAccessoryView = nil
        terminalView.backgroundColor = UIColor(red: 0.078, green: 0.086, blue: 0.102, alpha: 1)
        terminalView.nativeBackgroundColor = terminalView.backgroundColor ?? .black
        terminalView.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        terminalView.addGestureRecognizer(pinch)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .changed:
            onPinchScale?(gesture.scale, false)
        case .ended, .cancelled:
            onPinchScale?(gesture.scale, true)
        default:
            break
        }
    }

    func feed(_ data: Data) {
        terminalView.feed(byteArray: ArraySlice([UInt8](data)))
    }

    /// RIS 全量重置:重连回放前清场,备用屏/滚回一起清
    func reset() {
        terminalView.feed(text: "\u{1b}c")
    }

    /// Mac 下发的主题色板整套应用(终端与 Mac 同款观感)
    func applyTheme(_ theme: RemoteThemePayload) {
        let background = UIColor(hex: theme.background)
        terminalView.backgroundColor = background
        terminalView.nativeBackgroundColor = background
        terminalView.nativeForegroundColor = UIColor(hex: theme.foreground)
        terminalView.caretColor = UIColor(hex: theme.cursor)
        terminalView.installColors(theme.ansi.map { SwiftTerm.Color(hex: $0) })
    }

    func setFont(size: CGFloat) {
        terminalView.font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// 镜像模式:Mac 网格在当前字号下的实际内容尺寸
    func mirrorContentSize(cols: Int, rows: Int, fontSize: CGFloat) -> CGSize {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let cellWidth = ("W" as NSString).size(withAttributes: [.font: font]).width
        return CGSize(width: ceil(cellWidth * CGFloat(cols)) + 1,
                      height: ceil(font.lineHeight * CGFloat(rows)))
    }

    /// 镜像模式:把网格钉回 Mac 尺寸(frame 已按 mirrorContentSize 摆好后调用)
    func pinGrid(cols: Int, rows: Int) {
        let terminal = terminalView.getTerminal()
        if terminal.cols != cols || terminal.rows != rows {
            terminal.resize(cols: cols, rows: rows)
        }
    }

    /// 适配模式:视图当前自算的网格(= 设备该有的 PTY 尺寸)
    func currentGrid() -> (cols: Int, rows: Int) {
        let terminal = terminalView.getTerminal()
        return (terminal.cols, terminal.rows)
    }
}

extension TerminalBridge: TerminalViewDelegate {
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        client?.sendInput(Data(data))
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        // 适配模式:视图自算网格 = 设备该有的 PTY 尺寸,上报;镜像模式网格由 pinGrid 钉死
        guard fitMode else { return }
        onGridChange?(newCols, newRows)
    }

    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}

    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }

    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        UIPasteboard.general.string = String(data: content, encoding: .utf8)
    }

    func bell(source: SwiftTerm.TerminalView) {
        guard hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}

extension TerminalBridge: UIGestureRecognizerDelegate {
    /// 捏合与 SwiftTerm 自己的滚动/选择手势共存
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// UIKit 宿主:按模式摆放终端视图(适配=铺满容器;镜像=原尺寸+整体缩放)。
/// 不含任何外层滚动视图——滚回滚动全权交给 TerminalView 自己。
final class TerminalHostView: UIView {
    let terminalView: SwiftTerm.TerminalView
    var mirror = false
    var mirrorSize = CGSize.zero

    init(terminalView: SwiftTerm.TerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(terminalView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 10 else { return }
        if mirror, mirrorSize.width > 0 {
            terminalView.transform = .identity
            terminalView.frame = CGRect(origin: .zero, size: mirrorSize)
            let scale = min(1, bounds.width / mirrorSize.width)
            terminalView.transform = CGAffineTransform(scaleX: scale, y: scale)
            terminalView.frame.origin = CGPoint(x: (bounds.width - terminalView.frame.width) / 2, y: 0)
        } else {
            terminalView.transform = .identity
            terminalView.frame = bounds
        }
    }
}

/// SwiftUI 包装:视图实例由 bridge 持有,SwiftUI 只负责摆放
struct TerminalCanvas: UIViewRepresentable {
    let bridge: TerminalBridge
    var mirror: Bool
    var mirrorSize: CGSize

    func makeUIView(context: Context) -> TerminalHostView {
        TerminalHostView(terminalView: bridge.terminalView)
    }

    func updateUIView(_ host: TerminalHostView, context: Context) {
        host.mirror = mirror
        host.mirrorSize = mirrorSize
        host.setNeedsLayout()
    }
}

extension SwiftTerm.Color {
    convenience init(hex: String) {
        let ui = UIColor(hex: hex)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        ui.getRed(&red, green: &green, blue: &blue, alpha: nil)
        self.init(red: UInt16(red * 65535), green: UInt16(green * 65535), blue: UInt16(blue * 65535))
    }
}

extension UIColor {
    /// "#RRGGBB" / "RRGGBB" → UIColor(解析失败回落中灰,别黑屏)
    convenience init(hex: String) {
        var value: UInt64 = 0
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard Scanner(string: cleaned).scanHexInt64(&value), cleaned.count == 6 else {
            self.init(white: 0.5, alpha: 1)
            return
        }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
