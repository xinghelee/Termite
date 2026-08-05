import SwiftTerm
import SwiftUI
import UIKit

/// SwiftTerm TerminalView 的持有者与代理:输出喂给视图、键入转发给 RemoteClient。
/// 网格钉死策略:Mac 端 PTY 尺寸是权威;字号「可读优先」——用用户偏好字号渲染,
/// 列数装不下屏宽就横向滚动,绝不为塞下而把字缩到看不清。
@MainActor
final class TerminalBridge: NSObject {
    let terminalView: SwiftTerm.TerminalView
    weak var client: RemoteClient?
    /// 响铃触感开关(设置页)
    var hapticsEnabled = true

    /// 当前内容尺寸(SwiftUI 侧用来定 frame)
    private(set) var contentSize = CGSize(width: 320, height: 480)

    private var cols = 80
    private var rows = 24
    private var fontSize: CGFloat = MobileSettingsKeys.defaultFontSize

    override init() {
        terminalView = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        super.init()
        terminalView.terminalDelegate = self
        terminalView.backgroundColor = UIColor(red: 0.078, green: 0.086, blue: 0.102, alpha: 1)
        terminalView.nativeBackgroundColor = terminalView.backgroundColor ?? .black
        terminalView.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
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

    /// 网格/字号变化后重排:frame 精确到格,视图自算的格数与 PTY 一致
    func layout(cols: Int, rows: Int, fontSize: CGFloat) {
        guard cols > 0, rows > 0 else { return }
        self.cols = cols
        self.rows = rows
        self.fontSize = fontSize
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminalView.font = font
        // 多给 1pt,避免视图按 bounds 向下取整少一列
        let width = ceil(cellWidth(font: font) * CGFloat(cols)) + 1
        let height = ceil(font.lineHeight * CGFloat(rows))
        terminalView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        contentSize = CGSize(width: width, height: height)
        let terminal = terminalView.getTerminal()
        if terminal.cols != cols || terminal.rows != rows {
            terminal.resize(cols: cols, rows: rows)
        }
    }

    private func cellWidth(font: UIFont) -> CGFloat {
        ("W" as NSString).size(withAttributes: [.font: font]).width
    }

    /// 「适配手机宽度」用:这块屏幕在该字号下能装下的网格
    func gridThatFits(size: CGSize, fontSize: CGFloat) -> (cols: Int, rows: Int) {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let cols = max(10, Int((size.width - 6) / cellWidth(font: font)))
        let rows = max(4, Int(size.height / font.lineHeight))
        return (cols, rows)
    }
}

extension TerminalBridge: TerminalViewDelegate {
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        client?.sendInput(Data(data))
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        // 网格由 Mac 端拥有,本地布局变化不回推
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

/// SwiftUI 包装:视图实例由 bridge 持有,SwiftUI 只负责摆放
struct TerminalCanvas: UIViewRepresentable {
    let bridge: TerminalBridge

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        bridge.terminalView
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {}
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
