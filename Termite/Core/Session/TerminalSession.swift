import AppKit
import Foundation
import Observation
import SwiftTerm

/// 会话恢复时的保活重连票据:守护进程里的会话 ID + 上次已消费的输出偏移
struct PtyReattach {
    let id: UUID
    let offset: UInt64
}

/// 本地终端会话:持有一个 TermiteTerminalView(内嵌 PTY 子进程)。
/// 负责 shell 启动、OSC 133 命令跟踪(⌘↑/⌘↓ 跳转、复制输出、退出码/耗时)、
/// OSC 7 工作目录、标题、git 分支探测、会话录制与退出处理。
/// 生命周期跟随 SessionManager,不跟随视图 —— 切换标签不丢 scrollback。
@MainActor
@Observable
final class TerminalSession: Identifiable {
    enum State: Equatable {
        case running
        case exited(Int32?)
    }

    /// 保活会话沿用 daemon PTY ID，Mac App 重启后远端书签和正在附着的设备仍指向同一会话。
    let id: UUID
    let terminalView: TermiteTerminalView

    private(set) var state: State = .running
    private(set) var startedAt = Date()
    /// OSC 0/2 标题(shell 集成或程序设置)
    private(set) var title = ""
    /// 当前工作目录(OSC 7 上报)
    private(set) var workingDirectory: String?
    /// 当前 cwd 的 git 分支(直读 .git/HEAD,零子进程)
    private(set) var gitBranch: String?
    /// 未提交文件数(状态栏 ●n;非仓库为 nil)
    private(set) var gitDirtyCount: Int?
    /// git 提交身份的变更计数:配置文件(仓库 config / 全局 gitconfig)动过就 +1,
    /// 状态栏据此重读身份 —— 终端里 git config user.email 改完立刻反映到条上
    private(set) var gitIdentityRevision = 0
    /// 输出里检测到的最近一个本机服务 URL(dev server 场景,状态栏一键打开)
    private(set) var detectedLocalURL: String?
    /// 最近一条命令的退出码(需 OSC 133 shell 集成)
    private(set) var lastExitCode: Int?
    /// 最近一条命令的耗时(OSC 133 C→D)
    private(set) var lastCommandDuration: TimeInterval?
    /// 当前是否正在执行命令(OSC 133 C..D 之间)
    private(set) var runningCommand = false
    /// 命令连续跑超过阈值(ssh / dev server / TUI 这类长驻进程):
    /// 转圈指示降级为静态点,别让菊花永动干扰视线(issue #9)
    private(set) var longRunningCommand = false
    /// 当前命令开始执行的时间(驱动状态栏实时计时)
    private(set) var commandRunningSince: Date?
    /// 是否有可复制的命令输出(驱动菜单可用态)
    private(set) var hasCommandOutput = false
    /// 后台标签活动:非可见会话有新输出时点亮,聚焦后由 SessionManager 清除
    var hasUnseenActivity = false
    /// 远端设备接管中(独占 PTY 网格与输入)的设备名;nil = Mac 自己控制。
    /// 驱动 pane 遮罩:接管期间 Mac 只按对方网格渲染,点一下或敲一下即夺回
    private(set) var remoteController: String?
    /// pane 注意力(等待输入 / 命令完成):驱动 pane 徽标与呼吸边框、标签橙点、侧边栏提醒点
    private(set) var attention: PaneAttention = .none
    /// 进入注意力态的时间(⌘J 按等待最久优先跳转)
    private(set) var attentionSince: Date?
    /// 失焦 pane 命令刚结束的一次性边框闪烁信号(叶子视图消费)
    private(set) var finishFlash: FinishFlash?
    /// 选中即复制成功的一次性 toast 信号(pane 视图消费;每次复制换新时间戳触发 onChange)
    private(set) var copyToast: Date?
    @ObservationIgnored private var silenceHeuristic = SilenceHeuristic()
    @ObservationIgnored private var silenceWatch: Task<Void, Never>?
    @ObservationIgnored private var lastAttentionNotice = Date.distantPast
    /// 恢复会话的 backlog 回灌里可能带着历史 BEL,启动初期的响铃不算注意力
    /// (markTransportReady 时再顺延,覆盖守护进程冷启动慢于此窗口的情况)
    @ObservationIgnored private var bellArmedAt = Date().addingTimeInterval(5)
    /// 收到过用户输入才把后台输出算作新活动:恢复会话时 shell 启动输出
    /// (zshrc 初始化、首个提示符)会打到所有后台标签,不该点亮绿点
    private var hasReceivedUserInput = false
    /// 保活传输:非 nil = shell 活在 termite-ptyhost 守护进程里(app 重启不丢);
    /// nil = 本地 LocalProcess 直连(保活关闭 / 守护进程不可用 / 下拉终端)
    @ObservationIgnored private(set) var hostPtyID: UUID?
    var usesHostTransport: Bool { hostPtyID != nil }
    /// 落盘票据:活连接用当前会话;回落本地时沿用押着的孤儿票据,下次启动接回真身
    var persistableReattach: PtyReattach? {
        if let hostPtyID { return PtyReattach(id: hostPtyID, offset: consumedHostOffset) }
        return orphanedReattach
    }
    /// 传输就绪前(保活握手 + CREATE 往返,冷启动拉守护进程可达秒级)的键入
    /// 先攒着,就绪后按原序补发;此前这段输入直接打进未启动的 LocalProcess 丢掉
    @ObservationIgnored private var transportReady = false
    @ObservationIgnored private var pendingInput: [UInt8] = []
    /// 已消费的守护进程输出流偏移(持久化后用于重连断点续传)
    @ObservationIgnored private(set) var consumedHostOffset: UInt64 = 0
    @ObservationIgnored private var pendingReattach: PtyReattach?
    /// 接回失败/守护进程连不上时押着的票据:真身还活在守护进程里。
    /// 丢了它,下次启动真身就被孤儿收养成重复标签(存档同项目 ×2/×4/×6 的元凶)
    @ObservationIgnored private var orphanedReattach: PtyReattach?
    /// 命令时间线(OSC 133 完整周期的记录,新在后)
    private(set) var commandHistory: [CommandRecord] = []
    /// 当前正在录制到的文件 URL(nil = 未录制)
    private(set) var logURL: URL?
    var isLogging: Bool { logURL != nil }
    /// asciinema 录制中的 .cast 文件(nil = 未录制)
    private(set) var castURL: URL?
    var isCasting: Bool { castURL != nil }

    let shellPath: String
    var shellName: String { (shellPath as NSString).lastPathComponent }

    /// 用户自定义分屏名(右键「重命名分屏」;区分同目录多 agent),优先于一切自动标题
    var customName: String?

    /// 空白/空串回落自动标题;改名随手落盘
    func setCustomName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        customName = trimmed.isEmpty ? nil : trimmed
        manager?.layoutChangedSoon()
    }

    /// 标签 chip / 标题胶囊显示名:自定义名 > OSC 标题(压缩为最后一段目录)> cwd 目录名 > shell 名
    var displayTitle: String {
        if let customName { return customName }
        if !title.isEmpty { return Self.compactTitle(title) }
        if let dir = workingDirectory {
            let short = (dir as NSString).abbreviatingWithTildeInPath
            return short == "~" ? "~" : (short as NSString).lastPathComponent
        }
        return shellName
    }

    /// shell 默认标题形如 "user@host:/full/path" 或纯路径 → 只留最后一段目录;
    /// 程序自定义标题(vim README.md 等)原样保留
    static func compactTitle(_ title: String) -> String {
        let path: Substring
        if let colon = title.lastIndex(of: ":"),
           let first = title[title.index(after: colon)...].first, first == "/" || first == "~" {
            path = title[title.index(after: colon)...]
        } else if title.hasPrefix("/") || title.hasPrefix("~") {
            path = title[...]
        } else {
            return title
        }
        let last = (String(path) as NSString).lastPathComponent
        return last.isEmpty ? String(path) : last
    }

    /// shell 进程退出时回调,由 SessionManager 设为关闭该 pane
    @ObservationIgnored var onProcessExit: (() -> Void)?
    /// 所属窗口的会话管理器(下拉终端会话为 nil)
    @ObservationIgnored weak var manager: SessionManager?

    @ObservationIgnored private var commandStartedAt: Date?
    /// 长驻判定的延时翻转(命令结束即取消)
    @ObservationIgnored private var longRunningFlip: DispatchWorkItem?
    /// 连续运行超过这个秒数视为长驻进程
    private static let longRunningThreshold: TimeInterval = 15
    /// 提示符位置标记(scroll-invariant 行号),⌘↑/⌘↓ 在命令间跳转
    @ObservationIgnored private var commandMarks: [Int] = []
    @ObservationIgnored private var pendingOutputStart: Int?
    @ObservationIgnored private var pendingPromptRow: Int?
    @ObservationIgnored private var pendingCommandText = ""
    /// scroll-invariant 行号的已知边界(增量探测,避免每个提示符全量扫描)
    @ObservationIgnored private var siLower = 0
    @ObservationIgnored private var siUpper = 0
    @ObservationIgnored private var osc133 = OSC133Scanner()
    @ObservationIgnored private var synchronizedOutputScanner = SynchronizedOutputScanner()
    @ObservationIgnored private var inlineTUIActive = false
    var requiresSharedTUILayout: Bool {
        let terminal = terminalView.getTerminal()
        return terminal.isCurrentBufferAlternate || inlineTUIActive || terminal.mouseMode != .off
    }
    /// 本次会话「新内容」的起始 SI 行:恢复回灌的旧内容之前,不参与下次快照(防横幅叠罗汉)
    @ObservationIgnored private var snapshotFloor = 0
    @ObservationIgnored private var logHandle: FileHandle?
    @ObservationIgnored private var castHandle: FileHandle?
    @ObservationIgnored private var castStartedAt: Date?
    @ObservationIgnored private var gitProbeTask: Task<Void, Never>?
    @ObservationIgnored private var gitDirtyTask: Task<Void, Never>?
    @ObservationIgnored private var lastGitDirtyProbeAt = Date.distantPast
    @ObservationIgnored private var gitIdentityTask: Task<Void, Never>?
    @ObservationIgnored private var gitIdentityStamp: String?

    /// manager 必须在 init 传入(而非事后赋值):start() 里靠它区分
    /// 普通会话(可保活)与下拉终端(始终本地直连)
    init(workingDirectory directory: String? = nil, restoreScrollback: String? = nil,
         reattach: PtyReattach? = nil, spawnDelay: TimeInterval = 0, manager: SessionManager? = nil) {
        id = reattach?.id ?? UUID()
        shellPath = ShellResolver.loginShell()
        isSerial = false
        self.spawnDelay = spawnDelay
        pendingReattach = reattach
        self.manager = manager
        let view = Self.makeConfiguredView()
        terminalView = view
        view.session = self
        view.processDelegate = self
        // 上次会话的屏幕内容:起 shell 之前灰字回灌,像 iTerm2 一样"从上次的位置继续"
        if let restoreScrollback, !restoreScrollback.isEmpty {
            let normalized = restoreScrollback.replacingOccurrences(of: "\n", with: "\r\n")
            let stamp = Date().formatted(date: .omitted, time: .shortened)
            view.feed(text: "\u{1b}[2m" + normalized + "\r\n─── 以上为上次会话内容 · \(stamp) 恢复 ───\u{1b}[0m\r\n")
            // 回灌的旧内容不参与下次快照
            refreshScrollInvariantBounds()
            snapshotFloor = siUpper
        }
        start(in: directory)
    }

    /// 串口会话(issue #6):打开 /dev/cu.* 设备直连终端视图(8N1)。
    /// 无 shell、无保活、不进会话快照;断开保留画面示错,由用户 ⌘W 关闭
    init?(serialDevice: String, baud: Int, localEcho: Bool = false, manager: SessionManager?) {
        guard let fd = SerialPort.open(path: serialDevice, baud: baud) else { return nil }
        id = UUID()
        shellPath = serialDevice // shellName / 标签标题借此显示设备名
        isSerial = true
        serialLocalEcho = localEcho
        spawnDelay = 0
        pendingReattach = nil
        self.manager = manager
        let view = Self.makeConfiguredView()
        terminalView = view
        view.session = self
        view.processDelegate = self
        serialFD = fd
        markTransportReady()
        startSerialReader(fd: fd)
        view.feed(text: "\u{1b}[2m─── \(String(localized: "串口已连接")) \(serialDevice) @ \(baud) ───\u{1b}[0m\r\n")
    }

    /// 两种会话共用的视图装配(字体/主题/滚回/光标偏好)。
    /// Metal 由 TermiteTerminalView 在挂进窗口后启用:离窗初始化会渲染不刷新/光标异常
    private static func makeConfiguredView() -> TermiteTerminalView {
        let view = TermiteTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.font = FontPrefs.font()
        view.optionAsMetaKey = UserDefaults.standard.object(forKey: SettingsKeys.optionAsMeta) as? Bool ?? true
        view.allowMouseReporting = UserDefaults.standard.object(forKey: SettingsKeys.mouseReporting) as? Bool ?? true
        let scrollback = UserDefaults.standard.object(forKey: SettingsKeys.scrollbackLines) as? Int ?? 10_000
        view.getTerminal().changeScrollback(scrollback)
        ThemeStore.shared.apply(to: view)
        CursorPrefs.apply(to: view)
        return view
    }

    // MARK: - 串口传输(v1:本地直连,无保活)

    /// 串口标记(会话快照/保活/项目归属全部跳过)
    let isSerial: Bool
    /// 本地回显:哑设备(不回显键入)场景在本端直接显示键入内容
    @ObservationIgnored private var serialLocalEcho = false
    @ObservationIgnored private var serialFD: Int32?
    @ObservationIgnored private var serialSource: DispatchSourceRead?
    /// 串口写队列:fd 是 O_NONBLOCK 的,低波特率大粘贴会 EAGAIN,
    /// 在后台队列按背压重试写完,不丢字节也不卡主线程
    @ObservationIgnored private let serialWriteQueue = DispatchQueue(label: "termite.serial.write", qos: .userInitiated)

    private func startSerialReader(fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                let bytes = Array(buffer[0..<count])
                DispatchQueue.main.async { self?.processOutput(ArraySlice(bytes)) }
            } else if count == 0 || errno != EAGAIN {
                // EOF / 设备拔出:读源先停,主线程标记断开
                DispatchQueue.main.async { self?.serialDisconnected() }
            }
        }
        source.setCancelHandler { close(fd) }
        serialSource = source
        source.resume()
    }

    private func serialDisconnected() {
        guard serialFD != nil else { return }
        serialFD = nil
        let source = serialSource
        serialSource = nil
        serialWriteQueue.async { source?.cancel() }
        state = .exited(nil)
        terminalView.feed(text: "\r\n\u{1b}[31m─── \(String(localized: "串口连接已断开")) ───\u{1b}[0m\r\n")
    }

    private func start(in directory: String?) {
        var env = ShellResolver.environmentDict()
        let integrationEnabled = UserDefaults.standard.object(forKey: SettingsKeys.shellIntegration) as? Bool ?? true
        if integrationEnabled {
            ShellIntegration.apply(to: &env, shellPath: shellPath)
        }
        let cwd = directory ?? FileManager.default.homeDirectoryForCurrentUser.path
        workingDirectory = cwd
        probeGitBranch(cwd)
        // 保活依赖启动恢复:恢复关了没人接回会话,守护进程只会攒僵尸。
        // 单测宿主 app 里禁用:测试不该拉起真守护进程、留下真 shell 会话
        let keepAlive = (UserDefaults.standard.object(forKey: SettingsKeys.sessionPersistence) as? Bool ?? true)
            && (UserDefaults.standard.object(forKey: SettingsKeys.restoreSessions) as? Bool ?? true)
            && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        if keepAlive, manager != nil { // 下拉终端(manager nil)不参与保活
            let reattach = pendingReattach
            pendingReattach = nil
            Task { await startViaHost(env: env, cwd: cwd, reattach: reattach) }
        } else if spawnDelay > 0 {
            // 恢复错峰(本地直连路径):批量冷启动排队,削掉并发尖峰
            Task {
                try? await Task.sleep(for: .seconds(spawnDelay))
                guard !didShutdown else { return }
                launchLocal(env: env, cwd: cwd)
            }
        } else {
            launchLocal(env: env, cwd: cwd)
        }
    }

    /// 恢复错峰:>0 时冷启动 spawn 推迟这么久再发(接回活会话的 attach 不延迟)
    private let spawnDelay: TimeInterval
    /// 已关闭标记:错峰等待期间 pane 被关掉的话,别再把 shell 拉起来留孤儿
    private var didShutdown = false

    /// 本地直连(保活关闭或守护进程不可用时的回落路径)
    private func launchLocal(env: [String: String], cwd: String) {
        terminalView.startProcess(
            executable: shellPath,
            args: [],
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: "-" + shellName,   // argv[0] 带 "-":登录 shell(与 Terminal.app 一致)
            currentDirectory: cwd
        )
        markTransportReady()
    }

    /// 保活接不上时的回落:沿用恢复错峰。原来直奔 launchLocal,批量恢复一旦回落
    /// 就是上百个 zsh 挤在同一秒起爆——首屏空白好几分钟,和卡死没法区分
    private func launchLocalFallback(env: [String: String], cwd: String) async {
        if spawnDelay > 0 {
            try? await Task.sleep(for: .seconds(spawnDelay))
            guard !didShutdown else { return }
        }
        feedFallbackNotice()
        launchLocal(env: env, cwd: cwd)
    }

    /// 回落是静默降级(保活没了却看不出来):在屏上留一行,退出前就知道这会话不保留
    private func feedFallbackNotice() {
        feedNotice(String(localized: "会话保活不可用,已本地直连:退出后此会话不保留"))
    }

    /// 守护进程冷启动可能要几十秒(更新后首次 exec 要过 Gatekeeper 评估),
    /// 而空白面板加个光标与「卡死」长得一模一样:等太久就在屏上说明一句
    private func longWaitHint() -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, !didShutdown else { return }
            feedNotice(String(localized: "正在连接会话守护进程…"))
        }
    }

    private func feedNotice(_ text: String) {
        terminalView.feed(text: "\u{1b}[2m─── " + text + " ───\u{1b}[0m\r\n")
    }

    /// 保活路径:shell 进程活在 termite-ptyhost 里,app 只是显示器
    private func startViaHost(env: [String: String], cwd: String, reattach: PtyReattach?) async {
        let client = PtyHostClient.shared
        let hint = longWaitHint()
        let ready = await client.ensureReady()
        hint.cancel()
        guard ready else {
            orphanedReattach = reattach
            await launchLocalFallback(env: env, cwd: cwd)
            return
        }
        if let reattach {
            if await tryReattach(reattach, client: client) { return }
            // 接回失败先押票:若接下来全新 create 也失败(多半传输又断了),
            // 票据照常落盘,下次启动仍能接回真身
            orphanedReattach = reattach
        }
        // 恢复错峰:接不回才需要冷启动 spawn,批量恢复时排队发出,
        // 别十几个 zsh 同一秒挤爆 CPU(空屏干等提示符的元凶);选中标签延迟为 0
        if spawnDelay > 0 {
            try? await Task.sleep(for: .seconds(spawnDelay))
            guard !didShutdown else { return }
        }
        let terminal = terminalView.getTerminal()
        let request = PtyCreateRequest(
            id: id, shellPath: shellPath, argv0: "-" + shellName,
            env: env, cwd: cwd, cols: terminal.cols, rows: terminal.rows
        )
        bindHostCallbacks(id, client: client)
        if await client.create(request) != nil {
            // 全新会话顶替了接回失败的真身:真身判死,否则下次启动被收养成重复标签
            if let orphaned = orphanedReattach {
                client.kill(id: orphaned.id)
                orphanedReattach = nil
            }
            hostPtyID = id
            markTransportReady()
            // 票据(ptyID)立即落盘:此刻崩溃也能凭它接回刚建的会话
            manager?.layoutChangedSoon()
        } else {
            client.unbind(id)
            feedFallbackNotice() // 错峰已在上面等过,这里直接起
            launchLocal(env: env, cwd: cwd)
        }
    }

    /// 重连活会话:LIST 验活 → 按已消费偏移续传 backlog → 尺寸轻推触发重绘
    private func tryReattach(_ reattach: PtyReattach, client: PtyHostClient) async -> Bool {
        guard let listing = await client.list(),
              let info = listing.first(where: { $0.id == reattach.id }) else { return false }
        guard info.alive else {
            client.kill(id: reattach.id) // 死会话:清掉守护进程里的记录,走全新启动
            return false
        }
        // 新 Terminal 解析器没有旧屏幕状态，单纯从已消费 offset 续传会在空闲 TUI 上得到 0B。
        // 新守护进程从缓冲中最早的完整同步帧连续回放；旧守护进程回落到完整环形历史。
        let replayOffset = info.screenReplayOffset ?? info.headOffset
        bindHostCallbacks(reattach.id, since: replayOffset, client: client)
        guard let attached = await client.attach(id: reattach.id, since: replayOffset) else {
            client.unbind(reattach.id)
            return false
        }
        hostPtyID = reattach.id
        consumedHostOffset = max(consumedHostOffset, max(attached.fromOffset, reattach.offset))
        markTransportReady()
        kickRedraw()
        manager?.layoutChangedSoon()
        return true
    }

    private func bindHostCallbacks(_ ptyID: UUID, since offset: UInt64 = 0,
                                   client: PtyHostClient) {
        client.bind(ptyID, since: offset) { [weak self] offset, data in
            guard let self else { return }
            consumedHostOffset = offset + UInt64(data.count)
            processOutput(ArraySlice(data))
        } exited: { [weak self] code in
            guard let self else { return }
            state = .exited(code)
            stopLogging()
            onProcessExit?()
        }
    }

    /// 尺寸抖一下再复原:TIOCSWINSZ 只在尺寸变化时发 SIGWINCH。
    /// 重连后屏幕内容是快照回灌的,靠这一下让 zle / 全屏 TUI 重绘到真实状态;
    /// 巡视/最大化整屏重排后也用它兜底(动画期间 SIGWINCH 连发,部分 TUI 漏掉末次重绘)
    func kickRedraw() {
        guard let hostPtyID else { return }
        // 共享 TUI 的语义网格已经冻结。Mac 重附或切换本地布局时只重画本机，
        // 不能再用 rows-1/rows 的 SIGWINCH 让 iPhone、iPad 同步抖动一次。
        guard !terminalView.usesSharedTUIRenderGrid else {
            terminalView.needsDisplay = true
            return
        }
        let terminal = terminalView.getTerminal()
        // 只对备用屏或同步输出 TUI 做「行数减一再复原」的双 SIGWINCH 唤醒——
        // 它们才需要整块重绘;普通 shell 收最终尺寸自己会画,
        // 白挨这两下反而内容上移一行再弹回,肉眼可见地抖(巡视切换反馈)
        guard requiresSharedTUILayout else { return }
        PtyHostClient.shared.resize(id: hostPtyID, cols: terminal.cols, rows: max(terminal.rows - 1, 1))
        // 两步必须隔开:ssh 会话里 SIGWINCH 会合并,紧挨着发 ssh 只读到复原后的尺寸,
        // 与远端一致就不转发,远端 TUI(grok/deepseek cli 等)收不到任何变化、不重画
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.requiresSharedTUILayout,
                  let hostPtyID = self.hostPtyID else { return }
            let terminal = self.terminalView.getTerminal()
            PtyHostClient.shared.resize(id: hostPtyID, cols: terminal.cols, rows: terminal.rows)
        }
    }

    /// 视图网格尺寸变化(保活模式经协议转发,替代 LocalProcess 的 ioctl)
    func hostResize(cols: Int, rows: Int) {
        RemoteSessionHub.shared.macViewportChanged(session: self, cols: cols, rows: rows)
    }

    /// Hub 决定好语义网格后的 PTY resize 出口，不能再回到 hostResize 形成递归。
    func resizePTY(cols: Int, rows: Int) {
        if let hostPtyID {
            PtyHostClient.shared.resize(id: hostPtyID, cols: cols, rows: rows)
        } else if !isSerial, case .running = state {
            let terminal = terminalView.getTerminal()
            terminal.resize(cols: cols, rows: rows)
            terminalView.sizeChanged(source: terminalView, newCols: cols, newRows: rows)
        }
    }

    /// TUI 期间 Mac 解析器使用固定语义网格，像移动端一样只在本地适配画布。
    func setSharedTUIRenderGrid(_ grid: (Int, Int)?) {
        terminalView.setSharedTUIRenderGrid(grid)
    }

    /// 关闭 pane 时终止 shell 子进程。
    /// 交互式 zsh 默认忽略 SIGTERM(SwiftTerm terminate 只发 SIGTERM),
    /// 这里像 Terminal.app 一样先对整个进程组发 SIGHUP,连同前台命令一起挂断。
    func shutdown() {
        didShutdown = true
        stopLogging()
        stopCasting()
        gitProbeTask?.cancel()
        silenceWatch?.cancel()
        silenceWatch = nil
        if isSerial {
            // 先摘 fd(新写入不再入队),已入队的写在队列里冲完后再 cancel
            //(cancel handler 里 close fd),避免写到已关闭/被复用的 fd
            serialFD = nil
            let source = serialSource
            serialSource = nil
            serialWriteQueue.async { source?.cancel() }
            return
        }
        if let orphaned = orphanedReattach {
            // 回落本地期间被 ⌘W:守护进程里的真身一并判死,不然下次启动复活成重复标签
            orphanedReattach = nil
            PtyHostClient.shared.kill(id: orphaned.id)
        }
        if let hostPtyID {
            // 保活会话:⌘W/关窗是明确的「关闭」,连守护进程里的 shell 一起挂断。
            // app 退出(⌘Q)不走这里——socket 断开即自动 detach,shell 继续活着
            PtyHostClient.shared.unbind(hostPtyID)
            PtyHostClient.shared.kill(id: hostPtyID)
            return
        }
        if case .running = state {
            let pid = terminalView.process.shellPid
            if pid > 0 {
                kill(-pid, SIGHUP)
                kill(pid, SIGHUP)
                // SwiftTerm terminate 会先取消子进程监视器,没人收尸会留僵尸;后台阻塞 waitpid 收掉
                DispatchQueue.global(qos: .utility).async {
                    var status: Int32 = 0
                    waitpid(pid, &status, 0)
                }
            }
            terminalView.terminate()
        }
    }

    func focusTerminal() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    /// Mac 侧的一切主动输入(键入以外的目录跳转、历史命令、文件浏览器等)都走这里:
    /// 远端接管中先夺回控制权,不然文字打进去了、网格还归着对方
    func sendText(_ text: String) {
        if remoteController != nil { RemoteSessionHub.shared.reclaimControl(sessionID: id) }
        sendRawInput(Array(text.utf8))
    }

    /// Hub 在接管开始/结束时调用,驱动 pane 遮罩
    func setRemoteController(_ device: String?) {
        guard remoteController != device else { return }
        remoteController = device
    }

    func sendRawInput(_ bytes: [UInt8]) {
        hasReceivedUserInput = true
        trackCommandOrigin(bytes)
        guard transportReady else {
            pendingInput += bytes
            return
        }
        if let serialFD {
            let fd = serialFD
            serialWriteQueue.async {
                var remaining = ArraySlice(bytes)
                while !remaining.isEmpty {
                    let written = remaining.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
                    if written > 0 {
                        remaining = remaining.dropFirst(written)
                    } else if errno == EAGAIN {
                        usleep(2000) // 输出缓冲满(低波特率),背压等一拍再写
                    } else if errno != EINTR {
                        break // 设备已断开/关闭,读路径负责标记状态
                    }
                }
            }
            if serialLocalEcho {
                // 回车补 LF,否则光标只回行首不换行
                let echoed = bytes.flatMap { $0 == 0x0D ? [0x0D, 0x0A] : [$0] }
                terminalView.feed(byteArray: ArraySlice(echoed))
            }
        } else if let hostPtyID {
            PtyHostClient.shared.input(id: hostPtyID, bytes)
        } else {
            terminalView.process.send(data: bytes[...])
        }
    }

    /// 传输落定(保活接通 / 本地 shell 启动)后调用:补发就绪前攒下的键入
    private func markTransportReady() {
        transportReady = true
        // 重连的 backlog 在此之后立刻回灌,其中的历史 BEL 不算注意力
        bellArmedAt = max(bellArmedAt, Date().addingTimeInterval(2))
        // 视图常在 create 应答前就挂载到真实尺寸,那次 winsize 同步因传输未就绪被丢弃,
        // PTY 停在 init 的 800×600 推算网格。表现:新分屏首个提示符按旧列宽换行、
        // PROMPT_SP 残留反白 %、zle 光标错位到下次任意 resize 才恢复。此处按当前网格补一次
        terminalView.syncPtyWindowSize()
        guard !pendingInput.isEmpty else { return }
        let buffered = pendingInput
        pendingInput = []
        sendRawInput(buffered)
    }

    /// 焦点 pane 的用户键入(TermiteTerminalView.send 回调)→ 广播到同标签其它 pane
    func didSendUserInput(_ bytes: [UInt8]) {
        hasReceivedUserInput = true
        clearAttention()
        manager?.broadcastInput(from: id, bytes: bytes)
    }

    // MARK: - ⌘E 命令行浮层编辑(issue #3:像编辑文本一样编辑命令)

    /// 浮层编辑器内容(非 nil = 呈现浮层);OSC 133 B 记录的命令起点用于捕获已键入文本
    var composerDraft: String?
    /// 「在新 Worktree 中分屏」浮层(右键菜单触发,pane 内呈现,不持久化)
    var worktreePromptPresented = false
    @ObservationIgnored private var commandOrigin: (row: Int, col: Int)?

    /// 命令起点追踪:shell 集成只发 A/C/D 不发 B,拿不到「提示符结束」标记。
    /// 改在提示符后第一个可见字符按下的瞬间记录光标位置——回显尚未返回,
    /// 此刻光标就是输入区起点,与 B 等价;且无集成的 ssh 远端同样适用。
    /// 回车/⌃C 清锚,下一条命令的首个可见字符重新记录;转义序列(方向键等)不算
    private func trackCommandOrigin(_ bytes: [UInt8]) {
        guard !runningCommand else { return }
        var inEscape = false
        for b in bytes {
            if b == 0x1b { inEscape = true; continue }
            if inEscape {
                // CSI/SS3 的终结字节是字母或 ~,之前的参数字节一律跳过
                if (0x40...0x7e).contains(b), b != 0x5b, b != 0x4f { inEscape = false }
                continue
            }
            if b == 0x0d || b == 0x03 {
                commandOrigin = nil
                continue
            }
            if commandOrigin == nil, b >= 0x20, b != 0x7f {
                let terminal = terminalView.getTerminal()
                guard !terminal.isCurrentBufferAlternate else { return }
                commandOrigin = (currentScrollInvariantRow(), terminal.buffer.x)
            }
        }
    }

    /// ⌘E:把提示符处已键入的命令捞进浮层(命令运行中 / TUI 下不可用)
    func beginComposeCommand() {
        guard case .running = state, !runningCommand,
              !terminalView.getTerminal().isCurrentBufferAlternate else { return }
        composerDraft = capturedCommandText() ?? ""
    }

    func cancelComposeCommand() {
        composerDraft = nil
        focusTerminal()
    }

    /// 浮层确认:⌃E+⌃U 清空 zle 当前缓冲,回填编辑后的命令(bracketed paste 保多行)
    func applyComposedCommand(_ text: String, execute: Bool) {
        composerDraft = nil
        sendRawInput([0x05, 0x15]) // ⌃E 行尾 + ⌃U kill-whole-line
        if terminalView.getTerminal().bracketedPasteMode {
            sendText("\u{1b}[200~" + text + "\u{1b}[201~")
        } else {
            // 无括号粘贴时换行会逐行执行,降级为单行
            sendText(text.replacingOccurrences(of: "\n", with: " "))
        }
        if execute { sendRawInput([0x0d]) }
        focusTerminal()
    }

    /// 从命令起点(OSC 133 B 的行列)读到光标位置,折行拼接为逻辑行。
    /// 末行在光标列截断:RPROMPT、autosuggestions 幽灵补全都渲染在光标之后,不能捞
    private func capturedCommandText() -> String? {
        guard let origin = commandOrigin else { return nil }
        let terminal = terminalView.getTerminal()
        let cursorRow = currentScrollInvariantRow()
        guard cursorRow >= origin.row else { return nil }
        var lines: [String] = []
        for row in origin.row...cursorRow {
            guard let line = terminal.getScrollInvariantLine(row: row) else { break }
            var text = line.translateToString(trimRight: true)
            if row == cursorRow {
                text = String(text.prefix(terminal.buffer.x))
            }
            if row == origin.row {
                text = String(text.dropFirst(min(origin.col, text.count)))
            }
            lines.append(text)
        }
        // 屏幕折行是同一逻辑行,直接拼接
        let text = lines.joined()
        return text.trimmingCharacters(in: .whitespaces).isEmpty ? "" : text
    }

    /// ⌘K:清空回滚缓冲与屏幕(ED2 + ED3 + 归位),shell 下次重绘提示符
    func clearBuffer() {
        terminalView.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
        // 让 shell 重绘当前提示符(等价按下 ^L 的重绘,不产生新命令)
        sendRawInput([0x0c])
    }

    // MARK: - PTY 输出处理(OSC 133 标记流)

    /// 处理原始 PTY 输出:录制、扫描 OSC 133 事件,分段喂给终端,使标记与光标状态对齐
    func processOutput(_ bytes: ArraySlice<UInt8>) {
        let synchronizedOutputOffset = synchronizedOutputScanner.scan(bytes)
        defer {
            RemoteSessionHub.shared.observeTerminalMode(
                sessionID: id,
                isTUI: requiresSharedTUILayout
            )
        }
        // 下拉终端会话(manager nil)不参与活动提示
        if !hasUnseenActivity, hasReceivedUserInput, let manager, !manager.isSessionVisible(id) {
            hasUnseenActivity = true
        }
        trackAttentionOutput()
        appendToLog(bytes)
        appendToCast(bytes)
        RemoteSessionHub.shared.mirror(sessionID: id, bytes: bytes)
        scanForLocalURL(bytes)
        let events = osc133.scan(bytes)
        if events.isEmpty {
            terminalView.feed(byteArray: bytes)
            if synchronizedOutputOffset != nil { inlineTUIActive = true }
            return
        }
        var fed = bytes.startIndex
        for (event, offset) in events {
            let cut = bytes.startIndex + offset
            if cut > fed {
                terminalView.feed(byteArray: bytes[fed..<cut])
                fed = cut
            }
            handle(event)
        }
        if fed < bytes.endIndex {
            terminalView.feed(byteArray: bytes[fed...])
        }
        if let synchronizedOutputOffset {
            let resetAfterSynchronizedOutput = events.contains { event, offset in
                guard offset > synchronizedOutputOffset else { return false }
                switch event {
                case .promptStart, .commandEnd: return true
                case .commandStart, .outputStart: return false
                }
            }
            if !resetAfterSynchronizedOutput { inlineTUIActive = true }
        }
    }

    private func handle(_ event: OSC133Scanner.Event) {
        switch event {
        case .promptStart:
            inlineTUIActive = false
            runningCommand = false
            recordCommandMark()
        case .commandStart:
            // 提示符画完、命令输入区起点:⌘E 捕获已键入内容的锚
            commandOrigin = (currentScrollInvariantRow(), terminalView.getTerminal().buffer.x)
        case .outputStart:
            commandOrigin = nil
            runningCommand = true
            commandStartedAt = Date()
            commandRunningSince = commandStartedAt
            scheduleLongRunningFlip()
            SessionManagerRegistry.shared.updateDockBadge()
            let outputRow = currentScrollInvariantRow()
            pendingOutputStart = outputRow
            pendingPromptRow = commandMarks.last
            // 命令行文本 = 提示符行..输出起始行(含提示符前缀,原样展示)
            let textStart = pendingPromptRow ?? max(outputRow - 1, siLower)
            pendingCommandText = extractText(from: textStart, to: outputRow)
        case .commandEnd(let code):
            inlineTUIActive = false
            let duration = commandStartedAt.map { Date().timeIntervalSince($0) }
            commandStartedAt = nil
            commandRunningSince = nil
            runningCommand = false
            longRunningCommand = false
            longRunningFlip?.cancel()
            longRunningFlip = nil
            lastExitCode = code
            lastCommandDuration = duration
            recordCommand(code: code, duration: duration)
            attentionAfterCommandEnd(code: code, duration: duration)
            notifyIfLongCommand(code: code, duration: duration)
            SessionManagerRegistry.shared.updateDockBadge()
            // 命令可能改了仓库状态(git/编辑器/构建都会):
            // 分支直读 .git/HEAD 零子进程,每条命令后都刷(修 checkout 后状态栏不更新);
            // 脏计数是子进程,保持节流(分支变化时 probeGitBranch 内部会强刷)
            if let dir = workingDirectory {
                probeGitBranch(dir)
                if gitBranch != nil {
                    probeGitDirty(dir)
                    probeGitIdentity(dir)
                }
            }
        }
    }

    /// 命令开跑后挂一个阈值定时器:到点还没结束就标记为长驻(菊花 → 静态点)
    private func scheduleLongRunningFlip() {
        longRunningCommand = false
        longRunningFlip?.cancel()
        let startedAt = commandStartedAt
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.runningCommand, self.commandStartedAt == startedAt else { return }
            self.longRunningCommand = true
        }
        longRunningFlip = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.longRunningThreshold, execute: work)
    }

    /// 后台长命令完成 → 系统通知(App 不活跃,或不是当前聚焦 pane)
    private func notifyIfLongCommand(code: Int?, duration: TimeInterval?) {
        let enabled = UserDefaults.standard.object(forKey: SettingsKeys.notifyLongCommand) as? Bool ?? true
        guard enabled, let duration, duration >= 10 else { return }
        let inForeground: Bool
        if let manager {
            inForeground = NSApp.isActive
                && SessionManagerRegistry.shared.active === manager
                && manager.selected === self
        } else {
            inForeground = NSApp.isActive // 下拉终端:App 前台即视为可见
        }
        guard !inForeground else { return }
        NotificationService.postCommandFinished(exitCode: code, duration: duration, title: displayTitle, sessionID: id)
    }

    // MARK: - pane 注意力(等待输入 / 命令完成)

    /// 「完成」注意力的最短命令时长(太短的后台命令靠活动绿点就够)
    static let finishedAttentionMinDuration: TimeInterval = 5

    /// 注意力检测总开关(下拉终端 manager 为 nil,不参与)
    private var attentionEnabled: Bool {
        manager != nil && (UserDefaults.standard.object(forKey: SettingsKeys.attentionDetection) as? Bool ?? true)
    }

    /// 本 pane 此刻是否被用户盯着(app 激活 + key 窗口 + 选中标签 + 聚焦 pane)
    private var isFocusedByUser: Bool {
        guard let manager else { return true }
        return manager.isSessionVisible(id) && manager.selectedTab?.focusedID == id
    }

    private func trackAttentionOutput() {
        silenceHeuristic.recordOutput()
        if case .needsInput(let fromBell) = attention {
            if !fromBell {
                // 静默判定是推测:输出恢复说明还在干活,自动撤销
                clearAttention()
            } else if let start = silenceHeuristic.streakStart, let since = attentionSince,
                      start > since, silenceHeuristic.hadBusyStreak() {
                // 摇铃后又持续输出:程序自己继续了,铃声已过时
                clearAttention()
            }
        }
        armSilenceWatch()
    }

    /// 独立 BEL(OSC 终止符不算):TUI 主动请求注意,如 Claude Code 等确认时摇铃
    func bellReceived() {
        guard attentionEnabled, Date() >= bellArmedAt, !isFocusedByUser else { return }
        setAttention(.needsInput(fromBell: true))
    }

    /// 命令执行期间盯住输出静默:持续输出(在干活)后静默达阈值 → 等待输入。
    /// 只在没有活跃 watcher 时起一个,睡到静默判定点再核对,输出恢复就顺延。
    private func armSilenceWatch() {
        guard silenceWatch == nil, attentionEnabled, runningCommand else { return }
        silenceWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.runningCommand,
                      let remaining = self.silenceHeuristic.remainingSilence() else { break }
                if remaining <= 0 {
                    self.silenceDidSettle()
                    break
                }
                try? await Task.sleep(for: .seconds(remaining))
            }
            // 被 cancel 的路径由取消方清引用:此刻可能已有新 watcher,不能误清
            if !Task.isCancelled { self?.silenceWatch = nil }
        }
    }

    private func silenceDidSettle() {
        guard attentionEnabled, runningCommand,
              silenceHeuristic.hadBusyStreak(), !isFocusedByUser else { return }
        setAttention(.needsInput(fromBell: false))
    }

    /// 命令结束:等待输入态已过时;失焦 pane 边框闪一下,长命令转「完成」注意力
    private func attentionAfterCommandEnd(code: Int?, duration: TimeInterval?) {
        silenceWatch?.cancel()
        silenceWatch = nil
        guard attentionEnabled else { return }
        guard !isFocusedByUser else {
            clearAttention()
            return
        }
        let failed = (code ?? 0) != 0
        finishFlash = FinishFlash(failed: failed, at: Date())
        clearAttention()
        if (duration ?? 0) >= Self.finishedAttentionMinDuration {
            setAttention(.finished(failed: failed))
        }
    }

    private func setAttention(_ new: PaneAttention) {
        guard attention != new else { return }
        if !attention.isActive { attentionSince = Date() }
        attention = new
        if case .needsInput = new { notifyAwaitingInputIfNeeded() }
    }

    /// 聚焦本 pane / 向它键入时由 SessionManager 调用
    func clearAttention() {
        guard attention.isActive else { return }
        attention = .none
        attentionSince = nil
    }

    /// 选中即复制写入剪贴板后调用:隐式操作没有系统反馈,pane 弹一枚小 toast 兜底
    func flashCopyToast() {
        copyToast = Date()
    }

    /// pane 可见(同标签失焦)时呼吸边框已足够;完全不可见或 app 在后台才弹系统通知
    private func notifyAwaitingInputIfNeeded() {
        let enabled = UserDefaults.standard.object(forKey: SettingsKeys.notifyAttention) as? Bool ?? true
        guard enabled, manager?.isSessionVisible(id) != true else { return }
        guard Date().timeIntervalSince(lastAttentionNotice) > 120 else { return }
        lastAttentionNotice = Date()
        NotificationService.postAwaitingInput(title: displayTitle, sessionID: id)
    }

    // MARK: - 命令位置标记(⌘↑/⌘↓ 跳转、复制输出)

    /// 增量刷新 scroll-invariant 行号边界:上界随输出前进,下界随 scrollback 修剪上移
    private func refreshScrollInvariantBounds() {
        let terminal = terminalView.getTerminal()
        while terminal.getScrollInvariantLine(row: siUpper) != nil { siUpper += 1 }
        while siLower < siUpper, terminal.getScrollInvariantLine(row: siLower) == nil { siLower += 1 }
        while terminal.getScrollInvariantLine(row: siLower - 1) != nil { siLower -= 1 }
    }

    /// 光标当前所在的 scroll-invariant 行号
    private func currentScrollInvariantRow() -> Int {
        refreshScrollInvariantBounds()
        let terminal = terminalView.getTerminal()
        let viewportTop = max(siLower, siUpper - terminal.rows)
        return viewportTop + terminal.buffer.y
    }

    private func recordCommandMark() {
        let row = currentScrollInvariantRow()
        if commandMarks.last != row {
            commandMarks.append(row)
            if commandMarks.count > 1000 { commandMarks.removeFirst(commandMarks.count - 1000) }
        }
    }

    /// 命令结束(OSC 133 D):落一条时间线记录
    private func recordCommand(code: Int?, duration: TimeInterval?) {
        guard let start = pendingOutputStart else { return }
        pendingOutputStart = nil
        let end = currentScrollInvariantRow()
        let record = CommandRecord(
            commandText: pendingCommandText,
            promptRow: pendingPromptRow,
            outputStart: start,
            outputEnd: end,
            exitCode: code,
            duration: duration,
            finishedAt: Date(),
            structured: detectStructured(start: start, end: end)
        )
        pendingPromptRow = nil
        pendingCommandText = ""
        commandHistory.append(record)
        if commandHistory.count > 200 { commandHistory.removeFirst(commandHistory.count - 200) }
        if end > start { hasCommandOutput = true }
        // 跨会话历史落盘(⌘⇧H 搜索与日报的数据源)
        CommandHistoryStore.shared.record(
            command: record.commandText,
            cwd: workingDirectory,
            exitCode: code,
            duration: duration,
            branch: gitBranch
        )
    }

    /// 嗅探输出是否结构化数据:只看首尾几行,避免大输出全量扫描。
    /// JSON:首行以 {/[ 起、末行以 }/] 收。
    /// CSV/TSV:采样开头连续 ≤5 行非空行,分隔符列数须全部一致;Tab ≥2 列,
    /// 逗号 ≥3 列——散文里成对出现的单逗号(如 git push 每行结尾的「, done.」)不再误报。
    private func detectStructured(start: Int, end: Int) -> StructuredOutputFormat? {
        guard end > start else { return nil }
        let terminal = terminalView.getTerminal()
        func text(_ row: Int) -> String {
            terminal.getScrollInvariantLine(row: row)?.translateToString(trimRight: true) ?? ""
        }
        var firstIndex = start
        while firstIndex < end, text(firstIndex).isEmpty { firstIndex += 1 }
        guard firstIndex < end else { return nil }
        let first = text(firstIndex).trimmingCharacters(in: .whitespaces)

        if first.hasPrefix("{") || first.hasPrefix("[") {
            var lastIndex = end - 1
            while lastIndex > firstIndex, text(lastIndex).isEmpty { lastIndex -= 1 }
            let last = text(lastIndex).trimmingCharacters(in: .whitespaces)
            return (last.hasSuffix("}") || last.hasSuffix("]")) ? .json : nil
        }

        var sample: [String] = []
        var row = firstIndex
        while row < end, sample.count < 5 {
            let line = text(row)
            if line.isEmpty { break }
            sample.append(line)
            row += 1
        }
        guard sample.count >= 2 else { return nil }
        for (separator, format, minColumns) in [("\t", StructuredOutputFormat.tsv, 2), (",", .csv, 3)] {
            let columns = sample[0].components(separatedBy: separator).count
            guard columns >= minColumns else { continue }
            if sample.dropFirst().allSatisfy({ $0.components(separatedBy: separator).count == columns }) {
                return format
            }
        }
        return nil
    }

    /// 提取 scroll-invariant 行区间的纯文本(空行保留,尾部空行去掉)。
    /// 行号可能回退(重连 backlog 回放、终端 reset/ED3 修剪),start > end 按空处理
    private func extractText(from start: Int, to end: Int) -> String {
        guard start < end else { return "" }
        let terminal = terminalView.getTerminal()
        var lines: [String] = []
        for row in start..<end {
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            lines.append(line.translateToString(trimRight: true))
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// 某条命令的完整输出文本(scrollback 修剪后可能已不可用 → nil)
    func outputText(of record: CommandRecord) -> String? {
        refreshScrollInvariantBounds()
        let start = max(record.outputStart, siLower)
        guard record.outputEnd > start else { return nil }
        let text = extractText(from: start, to: record.outputEnd)
        return text.isEmpty ? nil : text
    }

    /// 同一条命令上一次运行的记录(输出 Diff 用)
    func previousRun(of record: CommandRecord) -> CommandRecord? {
        guard !record.commandText.isEmpty,
              let index = commandHistory.firstIndex(where: { $0.id == record.id }) else { return nil }
        return commandHistory[..<index].last { $0.commandText == record.commandText && $0.hasOutput }
    }

    /// 复制某条命令的完整输出;返回是否成功
    @discardableResult
    func copyOutput(of record: CommandRecord) -> Bool {
        guard let text = outputText(of: record) else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    /// 复制上一条有输出的命令的输出到剪贴板
    @discardableResult
    func copyLastCommandOutput() -> Bool {
        guard let last = commandHistory.last(where: { $0.outputEnd > $0.outputStart }) else { return false }
        return copyOutput(of: last)
    }

    /// 时间线点击:滚动到该命令的提示符处
    func scrollTo(record: CommandRecord) {
        refreshScrollInvariantBounds()
        let terminal = terminalView.getTerminal()
        let row = record.promptRow ?? record.outputStart
        guard row >= siLower else { return }
        let maxScrollback = max((siUpper - siLower) - terminal.rows, 1)
        let position = Double(row - siLower) / Double(maxScrollback)
        terminalView.scroll(toPosition: min(max(position, 0), 1))
    }

    /// ⌘↑:跳到当前视口上方最近的提示符
    func jumpToPreviousCommand() { jumpToCommand(direction: -1) }
    /// ⌘↓:跳到当前视口下方最近的提示符;没有更多则回到底部
    func jumpToNextCommand() { jumpToCommand(direction: 1) }

    private func jumpToCommand(direction: Int) {
        guard !commandMarks.isEmpty else { return }
        refreshScrollInvariantBounds()
        let terminal = terminalView.getTerminal()
        // 修剪后已失效的旧标记一并清掉
        commandMarks.removeAll { $0 < siLower }
        let currentTop = siLower + terminal.buffer.yDisp
        let target = direction < 0
            ? commandMarks.last(where: { $0 < currentTop })
            : commandMarks.first(where: { $0 > currentTop })
        guard let target else {
            if direction > 0 { terminalView.scroll(toPosition: 1) }
            return
        }
        let maxScrollback = max((siUpper - siLower) - terminal.rows, 1)
        let position = Double(target - siLower) / Double(maxScrollback)
        terminalView.scroll(toPosition: min(max(position, 0), 1))
    }

    // MARK: - 会话录制

    /// 开始把输出录制到文件(剥离颜色码,追加写)。写入头部一行元信息。
    @discardableResult
    func startLogging(to url: URL) -> Bool {
        stopLogging()
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        handle.seekToEndOfFile()
        let header = "# Termite session log · \(shellName) · \(Date().formatted())\n"
        handle.write(Data(header.utf8))
        logHandle = handle
        logURL = url
        return true
    }

    func stopLogging() {
        try? logHandle?.close()
        logHandle = nil
        logURL = nil
    }

    private func appendToLog(_ bytes: ArraySlice<UInt8>) {
        guard let logHandle, let text = String(bytes: bytes, encoding: .utf8) else { return }
        logHandle.write(Data(ANSI.strip(text).utf8))
    }

    // MARK: - asciinema 录制(.cast v2,原始转义流 + 时间戳)

    @discardableResult
    func startCasting(to url: URL) -> Bool {
        stopCasting()
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        let terminal = terminalView.getTerminal()
        handle.write(Data((CastFile.headerLine(width: terminal.cols, height: terminal.rows, timestamp: Date()) + "\n").utf8))
        castHandle = handle
        castStartedAt = Date()
        castURL = url
        return true
    }

    func stopCasting() {
        try? castHandle?.close()
        castHandle = nil
        castStartedAt = nil
        castURL = nil
    }

    private func appendToCast(_ bytes: ArraySlice<UInt8>) {
        guard let castHandle, let castStartedAt,
              let text = String(bytes: bytes, encoding: .utf8),
              let line = CastFile.eventLine(time: Date().timeIntervalSince(castStartedAt), data: text) else { return }
        castHandle.write(Data((line + "\n").utf8))
    }

    /// 调试:无条件取缓冲区尾部(不过 3 行阈值)
    func debugBufferTail(lines: Int = 30) -> String {
        refreshScrollInvariantBounds()
        let start = max(siLower, siUpper - lines)
        guard siUpper > start else { return "(缓冲区为空 siLower=\(siLower) siUpper=\(siUpper))" }
        return extractText(from: start, to: siUpper)
    }

    /// 会话缓冲区尾部快照(scrollback 恢复用):
    /// 只取本次会话的新内容(不含上次回灌的旧内容),不足 3 行有效内容视为"没干过事",不存
    func scrollbackSnapshot(maxLines: Int = 2000) -> String? {
        refreshScrollInvariantBounds()
        let start = max(max(siLower, siUpper - maxLines), snapshotFloor)
        guard siUpper > start else { return nil }
        let text = extractText(from: start, to: siUpper)
        let meaningfulLines = text.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard meaningfulLines.count >= 3 else { return nil }
        return text
    }

    /// 从 Mac 当前终端模型生成可独立解析的 ANSI 画面。synchronized-output 只是原子更新，
    /// 单个 frame 可能是增量；远端重附必须拿到完整屏幕和正确光标位置。
    func terminalScreenSnapshot() -> Data {
        let terminal = terminalView.getTerminal()
        let firstRetainedRow = terminal.buffer.totalLinesTrimmed
        var viewportEnd = firstRetainedRow
        while terminal.getScrollInvariantLine(row: viewportEnd) != nil { viewportEnd += 1 }
        let viewportTop = max(firstRetainedRow, viewportEnd - terminal.rows)
        var output = "\u{1b}[?2026h"
        output += terminal.isCurrentBufferAlternate ? "\u{1b}[?1049h" : "\u{1b}[?1049l"
        output += terminal.applicationCursor ? "\u{1b}[?1h" : "\u{1b}[?1l"
        output += "\u{1b}[?25l\u{1b}[0m\u{1b}[2J\u{1b}[H"

        var activeAttribute: Attribute?
        for row in 0..<terminal.rows {
            guard let line = terminal.getScrollInvariantLine(row: viewportTop + row) else { continue }
            let cells = line.getData()
            let limit = min(line.getTrimmedLength(), cells.count)
            guard limit > 0 else { continue }
            output += "\u{1b}[\(row + 1);1H"
            var column = 0
            while column < limit {
                let cell = cells[column]
                if activeAttribute != cell.attribute {
                    output += Self.sgr(for: cell.attribute)
                    activeAttribute = cell.attribute
                }
                output.append(terminal.getCharacter(for: cell))
                column += max(Int(cell.width), 1)
            }
        }

        let cursorRow = min(max(terminal.buffer.y, 0), max(terminal.rows - 1, 0)) + 1
        let cursorColumn = min(max(terminal.buffer.x, 0), max(terminal.cols - 1, 0)) + 1
        output += "\u{1b}[0m\u{1b}[\(cursorRow);\(cursorColumn)H\u{1b}[?25h\u{1b}[?2026l"
        return Data(output.utf8)
    }

    private static func sgr(for attribute: Attribute) -> String {
        var codes = ["0"]
        let style = attribute.style
        if style.contains(.bold) { codes.append("1") }
        if style.contains(.dim) { codes.append("2") }
        if style.contains(.italic) { codes.append("3") }
        if style.contains(.underline) { codes.append("4") }
        if style.contains(.blink) { codes.append("5") }
        if style.contains(.inverse) { codes.append("7") }
        if style.contains(.invisible) { codes.append("8") }
        if style.contains(.crossedOut) { codes.append("9") }
        codes.append(contentsOf: colorCodes(attribute.fg, foreground: true))
        codes.append(contentsOf: colorCodes(attribute.bg, foreground: false))
        return "\u{1b}[" + codes.joined(separator: ";") + "m"
    }

    private static func colorCodes(_ color: Attribute.Color, foreground: Bool) -> [String] {
        switch color {
        case .defaultColor, .defaultInvertedColor:
            return [foreground ? "39" : "49"]
        case .ansi256(let code):
            if code < 8 { return [String((foreground ? 30 : 40) + Int(code))] }
            if code < 16 { return [String((foreground ? 90 : 100) + Int(code - 8))] }
            return [foreground ? "38" : "48", "5", String(code)]
        case .trueColor(let red, let green, let blue):
            return [foreground ? "38" : "48", "2", String(red), String(green), String(blue)]
        }
    }

    // MARK: - 本机服务 URL 检测(dev server 输出里的 localhost 链接)

    @ObservationIgnored private var urlScanBuffer = ""
    private static let localURLRegex = try? NSRegularExpression(
        pattern: #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0)(?::\d+)?(?:/[^\s"'<>\)\]]*)?"#
    )

    private func scanForLocalURL(_ bytes: ArraySlice<UInt8>) {
        guard let regex = Self.localURLRegex,
              let text = String(bytes: bytes, encoding: .utf8) else { return }
        urlScanBuffer += text
        while let newline = urlScanBuffer.firstIndex(of: "\n") {
            let line = ANSI.strip(String(urlScanBuffer[..<newline]))
            urlScanBuffer.removeSubrange(urlScanBuffer.startIndex...newline)
            let range = NSRange(line.startIndex..., in: line)
            if let match = regex.firstMatch(in: line, range: range),
               let matchRange = Range(match.range, in: line) {
                // 0.0.0.0 监听地址浏览器打不开,换成 localhost
                detectedLocalURL = String(line[matchRange])
                    .replacingOccurrences(of: "0.0.0.0", with: "localhost")
            }
        }
        if urlScanBuffer.count > 4096 {
            urlScanBuffer = String(urlScanBuffer.suffix(2048))
        }
    }

    // MARK: - git 分支探测

    private func probeGitBranch(_ path: String) {
        gitProbeTask?.cancel()
        gitProbeTask = Task { [weak self] in
            let branch = await Task.detached { GitProbe.branch(at: path) }.value
            guard !Task.isCancelled, let self else { return }
            let changed = branch != self.gitBranch
            self.gitBranch = branch
            if branch == nil {
                self.gitDirtyCount = nil
            } else if changed {
                // 分支变了(checkout/switch)脏计数必过期,绕过节流强刷
                self.probeGitDirty(path, force: true)
            }
        }
    }

    /// 外部(分支切换等)触发的 git 信息强刷
    func refreshGitInfo() {
        guard let dir = workingDirectory else { return }
        probeGitBranch(dir)
        probeGitDirty(dir, force: true)
        probeGitIdentity(dir)
    }

    /// 提交身份探测:先比对配置文件 mtime(纯 stat,零子进程),
    /// 真变了才通知状态栏去跑 git config —— 每条命令后都能发现改动,又不多花子进程
    private func probeGitIdentity(_ path: String) {
        gitIdentityTask?.cancel()
        gitIdentityTask = Task { [weak self] in
            let stamp = await Task.detached { GitProbe.identityStamp(at: path) }.value
            guard !Task.isCancelled, let self else { return }
            defer { gitIdentityStamp = stamp }
            // 首次(新会话 / 刚换目录)只记基线:视图本来就会按目录重读
            guard let previous = gitIdentityStamp, previous != stamp else { return }
            gitIdentityRevision += 1
        }
    }

    /// 未提交文件数探测(节流;命令结束/目录变化时刷)
    func probeGitDirty(_ path: String, force: Bool = false) {
        guard force || Date().timeIntervalSince(lastGitDirtyProbeAt) > 3 else { return }
        lastGitDirtyProbeAt = Date()
        gitDirtyTask?.cancel()
        gitDirtyTask = Task { [weak self] in
            let output = await GitService.run(["status", "--porcelain"], in: path)
            guard !Task.isCancelled else { return }
            guard let output else {
                self?.gitDirtyCount = nil
                return
            }
            self?.gitDirtyCount = output.components(separatedBy: "\n").filter { !$0.isEmpty }.count
        }
    }
}

// MARK: - LocalProcessTerminalViewDelegate

// @preconcurrency:协议是 nonisolated 的,回调实际全部来自主线程(SwiftTerm 在
// 主线程驱动),用动态隔离断言替代编译期告警(Swift 6 预备)
extension TerminalSession: @preconcurrency LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        self.title = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        // OSC 7 是 file:// URL;解析失败按原文处理
        let path: String
        if let url = URL(string: directory), url.scheme == "file" {
            path = url.path
        } else {
            path = directory
        }
        guard path != workingDirectory else { return }
        workingDirectory = path
        probeGitBranch(path)
        // 换目录必强刷脏计数:跨仓库切换分支名可能相同,branch 判等测不出变化
        probeGitDirty(path, force: true)
        // 身份指纹跟着目录走:换仓库后旧基线无意义,清掉重记
        gitIdentityStamp = nil
        probeGitIdentity(path)
        DirectoryHistory.shared.record(path: path)
        manager?.workingDirectoryChanged()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        state = .exited(exitCode)
        stopLogging()
        onProcessExit?()
    }
}

/// pane 注意力:失焦 pane 需要用户处理的信号(等待输入 > 命令完成)
enum PaneAttention: Equatable {
    case none
    /// 前台程序停下来等用户(fromBell:程序主动摇铃;否则为静默启发式判定)
    case needsInput(fromBell: Bool)
    /// 长命令在失焦 pane 跑完(failed:退出码非 0)
    case finished(failed: Bool)

    var needsInput: Bool {
        if case .needsInput = self { return true }
        return false
    }

    var isActive: Bool { self != .none }
}

/// 失焦 pane 命令结束时的一次性边框闪烁(绿=成功,红=失败)
struct FinishFlash: Equatable {
    let failed: Bool
    let at: Date
}

/// 静默启发式:TUI(如 Claude Code)不发 OSC 133 提示符标记,无法直接知道它何时停下,
/// 用「持续输出一段时间后突然静默」近似「停下来等输入」。
/// vim 一类打开后就安静的程序不满足持续输出条件,不误报。
struct SilenceHeuristic {
    /// 输出间隔超过该值视为一段新输出(agent 干活时至少每秒都在刷屏)
    var streakGap: TimeInterval = 2
    /// 输出需持续这么久才算「在干活」(短促输出后的静默不算)
    var minStreak: TimeInterval = 5
    /// 静默达到该时长即判定「在等输入」
    var silenceThreshold: TimeInterval = 6

    private(set) var lastOutputAt: Date?
    private(set) var streakStart: Date?

    mutating func recordOutput(at now: Date = Date()) {
        if let last = lastOutputAt, now.timeIntervalSince(last) <= streakGap {
            if streakStart == nil { streakStart = last }
        } else {
            streakStart = now
        }
        lastOutputAt = now
    }

    /// 距静默判定点还差多久(≤0 即已达标;从未有输出返回 nil)
    func remainingSilence(at now: Date = Date()) -> TimeInterval? {
        guard let last = lastOutputAt else { return nil }
        return silenceThreshold - now.timeIntervalSince(last)
    }

    /// 静默前的最后一段输出是否够长(证明之前真在干活)
    func hadBusyStreak() -> Bool {
        guard let start = streakStart, let last = lastOutputAt else { return false }
        return last.timeIntervalSince(start) >= minStreak
    }
}

/// 一条完整的命令周期记录(OSC 133 C→D):驱动命令时间线面板
struct CommandRecord: Identifiable, Equatable {
    let id = UUID()
    /// 命令行文本(提示符行..输出起始行的原样内容,含提示符前缀)
    let commandText: String
    /// 提示符所在 scroll-invariant 行(跳转定位用)
    let promptRow: Int?
    /// 输出区间 [outputStart, outputEnd)
    let outputStart: Int
    let outputEnd: Int
    let exitCode: Int?
    let duration: TimeInterval?
    let finishedAt: Date
    /// 输出嗅探出的结构化格式(驱动状态栏「查看」按钮)
    var structured: StructuredOutputFormat?

    var hasOutput: Bool { outputEnd > outputStart }
    var succeeded: Bool { (exitCode ?? 0) == 0 }
}

/// 结构化输出格式
enum StructuredOutputFormat: String {
    case json, csv, tsv

    var separator: String { self == .tsv ? "\t" : "," }
    var label: String { self == .json ? "JSON" : String(localized: "表格") }
    var symbol: String { self == .json ? "curlybraces" : "tablecells" }
}

/// 直读 .git/HEAD 拿当前分支(零子进程):从 path 逐级向上找 .git。
/// 向上不越过家目录,减少对受 TCC 保护目录(文稿/桌面等)的主动触碰。
enum GitProbe {
    static func branch(at path: String) -> String? {
        guard let gitDir = gitDirectory(at: path),
              let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if head.hasPrefix("ref: refs/heads/") {
            return String(head.dropFirst("ref: refs/heads/".count))
        }
        return String(head.prefix(8)) // detached HEAD:短 hash
    }

    /// 提交身份相关配置文件的 mtime 指纹(仓库级 + 全局):纯 stat,零子进程。
    /// 状态栏拿它判断「要不要再花几个 git config 子进程读身份」
    static func identityStamp(at path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var files = [
            home.appendingPathComponent(".gitconfig"),
            home.appendingPathComponent(".config/git/config"),
        ]
        if let gitDir = gitDirectory(at: path) {
            files.append(gitDir.appendingPathComponent("config"))
            // 链接 worktree 的 .git 指向 <main>/.git/worktrees/<name>,
            // user.* 落在主仓库的 config 上,顺着 commondir 一并盯住
            if let common = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !common.isEmpty {
                let resolved = common.hasPrefix("/")
                    ? URL(fileURLWithPath: common)
                    : gitDir.appendingPathComponent(common).standardizedFileURL
                files.append(resolved.appendingPathComponent("config"))
            }
        }
        return files.map { file in
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            let modified = attributes?[.modificationDate] as? Date
            return "\(file.path):\(modified?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
    }

    /// 向上找到 cwd 所属仓库的 .git 目录(worktree/submodule 的 gitdir 指针也解析)
    private static func gitDirectory(at path: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dir = URL(fileURLWithPath: path)
        for _ in 0..<24 {
            if let gitDir = resolveGitDir(at: dir) { return gitDir }
            // 家目录和根目录是遍历上界(家目录本身极少是仓库,其下受保护目录不再触碰)
            if dir.path == home || dir.path == "/" { return nil }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
        return nil
    }

    private static func resolveGitDir(at dir: URL) -> URL? {
        let gitPath = dir.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: gitPath.path, isDirectory: &isDirectory) else { return nil }
        guard !isDirectory.boolValue else { return gitPath }
        // worktree/submodule:.git 是一个 "gitdir: <path>" 文件
        guard let content = try? String(contentsOf: gitPath, encoding: .utf8),
              let gitdir = content.split(separator: ":").dropFirst().first?
                  .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return gitdir.hasPrefix("/")
            ? URL(fileURLWithPath: gitdir)
            : dir.appendingPathComponent(gitdir).standardizedFileURL
    }
}
