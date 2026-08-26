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
    /// 新连接先等 hello；仅 connect/close 的实例探活不能踢掉正式客户端。
    private var candidates: [Int32: ClientConn] = [:]
    private var idleExitTimer: DispatchSourceTimer?

    /// 常驻模式(LaunchAgent 拉起):空转宽限从 60 秒放宽到 30 分钟,
    /// 让登录时预热好的 shell 能等到用户打开 app
    private var resident = false
    /// 预热池:登录时按上次的 cwd 名单先起好的 shell。**不是会话**——不进 sessions、
    /// 不进 LIST,绝不能被孤儿收养(那就是一排重复标签,issue #9)
    private var pool: [PooledShell] = []
    private var poolTTLTimer: DispatchSourceTimer?

    private struct PooledShell {
        let session: HostSession
        /// 交付前提:shell/argv0/cwd/尺寸/环境全都对得上,否则这个 shell 作废
        let signature: String
    }

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
        // close-on-exec:守护进程 forkpty 出每一个 shell,不设就等于把监听 socket
        // 发给所有 shell。守护进程死后这些 shell 仍让 socket 活着,canConnect 照样成功,
        // 新守护进程会误判「已有守护进程在」而拒绝启动
        _ = fcntl(listenFD, F_SETFD, FD_CLOEXEC)
        var addr = Self.unixSockaddr(for: socketPath)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, len) }
        }
        guard bound == 0 else { throw PtyStreamError.badFrame("bind errno=\(errno)") }
        chmod(socketPath, 0o600)
        guard listen(listenFD, 4) == 0 else { throw PtyStreamError.badFrame("listen errno=\(errno)") }
    }

    /// LaunchAgent 模式:常驻 + 按计划预热(main.swift 解析命令行后调用)
    func enableResident(prewarmPlan url: URL?) {
        resident = true
        guard let url else { return }
        queue.async { [weak self] in self?.startPrewarm(planURL: url) }
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
        // 客户端 fd 漏进 shell 后,只有「所有副本都关掉」才读得到 EOF ——
        // app 已经退了,守护进程却因为一群 shell 还攥着副本而认为客户端仍在,
        // 会话归属判断随之失真([[双实例抢 socket]] 那类事故的温床)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        candidates[fd] = ClientConn(fd: fd, readSource: source,
                                    writer: FDWriter(fd: fd, queue: queue))
        source.setEventHandler { [weak self] in self?.readConnection(fd) }
        source.resume()
        log("候选客户端已连接")
    }

    private func readConnection(_ fd: Int32) {
        if client?.fd == fd {
            readClient(fd)
        } else {
            readCandidate(fd)
        }
    }

    /// 候选连接的首个完整帧必须是 hello；探活连接关闭时只清理自己。
    private func readCandidate(_ fd: Int32) {
        guard var candidate = candidates[fd] else { return }
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                do {
                    let frames = try candidate.parser.consume(Data(buf[0..<n]))
                    candidates[fd] = candidate
                    guard !frames.isEmpty else { continue }
                    guard frames[0].type == .hello else {
                        log("候选客户端首帧非 hello，拒绝")
                        dropCandidate(fd)
                        return
                    }
                    promoteCandidate(fd)
                    frames.forEach(handle)
                    return
                } catch {
                    log("候选客户端协议错乱:\(error)")
                    dropCandidate(fd)
                    return
                }
            } else if n == 0 {
                dropCandidate(fd)
                return
            } else {
                return // EAGAIN
            }
        }
    }

    private func promoteCandidate(_ fd: Int32) {
        guard let candidate = candidates.removeValue(forKey: fd) else { return }
        dropClient()
        client = candidate
        cancelIdleExit()
        log("客户端握手完成")
    }

    private func dropCandidate(_ fd: Int32) {
        guard let candidate = candidates.removeValue(forKey: fd) else { return }
        candidate.readSource.cancel()
        candidate.writer.close()
        close(candidate.fd)
    }

    private func dropClient() {
        guard let old = client else { return }
        old.readSource.cancel()
        old.writer.close()
        close(old.fd)
        client = nil
        scheduleIdleExitIfNeeded()
    }

    private func readClient(_ fd: Int32) {
        guard let conn = client, conn.fd == fd else { return }
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
                discardPool(reason: "客户端断开")
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
            if let pooled = claimPooled(for: req) {
                deliverPooled(pooled, to: req)
                return
            }
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
            // 帧在单队列串行处理:先到的 CREATE/ATTACH 必然已进 attached,后到的不在列表里,
            // 所以 attached 标记对「本次启动自建的会话」是无竞态的孤儿排除依据
            let listing = sessions.values.map { session in
                var info = session.info
                info.attached = client?.attached.contains(session.id) == true
                return info
            }
            reply(PtyFrameCodec.encode(.listing, json: listing))

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
            guard let session = sessions.values.first(where: { $0.pid == pid }) else {
                // 预热池里的 shell 自己死了(cwd 失效等):摘掉,别留个「活着」的假货
                if let index = pool.firstIndex(where: { $0.session.pid == pid }) {
                    pool.remove(at: index).session.purge()
                }
                continue
            }
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

    // MARK: - 登录预热池

    /// 一次最多预热多少个 shell(登录时的后台开销要有上限)
    private static let maxPrewarm = 12
    /// 没人认领就自杀的时限
    private static let poolTTL: TimeInterval = 30 * 60

    private func startPrewarm(planURL: URL) {
        guard let data = try? Data(contentsOf: planURL),
              let plan = try? JSONDecoder().decode(PtyPrewarmPlan.self, from: data),
              !plan.entries.isEmpty else { return }
        let entries = Array(plan.entries.prefix(Self.maxPrewarm))
        log("预热开始:\(entries.count) 个 shell(计划共 \(plan.entries.count) 个)")
        spawnPrewarm(plan: plan, entries: entries, index: 0)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        poolTTLTimer = timer
        timer.schedule(deadline: .now() + Self.poolTTL)
        timer.setEventHandler { [weak self] in self?.discardPool(reason: "无人认领,超时") }
        timer.resume()
    }

    /// 一个一个地起:登录时机器本来就忙,预热不该自己再造一次并发尖峰。
    /// 上一个出了提示符(环形缓冲有内容)或等满 1.5 秒就起下一个
    private func spawnPrewarm(plan: PtyPrewarmPlan, entries: [PtyPrewarmPlan.Entry], index: Int) {
        guard index < entries.count else {
            log("预热完成:池中 \(pool.count) 个 shell")
            return
        }
        let entry = entries[index]
        let request = PtyCreateRequest(
            id: UUID(), shellPath: plan.shellPath, argv0: plan.argv0,
            env: plan.env, cwd: entry.cwd, cols: entry.cols, rows: entry.rows
        )
        var spawned: HostSession?
        if let session = try? HostSession(request: request, queue: queue) {
            spawned = session
            pool.append(PooledShell(session: session, signature: Self.signature(of: request)))
        } else {
            log("预热失败(跳过):\(entry.cwd)")
        }
        // 上一个出了提示符(或等满 1.5 秒)再起下一个:登录时机器本来就忙,
        // 预热不该自己再造一次并发尖峰
        waitForPrompt(of: spawned, waited: 0) { [weak self] in
            self?.spawnPrewarm(plan: plan, entries: entries, index: index + 1)
        }
    }

    private func waitForPrompt(of session: HostSession?, waited: TimeInterval,
                               then next: @escaping () -> Void) {
        guard let session, session.ring.tailOffset == 0, waited < 1.5 else {
            next()
            return
        }
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForPrompt(of: session, waited: waited + 0.1, then: next)
        }
    }

    /// 交付:改挂 id、补发已经打出来的提示符,之后与普通会话别无二致
    private func deliverPooled(_ pooled: HostSession, to req: PtyCreateRequest) {
        pooled.adopt(id: req.id)
        pooled.onOutput = { [weak self] id, offset, data in
            guard let self, self.client?.attached.contains(id) == true else { return }
            self.reply(PtyFrameCodec.encodeOutput(id: id, startOffset: offset, bytes: data))
        }
        sessions[req.id] = pooled
        client?.attached.insert(req.id)
        reply(PtyFrameCodec.encode(.created, json: PtyCreated(id: req.id, pid: pooled.pid)))
        // 预热期间打出的提示符还在环形缓冲里:CREATE 的客户端从 0 收起,补发即可
        let backlog = pooled.ring.read(from: 0)
        if !backlog.data.isEmpty {
            reply(PtyFrameCodec.encodeOutput(id: req.id, startOffset: backlog.fromOffset, bytes: backlog.data))
        }
        log("预热交付 \(req.id) pid=\(pooled.pid) cwd=\(req.cwd) 补发=\(backlog.data.count)B")
    }

    /// 严格匹配:shell/argv0/cwd/尺寸/环境全对得上才交付,差一点就老实新孵一个
    private func claimPooled(for req: PtyCreateRequest) -> HostSession? {
        let wanted = Self.signature(of: req)
        guard let index = pool.firstIndex(where: { $0.signature == wanted && $0.session.alive }) else { return nil }
        return pool.remove(at: index).session
    }

    private func discardPool(reason: String) {
        guard !pool.isEmpty else { return }
        log("预热池清空(\(reason)):\(pool.count) 个")
        for pooled in pool {
            pooled.session.hangup()
            pooled.session.purge()
        }
        pool = []
        poolTTLTimer?.cancel()
        poolTTLTimer = nil
        scheduleIdleExitIfNeeded()
    }

    private static func signature(of req: PtyCreateRequest) -> String {
        let env = req.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{1}")
        return [req.shellPath, req.argv0, req.cwd, "\(req.cols)x\(req.rows)", env].joined(separator: "\u{2}")
    }

    // MARK: - 空转退出

    /// 无客户端且无存活会话时,宽限 60 秒后自行退出(死会话记录随之放弃:
    /// app 若在宽限期内回来,自然通过 LIST 拿到讣告)
    private func scheduleIdleExitIfNeeded() {
        guard client == nil, sessions.values.allSatisfy({ !$0.alive }), pool.isEmpty else { return }
        cancelIdleExit()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        idleExitTimer = timer
        // 常驻模式(登录时拉起、还没人来用)给足宽限,别在用户打开 app 之前就退了
        timer.schedule(deadline: .now() + (resident ? 30 * 60 : 60))
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
