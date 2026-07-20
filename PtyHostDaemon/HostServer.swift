import Darwin
import Foundation

/// Unix socket 服务:单客户端(Termite app)多路复用全部会话。
/// 新连接顶替旧连接(app 崩溃重启后旧 fd 可能半死不活)。
final class HostServer {
    private let queue = DispatchQueue(label: "ptyhost")
    private let listenFD: Int32
    private var acceptSource: DispatchSourceRead?
    private var sigchldSource: DispatchSourceSignal?

    private var sessions: [UUID: HostSession] = [:]
    /// 当前客户端连接(fd + 读源 + 写缓冲 + 帧解析器)
    private var client: ClientConn?
    private var idleExitTimer: DispatchSourceTimer?

    private struct ClientConn {
        let fd: Int32
        let readSource: DispatchSourceRead
        let writer: FDWriter
        var parser = PtyFrameParser()
        var attached: Set<UUID> = []
    }

    init(socketPath: String) throws {
        // 有活的守护进程就让位;连不上说明 socket 是陈尸,清掉重建
        if Self.canConnect(socketPath) {
            throw PtyStreamError.badFrame("已有守护进程在 \(socketPath)")
        }
        unlink(socketPath)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw PtyStreamError.badFrame("socket errno=\(errno)") }
        var addr = Self.unixSockaddr(for: socketPath)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, len) }
        }
        guard bound == 0 else { throw PtyStreamError.badFrame("bind errno=\(errno)") }
        chmod(socketPath, 0o600)
        guard listen(listenFD, 4) == 0 else { throw PtyStreamError.badFrame("listen errno=\(errno)") }
    }

    func run() {
        let accept = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        acceptSource = accept
        accept.setEventHandler { [weak self] in self?.acceptClient() }
        accept.resume()

        signal(SIGCHLD, SIG_DFL)
        let sigchld = DispatchSource.makeSignalSource(signal: SIGCHLD, queue: queue)
        sigchldSource = sigchld
        sigchld.setEventHandler { [weak self] in self?.reapChildren() }
        sigchld.resume()
    }

    // MARK: - 客户端连接

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        dropClient()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        client = ClientConn(fd: fd, readSource: source, writer: FDWriter(fd: fd, queue: queue))
        source.setEventHandler { [weak self] in self?.readClient() }
        source.resume()
        cancelIdleExit()
        log("客户端已连接")
    }

    private func dropClient() {
        guard let old = client else { return }
        old.readSource.cancel()
        old.writer.close()
        close(old.fd)
        client = nil
        scheduleIdleExitIfNeeded()
    }

    private func readClient() {
        guard let conn = client else { return }
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(conn.fd, &buf, buf.count)
            if n > 0 {
                do {
                    let frames = try client!.parser.consume(Data(buf[0..<n]))
                    frames.forEach(handle)
                } catch {
                    log("协议错乱,断开客户端:\(error)")
                    dropClient()
                    return
                }
            } else if n == 0 {
                log("客户端断开")
                dropClient()
                return
            } else {
                return // EAGAIN
            }
        }
    }

    private func reply(_ data: Data) {
        client?.writer.write(data)
    }

    // MARK: - 帧处理

    private func handle(_ frame: (type: PtyFrameType, payload: Data)) {
        switch frame.type {
        case .hello:
            reply(PtyFrameCodec.encode(.helloAck, json: PtyHello(version: ptyHostProtocolVersion)))

        case .create:
            guard let req: PtyCreateRequest = PtyFrameCodec.decodeJSON(frame.payload) else { return }
            do {
                let session = try HostSession(request: req, queue: queue)
                session.onOutput = { [weak self] id, offset, data in
                    guard let self, self.client?.attached.contains(id) == true else { return }
                    self.reply(PtyFrameCodec.encodeOutput(id: id, startOffset: offset, bytes: data))
                }
                sessions[req.id] = session
                client?.attached.insert(req.id)
                reply(PtyFrameCodec.encode(.created, json: PtyCreated(id: req.id, pid: session.pid)))
                log("创建会话 \(req.id) pid=\(session.pid) cwd=\(req.cwd)")
            } catch {
                reply(PtyFrameCodec.encode(.errorReply, json: PtyError(message: "\(error)")))
            }

        case .attach:
            guard let req: PtyAttachRequest = PtyFrameCodec.decodeJSON(frame.payload),
                  let session = sessions[req.id] else {
                reply(PtyFrameCodec.encode(.errorReply, json: PtyError(message: "会话不存在")))
                return
            }
            client?.attached.insert(req.id)
            let backlog = session.ring.read(from: req.sinceOffset)
            reply(PtyFrameCodec.encode(.attached, json: PtyAttached(id: req.id, fromOffset: backlog.fromOffset, gap: backlog.gap)))
            if !backlog.data.isEmpty {
                reply(PtyFrameCodec.encodeOutput(id: req.id, startOffset: backlog.fromOffset, bytes: backlog.data))
            }
            // 断开期间死掉的会话:补发讣告
            if !session.alive {
                reply(PtyFrameCodec.encode(.exited, json: PtyExited(id: req.id, exitCode: session.exitCode)))
            }
            log("attach \(req.id) since=\(req.sinceOffset) 补发=\(backlog.data.count)B gap=\(backlog.gap)")

        case .input:
            guard let (id, bytes) = PtyFrameCodec.decodeInput(frame.payload) else { return }
            sessions[id]?.send(bytes)

        case .resize:
            guard let req: PtyResizeRequest = PtyFrameCodec.decodeJSON(frame.payload) else { return }
            sessions[req.id]?.resize(cols: req.cols, rows: req.rows)

        case .detach:
            guard let ref: PtySessionRef = PtyFrameCodec.decodeJSON(frame.payload) else { return }
            client?.attached.remove(ref.id)

        case .kill:
            guard let ref: PtySessionRef = PtyFrameCodec.decodeJSON(frame.payload) else { return }
            if let session = sessions[ref.id] {
                if session.alive {
                    session.hangup() // SIGCHLD 收尸后统一清理
                } else {
                    session.purge()
                    sessions[ref.id] = nil
                    scheduleIdleExitIfNeeded()
                }
            }

        case .list:
            reply(PtyFrameCodec.encode(.listing, json: sessions.values.map(\.info)))

        default:
            log("忽略帧 \(frame.type)")
        }
    }

    // MARK: - 子进程收尸

    private func reapChildren() {
        while true {
            var status: Int32 = 0
            let pid = waitpid(-1, &status, WNOHANG)
            guard pid > 0 else { return }
            guard let session = sessions.values.first(where: { $0.pid == pid }) else { continue }
            let code: Int32? = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : nil
            session.markExited(code: code)
            log("会话 \(session.id) 退出 code=\(code.map(String.init) ?? "signal")")
            if client?.attached.contains(session.id) == true {
                reply(PtyFrameCodec.encode(.exited, json: PtyExited(id: session.id, exitCode: code)))
                // 已通知客户端,记录使命完成;未 attach 的留到下次 LIST/ATTACH 再清
                session.purge()
                sessions[session.id] = nil
            }
            scheduleIdleExitIfNeeded()
        }
    }

    // MARK: - 空转退出

    /// 无客户端且无存活会话时,宽限 60 秒后自行退出(死会话记录随之放弃:
    /// app 若在宽限期内回来,自然通过 LIST 拿到讣告)
    private func scheduleIdleExitIfNeeded() {
        guard client == nil, sessions.values.allSatisfy({ !$0.alive }) else { return }
        cancelIdleExit()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        idleExitTimer = timer
        timer.schedule(deadline: .now() + 60)
        timer.setEventHandler {
            log("空转,退出")
            exit(0)
        }
        timer.resume()
    }

    private func cancelIdleExit() {
        idleExitTimer?.cancel()
        idleExitTimer = nil
    }

    // MARK: - 工具

    private static func unixSockaddr(for path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.utf8CString.withUnsafeBufferPointer { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                dst.copyBytes(from: UnsafeRawBufferPointer(src).prefix(dst.count - 1))
            }
        }
        return addr
    }

    static func canConnect(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = unixSockaddr(for: path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
        }
    }
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
}
