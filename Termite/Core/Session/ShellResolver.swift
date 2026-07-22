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
            env["LANG"] = synthesizedLANG
        }
        // Xcode 启动调试时会带上一堆 DYLD/调试变量,不传给 shell
        for key in env.keys where key.hasPrefix("DYLD_") || key.hasPrefix("XPC_") {
            env.removeValue(forKey: key)
        }
        return env
    }

    /// 合成的 LANG 必须是系统真实存在的 locale:无效名字会让 zsh setlocale
    /// 静默退回 C locale,zle 按单字节拆多字节输入(中文变 <0080><0081>)。
    /// 固定用 en_US.UTF-8:macOS 上所有 *.UTF-8 的 LC_CTYPE 都软链到同一份
    /// C.UTF-8 数据,中文输入/宽度计算与 zh_CN.UTF-8 无差别,而工具提示保持英文。
    static let synthesizedLANG = "en_US.UTF-8"
}
