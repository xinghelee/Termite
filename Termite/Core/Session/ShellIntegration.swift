import Foundation

/// Shell 集成自动注入:让 zsh/bash 免配置发出 OSC 133(命令标记)与 OSC 7(工作目录)。
/// - zsh:ZDOTDIR 指向包装目录,其 .zshenv 先接回用户原配置,交互式会话再挂集成钩子
/// - bash:经环境注入 PROMPT_COMMAND(降级:无 C 标记,不统计耗时)
/// - fish:3.6+ 原生支持,无需注入
enum ShellIntegration {

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Termite/shell-integration", isDirectory: true)
    }

    private static var zdotdirWrapper: URL { directory.appendingPathComponent("zdotdir", isDirectory: true) }

    /// 启动时写入(幂等覆盖,保证升级后脚本最新)
    static func ensureInstalled() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: zdotdirWrapper, withIntermediateDirectories: true)
            let hooks = directory.appendingPathComponent("termite.zsh")
            try zshHooks.write(to: hooks, atomically: true, encoding: .utf8)
            let bootstrap = zshBootstrap(hooksPath: hooks.path)
            try bootstrap.write(to: zdotdirWrapper.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        } catch {
            NSLog("Termite: shell integration install failed: \(error)")
        }
    }

    /// 按 shell 类型往子进程环境注入集成配置
    static func apply(to env: inout [String: String], shellPath: String) {
        switch (shellPath as NSString).lastPathComponent {
        case "zsh":
            if let original = env["ZDOTDIR"] { env["TERMITE_ORIG_ZDOTDIR"] = original }
            env["ZDOTDIR"] = zdotdirWrapper.path
        case "bash", "sh":
            env["PROMPT_COMMAND"] = bashPromptCommand
        default:
            break // fish 等自带集成
        }
    }

    // MARK: - 脚本内容

    /// 包装目录 .zshenv:恢复原 ZDOTDIR → 接原 .zshenv → 交互式会话挂钩子。
    /// 钩子在用户 rc 之前注册,若用户 rc 也注册 precmd(如主题),其标题设置会在我们之后执行、自然覆盖。
    private static func zshBootstrap(hooksPath: String) -> String {
        """
        # Termite shell 集成引导(自动生成,勿手改)
        if [[ -n "$TERMITE_ORIG_ZDOTDIR" ]]; then
          export ZDOTDIR="$TERMITE_ORIG_ZDOTDIR"
          unset TERMITE_ORIG_ZDOTDIR
        else
          unset ZDOTDIR
        fi
        [[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]] && builtin source "${ZDOTDIR:-$HOME}/.zshenv"
        if [[ -o interactive ]]; then
          builtin source \(shellQuoted(hooksPath))
        fi
        """
    }

    /// OSC 133 提示符/输出/退出码标记 + OSC 7 工作目录 + OSC 2 标题(cwd)
    private static let zshHooks = """
    # Termite OSC 133/7 集成(自动生成,勿手改)
    (( ${+_termite_integrated} )) && return
    typeset -g _termite_integrated=1
    typeset -g _termite_executing=0

    autoload -Uz add-zsh-hook

    _termite_report_pwd() {
      local u="${PWD//\\%/%25}"
      u="${u// /%20}"
      printf '\\e]7;file://%s%s\\a' "$HOST" "$u"
      printf '\\e]2;%s\\a' "${PWD/#$HOME/~}"
    }

    _termite_precmd() {
      local st=$?
      if (( _termite_executing )); then
        printf '\\e]133;D;%s\\a' "$st"
        _termite_executing=0
      fi
      _termite_report_pwd
      printf '\\e]133;A\\a'
    }

    _termite_preexec() {
      _termite_executing=1
      printf '\\e]133;C\\a'
    }

    add-zsh-hook precmd _termite_precmd
    add-zsh-hook preexec _termite_preexec
    _termite_report_pwd

    # 终端内联看图(iTerm2 OSC 1337 协议,Termite 原生渲染),用法:imgcat 图.png
    imgcat() {
      local f size
      (( $# )) || { print -u2 "用法: imgcat <图片文件> ..."; return 1 }
      for f in "$@"; do
        if [[ ! -f "$f" ]]; then
          print -u2 "imgcat: 找不到文件 $f"
          continue
        fi
        size=$(stat -f%z "$f" 2>/dev/null || echo 0)
        printf '\\e]1337;File=name=%s;size=%s;inline=1:%s\\a\\n' \\
          "$(printf '%s' "${f:t}" | base64)" "$size" "$(base64 < "$f")"
      done
    }
    alias icat=imgcat

    """

    /// bash 无 preexec,只发 D(上条退出码)/ 7(cwd)/ A(提示符);耗时统计降级
    private static let bashPromptCommand =
        #"_termite_st=$?; printf '\e]133;D;%s\a\e]7;file://%s%s\a\e]2;%s\a\e]133;A\a' "$_termite_st" "$HOSTNAME" "${PWD// /%20}" "${PWD/#$HOME/\~}""#

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
