import Foundation
import Network

/// RFC 6455 服务端:帧编解码 + 会话桥接。
/// 一条 WS 连接同一时刻至多附着一个会话(手机屏幕一次只看一个终端)。
/// 线程模型:网络收发在 netQueue;桥接状态(附着会话、尺寸跟随)全部主线程,
/// 输入经 DispatchQueue.main FIFO 入主线程,和本地键入同路且保序。
final class RemoteWebSocketSession: @unchecked Sendable {
    private let connection: SocketConnection
    private let onClose: () -> Void
    private let connID = UUID()

    // netQueue 上的解析状态
    private var buffer = Data()
    private var fragmentOpcode: UInt8?
    private var fragmentData = Data()
    private var tornDown = false
    /// 已收到对端 close,回礼在途:停止解析新帧,等发送完成回调断开
    private var closing = false

    // 主线程上的桥接状态
    private var attachedSessionID: UUID?
    /// 这条连接是否正在推模拟器画面(镜像与终端互不影响,可以同时开)
    private var mirroring = false
    /// 这条连接是否正在订阅某个 agent 会话的转录
    private var chatting = false
    private var statusTimer: DispatchSourceTimer?

    private var pingTimer: DispatchSourceTimer?

    private static let maxMessage = 1 * 1024 * 1024

    init(connection: SocketConnection, onClose: @escaping () -> Void) {
        self.connection = connection
        self.onClose = onClose
    }

    func start(initialBuffer: Data) {
        buffer = initialBuffer
        sendJSON(HelloMsg())
        // 30 秒心跳:让死连接尽快在 TCP 层暴露,也顺带保 NAT 映射
        let ping = DispatchSource.makeTimerSource(queue: RemoteAccessServer.netQueue)
        pingTimer = ping
        ping.schedule(deadline: .now() + 30, repeating: 30)
        ping.setEventHandler { [weak self] in self?.sendFrame(opcode: 0x9, payload: Data()) }
        ping.resume()
        parseBuffer()
        receiveLoop()
    }

    /// 上层连接关闭时调用(netQueue)
    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        pingTimer?.cancel()
        pingTimer = nil
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.stopStatusTimer()
                self.stopMirror()
                AgentTranscriptHub.shared.detach(connID: self.connID)
                RemoteSessionHub.shared.detach(connID: self.connID)
            }
        }
    }

    // MARK: - 接收与帧解析(netQueue)

    private func receiveLoop() {
        connection.receive(maximumLength: 64 * 1024) { [weak self] data, isComplete, error in
            guard let self, !self.tornDown else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.parseBuffer()
            }
            if error != nil || isComplete {
                self.onClose()
                return
            }
            if !self.tornDown { self.receiveLoop() }
        }
    }

    private func parseBuffer() {
        while !closing, let frame = nextFrame() {
            handleFrame(fin: frame.fin, opcode: frame.opcode, payload: frame.payload)
            if tornDown { return }
        }
    }

    private func nextFrame() -> (fin: Bool, opcode: UInt8, payload: Data)? {
        guard buffer.count >= 2 else { return nil }
        let bytes = [UInt8](buffer.prefix(14)) // 头最长 2+8+4
        let fin = bytes[0] & 0x80 != 0
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        var length = UInt64(bytes[1] & 0x7F)
        var index = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = UInt64(bytes[2]) << 8 | UInt64(bytes[3])
            index = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = bytes[2..<10].reduce(0) { $0 << 8 | UInt64($1) }
            index = 10
        }
        // 浏览器→服务端必须掩码;超长直接断开(协议错乱或恶意)
        guard masked, length <= UInt64(Self.maxMessage) else {
            onClose()
            return nil
        }
        guard buffer.count >= index + 4 + Int(length) else { return nil }
        let key = [UInt8](buffer.dropFirst(index).prefix(4))
        var payload = [UInt8](buffer.dropFirst(index + 4).prefix(Int(length)))
        for i in payload.indices { payload[i] ^= key[i & 3] }
        buffer.removeFirst(index + 4 + Int(length))
        return (fin, opcode, Data(payload))
    }

    private func handleFrame(fin: Bool, opcode: UInt8, payload: Data) {
        switch opcode {
        case 0x0, 0x1, 0x2: // continuation / text / binary
            if opcode != 0x0 {
                fragmentOpcode = opcode
                fragmentData = payload
            } else {
                fragmentData.append(payload)
            }
            guard fragmentData.count <= Self.maxMessage else {
                onClose()
                return
            }
            guard fin, let messageOpcode = fragmentOpcode else { return }
            let message = fragmentData
            fragmentOpcode = nil
            fragmentData = Data()
            if messageOpcode == 0x1 {
                handleText(message)
            } else {
                handleBinary(message)
            }
        case 0x8: // close:回礼写完再半关闭(先冲数据再 FIN),
            // 紧跟 cancel 会把回礼丢在发送队列里
            closing = true
            connection.send(Data([0x88, 0x00]), isFinal: true) { [weak self] _ in
                self?.onClose()
            }
        case 0x9: // ping → pong 原样带回
            sendFrame(opcode: 0xA, payload: payload)
        case 0xA: // pong:心跳回包,无需处理
            break
        default:
            onClose()
        }
    }

    // MARK: - 桥接(主线程)

    private struct ClientMsg: Decodable {
        let type: String
        let id: UUID?
        let cols: Int?
        let rows: Int?
        /// 接管时上报的设备名,显示在 Mac 的遮罩上(「iPhone 正在操作」)
        let device: String?
        /// 模拟器镜像:目标 UDID 与画质参数
        let udid: String?
        let quality: Double?
        let fps: Double?
        /// 远端触摸:归一化坐标、阶段(0 按下 1 移动 2 抬起)、同一手势的编号
        let x: Double?
        let y: Double?
        let phase: Int?
        let touchID: UInt32?
        let bottomEdge: Bool?
        /// 对话模式:发给 agent 的文字、历史条数上限
        let text: String?
        let limit: Int?
        /// 应答模式:按下的那个键("1" / "y" / "enter" / "esc" / "up" / "down")
        let key: String?
        /// 唤起 agent:在哪个项目里(或直接给目录)、敲哪个命令
        let project: UUID?
        let cwd: String?
        let agent: String?
    }

    private func handleText(_ data: Data) {
        guard let msg = try? JSONDecoder().decode(ClientMsg.self, from: data) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                switch msg.type {
                case "list":
                    self.sendList()
                case "openProject":
                    guard let id = msg.id,
                          let session = RemoteSessionHub.shared.openProject(id: id) else {
                        self.sendJSON(ProjectOpenFailedMsg(
                            message: String(localized: "无法在 Mac 上启动这个项目")
                        ))
                        return
                    }
                    self.sendJSON(ProjectOpenedMsg(session: session))
                    self.sendList()
                case "attach":
                    if let id = msg.id { self.attach(id) }
                case "detach":
                    self.detachCurrent()
                case "simList":
                    let available = SimulatorMirror.shared.available
                    SimulatorMirror.shared.bootedDevices { devices in
                        self.sendJSON(SimListMsg(devices: devices, available: available))
                    }
                case "simDevices":
                    let available = SimulatorMirror.shared.available
                    SimulatorMirror.shared.allDevices { devices in
                        self.sendJSON(SimListMsg(devices: devices, available: available))
                    }
                case "simBoot", "simShutdown":
                    guard let udid = msg.udid else { break }
                    let boot = msg.type == "simBoot"
                    let action: (String, @escaping (Bool, String?) -> Void) -> Void =
                        boot ? SimulatorMirror.shared.boot : SimulatorMirror.shared.shutdown
                    action(udid) { ok, error in
                        // 启停要花几秒,完成后回一份新列表让手机刷新状态
                        SimulatorMirror.shared.allDevices { devices in
                            self.sendJSON(SimListMsg(devices: devices,
                                                     available: SimulatorMirror.shared.available))
                            if !ok, let error {
                                self.sendJSON(SimStateMsg(udid: nil, message: error))
                            }
                        }
                    }
                case "simAttach":
                    self.startMirror(udid: msg.udid, maxWidth: msg.cols, quality: msg.quality,
                                     fps: msg.fps)
                case "simDetach":
                    self.stopMirror()
                case "chatList":
                    let catalog = RemoteSessionHub.shared.sidebarCatalog()
                    self.sendJSON(ChatListMsg(
                        sessions: AgentTranscriptHub.shared.chatSessions(),
                        spaces: catalog.spaces,
                        projects: catalog.projects,
                        agents: AgentTranscriptHub.shared.agentOptions()))
                case "chatLaunch":
                    // 唤起 agent:在项目目录开一个**新** pane 再敲命令。
                    // 绝不复用已有 pane —— 那里可能正跑着别的东西,注入等于抢键盘。
                    // 入口有两个:选项目(project)、或对话页里就地重开(cwd)
                    guard let command = msg.agent else { break }
                    let launched = if let project = msg.project {
                        RemoteSessionHub.shared.launchAgent(projectID: project, command: command)
                    } else if let cwd = msg.cwd {
                        RemoteSessionHub.shared.launchAgent(cwd: cwd, command: command)
                    } else {
                        RemoteSessionInfo?.none
                    }
                    guard let info = launched else {
                        self.sendJSON(ChatErrorMsg(message: String(localized: "启动失败,目录可能已不存在")))
                        break
                    }
                    self.sendJSON(ChatLaunchedMsg(id: info.id, title: info.title))
                case "chatAttach":
                    guard let id = msg.id else { break }
                    let ok = AgentTranscriptHub.shared.attach(
                        connID: self.connID, sessionID: id, maxHistory: msg.limit ?? 200
                    ) { [weak self] messages, isHistory in
                        self?.sendJSON(ChatMessagesMsg(messages: messages, history: isHistory))
                    }
                    self.chatting = ok
                    if !ok {
                        self.sendJSON(ChatMessagesMsg(messages: [], history: true, unavailable: true))
                    }
                case "chatDetach":
                    AgentTranscriptHub.shared.detach(connID: self.connID)
                    self.chatting = false
                case "chatPrompt":
                    // 「它在等什么」:读 pane 当前画面。权限确认框只活在画面上,
                    // 转录里查无此事 —— 应答界面的问题原文只能从这儿来
                    guard let id = msg.id,
                          let prompt = AgentTranscriptHub.shared.prompt(sessionID: id) else { break }
                    self.sendJSON(ChatPromptMsg(prompt: prompt))
                case "chatKey":
                    // 按下选项。和 chatSend 同一道闸门:pane 底下没挂 agent 就不许注入,
                    // 否则一个 "1" 会被 bash 当成命令执行
                    guard let id = msg.id, let key = msg.key else { break }
                    guard AgentTranscriptHub.shared.sendKey(sessionID: id, key: key) else {
                        self.sendJSON(ChatErrorMsg(
                            message: String(localized: "这个会话的 agent 没在运行,按键发不出去")))
                        break
                    }
                    // 按完立刻回一份新画面,手机上不用等下一轮轮询才看到反应
                    if let prompt = AgentTranscriptHub.shared.prompt(sessionID: id) {
                        self.sendJSON(ChatPromptMsg(prompt: prompt))
                    }
                case "chatSend":
                    // 发消息 = 把文字注入回那个 pane 的 PTY(agent 自己会读)。
                    // 这是高层动作,不走接管的按键闸门 —— 对话模式的心智就是「跟 agent 说话」
                    guard let id = msg.id, let text = msg.text, !text.isEmpty,
                          let session = SessionManagerRegistry.shared.allSessions
                              .first(where: { $0.id == id }) else { break }
                    // 只往真在跑 agent 的 pane 注入:普通 shell 收到就等于执行了一句命令。
                    // 判据看进程(shell 底下挂没挂 agent),不看易失的终端状态
                    guard AgentTranscriptHub.shared.canInject(sessionID: id) else {
                        self.sendJSON(ChatErrorMsg(
                            message: String(localized: "这个会话的 agent 没在运行,发不出去")))
                        break
                    }
                    session.sendText(text + "\r")
                case "simTouch":
                    // 远端手指:归一化坐标 + 阶段。只有正在镜像的连接能发,
                    // 免得别的连接对着一台没在看的模拟器乱点
                    guard self.mirroring, let udid = msg.udid,
                          let x = msg.x, let y = msg.y, let phase = msg.phase else { break }
                    SimulatorMirror.shared.touch(udid: udid, phase: phase, x: x, y: y,
                                                 identifier: msg.touchID ?? 1,
                                                 bottomEdge: msg.bottomEdge ?? false)
                case "claim", "claimResize":
                    // 接管:PTY 网格改归这台设备,Mac 与其它端转只读。
                    // claimResize 是旧客户端的同义词(它本来就是「我要自己的网格」)
                    self.claim(cols: msg.cols, rows: msg.rows, device: msg.device)
                case "release", "releaseResize":
                    self.release()
                case "viewport", "resize":
                    // 无接管时设备视口不能改共享 PTY 网格,要自己的宽度得先 claim
                    break
                default:
                    break
                }
            }
        }
    }

    private func handleBinary(_ data: Data) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let sid = self.attachedSessionID else { return }
                RemoteSessionHub.shared.sendInput(connID: self.connID, sessionID: sid,
                                                  bytes: [UInt8](data))
            }
        }
    }

    @MainActor
    private func attach(_ sessionID: UUID) {
        detachCurrent()
        let hub = RemoteSessionHub.shared
        guard let result = hub.attach(
            connID: connID,
            sessionID: sessionID,
            pushOutput: { [weak self] data in
                self?.sendFrame(opcode: 0x2, payload: data)
            },
            pushViewport: { [weak self] cols, rows, tuiMode, control in
                self?.sendJSON(ViewportMsg(cols: cols, rows: rows, tuiMode: tuiMode,
                                           control: control))
            }
        ) else {
            sendJSON(ErrorMsg(message: String(localized: "会话不存在或已关闭")))
            return
        }
        attachedSessionID = sessionID
        sendJSON(AttachedMsg(id: sessionID, cols: result.cols, rows: result.rows,
                             tuiMode: result.tuiMode,
                             theme: RemoteTheme.current(),
                             control: result.control))
        if result.tuiMode {
            // 先回放近期控制序列，恢复鼠标/粘贴等终端模式；再用 Mac 当前终端模型的
            // 完整 ANSI 快照校正画面。最后一个 synchronized frame 可能只是增量，不能单独恢复。
            if !result.backlog.isEmpty {
                sendFrame(opcode: 0x2, payload: result.backlog)
            }
            if let snapshot = result.screenSnapshot {
                sendFrame(opcode: 0x2, payload: snapshot)
            }
        } else {
            // 镜像缓冲为空时用屏幕快照垫底(灰字示意历史内容),否则回放缓冲
            if let snapshot = result.snapshot {
                let normalized = snapshot.replacingOccurrences(of: "\n", with: "\r\n")
                sendFrame(opcode: 0x2, payload: Data(("\u{1b}[2m" + normalized + "\u{1b}[0m\r\n").utf8))
            }
            if !result.backlog.isEmpty {
                sendFrame(opcode: 0x2, payload: result.backlog)
            }
        }
        startStatusTimer()
    }

    // MARK: - 模拟器镜像
    //
    // 帧走这条连接的二进制帧,但前面加一个 4 字节魔数 "SIMG" 区分 ——
    // 终端输出同样是二进制帧,不打标记会串台。
    // 客户端约定:二进制帧以 SIMG 开头即镜像帧,其余按终端输出处理。

    @MainActor
    private func startMirror(udid: String?, maxWidth: Int?, quality: Double?, fps: Double?) {
        guard let udid else { return }
        mirroring = true
        SimulatorMirror.shared.start(
            udid: udid,
            maxWidth: maxWidth ?? 720,
            quality: quality ?? 0.6,
            maxFPS: fps ?? 20,
            onFrame: { [weak self] jpeg, width, height in
                guard let self else { return }
                var payload = Data("SIMG".utf8)
                // 宽高各 2 字节大端:客户端不用解 JPEG 头就知道画布尺寸
                payload.append(UInt8(width >> 8)); payload.append(UInt8(width & 0xFF))
                payload.append(UInt8(height >> 8)); payload.append(UInt8(height & 0xFF))
                payload.append(jpeg)
                self.sendFrame(opcode: 0x2, payload: payload)
            },
            completion: { [weak self] ok in
                guard let self else { return }
                if !ok { self.mirroring = false }
                self.sendJSON(SimStateMsg(
                    udid: ok ? udid : nil,
                    message: ok ? nil : String(localized: "这台模拟器没在运行,或 Xcode 私有接口不可用")))
            }
        )
    }

    @MainActor
    private func stopMirror() {
        guard mirroring else { return }
        SimulatorMirror.shared.stop()
        mirroring = false
        sendJSON(SimStateMsg(udid: nil, message: nil))
    }

    /// 接管请求。被别的端占着会被拒,回执当前控制权状态,客户端据此显示遮挡。
    @MainActor
    private func claim(cols: Int?, rows: Int?, device: String?) {
        guard let sid = attachedSessionID, let cols, let rows else { return }
        let name = device.map { String($0.prefix(40)) } ?? String(localized: "远程设备")
        let ok = RemoteSessionHub.shared.claimControl(connID: connID, sessionID: sid,
                                                     cols: cols, rows: rows, device: name)
        guard !ok, let info = RemoteSessionHub.shared.viewportInfo(sessionID: sid, connID: connID) else { return }
        sendJSON(ViewportMsg(cols: info.cols, rows: info.rows, tuiMode: info.tuiMode,
                             control: info.control))
    }

    @MainActor
    private func release() {
        guard let sid = attachedSessionID else { return }
        RemoteSessionHub.shared.releaseControl(sessionID: sid, from: connID)
    }

    @MainActor
    private func detachCurrent() {
        guard attachedSessionID != nil else { return }
        RemoteSessionHub.shared.detach(connID: connID)
        attachedSessionID = nil
        stopStatusTimer()
    }

    /// 每秒对照一次 Mac 视图网格和会话状态。网格变化由 Hub 统一广播。
    @MainActor
    private func startStatusTimer() {
        stopStatusTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        statusTimer = timer
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let sid = self.attachedSessionID else { return }
                guard RemoteSessionHub.shared.refreshStatus(sessionID: sid) == true else {
                    self.sendJSON(ExitedMsg())
                    self.detachCurrent()
                    return
                }
            }
        }
        timer.resume()
    }

    @MainActor
    private func stopStatusTimer() {
        statusTimer?.cancel()
        statusTimer = nil
    }

    // MARK: - 发送(任意线程;NWConnection 内部串行,调用序即发送序)

    private struct HelloMsg: Encodable {
        var type = "hello"
        var version = 1
    }

    private struct ListMsg: Encodable {
        var type = "list"
        var sessions: [RemoteSessionInfo]
        var spaces: [RemoteSidebarSpaceInfo]
        var projects: [RemoteSidebarProjectInfo]
        var theme: RemoteTheme
        var forwards: [RemoteForwardInfo]
    }

    private struct ProjectOpenedMsg: Encodable {
        var type = "projectOpened"
        var session: RemoteSessionInfo
    }

    private struct ProjectOpenFailedMsg: Encodable {
        var type = "projectOpenFailed"
        var message: String
    }

    private struct AttachedMsg: Encodable {
        var type = "attached"
        var id: UUID
        var cols: Int
        var rows: Int
        var tuiMode: Bool
        /// 当前 Mac 主题色板,远端终端同款观感
        var theme: RemoteTheme
        var control: RemoteControlInfo
    }

    private struct ViewportMsg: Encodable {
        var type = "viewport"
        var cols: Int
        var rows: Int
        var tuiMode: Bool
        var control: RemoteControlInfo
    }

    private struct ExitedMsg: Encodable {
        var type = "exited"
    }

    private struct SimListMsg: Encodable {
        var type = "simList"
        var devices: [SimulatorMirror.Device]
        /// Xcode 私有接口不可用时为 false,客户端整块隐藏
        var available: Bool
    }

    private struct ChatListMsg: Encodable {
        var type = "chatList"
        var sessions: [ChatSessionInfo]
        /// 工作空间目录:对话列表的筛选条和终端列表用同一套
        var spaces: [RemoteSidebarSpaceInfo]
        /// 唤起 agent 时选的项目;和侧边栏同一份目录
        var projects: [RemoteSidebarProjectInfo]
        /// Mac 上实际装了的 agent
        var agents: [ChatAgentOption]
    }

    private struct ChatLaunchedMsg: Encodable {
        var type = "chatLaunched"
        /// 新开的 pane,客户端直接附着上去
        var id: UUID
        var title: String
    }

    private struct ChatMessagesMsg: Encodable {
        var type = "chatMessages"
        var messages: [ChatMessage]
        /// true = 首次回放的历史,客户端应整体替换而不是追加
        var history: Bool
        /// 这个会话没有可读的转录(不是 agent 会话,或格式不认识)
        var unavailable = false
    }

    private struct ChatPromptMsg: Encodable {
        var type = "chatPrompt"
        var prompt: ChatPromptInfo
    }

    private struct ChatErrorMsg: Encodable {
        var type = "chatError"
        var message: String
    }

    private struct SimStateMsg: Encodable {
        var type = "simState"
        /// 正在镜像的 UDID;nil = 已停
        var udid: String?
        var message: String?
    }

    private struct ErrorMsg: Encodable {
        var type = "error"
        var message: String
    }

    @MainActor
    private func sendList() {
        let hub = RemoteSessionHub.shared
        let catalog = hub.sidebarCatalog()
        let forwards = RemoteForwarder.shared.forwards.map {
            RemoteForwardInfo(id: $0.id, label: $0.label,
                              target: Int($0.target), port: Int($0.listen))
        }
        sendJSON(ListMsg(sessions: hub.list(), spaces: catalog.spaces,
                         projects: catalog.projects, theme: RemoteTheme.current(),
                         forwards: forwards))
    }

    private func sendJSON(_ message: some Encodable) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        sendFrame(opcode: 0x1, payload: data)
    }

    private func sendFrame(opcode: UInt8, payload: Data) {
        var frame = Data()
        frame.append(0x80 | opcode) // FIN,不分片
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            var len = UInt64(payload.count).bigEndian
            withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
        }
        frame.append(payload)
        connection.send(frame)
    }
}
