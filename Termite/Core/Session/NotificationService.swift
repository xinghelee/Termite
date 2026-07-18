import Foundation
import UserNotifications

/// 系统通知:后台长命令完成提醒。首次使用时申请权限,拒绝则静默。
enum NotificationService {
    private static var authorizationRequested = false

    static func postCommandFinished(exitCode: Int?, duration: TimeInterval, title: String) {
        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
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

    private static func compact(_ duration: TimeInterval) -> String {
        if duration < 60 { return String(format: "%.0fs", duration) }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return "\(minutes)m\(seconds)s"
    }
}
