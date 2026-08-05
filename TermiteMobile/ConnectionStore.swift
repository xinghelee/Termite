import Foundation
import Observation

/// 与 Mac 端 Termite 的配对信息(扫码/粘贴链接获得)
struct Endpoint: Codable, Equatable {
    var host: String
    var port: UInt16
    var token: String

    /// IPv6 字面量要加方括号(Tailscale/局域网基本是 IPv4,兜底而已)
    private var urlHost: String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    var wsURL: URL? {
        URL(string: "ws://\(urlHost):\(port)/ws?t=\(token)")
    }

    var displayName: String { "\(host):\(port)" }

    /// 接受完整链接(http://192.168.1.8:9280/?t=xxx)或裸 host[:port]?t=xxx
    static func parse(_ text: String) -> Endpoint? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        guard let comps = URLComponents(string: trimmed), let host = comps.host, !host.isEmpty,
              let token = comps.queryItems?.first(where: { $0.name == "t" })?.value, !token.isEmpty else {
            return nil
        }
        let port = UInt16(comps.port ?? 9280)
        return Endpoint(host: host, port: port, token: token)
    }
}

/// 配对信息持久化(单 Mac;要连第二台就重新扫码)
@MainActor
@Observable
final class ConnectionStore {
    private static let key = "endpoint"

    var endpoint: Endpoint? {
        didSet { persist() }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(Endpoint.self, from: data) {
            endpoint = saved
        }
    }

    private func persist() {
        if let endpoint, let data = try? JSONEncoder().encode(endpoint) {
            UserDefaults.standard.set(data, forKey: Self.key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }
}
