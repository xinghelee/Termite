import SwiftUI

/// 全 App 共用的配色,由 Mac 下发的终端主题派生。
///
/// 之前只有终端那屏跟着 Mac 主题走,对话和模拟器用 iOS 系统默认色,
/// 并排看像两个 App。现在三个 tab 吃同一套:同一块底、同一种浮起、同一个强调色。
///
/// 派生规则(和 Mac 端的 chrome 设计语言一致):
/// - 底:主题背景色本身
/// - 面:在底上抬一层(深色抬白、浅色压黑),用来做行/气泡/输入条
/// - 强调:主题强调色,拿不到就用 Termite 品牌琥珀
struct TermiteTheme {
    var palette: RemoteThemePayload?

    static let brandAmber = Color(red: 0.91, green: 0.64, blue: 0.24)

    var isDark: Bool { palette?.isDark ?? true }

    var colorScheme: ColorScheme { isDark ? .dark : .light }

    var background: Color {
        guard let palette else { return isDark ? Color(white: 0.07) : Color(white: 0.97) }
        return Color(UIColor(hex: palette.background))
    }

    /// 行、气泡、输入条的底:在背景上抬一层
    var surface: Color {
        isDark ? Color.white.opacity(0.075) : Color.black.opacity(0.055)
    }

    /// 再抬一层(选中态、次级卡片)
    var surfaceRaised: Color {
        isDark ? Color.white.opacity(0.13) : Color.black.opacity(0.09)
    }

    var accent: Color {
        guard let palette else { return Self.brandAmber }
        return Color(UIColor(hex: palette.accent))
    }

    var primaryText: Color {
        guard let palette else { return isDark ? .white : .black }
        return Color(UIColor(hex: palette.foreground))
    }

    var secondaryText: Color { primaryText.opacity(0.6) }
    var tertiaryText: Color { primaryText.opacity(0.38) }

    /// 分隔线
    var separator: Color { primaryText.opacity(0.08) }
}

/// 主题从终端连接来(Mac 在 list/attached 里下发),放进环境供三个 tab 共用
@MainActor
@Observable
final class ThemeStore {
    var palette: RemoteThemePayload?

    var theme: TermiteTheme { TermiteTheme(palette: palette) }
}

private struct TermiteThemeKey: EnvironmentKey {
    static let defaultValue = TermiteTheme(palette: nil)
}

extension EnvironmentValues {
    var termiteTheme: TermiteTheme {
        get { self[TermiteThemeKey.self] }
        set { self[TermiteThemeKey.self] = newValue }
    }
}

extension View {
    /// 一屏套一次:主题底 + 去掉系统 List 的默认底 + 配色方案 + 强调色
    func termiteScreen(_ theme: TermiteTheme) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(theme.background.ignoresSafeArea())
            .environment(\.colorScheme, theme.colorScheme)
            .tint(theme.accent)
            .toolbarBackground(theme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(theme.colorScheme, for: .navigationBar)
    }

    /// 列表行的统一底:抬一层的面 + 统一圆角
    func termiteRow(_ theme: TermiteTheme) -> some View {
        self
            .listRowBackground(theme.surface)
            .listRowSeparatorTint(theme.separator)
    }
}
