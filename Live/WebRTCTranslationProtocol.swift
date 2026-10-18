import Foundation

/// Pure WebRTC translation handshake building blocks.
/// Kept independent of the WebRTC binary so protocol tests run on CI.
enum WebRTCTranslationProtocol {
    enum ProtocolError: Error {
        case unsupportedLanguage, invalidCredential, invalidSDP
    }
    static let clientSecretsEndpoint = URL(
        string: "https://api.openai.com/v1/realtime/translations/client_secrets"
    )!
    static let callsEndpoint = URL(
        string: "https://api.openai.com/v1/realtime/translations/calls"
    )!

    static func sessionJSON(target: String) throws -> Data {
        guard ["ru", "de", "en", "ro", "es", "pl"].contains(target) else {
            throw ProtocolError.unsupportedLanguage
        }
        return try JSONSerialization.data(withJSONObject: [
            "session": [
                "model": "gpt-realtime-translate",
                "audio": [
                    "input": ["noise_reduction": NSNull(), "transcription": NSNull()],
                    "output": ["language": target]
                ]
            ]
        ])
    }

    static func shortLivedSecret(response: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
        else { throw ProtocolError.invalidCredential }
        let nested = object["client_secret"] as? [String: Any]
        guard let value = (object["client_secret"] as? String)
            ?? (nested?["value"] as? String) ?? (object["value"] as? String),
              !value.isEmpty else { throw ProtocolError.invalidCredential }
        return value
    }

    static func answerSDP(response: Data) throws -> String {
        guard let answer = String(data: response, encoding: .utf8),
              answer.hasPrefix("v=0") else { throw ProtocolError.invalidSDP }
        return answer
    }
}
