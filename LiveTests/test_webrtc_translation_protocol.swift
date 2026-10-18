import Foundation

@main struct WebRTCTranslationProtocolTests {
    static func expect(_ condition: Bool, _ label: String) {
        if !condition { fatalError(label) }
    }

    static func main() throws {
        for lang in ["ru", "de", "en", "ro", "es", "pl"] {
            let payload = try WebRTCTranslationProtocol.sessionJSON(target: lang)
            let parsed = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
            let session = parsed["session"] as! [String: Any]
            expect(session["model"] as? String == "gpt-realtime-translate", "Wrong model")
            let audio = session["audio"] as! [String: Any]
            let output = audio["output"] as! [String: Any]
            expect(output["language"] as? String == lang, "Wrong translation target")
            expect(!String(decoding: payload, as: UTF8.self).contains("api_key"), "Secret in JSON")
        }

        do {
            _ = try WebRTCTranslationProtocol.sessionJSON(target: "unknown")
            fatalError("Unsupported language accepted")
        } catch WebRTCTranslationProtocol.ProtocolError.unsupportedLanguage {}

        expect(try WebRTCTranslationProtocol.shortLivedSecret(
            response: Data(#"{"client_secret":"ek_test"}"#.utf8)
        ) == "ek_test", "String ephemeral secret")
        expect(try WebRTCTranslationProtocol.shortLivedSecret(
            response: Data(#"{"client_secret":{"value":"ek_nested"}}"#.utf8)
        ) == "ek_nested", "Nested ephemeral secret")
        do {
            _ = try WebRTCTranslationProtocol.shortLivedSecret(response: Data("{}".utf8))
            fatalError("Missing secret accepted")
        } catch WebRTCTranslationProtocol.ProtocolError.invalidCredential {}
        expect(try WebRTCTranslationProtocol.answerSDP(response:
            Data("v=0\r\no=- 1 1 IN IP4 127.0.0.1".utf8)).hasPrefix("v=0"), "SDP valid")
        do {
            _ = try WebRTCTranslationProtocol.answerSDP(response: Data("invalid".utf8))
            fatalError("Invalid SDP accepted")
        } catch WebRTCTranslationProtocol.ProtocolError.invalidSDP {}
        print("WebRTC translation handshake and credential tests passed")
    }
}
