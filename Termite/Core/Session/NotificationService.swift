import Foundation
import UserNotifications

/// 系统通知:后台长命令完成 / 分屏等待输入提醒。首次使用时申请权限,拒绝则静默。
enum NotificationService {
    private static var authorizationRequested = false

    private static func center() -> UNUserNotificationCenter {
        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        return center
    }

    static func postCommandFinished(exitCode: Int?, duration: TimeInterval, title: String) {
        let center = center()
        let content = UNMutableNotificationContent()
        let ok = (exitCode ?? 0) == 0
        content.title = ok
            ? String(localized: "命令完成 · \(compact(duration))")
            : String(localized: "命令失败(退出码 \(exitCode ?? -1))· \(compact(duration))")
        content.body = title
        content.sound = ok ? nil : .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }

    /// 分屏(agent/TUI)停下来等用户输入
    static func postAwaitingInput(title: String) {
        let center = center()
        let content = UNMutableNotificationContent()
        content.title = String(localized: "分屏在等待你的输入")
        content.body = title
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }

    /// 自动检查发现新版本(点击通知激活 app 后经菜单下载)
    static func postUpdateAvailable(version: String) {
        let center = center()
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Termite \(version) 已发布")
        content.body = String(localized: "在菜单「Termite → 检查更新」中下载升级。")
        let request = UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil)
        center.add(request)
    }

    private static func compact(_ duration: TimeInterval) -> String {
        if duration < 60 { return String(format: "%.0fs", duration) }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return "\(minutes)m\(seconds)s"
    }
}
