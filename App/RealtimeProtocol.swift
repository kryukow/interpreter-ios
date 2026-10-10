import Foundation

enum RealtimeProtocol {
    static let endpoint = URL(string: "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate")!
    static let sampleRate = 24000
    static let bytesPerSecond = sampleRate * 2
    static let maximumSeconds = 60

    static func configuration(target: String) throws -> String {
        guard ["ru", "de"].contains(target) else { throw ProtocolError.invalidLanguage }
        return try json(["type": "session.update", "session": ["audio": [
            "input": ["noise_reduction": ["type": "near_field"]],
            "output": ["language": target]
        ]]])
    }
    static func append(_ audio: Data) throws -> String {
        guard !audio.isEmpty, audio.count % 2 == 0 else { throw ProtocolError.invalidAudio }
        return try json(["type": "session.input_audio_buffer.append", "audio": audio.base64EncodedString()])
    }
    static func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    enum ProtocolError: Error { case invalidLanguage, invalidAudio, invalidEvent }
    enum Event {
        case created, updated(String), transcript(String), audio(Data), closed, failure(String), other
    }
    static func event(_ data: Data) throws -> Event {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = value["type"] as? String else { throw ProtocolError.invalidEvent }
        switch type {
        case "session.created": return .created
        case "session.updated":
            guard let session = value["session"] as? [String: Any],
                  session["model"] as? String == "gpt-realtime-translate",
                  let audio = session["audio"] as? [String: Any],
                  let output = audio["output"] as? [String: Any],
                  let language = output["language"] as? String else { throw ProtocolError.invalidEvent }
            return .updated(language)
        case "session.output_transcript.delta":
            guard let delta = value["delta"] as? String else { throw ProtocolError.invalidEvent }
            return .transcript(delta)
        case "session.output_audio.delta":
            guard let encoded = value["delta"] as? String, let pcm = Data(base64Encoded: encoded),
                  !pcm.isEmpty, pcm.count % 2 == 0,
                  (value["sample_rate"] as? Int ?? sampleRate) == sampleRate,
                  (value["channels"] as? Int ?? 1) == 1,
                  (value["format"] as? String ?? "pcm16") == "pcm16" else { throw ProtocolError.invalidAudio }
            return .audio(pcm)
        case "session.closed": return .closed
        case "error":
            let error = value["error"] as? [String: Any]
            // Never display the remote message: it can echo credentials or source audio.
            switch error?["code"] as? String {
            case "invalid_api_key": return .failure("Проверь API-ключ в настройках.")
            case "insufficient_quota": return .failure("Недостаточно кредитов API или достигнут лимит проекта.")
            case "rate_limit_exceeded": return .failure("Достигнут лимит запросов. Попробуй немного позже.")
            case "model_not_found", "permission_denied": return .failure("Модель недоступна этому API-ключу. Проверь доступ проекта.")
            default: return .failure("OpenAI отклонил голосовую сессию. Проверь ключ, доступ к модели и баланс API.")
            }
        default: return .other
        }
    }
    static func wav(_ pcm: Data) throws -> Data {
        guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= 12_000_000 else { throw ProtocolError.invalidAudio }
        var result = Data()
        func label(_ value: String) { result.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { result.append(UInt8(value & 255)); result.append(UInt8(value >> 8)) }
        func u32(_ value: UInt32) { for shift in stride(from: 0, through: 24, by: 8) { result.append(UInt8((value >> shift) & 255)) } }
        label("RIFF"); u32(UInt32(pcm.count + 36)); label("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(bytesPerSecond)); u16(2); u16(16)
        label("data"); u32(UInt32(pcm.count)); result.append(pcm)
        return result
    }
}
