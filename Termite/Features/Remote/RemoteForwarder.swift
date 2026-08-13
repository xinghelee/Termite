import Foundation
import Network
import Observation

/// 本机端口转发:把 Mac 上只监听 127.0.0.1 的服务透过远程访问通道给手机用。
///
/// 典型场景是「人在外面用手机连回家里开发」:模拟器与 Mac 共用网络栈,跑在模拟器里的
/// App(比如链了 SandboxServer 的调试 console)在 Mac 上就是 127.0.0.1:xxxx,
/// 转发出去手机就能看画面、点按、滑动;dev server / Storybook 同理。
///
/// 为什么一个转发独占一个监听端口,而不是 /p/<port>/ 这种路径前缀:被代理的页面里
/// 只要有一条绝对路径(/app.js、/ws)就会绕开前缀打到 Termite 自己身上,整页崩。
/// 独占端口时代理根就是目标根,绝对路径原样成立,WebSocket 升级也不用特判。
@MainActor
@Observable
final class RemoteForwarder {
    static let shared = RemoteForwarder()

    struct Forward: Codable, Identifiable, Equatable {
        var id: UUID
        /// 本机服务端口(127.0.0.1 上的那个)
        var target: UInt16
        /// 对外监听端口
        var listen: UInt16
        var label: String
    }

    private(set) var forwards: [Forward] = []
    private(set) var lastError: String?

    private var listeners: [UUID: NWListener] = [:]
    private let connections = ConnectionBag()

    private static let storageKey = "remote.forwards"
    /// 对外端口从这里往上找空位,避开常用端口段
    private static let listenBase: UInt16 = 19280

    init() {
        load()
    }

    // MARK: - 增删

    @discardableResult
    func add(target: UInt16, label: String) -> Forward? {
        guard target >= 1, !forwards.contains(where: { $0.target == target }) else { return nil }
        guard let listen = freeListenPort() else {
            lastError = String(localized: "没有可用的对外端口")
            return nil
        }
        let forward = Forward(id: UUID(), target: target, listen: listen,
                              label: label.isEmpty ? "localhost:\(target)" : label)
        forwards.append(forward)
        persist()
        startListener(forward)
        return forward
    }

    func remove(_ forward: Forward) {
        listeners.removeValue(forKey: forward.id)?.cancel()
        forwards.removeAll { $0.id == forward.id }
        persist()
    }

    /// 远程访问服务起停时跟随:关掉远程访问,转发也不该继续开着
    func startAll() {
        for forward in forwards where listeners[forward.id] == nil {
            startListener(forward)
        }
    }

    func stopAll() {
        for listener in listeners.values { listener.cancel() }
        listeners = [:]
        connections.cancelAll()
    }

    func url(for forward: Forward, host: String, token: String) -> String {
        "http://\(host):\(forward.listen)/?t=\(token)"
    }

    // MARK: - 监听

    private func freeListenPort() -> UInt16? {
        let used = Set(forwards.map(\.listen) + [RemoteAccessServer.shared.port])
        for candidate in Self.listenBase..<(Self.listenBase + 64) where !used.contains(candidate) {
            return candidate
        }
        return nil
    }

    private func startListener(_ forward: Forward) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: forward.listen),
              let listener = try? NWListener(using: params, on: port) else {
            lastError = String(localized: "端口 \(String(forward.listen)) 监听失败")
            return
        }
        listeners[forward.id] = listener
        let token = RemoteAccessServer.shared.token
        let target = forward.target
        let bag = connections
        listener.newConnectionHandler = { connection in
            let proxy = RemoteProxyConnection(client: connection, targetPort: target,
                                              token: token) { done in
                bag.remove(done)
            }
            bag.add(proxy)
            proxy.start()
        }
        listener.start(queue: RemoteAccessServer.netQueue)
    }

    // MARK: - 持久化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let saved = try? JSONDecoder().decode([Forward].self, from: data) else { return }
        forwards = saved
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(forwards) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    final class ConnectionBag: @unchecked Sendable {
        private var conns: [ObjectIdentifier: RemoteProxyConnection] = [:]

        func add(_ conn: RemoteProxyConnection) {
            RemoteAccessServer.netQueue.async { self.conns[ObjectIdentifier(conn)] = conn }
        }

        func remove(_ conn: RemoteProxyConnection) {
            RemoteAccessServer.netQueue.async { self.conns[ObjectIdentifier(conn)] = nil }
        }

        func cancelAll() {
            RemoteAccessServer.netQueue.async {
                let open = self.conns.values
                self.conns = [:]
                for conn in open { conn.cancel() }
            }
        }
    }
}

/// 一条被代理的连接:验完 token 就退化成纯字节对拼(所以 WS / SSE / 长连接都不用特判)。
/// 鉴权只看第一个请求头 —— 之后浏览器带的是 cookie,子资源(app.js 之类)不会再带 ?t=
final class RemoteProxyConnection: @unchecked Sendable {
    private let client: NWConnection
    private let targetPort: UInt16
    private let token: String
    private let onClosed: (RemoteProxyConnection) -> Void

    private var upstream: NWConnection?
    private var buffer = Data()
    private var closed = false

    private static let cookieName = "termite_fwd"
    private static let maxHead = 64 * 1024

    init(client: NWConnection, targetPort: UInt16, token: String,
         onClosed: @escaping (RemoteProxyConnection) -> Void) {
        self.client = client
        self.targetPort = targetPort
        self.token = token
        self.onClosed = onClosed
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.cancel() }
            if case .cancelled = state { self?.cancel() }
        }
        client.start(queue: RemoteAccessServer.netQueue)
        readHead()
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        client.cancel()
        upstream?.cancel()
        onClosed(self)
    }

    // MARK: - 鉴权

    private func readHead() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            if error != nil || isComplete { self.cancel(); return }
            if let range = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = Data(self.buffer[..<range.upperBound])
                let leftover = Data(self.buffer[range.upperBound...])
                self.buffer = Data()
                self.handle(head: head, leftover: leftover)
            } else if self.buffer.count > Self.maxHead {
                self.cancel()
            } else {
                self.readHead()
            }
        }
    }

    private func handle(head: Data, leftover: Data) {
        guard let text = String(data: head, encoding: .utf8) else { cancel(); return }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        let target = requestLine.components(separatedBy: " ").dropFirst().first ?? "/"

        // ?t=token 来自手机点开的链接;cookie 供之后的子资源与 WS 升级用
        let queryToken = Self.queryValue("t", in: target)
        let cookieToken = Self.cookieValue(Self.cookieName, in: lines)
        let authed = [queryToken, cookieToken].contains {
            guard let value = $0 else { return false }
            return RemoteAccessServer.tokensMatch(value, token)
        }
        guard authed else {
            send("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        // 带着 ?t= 进来的第一跳:种 cookie 后跳到干净地址,免得 token 留在地址栏和 referer 里
        if queryToken != nil, cookieToken == nil {
            let clean = Self.stripToken(from: target)
            var response = "HTTP/1.1 302 Found\r\n"
            response += "Location: \(clean)\r\n"
            response += "Set-Cookie: \(Self.cookieName)=\(token); Path=/; HttpOnly; SameSite=Lax\r\n"
            response += "Content-Length: 0\r\nConnection: close\r\n\r\n"
            send(response)
            return
        }
        connectUpstream(head: head, leftover: leftover)
    }

    private func send(_ response: String) {
        client.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            self?.cancel()
        })
    }

    /// 目标服务没起来:回一句人话,别让手机上白转圈。
    /// Content-Length 按字节算 —— 中文一个字三字节,写死数字必错
    private func sendGatewayError() {
        // 端口号插值必须先转成 String:插 Int 会走数字格式化,8099 被写成「8,099」
        let body = Data(String(localized: "本机 \(String(targetPort)) 端口上没有服务在跑").utf8)
        var head = "HTTP/1.1 502 Bad Gateway\r\n"
        head += "Content-Type: text/plain; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        client.send(content: out, completion: .contentProcessed { [weak self] _ in
            self?.cancel()
        })
    }

    // MARK: - 对拼

    private func connectUpstream(head: Data, leftover: Data) {
        guard let port = NWEndpoint.Port(rawValue: targetPort) else { cancel(); return }
        let upstream = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        self.upstream = upstream
        upstream.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                var initial = head
                initial.append(leftover)
                upstream.send(content: initial, completion: .idempotent)
                self.pump(from: upstream, to: self.client)
                self.pump(from: self.client, to: upstream)
            // 连不上时 NWConnection 先进 .waiting(ECONNREFUSED 会一直重试),不是 .failed
            case .failed, .cancelled, .waiting:
                self.sendGatewayError()
            default:
                break
            }
        }
        upstream.start(queue: RemoteAccessServer.netQueue)
    }

    private func pump(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                sink.send(content: data, completion: .idempotent)
            }
            if error != nil || isComplete { self.cancel(); return }
            self.pump(from: source, to: sink)
        }
    }

    // MARK: - 解析小工具

    private static func queryValue(_ key: String, in target: String) -> String? {
        guard let qIndex = target.firstIndex(of: "?") else { return nil }
        for pair in target[target.index(after: qIndex)...].components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2, kv[0] == key { return kv[1] }
        }
        return nil
    }

    private static func cookieValue(_ name: String, in lines: [String]) -> String? {
        guard let header = lines.first(where: { $0.lowercased().hasPrefix("cookie:") }) else { return nil }
        let body = header.dropFirst("cookie:".count)
        for pair in body.components(separatedBy: ";") {
            let kv = pair.trimmingCharacters(in: .whitespaces).components(separatedBy: "=")
            if kv.count == 2, kv[0] == name { return kv[1] }
        }
        return nil
    }

    /// 去掉 ?t=,其余查询参数原样保留
    private static func stripToken(from target: String) -> String {
        guard let qIndex = target.firstIndex(of: "?") else { return target }
        let path = String(target[..<qIndex])
        let kept = target[target.index(after: qIndex)...]
            .components(separatedBy: "&")
            .filter { !$0.hasPrefix("t=") }
        return kept.isEmpty ? (path.isEmpty ? "/" : path) : path + "?" + kept.joined(separator: "&")
    }
}
