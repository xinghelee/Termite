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

    # 首个提示符抑制 zsh 的行尾标记(反白 %):shell 在视图完成布局前按默认宽度
    # 启动,开屏即打的 EOL 标记会被随后的 resize 反流搁浅成一枚游离 %。
    # 第二个提示符起恢复默认,不影响真实的「输出未换行」提示;
    # 用户 rc 若自己设了 PROMPT_EOL_MARK 则尊重其设置不动
    PROMPT_EOL_MARK=''
    _termite_restore_eol() {
      [[ -z "$PROMPT_EOL_MARK" ]] && unset PROMPT_EOL_MARK
      add-zsh-hook -d precmd _termite_restore_eol
      unfunction _termite_restore_eol
    }
    add-zsh-hook precmd _termite_restore_eol

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
    #
    # 宽图声明 width=100%(按终端宽度缩放)而不是留默认的原始像素:同一串字节
    # 会同时喂给 Mac 的宽画布和手机的窄画布,任何绝对尺寸必然在其中一端错 ——
    # 远程看截图时表现为手机上只露出左上角一块。小图(图标之类)保持原尺寸不放大
    imgcat() {
      local f size pixels args
      (( $# )) || { print -u2 "用法: imgcat <图片文件> ..."; return 1 }
      for f in "$@"; do
        if [[ ! -f "$f" ]]; then
          print -u2 "imgcat: 找不到文件 $f"
          continue
        fi
        size=$(stat -f%z "$f" 2>/dev/null || echo 0)
        pixels=$(sips -g pixelWidth "$f" 2>/dev/null | awk '/pixelWidth/ { print $2 }')
        args=""
        (( ${pixels:-0} > 640 )) && args="width=100%;preserveAspectRatio=1;"
        printf '\\e]1337;File=name=%s;size=%s;%sinline=1:%s\\a\\n' \\
          "$(printf '%s' "${f:t}" | base64)" "$size" "$args" "$(base64 < "$f")"
      done
    }
    alias icat=imgcat

    # 截当前启动的模拟器并内联显示,用法:simshot [-f] [保存路径]
    # 为「人在外面、用手机连回家里这台 Mac 开发 iOS」准备:手机端终端里直接看 UI。
    # 默认降到 1400px 再显示 —— 原图 6MB base64 完是 8MB,手机流量等半天,
    # 还会把远程镜像的回放缓冲一次冲干净(重连后图是碎的)。原图始终留在磁盘上
    simshot() {
      local full=0
      [[ "$1" == "-f" ]] && { full=1; shift }
      local out="${1:-$(mktemp -t simshot).png}"
      if ! xcrun simctl io booted screenshot "$out" 2>/dev/null; then
        print -u2 "simshot: 没有已启动的模拟器(先 open -a Simulator)"
        return 1
      fi
      _termite_show_shot "$out" "$full"
    }

    # 内联显示截图:默认缩到 1400px 的 JPEG(约 240KB,原图 PNG 是 8MB)。
    # 这个尺寸手机上够看清 UI,又刚好塞得进远程镜像 512K 的回放缓冲 ——
    # 断线重连后那张图还是完整的。要像素级细节用 -f 走原图。
    # 注意别用 path 当局部变量名 —— zsh 里它绑定着 PATH,一赋值这个函数里
    # 所有外部命令都会 command not found
    _termite_show_shot() {
      local shot="$1" full="$2" small
      if (( full )); then
        imgcat "$shot"
      else
        small=$(mktemp -t shot).jpg
        if sips -Z 1400 -s format jpeg -s formatOptions 75 "$shot" --out "$small" >/dev/null 2>&1; then
          imgcat "$small"
          command rm -f "$small"
        else
          imgcat "$shot"
        fi
      fi
      print -u2 "→ $shot"
    }

    # 真机截图(需要设备已连接/已配对),用法:devshot [-f] [保存路径]
    devshot() {
      local full=0
      [[ "$1" == "-f" ]] && { full=1; shift }
      local out="${1:-$(mktemp -t devshot).png}" udid
      # 机器名里有空格(「iPad Pro 13-inch (M5)」),不能按列号取,认 UUID 形状
      udid=$(xcrun devicectl list devices 2>/dev/null \\
             | awk '/connected/ && /physical/ { for (i=1; i<=NF; i++) if ($i ~ /^[0-9A-F]{8}-/) { print $i; exit } }')
      if [[ -z "$udid" ]]; then
        print -u2 "devshot: 没有已连接的真机"
        return 1
      fi
      xcrun devicectl device screenshot --device "$udid" "$out" >/dev/null 2>&1 || {
        print -u2 "devshot: 截图失败(设备可能锁屏或未信任)"
        return 1
      }
      _termite_show_shot "$out" "$full"
    }

    # 在 Termite 开新标签:termite [目录],缺省当前目录
    termite() { open -a Termite "${1:-$PWD}" }

    """

    /// bash 无 preexec,只发 D(上条退出码)/ 7(cwd)/ A(提示符);耗时统计降级
    private static let bashPromptCommand =
        #"_termite_st=$?; printf '\e]133;D;%s\a\e]7;file://%s%s\a\e]2;%s\a\e]133;A\a' "$_termite_st" "$HOSTNAME" "${PWD// /%20}" "${PWD/#$HOME/\~}""#

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
