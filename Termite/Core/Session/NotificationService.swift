import Foundation
import UserNotifications

/// 系统通知:后台长命令完成 / 分屏等待输入提醒。首次使用时申请权限,拒绝则静默。
/// 等待输入的通知带快速回复动作:「回车确认」一键放行,「回复…」内联输入直接发进 pane,
/// 点通知本体跳到该分屏 —— 处理 agent 打断不必切上下文。
enum NotificationService {
    private static var authorizationRequested = false
    private static let router = NotificationActionRouter()

    static let awaitingCategory = "termite.awaitingInput"
    static let actionEnter = "termite.reply.enter"
    static let actionText = "termite.reply.text"

    private static func center() -> UNUserNotificationCenter {
        let center = UNUserNotificationCenter.current()
        if !authorizationRequested {
            authorizationRequested = true
            center.delegate = router
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
            let enter = UNNotificationAction(identifier: actionEnter,
                                             title: String(localized: "回车确认"))
            let reply = UNTextInputNotificationAction(identifier: actionText,
                                                      title: String(localized: "回复…"),
                                                      textInputButtonTitle: String(localized: "发送"),
                                                      textInputPlaceholder: String(localized: "发送到该分屏"))
            center.setNotificationCategories([
                UNNotificationCategory(identifier: awaitingCategory, actions: [enter, reply],
                                       intentIdentifiers: [])
            ])
        }
        return center
    }

    static func postCommandFinished(exitCode: Int?, duration: TimeInterval, title: String, sessionID: UUID) {
        let center = center()
        let content = UNMutableNotificationContent()
        let ok = (exitCode ?? 0) == 0
        content.title = ok
            ? String(localized: "命令完成 · \(compact(duration))")
            : String(localized: "命令失败(退出码 \(exitCode ?? -1))· \(compact(duration))")
        content.body = title
        content.sound = ok ? nil : .default
        content.userInfo = ["sessionID": sessionID.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }

    /// 分屏(agent/TUI)停下来等用户输入
    static func postAwaitingInput(title: String, sessionID: UUID) {
        let center = center()
        let content = UNMutableNotificationContent()
        content.title = String(localized: "分屏在等待你的输入")
        content.body = title
        content.sound = .default
        content.categoryIdentifier = awaitingCategory
        content.userInfo = ["sessionID": sessionID.uuidString]
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

/// 通知动作路由:快速回复动作把文本发进对应会话;点通知本体跳到该分屏
final class NotificationActionRouter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info["sessionID"] as? String, let id = UUID(uuidString: raw) else { return }
        let text: String?
        switch response.actionIdentifier {
        case NotificationService.actionEnter:
            text = "\r"
        case NotificationService.actionText:
            let typed = (response as? UNTextInputNotificationResponse)?.userText ?? ""
            text = typed.isEmpty ? "\r" : typed + "\r"
        default:
            text = nil // 点通知本体:激活并跳到该分屏
        }
        await MainActor.run {
            if let text {
                SessionManagerRegistry.shared.quickReply(id, text: text)
            } else {
                SessionManagerRegistry.shared.focusSession(id)
            }
        }
    }

    /// app 在前台时也照常横幅(是否该发由调用方按可见性把关)
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
