import Foundation
import Network
import Observation
import os

/// 局域网自动发现:浏览 Mac 端广播的 _termite._tcp,配对页直接列出附近的 Mac。
///
/// 广播里只有机器名和端口 —— token 绝不上广播(同网段谁都收得到),
/// 所以选中一台之后还要输 Mac 设置页上的 6 位配对码,凭码走 /pair 换 token。
///
/// 只覆盖同一局域网:tailnet 没有组播,mDNS 过不去。异地用不着发现,
/// 配对是一次性的,token 进 Keychain 后直接连 tailnet 地址。
@MainActor
@Observable
final class LanDiscovery {
    struct Found: Identifiable, Hashable {
        /// Bonjour 服务名(= Mac 的机器名),同一台机器名字稳定,拿来做 id
        var id: String { name }
        let name: String
        let endpoint: NWEndpoint
    }

    private(set) var macs: [Found] = []
    private(set) var browsing = false

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: RemotePairing.serviceType, domain: nil),
                                using: params)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.browsing = true
                case .failed, .cancelled:
                    self?.browsing = false
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Found? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return Found(name: name, endpoint: result.endpoint)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor in self?.macs = found }
        }
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        browsing = false
        macs = []
    }
}

/// 凭配对码换 token:直接对 Bonjour 端点开 NWConnection 说 HTTP,
/// 免去先把服务解析成 IP 再拼 URL(URLSession 不吃 .service 端点)。
/// 顺带从连接的实际路径里取回 IP —— 那才是真正走得通的地址,存下来供以后直连。
enum RemotePairing {
    static let serviceType = "_termite._tcp"

    struct Granted {
        let host: String
        let port: UInt16
        let token: String
        let name: String
    }

    enum Failure: Error {
        case unreachable
        case rejected      // 码不对 / 过期 / 已用掉
        case malformed
    }

    static func redeem(code: String, at endpoint: NWEndpoint) async throws -> Granted {
        let connection = NWConnection(to: endpoint, using: .tcp)
        defer { connection.cancel() }
        try await connection.waitUntilReady()

        let request = "GET /pair?code=\(code) HTTP/1.1\r\nHost: termite\r\nConnection: close\r\n\r\n"
        try await connection.send(Data(request.utf8))
        let response = try await connection.readUntilClose()

        guard let text = String(data: response, encoding: .utf8),
              let headEnd = text.range(of: "\r\n\r\n") else {
            throw Failure.malformed
        }
        let status = text.components(separatedBy: "\r\n").first ?? ""
        guard status.contains(" 200 ") else { throw Failure.rejected }
        let body = Data(text[headEnd.upperBound...].utf8)
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let token = json["token"] as? String, !token.isEmpty else {
            throw Failure.malformed
        }
        let name = json["name"] as? String ?? ""
        let port = UInt16(json["port"] as? Int ?? 9280)
        // 优先用 Mac 自报的 IPv4:Bonjour 解析到的多半是链路本地 IPv6(fe80::…),
        // 少了 %en0 区域标识不可路由、带着又随网络变化失效 —— 存进去就是永远「连接中」。
        // 局域网地址排在 Tailscale 前面(lanAddresses 已按此排序),都没有才回落到解析地址
        let advertised = (json["addresses"] as? [[String: Any]] ?? [])
            .compactMap { $0["ip"] as? String }
            .first { $0.contains(".") }
        guard let host = advertised ?? connection.resolvedHost else { throw Failure.malformed }
        return Granted(host: host, port: port, token: token,
                       name: name.isEmpty ? host : name)
    }
}

private extension NWConnection {
    /// 连接解析后的对端 IP(去掉 IPv6 的 %en0 之类接口后缀)
    var resolvedHost: String? {
        guard case let .hostPort(host, _)? = currentPath?.remoteEndpoint else { return nil }
        let text: String?
        switch host {
        case .ipv4(let address): text = "\(address)"
        case .ipv6(let address): text = "\(address)"
        case .name(let name, _): text = name
        @unknown default: text = nil
        }
        return text?.components(separatedBy: "%").first
    }

    func waitUntilReady(timeout: TimeInterval = 6) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    let resumed = OSAllocatedUnfairLock(initialState: false)
                    let finish: (Result<Void, Error>) -> Void = { result in
                        let alreadyResumed = resumed.withLock { done -> Bool in
                            defer { done = true }
                            return done
                        }
                        guard !alreadyResumed else { return }
                        continuation.resume(with: result)
                    }
                    self.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            finish(.success(()))
                        case .failed, .cancelled:
                            finish(.failure(RemotePairing.Failure.unreachable))
                        default:
                            break
                        }
                    }
                    self.start(queue: .global(qos: .userInitiated))
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw RemotePairing.Failure.unreachable
            }
            try await group.next()
            group.cancelAll()
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// 读到对端关闭为止(服务端回完 /pair 就 close,响应很小)
    func readUntilClose(limit: Int = 64 * 1024) async throws -> Data {
        var buffer = Data()
        while buffer.count < limit {
            let (chunk, done) = try await receiveOnce()
            if let chunk { buffer.append(chunk) }
            if done { break }
        }
        return buffer
    }

    private func receiveOnce() async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }
}
