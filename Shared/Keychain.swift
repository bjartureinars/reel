import Foundation
import Security

/// Minimal Keychain wrapper for the server password and access tokens.
enum Keychain {
    private static let service = "com.bjartur.reel"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

enum DeviceIdentity {
    /// Stable per-install identifier Jellyfin uses to tell devices apart.
    static var id: String {
        if let existing = UserDefaults.standard.string(forKey: "reel.deviceId") { return existing }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: "reel.deviceId")
        return new
    }
}
