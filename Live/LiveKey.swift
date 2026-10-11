import Foundation
import Security

enum LiveKey {
    private static let service = "org.interpreter.live.api"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "openai"]
    }
    static func read() throws -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else { throw KeyError.storage }
        return key
    }
    static func save(_ text: String) throws {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), key.count >= 20,
              !key.contains(where: { $0.isWhitespace }) else { throw KeyError.invalid }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = Data(key.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw KeyError.storage }
        } else if status != errSecSuccess { throw KeyError.storage }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyError.storage }
    }
    enum KeyError: LocalizedError {
        case storage, invalid
        var errorDescription: String? {
            self == .invalid ? "Вставь полный API-ключ OpenAI без пробелов." : "Не удалось открыть защищённое хранилище iPhone."
        }
    }
}
