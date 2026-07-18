import Darwin
import Foundation

/// 解析用户的登录 shell 与终端子进程环境。
/// GUI app 拿不到终端里的 SHELL 环境变量,以 passwd 记录(getpwuid)为准。
enum ShellResolver {

    static func loginShell() -> String {
        if let override = UserDefaults.standard.string(forKey: SettingsKeys.shellPath),
           !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        if let pw = getpwuid(getuid()), let raw = pw.pointee.pw_shell {
            let shell = String(cString: raw)
            if !shell.isEmpty { return shell }
        }
        return "/bin/zsh"
    }

    /// 子进程环境:继承 GUI 环境 + 终端身份标识。PATH 交给登录 shell 的 /etc/zprofile(path_helper)补全。
    static func environmentDict() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Termite"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        if env["LANG"] == nil {
            let locale = Locale.current.identifier.replacingOccurrences(of: "-", with: "_")
            env["LANG"] = locale.contains("_") ? "\(locale).UTF-8" : "en_US.UTF-8"
        }
        // Xcode 启动调试时会带上一堆 DYLD/调试变量,不传给 shell
        for key in env.keys where key.hasPrefix("DYLD_") || key.hasPrefix("XPC_") {
            env.removeValue(forKey: key)
        }
        return env
    }
}
