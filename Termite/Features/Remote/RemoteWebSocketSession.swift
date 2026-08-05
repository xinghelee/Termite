import Foundation
import Network

/// RFC 6455 服务端:帧编解码 + 会话桥接。
/// 一条 WS 连接同一时刻至多附着一个会话(手机屏幕一次只看一个终端)。
/// 线程模型:网络收发在 netQueue;桥接状态(附着会话、尺寸跟随)全部主线程,
/// 输入经 DispatchQueue.main FIFO 入主线程,和本地键入同路且保序。
final class RemoteWebSocketSession: @unchecked Sendable {
    private let connection: NWConnection
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
    /// 上次见到的 Mac 视图网格(变化 = Mac 端 resize 夺回尺寸主导权,推给远端)
    private var lastCols = 0
    private var lastRows = 0
    private var statusTimer: DispatchSourceTimer?

    private var pingTimer: DispatchSourceTimer?

    private static let maxMessage = 1 * 1024 * 1024

    init(connection: NWConnection, onClose: @escaping () -> Void) {
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
                RemoteSessionHub.shared.detach(connID: self.connID)
            }
        }
    }

    // MARK: - 接收与帧解析(netQueue)

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
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
        case 0x8: // close:回礼标记 finalMessage(先冲数据再 FIN);
            // contentProcessed 不等于已落线,紧跟 cancel 会把回礼丢在栈里
            closing = true
            connection.send(content: Data([0x88, 0x00]), contentContext: .finalMessage,
                            isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.onClose()
            })
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
    }

    private func handleText(_ data: Data) {
        guard let msg = try? JSONDecoder().decode(ClientMsg.self, from: data) else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                switch msg.type {
                case "list":
                    self.sendJSON(ListMsg(sessions: RemoteSessionHub.shared.list(),
                                          theme: RemoteTheme.current()))
                case "attach":
                    if let id = msg.id { self.attach(id) }
                case "detach":
                    self.detachCurrent()
                case "resize":
                    // 「适配手机宽度」:远端接管 PTY 尺寸,解附自动还给 Mac。
                    // 不动 lastCols/lastRows——它们跟踪的是 Mac 视图网格(变化=Mac 夺回),
                    // override 只改 PTY,Mac 视图不变,轮询自然不误报
                    if let sid = self.attachedSessionID, let cols = msg.cols, let rows = msg.rows {
                        RemoteSessionHub.shared.overrideSize(connID: self.connID, sessionID: sid,
                                                             cols: cols, rows: rows)
                    }
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
                RemoteSessionHub.shared.sendInput(sessionID: sid, bytes: [UInt8](data))
            }
        }
    }

    @MainActor
    private func attach(_ sessionID: UUID) {
        detachCurrent()
        let hub = RemoteSessionHub.shared
        guard let result = hub.attach(connID: connID, sessionID: sessionID, push: { [weak self] data in
            self?.sendFrame(opcode: 0x2, payload: data)
        }) else {
            sendJSON(ErrorMsg(message: String(localized: "会话不存在或已关闭")))
            return
        }
        attachedSessionID = sessionID
        lastCols = result.cols
        lastRows = result.rows
        sendJSON(AttachedMsg(id: sessionID, cols: result.cols, rows: result.rows,
                             theme: RemoteTheme.current()))
        // 镜像缓冲为空时用屏幕快照垫底(灰字示意历史内容),否则回放缓冲
        if let snapshot = result.snapshot {
            let normalized = snapshot.replacingOccurrences(of: "\n", with: "\r\n")
            sendFrame(opcode: 0x2, payload: Data(("\u{1b}[2m" + normalized + "\u{1b}[0m\r\n").utf8))
        }
        if !result.backlog.isEmpty {
            sendFrame(opcode: 0x2, payload: result.backlog)
        }
        startStatusTimer()
    }

    @MainActor
    private func detachCurrent() {
        guard attachedSessionID != nil else { return }
        RemoteSessionHub.shared.detach(connID: connID)
        attachedSessionID = nil
        stopStatusTimer()
    }

    /// 每秒对照一次会话状态:Mac 端窗口调整 → 推 resize;会话退出/被关 → 推 exited。
    /// 轮询换取与所有传输路径解耦(保活/本地/串口一视同仁)
    @MainActor
    private func startStatusTimer() {
        stopStatusTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        statusTimer = timer
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let sid = self.attachedSessionID else { return }
                guard let status = RemoteSessionHub.shared.status(sessionID: sid), status.alive else {
                    self.sendJSON(ExitedMsg())
                    self.detachCurrent()
                    return
                }
                if status.cols != self.lastCols || status.rows != self.lastRows {
                    self.lastCols = status.cols
                    self.lastRows = status.rows
                    self.sendJSON(ResizeMsg(cols: status.cols, rows: status.rows))
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
        var theme: RemoteTheme
    }

    private struct AttachedMsg: Encodable {
        var type = "attached"
        var id: UUID
        var cols: Int
        var rows: Int
        /// 当前 Mac 主题色板,远端终端同款观感
        var theme: RemoteTheme
    }

    private struct ResizeMsg: Encodable {
        var type = "resize"
        var cols: Int
        var rows: Int
    }

    private struct ExitedMsg: Encodable {
        var type = "exited"
    }

    private struct ErrorMsg: Encodable {
        var type = "error"
        var message: String
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
        connection.send(content: frame, completion: .idempotent)
    }
}
