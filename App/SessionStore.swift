import Foundation
import Security

struct Session: Codable {
    let client: String
    let subject: String
    let email: String
    let accessToken: String
    let refreshToken: String?
    let expires: Date
}

enum Failure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

enum SessionStore {

    static let service = "Interpreter.ChatGPT"
    static func query() throws -> [String: Any] {
        // App-private Keychain: no App Group or shared Safari session required.
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "session"]
    }
    static func load() throws -> Session? {
        var q = try query(); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw Failure.message("Нет доступа к защищённой сессии. Проверь подпись Interpreter (\(status)).")
        }
        return try JSONDecoder().decode(Session.self, from: data)
    }
    static func save(_ session: Session) throws {
        let data = try JSONEncoder().encode(session)
        let status = SecItemUpdate(try query() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = try query(); q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(q as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.message("Не удалось сохранить сессию (\(added)).") }
        } else if status != errSecSuccess { throw Failure.message("Не удалось обновить сессию (\(status)).") }
    }
    static func clear() throws {
        let status = SecItemDelete(try query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.message("Ошибка удаления сессии (\(status)).") }
    }
    static func defaults() throws -> UserDefaults {
        return UserDefaults.standard
    }
    static func host() throws -> String {
        let d = try defaults()
        if let host = d.string(forKey: "host") { return host }
        let host = "urn:uuid:" + UUID().uuidString.lowercased(); d.set(host, forKey: "host"); return host
    }
}

