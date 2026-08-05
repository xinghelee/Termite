import SwiftTerm
import SwiftUI
import UIKit

/// SwiftTerm TerminalView 的持有者与代理:输出喂给视图、键入转发给 RemoteClient。
/// 网格钉死策略:Mac 端 PTY 尺寸是权威,这里按列数反推字号装进屏宽
/// (最小 7pt,再宽就横向滚动),frame 精确到格,视图自算的格数与 PTY 一致。
@MainActor
final class TerminalBridge: NSObject {
    let terminalView: SwiftTerm.TerminalView
    weak var client: RemoteClient?

    /// 当前内容尺寸(SwiftUI 侧用来定 frame)
    private(set) var contentSize = CGSize(width: 320, height: 480)

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

    /// 按 PTY 网格与容器宽度定字号和 frame
    func fit(cols: Int, rows: Int, containerWidth: CGFloat) {
        guard cols > 0, rows > 0, containerWidth > 40 else { return }
        var size: CGFloat = 17
        while size > 7 {
            if cellWidth(fontSize: size) * CGFloat(cols) <= containerWidth { break }
            size -= 1
        }
        let font = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        terminalView.font = font
        // frame 取整到「刚好装下 cols 列」:多给 1pt,避免向下取整少一列
        let width = ceil(cellWidth(fontSize: size) * CGFloat(cols)) + 1
        let height = ceil(font.lineHeight * CGFloat(rows))
        terminalView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        contentSize = CGSize(width: width, height: height)
        // 视图按 bounds 自算格数可能差一列,以 PTY 为准兜底钉一次
        let terminal = terminalView.getTerminal()
        if terminal.cols != cols || terminal.rows != rows {
            terminal.resize(cols: cols, rows: rows)
        }
    }

    private func cellWidth(fontSize: CGFloat) -> CGFloat {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return ("W" as NSString).size(withAttributes: [.font: font]).width
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
