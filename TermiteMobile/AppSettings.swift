import Foundation

/// @AppStorage 键名统一定义(与 Mac 端 SettingsKeys 同风格)
enum MobileSettingsKeys {
    /// 终端字号(pt),捏合/设置页可调
    static let fontSize = "terminal.fontSize"
    /// 终端页保持屏幕常亮
    static let keepAwake = "terminal.keepAwake"
    /// 响铃触感反馈
    static let bellHaptics = "terminal.bellHaptics"
    /// 上次附着的会话(按 Mac 记):"<macID>" → sessionID
    static let lastSessionPrefix = "session.last."

    static let defaultFontSize: Double = 13
    static let fontSizeRange: ClosedRange<Double> = 8...24
}
