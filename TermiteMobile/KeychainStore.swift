import Foundation
import Security

/// 访问密钥的 Keychain 存取(按 Mac id 一条一密)。
/// token 等于 Mac 终端的钥匙,不落 UserDefaults 明文——上架产品的底线。
enum KeychainStore {
    private static let service = "com.termite.mobile.token"

    static func token(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String, for id: UUID) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        let payload = Data(token.utf8)
        let update = [kSecValueData as String: payload]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        guard status != errSecSuccess else { return }
        var add = base
        add[kSecValueData as String] = payload
        // 本机专用凭据:不进 iCloud 同步,解锁后可用
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func removeToken(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
