import Darwin
import Foundation

/// BSD socket 监听 + 连接读写。
///
/// 为什么不用 Network.framework:`NWListener` 收不到 VPN(utun)接口上的入站连接。
/// 同一台机器上,普通 socket 绑 `::` 时 Tailscale 地址(100.64/10)可达,而 NWListener
/// 在默认参数、`requiredInterfaceType = .other`、绑定 utun 地址、`preferNoProxies`
/// 四种配置下一律握手超时 —— 而远程访问的主力场景恰恰是 Tailscale。
///
/// 线程模型:所有状态只在 `queue`(串行)上读写,对外方法可从任意线程调用,内部 async 入队。
/// 发送顺序 = 调用顺序(串行队列 FIFO),和原来 NWConnection 的保序语义一致。
final class SocketListener: @unchecked Sendable {
    enum Failure: Error {
        case socketFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
    }

    private let queue: DispatchQueue
    private let fd: Int32
    private var source: DispatchSourceRead?
    private var closed = false

    /// 绑 `::` 且关掉 IPV6_V6ONLY:一个 socket 同时收 IPv6 与 IPv4(含 Tailscale 的 100.x)
    init(port: UInt16, queue: DispatchQueue, onAccept: @escaping (SocketConnection) -> Void) throws {
        self.queue = queue

        let handle = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        guard handle >= 0 else { throw Failure.socketFailed(errno) }
        // 出生即 close-on-exec:终端会话是 fork+exec 出来的,监听 fd 一旦被 shell 继承,
        // app 退出后端口仍被这些 shell 占着,下一个实例 bind 失败、远程访问静默死掉
        //(表现为手机连不上却查不出原因);顺带也不该把终端控制服务的 socket
        // 交到用户在终端里随手运行的任何程序手上
        _ = fcntl(handle, F_SETFD, FD_CLOEXEC)
        self.fd = handle

        var yes: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var no: Int32 = 0
        setsockopt(handle, IPPROTO_IPV6, IPV6_V6ONLY, &no, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any

        let bound = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(handle)
            throw Failure.bindFailed(code)
        }
        guard listen(handle, 32) == 0 else {
            let code = errno
            close(handle)
            throw Failure.listenFailed(code)
        }
        _ = fcntl(handle, F_SETFL, O_NONBLOCK)

        let accepting = DispatchSource.makeReadSource(fileDescriptor: handle, queue: queue)
        // 不捕获 self:weak self 会让「listener 已释放但 source 还在」退化成
        // 连接能建、永不被 accept 的静默假死;生命周期改由 deinit 明确终结
        accepting.setEventHandler {
            // 一次事件可能积压多个连接,取干净为止
            while true {
                var storage = sockaddr_storage()
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let client = withUnsafeMutablePointer(to: &storage) { raw in
                    raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(handle, $0, &length)
                    }
                }
                guard client >= 0 else { return }
                // 同上:accept 出来的连接 fd 也不能漏给 shell,否则对端关掉后
                // 连接卡在 CLOSE_WAIT 收不干净(fd 还被子进程攥着)
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                onAccept(SocketConnection(fd: client, queue: queue))
            }
        }
        accepting.setCancelHandler { close(handle) }
        self.source = accepting
        accepting.resume()
    }

    func cancel() {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            self.source?.cancel()
            self.source = nil
        }
    }

    deinit {
        source?.cancel() // cancelHandler 里 close(fd),不碰 self
    }
}

/// 一条已建立的 TCP 连接。
///
/// 接口有意贴着原来用到的那一小片 `NWConnection` 表面(receive 一块、send 一块、cancel),
/// 调用点照原样递归收包即可。`isFinal` 对应 NWConnection 的 `.finalMessage`:
/// 数据真正写出去之后再半关闭,close 回礼不会丢在栈里。
final class SocketConnection: @unchecked Sendable {
    enum Failure: Error {
        case closed
        case errno(Int32)
    }

    private struct Outgoing {
        let data: Data
        var offset: Int
        let final: Bool
        let completion: ((Error?) -> Void)?
    }

    let queue: DispatchQueue
    private let fd: Int32
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var readRunning = false
    private var writeRunning = false
    private var liveSources = 0
    private var closed = false

    private var pendingReader: ((Data?, Bool, Error?) -> Void)?
    private var outbox: [Outgoing] = []

    /// 连接因对端断开或出错而失效时回调一次(替代 stateUpdateHandler 里的 .failed)
    var onFailure: (() -> Void)?

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var yes: Int32 = 1
        // SIGPIPE 会直接杀进程:对端先关时 write 必须以 EPIPE 返回而不是发信号
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    /// 建好读写源。fd 由两个源共同持有,最后一个取消时才 close
    func start() {
        queue.async {
            guard !self.closed, self.readSource == nil else { return }

            let reading = DispatchSource.makeReadSource(fileDescriptor: self.fd, queue: self.queue)
            reading.setEventHandler { [weak self] in self?.readReady() }
            reading.setCancelHandler { [weak self] in self?.sourceFinished() }
            self.readSource = reading
            self.liveSources += 1

            let writing = DispatchSource.makeWriteSource(fileDescriptor: self.fd, queue: self.queue)
            writing.setEventHandler { [weak self] in self?.drainOutbox() }
            writing.setCancelHandler { [weak self] in self?.sourceFinished() }
            self.writeSource = writing
            self.liveSources += 1

            // 读源按需 resume(有人等数据才读),写源按需 resume(有东西要写才写)
            if self.pendingReader != nil { self.resumeRead() }
            if !self.outbox.isEmpty { self.drainOutbox() }
        }
    }

    /// 收一块数据。completion 参数与 NWConnection 同序:(data, isComplete, error)
    func receive(maximumLength: Int, completion: @escaping (Data?, Bool, Error?) -> Void) {
        queue.async {
            guard !self.closed else {
                completion(nil, true, Failure.closed)
                return
            }
            self.maxRead = maximumLength
            self.pendingReader = completion
            self.resumeRead()
        }
    }

    /// 发一块数据。isFinal 表示写完即半关闭(冲刷后 FIN)
    func send(_ data: Data, isFinal: Bool = false, completion: ((Error?) -> Void)? = nil) {
        queue.async {
            guard !self.closed else {
                completion?(Failure.closed)
                return
            }
            self.outbox.append(Outgoing(data: data, offset: 0, final: isFinal, completion: completion))
            self.drainOutbox()
        }
    }

    func cancel() {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            self.pendingReader = nil
            self.outbox.removeAll()
            // suspend 状态的源被 cancel 后 cancelHandler 不会跑,必须先放行
            if let reading = self.readSource {
                reading.cancel()
                if !self.readRunning { reading.resume(); self.readRunning = true }
            }
            if let writing = self.writeSource {
                writing.cancel()
                if !self.writeRunning { writing.resume(); self.writeRunning = true }
            }
            self.readSource = nil
            self.writeSource = nil
            // start() 还没来得及建源:直接关 fd,否则等两个源的 cancelHandler
            if self.liveSources == 0 { close(self.fd) }
        }
    }

    // MARK: - 读

    private var maxRead = 64 * 1024

    private func readReady() {
        guard !closed else { return }
        guard let reader = pendingReader else {
            suspendRead()
            return
        }
        var buffer = [UInt8](repeating: 0, count: maxRead)
        let count = buffer.withUnsafeMutableBytes { raw in
            read(fd, raw.baseAddress, raw.count)
        }
        if count > 0 {
            pendingReader = nil
            suspendRead()
            reader(Data(buffer.prefix(count)), false, nil)
            return
        }
        if count == 0 { // 对端关闭
            pendingReader = nil
            suspendRead()
            reader(nil, true, nil)
            return
        }
        let code = errno
        if code == EAGAIN || code == EWOULDBLOCK || code == EINTR { return } // 等下一次事件
        pendingReader = nil
        suspendRead()
        reader(nil, true, Failure.errno(code))
    }

    private func resumeRead() {
        guard let reading = readSource, !readRunning, !closed else { return }
        readRunning = true
        reading.resume()
    }

    private func suspendRead() {
        guard let reading = readSource, readRunning else { return }
        readRunning = false
        reading.suspend()
    }

    // MARK: - 写

    private func drainOutbox() {
        guard !closed else { return }
        while var head = outbox.first {
            let remaining = head.data.count - head.offset
            if remaining <= 0 {
                outbox.removeFirst()
                if head.final { shutdown(fd, SHUT_WR) }
                head.completion?(nil)
                continue
            }
            let written = head.data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base.advanced(by: head.offset), remaining)
            }
            if written > 0 {
                head.offset += written
                outbox[0] = head
                continue
            }
            let code = errno
            if written < 0, code == EAGAIN || code == EWOULDBLOCK || code == EINTR {
                resumeWrite() // 内核缓冲满,等可写事件
                return
            }
            // 真出错:通知所有在等的发送方,连接作废
            let pending = outbox
            outbox.removeAll()
            for item in pending { item.completion?(Failure.errno(code)) }
            suspendWrite()
            failNow()
            return
        }
        suspendWrite()
    }

    private func resumeWrite() {
        guard let writing = writeSource, !writeRunning, !closed else { return }
        writeRunning = true
        writing.resume()
    }

    private func suspendWrite() {
        guard let writing = writeSource, writeRunning else { return }
        writeRunning = false
        writing.suspend()
    }

    // MARK: - 收尾

    private func sourceFinished() {
        liveSources -= 1
        if liveSources <= 0 { close(fd) }
    }

    private func failNow() {
        let notify = onFailure
        onFailure = nil
        notify?()
    }

    /// 正常路径都会显式 cancel;这里兜底,防止漏掉一条就泄一个 fd
    deinit {
        if let reading = readSource {
            reading.cancel()
            if !readRunning { reading.resume() }
        }
        if let writing = writeSource {
            writing.cancel()
            if !writeRunning { writing.resume() }
        }
        // 源都没建起来过(start 没调用),fd 还没人管
        if readSource == nil, writeSource == nil, !closed { close(fd) }
    }
}
