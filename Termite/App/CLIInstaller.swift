import AppKit
import Foundation

/// `termite` 命令行工具安装:/usr/local/bin/termite(zsh 用户其实已内置同名函数,
/// 这个给 bash/fish/脚本等场景)。直接写失败时走管理员授权回退。
enum CLIInstaller {

    static let scriptBody = """
    #!/bin/sh
    # Termite CLI:在 Termite 中打开目录(缺省当前目录)
    exec open -a Termite "${1:-$PWD}"
    """

    @MainActor
    static func install() -> String {
        let target = "/usr/local/bin/termite"
        do {
            try FileManager.default.createDirectory(atPath: "/usr/local/bin", withIntermediateDirectories: true)
            try scriptBody.write(toFile: target, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
            return String(localized: "已安装:\(target)")
        } catch {
            // 权限不足 → 管理员授权拷贝
            let temp = NSTemporaryDirectory() + "termite-cli-\(UUID().uuidString)"
            do {
                try scriptBody.write(toFile: temp, atomically: true, encoding: .utf8)
            } catch {
                return String(localized: "安装失败:\(error.localizedDescription)")
            }
            let command = "mkdir -p /usr/local/bin && cp '\(temp)' /usr/local/bin/termite && chmod 755 /usr/local/bin/termite"
            let source = "do shell script \"\(command)\" with administrator privileges"
            var errorInfo: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
            try? FileManager.default.removeItem(atPath: temp)
            if errorInfo == nil {
                return String(localized: "已安装:\(target)")
            }
            return String(localized: "安装取消或失败")
        }
    }
}
