import CryptoKit
import Darwin
import Foundation
import Network
import Observation

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

    private var listener: NWListener?
    /// 打开中的连接(netQueue 专属,强引用防释放)
    private let connectionBag = ConnectionBag()

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
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: params, on: nwPort) else {
            lastError = String(localized: "端口 \(Int(port)) 监听失败")
            return
        }
        self.listener = listener
        let expectedToken = token
        RemoteSessionHub.shared.start()

        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                    case .failed(let error):
                        self.lastError = String(localized: "监听失败:\(error.localizedDescription)")
                        self.stop()
                    default:
                        break
                    }
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let bag = self.connectionBag
            let http = RemoteHTTPConnection(connection: connection, token: expectedToken) { conn in
                bag.remove(conn)
            }
            bag.add(http)
            http.start()
        }
        listener.start(queue: Self.netQueue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
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
    private let connection: NWConnection
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

    init(connection: NWConnection, token: String, onClosed: @escaping (RemoteHTTPConnection) -> Void) {
        self.connection = connection
        self.token = token
        self.onClosed = onClosed
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.cancel() }
        }
        connection.start(queue: RemoteAccessServer.netQueue)
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
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

        if path == "/ws" {
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
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.cancel()
        })
    }

    private func sendSimple(status: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            self?.cancel()
        })
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
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                self?.cancel()
                return
            }
            let ws = RemoteWebSocketSession(connection: self.connection) { [weak self] in
                self?.cancel()
            }
            self.websocket = ws
            ws.start(initialBuffer: leftover)
        })
    }
}
