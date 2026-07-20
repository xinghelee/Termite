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
            env["LANG"] = utf8LocaleName(for: Locale.current)
        }
        // Xcode 启动调试时会带上一堆 DYLD/调试变量,不传给 shell
        for key in env.keys where key.hasPrefix("DYLD_") || key.hasPrefix("XPC_") {
            env.removeValue(forKey: key)
        }
        return env
    }

    /// 合成的 LANG 必须是系统真实存在的 locale:app 内 Locale.current 是
    /// 「应用语言+地区」组合(如 zh-Hans_PH),直接拼 .UTF-8 得到的名字
    /// /usr/share/locale 里往往没有,zsh setlocale 失败会静默退回 C locale,
    /// zle 随即按单字节拆多字节输入(中文变 <0080><0081>)、按字节给提示符计宽。
    static func utf8LocaleName(for locale: Locale) -> String {
        let lang = locale.language.languageCode?.identifier ?? "en"
        let region = locale.region?.identifier ?? "US"
        var candidates = ["\(lang)_\(region)"]
        switch lang {
        case "zh":
            candidates.append(locale.language.script?.identifier == "Hant" ? "zh_TW" : "zh_CN")
        case "ja":
            candidates.append("ja_JP")
        case "ko":
            candidates.append("ko_KR")
        default:
            break
        }
        candidates.append("en_US")
        for name in candidates.map({ "\($0).UTF-8" })
        where FileManager.default.fileExists(atPath: "/usr/share/locale/\(name)/LC_CTYPE") {
            return name
        }
        return "en_US.UTF-8"
    }
}
