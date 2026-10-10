import Foundation
import Security

enum RealtimeKeyStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Interpreter.RealtimeAPI",
         kSecAttrAccount as String: "personal-key"]
    }
    static func load() throws -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw Failure.message("Не удалось прочитать защищённый API-ключ. Проверь подпись приложения.")
        }
        return key
    }
    static func save(_ input: String) throws {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), key.count > 20, !key.contains(where: { $0.isWhitespace }) else {
            throw Failure.message("Вставь полный секретный API-ключ OpenAI.")
        }
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw Failure.message("Не удалось сохранить API-ключ.") }
        } else if status != errSecSuccess { throw Failure.message("Не удалось обновить API-ключ.") }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.message("Не удалось удалить API-ключ.") }
    }
}
