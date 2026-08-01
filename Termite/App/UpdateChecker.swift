import AppKit
import Observation

/// 基于 GitHub Release 的更新检查:拉 releases/latest,比对 tag 与本机版本。
/// 手动检查(菜单「检查更新…」)弹窗反馈;启动自动检查(24h 一次)静默进行,
/// 发现新版发系统通知并点亮菜单项 / 菜单栏入口。
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()

    struct AvailableUpdate {
        let version: String
        let notes: String
        let pageURL: URL
        let dmgURL: URL?
    }

    /// 已发现的新版本(nil = 无);菜单项与菜单栏入口据此点亮
    private(set) var available: AvailableUpdate?
    @ObservationIgnored private var checking = false

    private static let lastCheckKey = "update.lastCheckedAt"
    private static let apiURL = URL(string: "https://api.github.com/repos/xinghelee/Termite/releases/latest")!
    private static let fallbackPage = URL(string: "https://github.com/xinghelee/Termite/releases/latest")!

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// 启动自动检查:设置可关,24h 至多一次,失败静默
    func checkOnLaunch() {
        let auto = UserDefaults.standard.object(forKey: SettingsKeys.autoCheckUpdates) as? Bool ?? true
        guard auto else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        Task { await check(interactive: false) }
    }

    /// 菜单「检查更新…」:无论结果都弹窗反馈
    func checkInteractively() {
        Task { await check(interactive: true) }
    }

    /// 打开下载(优先 DMG 直链,无则 Release 页)
    func openDownload() {
        let url = available.map { $0.dmgURL ?? $0.pageURL } ?? Self.fallbackPage
        NSWorkspace.shared.open(url)
    }

    private func check(interactive: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        do {
            var request = URLRequest(url: Self.apiURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let release = try decoder.decode(GitHubRelease.self, from: data)
            let version = release.tagName.hasPrefix("v")
                ? String(release.tagName.dropFirst()) : release.tagName
            guard Self.isNewer(version, than: currentVersion) else {
                available = nil
                if interactive { presentUpToDate() }
                return
            }
            available = AvailableUpdate(
                version: version,
                notes: release.body ?? "",
                pageURL: URL(string: release.htmlUrl) ?? Self.fallbackPage,
                dmgURL: release.assets
                    .first { $0.name.hasSuffix(".dmg") }
                    .flatMap { URL(string: $0.browserDownloadUrl) }
            )
            if interactive {
                presentUpdateFound()
            } else {
                NotificationService.postUpdateAvailable(version: version)
            }
        } catch {
            if interactive { presentFailure(error) }
        }
    }

    /// 版本号逐段数值比较:"1.10" > "1.9"(字符串比较会判反)
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - 弹窗(仅手动检查)

    private func presentUpdateFound() {
        guard let available else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "Termite \(available.version) 已发布")
        var notes = available.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 600 { notes = String(notes.prefix(600)) + "…" }
        alert.informativeText = notes.isEmpty
            ? String(localized: "当前版本 \(currentVersion)。")
            : notes
        alert.addButton(withTitle: String(localized: "下载"))
        alert.addButton(withTitle: String(localized: "稍后"))
        if alert.runModal() == .alertFirstButtonReturn {
            openDownload()
        }
    }

    private func presentUpToDate() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "已是最新版本")
        alert.informativeText = String(localized: "Termite \(currentVersion) 即为最新发布版本。")
        alert.runModal()
    }

    private func presentFailure(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "检查更新失败")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

/// GitHub releases/latest 应答(snake_case 经 convertFromSnakeCase 映射)
private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlUrl: String
    let body: String?
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: String
    }
}
