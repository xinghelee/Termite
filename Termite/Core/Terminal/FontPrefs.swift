import AppKit
import Foundation

/// 终端字体偏好:字体族(空 = 系统等宽 SF Mono)× 字号。改动即时应用到所有会话。
enum FontPrefs {
    static func font() -> NSFont {
        let size = CGFloat(UserDefaults.standard.object(forKey: SettingsKeys.terminalFontSize) as? Double ?? 13)
        if let family = UserDefaults.standard.string(forKey: SettingsKeys.terminalFontFamily),
           !family.isEmpty,
           let custom = NSFont(name: family, size: size) {
            return custom
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
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
