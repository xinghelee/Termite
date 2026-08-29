import AppKit
import Foundation

/// 终端字体偏好:字体族(空 = 内置 JetBrainsMono Nerd Font Mono)× 字号。改动即时应用到所有会话。
///
/// Nerd Font 图标(powerlevel10k/starship/eza 满屏的 、、)全在 Unicode 私有区,
/// 系统字体回退表不覆盖,没装 patched 字体的用户看到的是整片 tofu——社区反馈的第一印象杀手。
/// 两层解法(Ghostty 同款思路):
/// 1. 默认字体换成内置的 JetBrainsMono Nerd Font Mono:图标原生齐全且严格单格宽,
///    Bold/Italic 是真字面,SwiftTerm 用 NSFontManager 派生粗斜体时命中真字面、图标不丢。
///    (旧默认 .monospacedSystemFont 是死路:私有系统字体在 BMP 私有区 U+E000–F8FF
///    直接给 LastResort,连自定义级联表都无视,实测确认。)
/// 2. 用户自选字体(Menlo 等)挂 Symbols Nerd Font Mono 级联:缺图标字形时优先落到它,
///    查不到照走系统回退,中文→苹方不受影响(实测确认)。
enum FontPrefs {
    /// 内置默认字体家族名(Resources/Fonts 里的四面,ATSApplicationFontsPath 注册)
    static let bundledFamily = "JetBrainsMono Nerd Font Mono"
    /// 内置图标回退字体的 PostScript 名(只含 Nerd Font 图标,不做正文字体)
    private static let symbolsFontName = "SymbolsNFM"

    static func font() -> NSFont {
        let size = CGFloat(UserDefaults.standard.object(forKey: SettingsKeys.terminalFontSize) as? Double ?? 13)
        if let family = UserDefaults.standard.string(forKey: SettingsKeys.terminalFontFamily),
           !family.isEmpty,
           let custom = NSFont(name: family, size: size) {
            return withSymbolsFallback(custom)
        }
        if let bundled = NSFont(name: bundledFamily, size: size) {
            return withSymbolsFallback(bundled)
        }
        // 内置字体加载失败的兜底:回到旧版行为(系统等宽,无图标)
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// 把图标字体挂进正文字体的 CoreText 级联表。SwiftTerm 两条渲染路径(CG/Metal)
    /// 都经 CTLineCreateWithAttributedString 排版,级联对两者同时生效;字形按列吸附,
    /// 回退字体的 advance 不会造成偏移。
    /// 已知局限:SwiftTerm 派生的粗体会丢级联属性(NSFontManager 按家族重建字体),
    /// 自选非 Nerd 字体时「加粗的图标」仍可能缺字;默认内置字体不受影响(真字面自带图标)。
    private static func withSymbolsFallback(_ base: NSFont) -> NSFont {
        guard NSFont(name: symbolsFontName, size: base.pointSize) != nil else { return base }
        let cascade = CTFontDescriptorCreateWithNameAndSize(symbolsFontName as CFString, 0)
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [cascade]])
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    /// 系统所有等宽字体名(设置里的字体族候选)
    static func monospacedFamilies() -> [String] {
        let manager = NSFontManager.shared
        let names = manager.availableFontNames(with: .fixedPitchFontMask) ?? []
        // 只留字体族主名(去掉 -Bold/-Italic 变体),排除隐藏字体(. 前缀)
        var families: Set<String> = []
        for name in names where !name.hasPrefix(".") {
            if let font = NSFont(name: name, size: 12) {
                families.insert(font.familyName ?? name)
            }
        }
        // 图标回退字体没有正文字形,不进候选;内置默认族单列在「默认」项里
        families.remove("Symbols Nerd Font Mono")
        families.remove(bundledFamily)
        return families.sorted()
    }

    @MainActor
    static func applyToAllSessions() {
        let resolved = font()
        for session in SessionManagerRegistry.shared.allSessions {
            session.terminalView.font = resolved
        }
        QuickTerminalController.shared.applyFont()
    }
}
