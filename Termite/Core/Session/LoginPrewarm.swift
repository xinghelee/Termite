import AppKit
import Foundation
import os

/// 登录预热:装一个 LaunchAgent,登录时就把 termite-ptyhost 拉起来,并照着 app 落下的
/// 计划把上次那些标签的 shell 提前孵好。
///
/// 「重启电脑后第一次打开」是唯一一次所有 shell 都必须冷孵化的场景(守护进程随关机
/// 一起没了,日常重启 app 都是接回活会话)。实测几十个 zsh 同时冷启动,连用户正盯着的
/// 那个标签都要被拖慢一倍。把这份成本挪到登录时——那会儿没人在等。
///
/// 卸载只删 plist、不 bootout:bootout 会 SIGTERM 掉正在跑的守护进程,
/// 连坐杀掉里面所有保活会话。下次登录不再拉起即可。
@MainActor
enum LoginPrewarm {
    private static let log = Logger(subsystem: "com.termite.app", category: "keepalive")

    /// 与 socket 同一套构建隔离:开发构建别去顶正式版的 agent
    static var label: String {
        var name = "com.termite.ptyhost"
        if let bundleID = Bundle.main.bundleIdentifier, bundleID != "com.termite.app" {
            name += "." + bundleID
        }
        #if DEBUG
        name += ".debug"
        #endif
        return name
    }

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// 装 LaunchAgent(下次登录生效——本次登录守护进程多半已在跑,不去打扰它)
    @discardableResult
    static func install() -> Bool {
        guard let daemon = Bundle.main.url(forAuxiliaryExecutable: "termite-ptyhost") else {
            log.error("装不了登录预热:bundle 里找不到 termite-ptyhost")
            return false
        }
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [daemon.path, "--resident", "--prewarm"],
            "RunAtLoad": true,
        ]
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            log.notice("登录预热已安装:\(plistURL.path, privacy: .public)")
            return true
        } catch {
            log.error("登录预热安装失败:\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func uninstall() {
        try? FileManager.default.removeItem(at: plistURL)
        removePlan()
    }

    // MARK: - 预热计划

    static func writePlan(_ plan: PtyPrewarmPlan) {
        guard let data = try? JSONEncoder().encode(plan) else { return }
        try? FileManager.default.createDirectory(
            at: PtyHostPaths.prewarmPlanURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: PtyHostPaths.prewarmPlanURL, options: .atomic)
    }

    static func removePlan() {
        try? FileManager.default.removeItem(at: PtyHostPaths.prewarmPlanURL)
    }
}
