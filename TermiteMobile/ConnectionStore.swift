import Foundation
import Observation

/// 一台已配对的 Mac(token 单独存 Keychain,这里只有连接坐标)
struct SavedMac: Identifiable, Codable, Equatable {
    let id: UUID
    /// 显示名,默认取 host,可改
    var name: String
    var host: String
    var port: UInt16
}

/// 连接端点(host + port + token),配对链接解析产物
struct Endpoint: Equatable {
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

    /// 接受完整链接(http://192.168.1.8:9280/?t=xxx)、裸 host[:port]?t=xxx,
    /// 以及 termite://pair?host=..&port=..&t=..(URL scheme 一键配对)
    static func parse(_ text: String) -> Endpoint? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "http://" + trimmed }
        guard let comps = URLComponents(string: trimmed) else { return nil }
        if comps.scheme == "termite" {
            guard let items = comps.queryItems,
                  let host = items.first(where: { $0.name == "host" })?.value, !host.isEmpty,
                  let token = items.first(where: { $0.name == "t" })?.value, !token.isEmpty else {
                return nil
            }
            let port = items.first(where: { $0.name == "port" })?.value.flatMap { UInt16($0) } ?? 9280
            return Endpoint(host: host, port: port, token: token)
        }
        guard let host = comps.host, !host.isEmpty,
              let token = comps.queryItems?.first(where: { $0.name == "t" })?.value, !token.isEmpty else {
            return nil
        }
        let port = UInt16(comps.port ?? 9280)
        return Endpoint(host: host, port: port, token: token)
    }
}

/// 多 Mac 配对管理:列表 + 当前选中;token 进出 Keychain。
@MainActor
@Observable
final class ConnectionStore {
    private static let listKey = "macs"
    private static let selectedKey = "selectedMac"
    private static let legacyKey = "endpoint"

    private(set) var macs: [SavedMac] = []
    var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: Self.selectedKey) }
    }

    var selected: SavedMac? {
        macs.first { $0.id == selectedID } ?? macs.first
    }

    init() {
        load()
        migrateLegacyIfNeeded()
    }

    func endpoint(for mac: SavedMac) -> Endpoint? {
        guard let token = KeychainStore.token(for: mac.id) else { return nil }
        return Endpoint(host: mac.host, port: mac.port, token: token)
    }

    /// 配对新 Mac;同 host:port 已存在则视为「重新配对」,只换 token
    @discardableResult
    func adopt(_ endpoint: Endpoint) -> SavedMac {
        if let existing = macs.first(where: { $0.host == endpoint.host && $0.port == endpoint.port }) {
            KeychainStore.setToken(endpoint.token, for: existing.id)
            selectedID = existing.id
            return existing
        }
        let mac = SavedMac(id: UUID(), name: endpoint.host, host: endpoint.host, port: endpoint.port)
        KeychainStore.setToken(endpoint.token, for: mac.id)
        macs.append(mac)
        selectedID = mac.id
        persist()
        return mac
    }

    func rename(_ mac: SavedMac, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = macs.firstIndex(where: { $0.id == mac.id }) else { return }
        macs[index].name = trimmed
        persist()
    }

    func remove(_ mac: SavedMac) {
        KeychainStore.removeToken(for: mac.id)
        UserDefaults.standard.removeObject(forKey: MobileSettingsKeys.lastSessionPrefix + mac.id.uuidString)
        macs.removeAll { $0.id == mac.id }
        if selectedID == mac.id { selectedID = macs.first?.id }
        persist()
    }

    // MARK: - 上次会话(按 Mac 记)

    func lastSession(of mac: SavedMac) -> UUID? {
        UserDefaults.standard.string(forKey: MobileSettingsKeys.lastSessionPrefix + mac.id.uuidString)
            .flatMap(UUID.init)
    }

    func rememberSession(_ sessionID: UUID?, of mac: SavedMac) {
        let key = MobileSettingsKeys.lastSessionPrefix + mac.id.uuidString
        if let sessionID {
            UserDefaults.standard.set(sessionID.uuidString, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - 持久化

    private func persist() {
        if let data = try? JSONEncoder().encode(macs) {
            UserDefaults.standard.set(data, forKey: Self.listKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.listKey),
           let saved = try? JSONDecoder().decode([SavedMac].self, from: data) {
            macs = saved
        }
        selectedID = UserDefaults.standard.string(forKey: Self.selectedKey).flatMap(UUID.init)
            ?? macs.first?.id
    }

    /// v1 单端点(token 曾明文在 UserDefaults)→ v2 列表 + Keychain,迁完即清
    private func migrateLegacyIfNeeded() {
        guard macs.isEmpty,
              let data = UserDefaults.standard.data(forKey: Self.legacyKey) else { return }
        struct LegacyEndpoint: Codable {
            var host: String
            var port: UInt16
            var token: String
        }
        if let legacy = try? JSONDecoder().decode(LegacyEndpoint.self, from: data) {
            adopt(Endpoint(host: legacy.host, port: legacy.port, token: legacy.token))
        }
        UserDefaults.standard.removeObject(forKey: Self.legacyKey)
    }
}
