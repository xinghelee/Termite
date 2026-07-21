import AppKit
import Darwin
import Foundation

/// termite-ptyhost 守护进程的 app 侧客户端:单连接多路复用全部会话。
/// 守护进程按需拉起(bundle 内 Contents/MacOS/termite-ptyhost);
/// 连不上/握手失败时调用方回落本地 LocalProcess 路径。
@MainActor
final class PtyHostClient {
    static let shared = PtyHostClient()

    /// 会话回调(MainActor 上调用)
    struct Binding {
        var output: (UInt64, Data) -> Void
        var exited: (Int32?) -> Void
    }

    private let ioQueue = DispatchQueue(label: "ptyhost.client")
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writer: FDWriter?
    private var parser = PtyFrameParser()
    private var bindings: [UUID: Binding] = [:]
    /// 排队中的请求应答位:守护进程按序处理帧,应答按 FIFO 对号
    private var waiters: [(token: UUID, expect: Set<PtyFrameType>, cont: CheckedContinuation<(PtyFrameType, Data)?, Never>)] = []

    var isConnected: Bool { fd >= 0 }

    // MARK: - 连接与握手

    /// 确保已连接且版本握手通过;必要时拉起守护进程(spawnIfNeeded=false 只连不拉,
    /// 供「查孤儿」这类没有守护进程就没意义的场景)。失败返回 false(调用方回落本地)。
    ///
    /// 单飞:启动恢复会并发创建多个会话,曾各自走完整握手——重复 spawn 守护进程
    /// (输家 bind errno=48 退出)、重复 connect 反复顶掉共享的 fd/writer/parser,
    /// waiters 应答错配后超时兜底又把唯一活连接断掉,留下有 hostPtyID 却没有
    /// writer 的「听不见输入」死会话。并发调用在这里合流,等同一次握手的结果。
    func ensureReady(spawnIfNeeded: Bool = true) async -> Bool {
        while true {
            if isConnected { return true }
            guard let current = connecting else { break }
            if await current.task.value { return true }
            // 上一轮失败:它拉起过守护进程(或本调用同样只探测)就没有更多可做;
            // 只探测的轮次失败而本调用允许拉起 → 回到循环自己开一轮
            if current.spawns || !spawnIfNeeded { return false }
        }
        let task = Task {
            let ok = await self.establishConnection(spawnIfNeeded: spawnIfNeeded)
            self.connecting = nil // 在完成前清掉,等待方恢复时看到的一定是新状态
            return ok
        }
        connecting = (spawns: spawnIfNeeded, task: task)
        return await task.value
    }

    /// 进行中的连接/握手(spawns 记录该轮是否允许拉起守护进程)
    private var connecting: (spawns: Bool, task: Task<Bool, Never>)?

    private func establishConnection(spawnIfNeeded: Bool) async -> Bool {
        let path = PtyHostPaths.socketURL.path
        try? FileManager.default.createDirectory(at: PtyHostPaths.socketURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var spawned = false
        for _ in 0..<20 {
            if connect(to: path) {
                guard let reply = await request(.hello, payload: heloPayload(), expect: [.helloAck]),
                      let ack: PtyHello = PtyFrameCodec.decodeJSON(reply.1),
                      ack.version == ptyHostProtocolVersion else {
                    // 版本对不上(理论上 socket 名已隔离版本):放弃保活
                    disconnect(notifySessions: false)
                    return false
                }
                return true
            }
            if !spawned {
                guard spawnIfNeeded else { return false }
                spawned = true
                guard spawnDaemon() else { return false }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func heloPayload() -> Data {
        (try? JSONEncoder().encode(PtyHello(version: ptyHostProtocolVersion))) ?? Data()
    }

    private func spawnDaemon() -> Bool {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "termite-ptyhost") else { return false }
        let process = Process()
        process.executableURL = url
        return (try? process.run()) != nil
    }

    private func connect(to path: String) -> Bool {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.utf8CString.withUnsafeBufferPointer { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                dst.copyBytes(from: UnsafeRawBufferPointer(src).prefix(dst.count - 1))
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sock, $0, len) == 0 }
        }
        guard ok else {
            close(sock)
            return false
        }
        _ = fcntl(sock, F_SETFL, fcntl(sock, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        fd = sock
        parser = PtyFrameParser()
        writer = FDWriter(fd: sock, queue: ioQueue)
        let source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: ioQueue)
        readSource = source
        source.setEventHandler { [weak self] in self?.drainSocket(sock) }
        source.resume()
        return true
    }

    /// ioQueue 上读 socket,帧解析后逐帧回主线程分发
    private nonisolated func drainSocket(_ sock: Int32) {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(sock, &buf, buf.count)
            if n > 0 {
                let data = Data(buf[0..<n])
                Task { @MainActor in self.ingest(data) }
            } else if n == 0 {
                Task { @MainActor in self.disconnect(notifySessions: true) }
                return
            } else {
                return // EAGAIN
            }
        }
    }

    private func ingest(_ data: Data) {
        guard let frames = try? parser.consume(data) else {
            disconnect(notifySessions: true)
            return
        }
        for frame in frames {
            switch frame.type {
            case .output:
                guard let (id, offset, bytes) = PtyFrameCodec.decodeOutput(frame.payload) else { continue }
                bindings[id]?.output(offset, bytes)
            case .exited:
                guard let ex: PtyExited = PtyFrameCodec.decodeJSON(frame.payload) else { continue }
                bindings[ex.id]?.exited(ex.exitCode)
                bindings[ex.id] = nil
            default:
                guard let index = waiters.firstIndex(where: { $0.expect.contains(frame.type) }) else { continue }
                let waiter = waiters.remove(at: index)
                waiter.cont.resume(returning: (frame.type, frame.payload))
            }
        }
    }

    /// 守护进程死亡 = 它名下的 shell 全部收到 SIGHUP,如实上报会话退出
    private func disconnect(notifySessions: Bool) {
        readSource?.cancel()
        readSource = nil
        if let writer {
            ioQueue.async { writer.close() }
        }
        writer = nil
        if fd >= 0 { close(fd) }
        fd = -1
        for waiter in waiters { waiter.cont.resume(returning: nil) }
        waiters = []
        if notifySessions {
            let dropped = bindings
            bindings = [:]
            for (_, binding) in dropped { binding.exited(nil) }
        }
    }

    // MARK: - 请求应答

    private func request(_ type: PtyFrameType, payload: Data, expect: Set<PtyFrameType>) async -> (PtyFrameType, Data)? {
        guard isConnected else { return nil }
        send(PtyFrameCodec.encode(type, payload: payload))
        let token = UUID()
        return await withCheckedContinuation { cont in
            waiters.append((token: token, expect: expect.union([.errorReply]), cont: cont))
            // 兜底超时:5 秒无应答按失败处理(守护进程卡死等极端情况)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, let index = self.waiters.firstIndex(where: { $0.token == token }) else { return }
                let waiter = self.waiters.remove(at: index)
                waiter.cont.resume(returning: nil)
            }
        }
    }

    private func send(_ data: Data) {
        guard let writer else { return }
        ioQueue.async { writer.write(data) }
    }

    // MARK: - 会话操作

    func bind(_ id: UUID, output: @escaping (UInt64, Data) -> Void, exited: @escaping (Int32?) -> Void) {
        bindings[id] = Binding(output: output, exited: exited)
    }

    func unbind(_ id: UUID) {
        bindings[id] = nil
    }

    func create(_ request: PtyCreateRequest) async -> PtyCreated? {
        guard let reply = await self.request(.create, payload: encodeJSON(request), expect: [.created]),
              reply.0 == .created else { return nil }
        return PtyFrameCodec.decodeJSON(reply.1)
    }

    func attach(id: UUID, since offset: UInt64) async -> PtyAttached? {
        let req = PtyAttachRequest(id: id, sinceOffset: offset)
        guard let reply = await request(.attach, payload: encodeJSON(req), expect: [.attached]),
              reply.0 == .attached else { return nil }
        return PtyFrameCodec.decodeJSON(reply.1)
    }

    func list() async -> [PtySessionInfo]? {
        guard let reply = await request(.list, payload: Data(), expect: [.listing]),
              reply.0 == .listing else { return nil }
        return PtyFrameCodec.decodeJSON(reply.1)
    }

    func input(id: UUID, _ bytes: [UInt8]) {
        send(PtyFrameCodec.encodeInput(id: id, bytes: bytes))
    }

    func resize(id: UUID, cols: Int, rows: Int) {
        send(PtyFrameCodec.encode(.resize, json: PtyResizeRequest(id: id, cols: cols, rows: rows)))
    }

    func detach(id: UUID) {
        unbind(id)
        send(PtyFrameCodec.encode(.detach, json: PtySessionRef(id: id)))
    }

    func kill(id: UUID) {
        send(PtyFrameCodec.encode(.kill, json: PtySessionRef(id: id)))
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
}