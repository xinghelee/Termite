import Foundation
import Observation
import UserNotifications

/// 「agent 在等你」的提醒。
///
/// 能力边界要说清楚:iOS 会在切后台几十秒后挂起我们的 WebSocket,
/// 所以这里只保证「手机在手上时不错过」,做不到「随时叫醒你」。
/// 真正的随时可达需要 APNs —— 那要一台推送服务器,不在内网直连的设计范围里。
///
/// 判据完全复用 Mac 的注意力系统(bell + 静默启发式),这边只负责去重和路由:
/// 同一个会话进入等待只提醒一次,等待解除后再进入才会再提醒。
@MainActor
@Observable
final class ReplyNotifier: NSObject {
    /// 点了通知要去的会话。列表页看到它就把页面推进去
    var pendingSessionID: UUID?

    /// 已经提醒过的会话。等待解除时移除,同一场等待不会反复响
    @ObservationIgnored private var notified: Set<UUID> = []
    @ObservationIgnored private var authorized = false
    @ObservationIgnored private var asked = false
    /// 首轮不提醒:刚连上时拿到的等待可能已经挂了半天,不该炸一串通知
    @ObservationIgnored private var primed = false

    private static let category = "termite.reply"

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// 进应答 tab 时问一次。不在启动时问 —— 那时候用户还不知道这通知是干嘛的
    func requestAuthorizationIfNeeded() {
        guard !asked else { return }
        asked = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                Task { @MainActor in self.authorized = granted }
            }
    }

    /// 每轮 chatList 之后调用:比对等待集合,新进入等待的才提醒
    func sync(waiting: [ChatClient.SessionInfo]) {
        let current = Set(waiting.map(\.id))
        notified.formIntersection(current)
        guard primed else {
            // 首轮只记账:连上那一刻已经在等的,静默收进列表就好
            primed = true
            notified = current
            return
        }
        guard authorized else { return }
        for session in waiting where !notified.contains(session.id) {
            notified.insert(session.id)
            post(session)
        }
    }

    /// 断开重连时重新记账 —— 否则重连后会把所有等待当成新的,炸一串通知
    func reset() {
        primed = false
        notified = []
    }

    private func post(_ session: ChatClient.SessionInfo) {
        let content = UNMutableNotificationContent()
        content.title = session.project ?? session.title
        // 问题原文就是通知正文:不点进去也知道该不该现在管
        content.body = session.question ?? String(localized: "agent 在等你回复")
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.userInfo = ["session": session.id.uuidString]
        let request = UNNotificationRequest(identifier: session.id.uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

extension ReplyNotifier: UNUserNotificationCenterDelegate {
    /// app 开着时也要横幅:用户可能正在别的 tab 里看东西
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let raw = response.notification.request.content.userInfo["session"] as? String
        guard let id = raw.flatMap(UUID.init) else { return }
        await MainActor.run { self.pendingSessionID = id }
    }
}
