import CryptoKit
import Darwin
import Foundation
import Network
import Observation

private extension Int {
    /// 设置里存的端口可能是 0(没设过)或越界值,回落到默认端口
    var clampedPort: Int {
        (1024...65535).contains(self) ? self : Int(RemoteAccessServer.defaultPort)
    }
}

/// 远程访问服务:app 内置 HTTP + WebSocket 服务器,手机/iPad 浏览器访问。
/// 定位是 LAN / Tailscale 内网使用:token 鉴权,不做公网穿透;
/// 会话数据面走 RemoteSessionHub(app 是守护进程唯一客户端,远端全部经 app 中转)。
@MainActor
@Observable
final class RemoteAccessServer {
    static let shared = RemoteAccessServer()

    static let defaultPort: UInt16 = 9280

    /// 网络回调统一落在这个串行队列;主线程只做 hub 交互与 UI 状态
    nonisolated static let netQueue = DispatchQueue(label: "remote.net")

    private(set) var isRunning = false
    private(set) var lastError: String?

    private var listener: SocketListener?
    /// Bonjour 广播独立于监听:BSD socket 自己不发布服务
    private var bonjour: NetService?
    /// 打开中的连接(netQueue 专属,强引用防释放)
    private let connectionBag = ConnectionBag()

    /// Bonjour 广播:手机在同一局域网里自动发现这台 Mac(不含 token,广播是明文的)
    nonisolated static let serviceType = "_termite._tcp"
    nonisolated static var serviceName: String { Host.current().localizedName ?? "Termite" }

    /// 一次性配对码的仲裁者。跨线程(HTTP 在 netQueue,设置页在主线程),用锁保。
    let pairing = PairingBroker()

    /// 配对码:6 位数字、5 分钟有效、验一次即作废、错 5 次直接废掉。
    /// 广播只带主机名和端口,token 必须靠这道码换 —— 同网段谁都收得到广播
    final class PairingBroker: @unchecked Sendable {
        private let lock = NSLock()
        private var code: String?
        private var token: String?
        private var expiresAt = Date.distantPast
        private var attempts = 0

        static let ttl: TimeInterval = 300
        private static let maxAttempts = 5

        /// 当前有效的码(设置页展示用)
        var current: (code: String, expiresAt: Date)? {
            lock.lock(); defer { lock.unlock() }
            guard let code, expiresAt > Date() else { return nil }
            return (code, expiresAt)
        }

        func issue(token: String) -> String {
            var bytes = [UInt8](repeating: 0, count: 6)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            let fresh = String(bytes.map { Character(String($0 % 10)) })
            lock.lock()
            code = fresh
            self.token = token
            expiresAt = Date().addingTimeInterval(Self.ttl)
            attempts = 0
            lock.unlock()
            return fresh
        }

        func cancel() {
            lock.lock()
            code = nil; token = nil; attempts = 0; expiresAt = .distantPast
            lock.unlock()
        }

        /// 验码换 token。成功即作废(一码一次),错够次数也作废
        func redeem(_ input: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            guard let code, let token, expiresAt > Date() else { return nil }
            guard RemoteAccessServer.tokensMatch(input, code) else {
                attempts += 1
                if attempts >= Self.maxAttempts {
                    self.code = nil; self.token = nil; expiresAt = .distantPast
                }
                return nil
            }
            self.code = nil
            self.token = nil
            expiresAt = .distantPast
            return token
        }
    }

    /// netQueue 上维护的连接注册表
    final class ConnectionBag: @unchecked Sendable {
        private var conns: [ObjectIdentifier: RemoteHTTPConnection] = [:]

        func add(_ conn: RemoteHTTPConnection) {
            RemoteAccessServer.netQueue.async { self.conns[ObjectIdentifier(conn)] = conn }
        }

        func remove(_ conn: RemoteHTTPConnection) {
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

    // MARK: - 配置

    var port: UInt16 {
        let stored = UserDefaults.standard.integer(forKey: SettingsKeys.remoteAccessPort)
        return (1024...65535).contains(stored) ? UInt16(stored) : Self.defaultPort
    }

    /// 首次取用时生成;设置页可重新生成(旧链接立即失效)
    var token: String {
        if let existing = UserDefaults.standard.string(forKey: SettingsKeys.remoteAccessToken),
           !existing.isEmpty {
            return existing
        }
        let fresh = Self.makeToken()
        UserDefaults.standard.set(fresh, forKey: SettingsKeys.remoteAccessToken)
        return fresh
    }

    func regenerateToken() {
        UserDefaults.standard.set(Self.makeToken(), forKey: SettingsKeys.remoteAccessToken)
        // 在途的配对码换的是旧 token,一起作废
        pairing.cancel()
    }

    /// 设置页点「生成配对码」:手机发现这台 Mac 后输这 6 位就能拿到 token
    @discardableResult
    func issuePairingCode() -> String {
        pairing.issue(token: token)
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789") // 去掉易混字符
        return String(bytes.prefix(16).map { alphabet[Int($0) % alphabet.count] })
    }

    // MARK: - 生命周期

    /// app 启动时调用:开关开着就把服务拉起来
    func startIfEnabled() {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.remoteAccessEnabled) else { return }
        start()
    }

    func start() {
        guard listener == nil else { return }
        lastError = nil
        let expectedToken = token
        let broker = pairing
        let bag = connectionBag
        guard let listener = try? SocketListener(port: port, queue: Self.netQueue,
                                                 onAccept: { connection in
            let http = RemoteHTTPConnection(connection: connection, token: expectedToken,
                                            pairing: broker) { conn in
                bag.remove(conn)
            }
            bag.add(http)
            http.start()
        }) else {
            lastError = String(localized: "端口 \(Int(port)) 监听失败")
            return
        }
        self.listener = listener
        isRunning = true
        // 广播只暴露「这台 Mac 上有 Termite」和端口,不含 token
        let service = NetService(domain: "local.", type: "\(Self.serviceType).",
                                 name: Self.serviceName, port: Int32(port))
        service.publish()
        bonjour = service
        RemoteSessionHub.shared.start()
        RemoteForwarder.shared.startAll()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        bonjour?.stop()
        bonjour = nil
        isRunning = false
        pairing.cancel()
        RemoteForwarder.shared.stopAll()
        RemoteSessionHub.shared.stop()
        connectionBag.cancelAll()
    }

    // MARK: - 地址展示(设置页)

    struct AccessAddress: Identifiable {
        var id: String { ip }
        var label: String
        var ip: String
    }

    /// 本机可访问地址:en*(Wi-Fi/网线)优先,其次 Tailscale(CGNAT 100.64/10),忽略回环
    nonisolated static func lanAddresses() -> [AccessAddress] {
        var result: [AccessAddress] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
                  (Int32(ifa.ifa_flags) & IFF_UP) != 0,
                  (Int32(ifa.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let name = String(cString: ifa.ifa_name)
            if ip.hasPrefix("169.254.") { continue } // link-local 无意义
            let isTailscale = ip.hasPrefix("100.") // CGNAT 段,Tailscale 惯用
            let label: String
            if isTailscale {
                label = "Tailscale"
            } else if name.hasPrefix("en") {
                label = String(localized: "局域网")
            } else {
                continue // 其余 utun/bridge 一般不可达,别把列表弄花
            }
            result.append(AccessAddress(label: label, ip: ip))
        }
        // 局域网在前,Tailscale 其次;同类按接口出现顺序
        return result.sorted { a, b in
            let rank = { (addr: AccessAddress) in addr.label == "Tailscale" ? 1 : 0 }
            return rank(a) < rank(b)
        }
    }

    func accessURL(ip: String) -> String {
        "http://\(ip):\(port)/?t=\(token)"
    }

    // MARK: - 工具

    /// 常量时间比较,避免 token 逐字节试探
    nonisolated static func tokensMatch(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count, !ab.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }
}

// MARK: - 单条 HTTP 连接

/// 一次 HTTP 交换(静态文件)或升级为 WebSocket 长连接。
/// 生命周期全程在 RemoteAccessServer.netQueue 上。
final class RemoteHTTPConnection: @unchecked Sendable {
    private let connection: SocketConnection
    private let token: String
    private let onClosed: (RemoteHTTPConnection) -> Void
    private var buffer = Data()
    private var websocket: RemoteWebSocketSession?
    private var closed = false

    /// 静态文件白名单:路径 → (bundle 内相对路径, MIME)。不做通用文件服务,杜绝路径穿越
    private static let staticFiles: [String: (subpath: String, mime: String)] = [
        "/": ("index.html", "text/html; charset=utf-8"),
        "/index.html": ("index.html", "text/html; charset=utf-8"),
        "/app.js": ("app.js", "application/javascript; charset=utf-8"),
        "/style.css": ("style.css", "text/css; charset=utf-8"),
        "/vendor/xterm.min.js": ("vendor/xterm.min.js", "application/javascript; charset=utf-8"),
        "/vendor/xterm.min.css": ("vendor/xterm.min.css", "text/css; charset=utf-8"),
    ]

    private let pairing: RemoteAccessServer.PairingBroker

    init(connection: SocketConnection, token: String,
         pairing: RemoteAccessServer.PairingBroker,
         onClosed: @escaping (RemoteHTTPConnection) -> Void) {
        self.connection = connection
        self.token = token
        self.pairing = pairing
        self.onClosed = onClosed
    }

    func start() {
        connection.onFailure = { [weak self] in self?.cancel() }
        connection.start()
        receiveHead()
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        websocket?.teardown()
        websocket = nil
        connection.cancel()
        onClosed(self)
    }

    // MARK: - 请求头接收与路由

    private func receiveHead() {
        connection.receive(maximumLength: 64 * 1024) { [weak self] data, isComplete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            if error != nil || (isComplete && data == nil) {
                self.cancel()
                return
            }
            if let headEnd = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = self.buffer[..<headEnd.lowerBound]
                let leftover = Data(self.buffer[headEnd.upperBound...])
                self.buffer = Data()
                self.route(head: head, leftover: leftover)
            } else if self.buffer.count > 64 * 1024 {
                self.cancel() // 头都超 64K,不是正经浏览器
            } else {
                self.receiveHead()
            }
        }
    }

    private func route(head: Data, leftover: Data) {
        guard let headText = String(data: head, encoding: .utf8) else {
            cancel()
            return
        }
        let lines = headText.components(separatedBy: "\r\n")
        let request = lines[0].components(separatedBy: " ")
        guard request.count >= 2, request[0] == "GET" else {
            sendSimple(status: "405 Method Not Allowed")
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = request[1]
        let path = target.components(separatedBy: "?")[0]
        let query = queryItems(of: target)

        if path == "/pair" {
            servePairing(code: query["code"])
        } else if path == "/ws" {
            upgradeToWebSocket(headers: headers, query: query, leftover: leftover)
        } else if let file = Self.staticFiles[path] {
            serveStatic(file)
        } else {
            sendSimple(status: "404 Not Found")
        }
    }

    private func queryItems(of target: String) -> [String: String] {
        guard let qIndex = target.firstIndex(of: "?") else { return [:] }
        var items: [String: String] = [:]
        for pair in target[target.index(after: qIndex)...].components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            guard kv.count == 2 else { continue }
            items[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
        }
        return items
    }

    // MARK: - 配对(唯一不带 token 的端点)

    /// GET /pair?code=123456 → {"token":..,"name":..,"port":..}
    /// 码是一次性且限次的,所以这里不需要额外限流;错码一律 403、不区分「码不对」和「没有码」
    private func servePairing(code: String?) {
        guard let code, let granted = pairing.redeem(code) else {
            sendSimple(status: "403 Forbidden")
            return
        }
        // 带上本机 IPv4 地址:Bonjour 解析出来的往往是链路本地 IPv6(fe80::…),
        // 它离了 %en0 区域标识就不可路由,带着又会随网络变化失效。
        // 让手机存这里给的 IPv4 才稳
        let addresses = RemoteAccessServer.lanAddresses().map {
            ["label": $0.label, "ip": $0.ip]
        }
        let payload: [String: Any] = [
            "token": granted,
            "name": RemoteAccessServer.serviceName,
            "port": Int(UserDefaults.standard.integer(forKey: SettingsKeys.remoteAccessPort)
                        .clampedPort),
            "addresses": addresses,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            sendSimple(status: "500 Internal Server Error")
            return
        }
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: application/json; charset=utf-8\r\n"
        response += "Content-Length: \(data.count)\r\n"
        response += "Cache-Control: no-store\r\n"
        response += "Connection: close\r\n\r\n"
        var out = Data(response.utf8)
        out.append(data)
        connection.send(out, isFinal: true) { [weak self] _ in
            self?.cancel()
        }
    }

    // MARK: - 静态文件

    private func serveStatic(_ file: (subpath: String, mime: String)) {
        guard let base = Bundle.main.resourceURL?.appendingPathComponent("RemoteWeb"),
              let data = try? Data(contentsOf: base.appendingPathComponent(file.subpath)) else {
            sendSimple(status: "404 Not Found")
            return
        }
        // vendor 内容不变可缓存;页面与 app.js 每次取新,改版即生效
        let cache = file.subpath.hasPrefix("vendor/") ? "max-age=86400" : "no-cache"
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: \(file.mime)\r\n"
        response += "Content-Length: \(data.count)\r\n"
        response += "Cache-Control: \(cache)\r\n"
        response += "Connection: close\r\n\r\n"
        var payload = Data(response.utf8)
        payload.append(data)
        connection.send(payload, isFinal: true) { [weak self] _ in
            self?.cancel()
        }
    }

    private func sendSimple(status: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(Data(response.utf8), isFinal: true) { [weak self] _ in
            self?.cancel()
        }
    }

    // MARK: - WebSocket 升级

    private func upgradeToWebSocket(headers: [String: String], query: [String: String], leftover: Data) {
        guard RemoteAccessServer.tokensMatch(query["t"] ?? "", token) else {
            sendSimple(status: "403 Forbidden")
            return
        }
        guard headers["upgrade"]?.lowercased() == "websocket",
              let key = headers["sec-websocket-key"] else {
            sendSimple(status: "400 Bad Request")
            return
        }
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let accept = Data(Insecure.SHA1.hash(data: Data(magic.utf8))).base64EncodedString()
        var response = "HTTP/1.1 101 Switching Protocols\r\n"
        response += "Upgrade: websocket\r\n"
        response += "Connection: Upgrade\r\n"
        response += "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.send(Data(response.utf8)) { [weak self] error in
            guard let self, error == nil else {
                self?.cancel()
                return
            }
            let ws = RemoteWebSocketSession(connection: self.connection) { [weak self] in
                self?.cancel()
            }
            self.websocket = ws
            ws.start(initialBuffer: leftover)
        }
    }
}
