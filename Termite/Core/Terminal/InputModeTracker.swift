import Foundation
import SwiftTerm

/// 重连会话时要带回的「输入相关终端模式」。
///
/// 重连只回放守护进程缓冲里最近的同步帧,TUI 启动时发的一次性模式开关
/// (Claude Code 的 kitty 键盘协议 `CSI > 5 u`、括号粘贴、焦点上报…)不在其中:
/// 新 Terminal 停在默认模式,⌃↩ 发不出任何字节、⇧↩ 变回普通回车、粘贴多行被逐行提交。
/// 退出前把这些模式拍成一串转义序列随票据落盘,重连时在回放之前先灌给新 Terminal。
struct InputModeTracker {
    /// SwiftTerm 不公开的两个模式:只能从输出流里自己记
    private(set) var focusReporting = false
    private(set) var sgrMouse = false

    /// 只认这几个独立出现的私有模式开关(TUI 通常各发各的,不合并成 ?1004;1006h)
    private static let tracked: [(code: [UInt8], keyPath: WritableKeyPath<InputModeTracker, Bool>)] = [
        (Array("1004".utf8), \.focusReporting),
        (Array("1006".utf8), \.sgrMouse),
    ]

    mutating func scan(_ bytes: ArraySlice<UInt8>) {
        // 快速路径:没有 ESC 的大段输出直接跳过
        guard bytes.contains(0x1b) else { return }
        var i = bytes.startIndex
        let end = bytes.endIndex
        // 最短形态 ESC [ ? n n n n h = 8 字节
        while i + 7 < end {
            if bytes[i] == 0x1b,
               bytes[i + 1] == UInt8(ascii: "["), bytes[i + 2] == UInt8(ascii: "?") {
                let final = bytes[i + 7]
                if final == UInt8(ascii: "h") || final == UInt8(ascii: "l") {
                    let code = bytes[(i + 3)..<(i + 7)]
                    for entry in Self.tracked where code.elementsEqual(entry.code) {
                        self[keyPath: entry.keyPath] = final == UInt8(ascii: "h")
                    }
                }
            }
            i += 1
        }
    }

    /// 当前输入模式拍成的转义序列;全是默认值时为 nil
    func preamble(for terminal: Terminal) -> String? {
        Self.preamble(
            kittyFlags: terminal.keyboardEnhancementFlags.rawValue,
            bracketedPaste: terminal.bracketedPasteMode,
            applicationCursor: terminal.applicationCursor,
            mouseMode: terminal.mouseMode,
            focusReporting: focusReporting,
            sgrMouse: sgrMouse
        )
    }

    static func preamble(kittyFlags: Int, bracketedPaste: Bool, applicationCursor: Bool,
                         mouseMode: Terminal.MouseMode, focusReporting: Bool, sgrMouse: Bool) -> String? {
        var out = ""
        if applicationCursor { out += "\u{1b}[?1h" }
        if bracketedPaste { out += "\u{1b}[?2004h" }
        if focusReporting { out += "\u{1b}[?1004h" }
        switch mouseMode {
        case .off: break
        case .x10: out += "\u{1b}[?9h"
        case .vt200: out += "\u{1b}[?1000h"
        case .buttonEventTracking: out += "\u{1b}[?1002h"
        case .anyEvent: out += "\u{1b}[?1003h"
        }
        if mouseMode != .off, sgrMouse { out += "\u{1b}[?1006h" }
        // 压栈形式:程序退出时自己的 CSI < u 弹回默认
        if kittyFlags != 0 { out += "\u{1b}[>\(kittyFlags)u" }
        return out.isEmpty ? nil : out
    }
}
