import Foundation

enum WireError: LocalizedError {
    case invalidRecording, unsupportedRecording, invalidLanguage, invalidResponse
    case configuration, authorization, quota, rateLimit, connection, timedOut, sending

    var errorDescription: String? {
        switch self {
        case .invalidRecording: return "Запись повреждена или пуста. Запиши фразу ещё раз."
        case .unsupportedRecording: return "Нужна запись PCM16: один канал, 24 кГц, не более 60 секунд."
        case .invalidLanguage: return "Неизвестное направление перевода."
        case .invalidResponse: return "Сервис вернул некорректный ответ."
        case .configuration: return "Сервис не подтвердил модель или язык перевода."
        case .authorization: return "Проверь API-ключ и доступ к модели в настройках."
        case .quota: return "Недостаточно средств API или достигнут лимит проекта."
        case .rateLimit: return "Достигнут лимит запросов. Попробуй позже."
        case .connection: return "Соединение прервалось. Незавершённый ответ не используется."
        case .timedOut: return "Сервис не завершил ответ вовремя. Попробуй позже."
        case .sending: return "Запись не отправлена полностью. Проверь соединение."
        }
    }
}

enum WavePCM {
    static let sampleRate = 24_000
    static let bytesPerSecond = 48_000
    static let maximumInputBytes = bytesPerSecond * 60
    static let maximumOutputBytes = 12_000_000
    static let frameBytes = 9_600

    /// Extract PCM bytes without changing samples, gain, timing, or silence.
    static func decode(_ wav: Data) throws -> Data {
        let bytes = [UInt8](wav)
        guard bytes.count >= 44, label(bytes, 0, "RIFF"), label(bytes, 8, "WAVE"),
              Int(read32(bytes, 4)) + 8 == bytes.count else { throw WireError.invalidRecording }
        var offset = 12
        var formatSeen = false
        var pcm: Data?
        while offset < bytes.count {
            guard bytes.count - offset >= 8 else { throw WireError.invalidRecording }
            let size = Int(read32(bytes, offset + 4))
            let start = offset + 8
            guard size <= bytes.count - start else { throw WireError.invalidRecording }
            if label(bytes, offset, "fmt ") {
                guard !formatSeen, size >= 16 else { throw WireError.invalidRecording }
                guard read16(bytes, start) == 1, read16(bytes, start + 2) == 1,
                      read32(bytes, start + 4) == sampleRate,
                      read32(bytes, start + 8) == bytesPerSecond,
                      read16(bytes, start + 12) == 2, read16(bytes, start + 14) == 16 else {
                    throw WireError.unsupportedRecording
                }
                formatSeen = true
            } else if label(bytes, offset, "data") {
                guard pcm == nil else { throw WireError.invalidRecording }
                guard size > 0, size % 2 == 0, size <= maximumInputBytes else {
                    throw WireError.unsupportedRecording
                }
                pcm = Data(bytes[start..<(start + size)])
            }
            let paddedSize = size + (size % 2)
            guard paddedSize <= bytes.count - start else { throw WireError.invalidRecording }
            offset = start + paddedSize
        }
        guard formatSeen, let pcm else { throw WireError.invalidRecording }
        return pcm
    }

    /// Canonical WAV wrapper; PCM samples are copied byte for byte.
    static func encode(_ pcm: Data) throws -> Data {
        guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= maximumOutputBytes else {
            throw WireError.invalidRecording
        }
        var wav = Data()
        func text(_ value: String) { wav.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { wav.append(UInt8(value & 255)); wav.append(UInt8(value >> 8)) }
        func u32(_ value: UInt32) {
            for shift in stride(from: 0, to: 32, by: 8) { wav.append(UInt8((value >> shift) & 255)) }
        }
        text("RIFF"); u32(UInt32(pcm.count + 36)); text("WAVE")
        text("fmt "); u32(16); u16(1); u16(1); u32(UInt32(sampleRate))
        u32(UInt32(bytesPerSecond)); u16(2); u16(16)
        text("data"); u32(UInt32(pcm.count)); wav.append(pcm)
        return wav
    }

    /// Match the PC control: pad only the final transport frame with zero samples.
    static func frames(_ pcm: Data) throws -> [Data] {
        guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= maximumInputBytes else {
            throw WireError.unsupportedRecording
        }
        return stride(from: 0, to: pcm.count, by: frameBytes).map { start in
            let lower = pcm.index(pcm.startIndex, offsetBy: start)
            let upper = pcm.index(pcm.startIndex, offsetBy: min(start + frameBytes, pcm.count))
            var frame = Data(pcm[lower..<upper])
            frame.append(Data(repeating: 0, count: frameBytes - frame.count))
            return frame
        }
    }

    private static func label(_ bytes: [UInt8], _ start: Int, _ value: String) -> Bool {
        let expected = Array(value.utf8)
        guard start >= 0, start + expected.count <= bytes.count else { return false }
        return Array(bytes[start..<(start + expected.count)]) == expected
    }
    private static func read16(_ bytes: [UInt8], _ start: Int) -> UInt16 {
        UInt16(bytes[start]) | (UInt16(bytes[start + 1]) << 8)
    }
    private static func read32(_ bytes: [UInt8], _ start: Int) -> UInt32 {
        UInt32(bytes[start]) | (UInt32(bytes[start + 1]) << 8)
            | (UInt32(bytes[start + 2]) << 16) | (UInt32(bytes[start + 3]) << 24)
    }
}

enum TranslationWire {
    static let model = "gpt-realtime-translate"
    static let endpoint = URL(string: "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate")!

    enum Event {
        case created, updated(String), text(String), audio(Data), closed, failure(WireError), other
    }

    static func configuration(target: String) throws -> String {
        guard target == "ru" || target == "de" else { throw WireError.invalidLanguage }
        return try json(["type": "session.update", "session": ["audio": [
            "input": ["noise_reduction": NSNull(), "transcription": NSNull()],
            "output": ["language": target]
        ]]])
    }

    static func append(_ pcm: Data) throws -> String {
        guard !pcm.isEmpty, pcm.count % 2 == 0 else { throw WireError.invalidRecording }
        return try json(["type": "session.input_audio_buffer.append", "audio": pcm.base64EncodedString()])
    }

    static func event(_ data: Data) throws -> Event {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { throw WireError.invalidResponse }
        switch type {
        case "session.created":
            guard let session = object["session"] as? [String: Any],
                  session["model"] as? String == model else { throw WireError.configuration }
            return .created
        case "session.updated":
            guard let session = object["session"] as? [String: Any], session["model"] as? String == model,
                  let audio = session["audio"] as? [String: Any],
                  let output = audio["output"] as? [String: Any],
                  let target = output["language"] as? String else { throw WireError.configuration }
            return .updated(target)
        case "session.output_transcript.delta":
            guard let delta = object["delta"] as? String else { throw WireError.invalidResponse }
            return .text(delta)
        case "session.output_audio.delta":
            guard let encoded = object["delta"] as? String, let pcm = Data(base64Encoded: encoded),
                  pcm.count % 2 == 0,
                  (object["sample_rate"] as? Int ?? WavePCM.sampleRate) == WavePCM.sampleRate,
                  (object["channels"] as? Int ?? 1) == 1,
                  (object["format"] as? String ?? "pcm16") == "pcm16" else { throw WireError.invalidResponse }
            return .audio(pcm)
        case "session.closed": return .closed
        case "error":
            let error = object["error"] as? [String: Any]
            switch error?["code"] as? String {
            case "invalid_api_key", "permission_denied", "model_not_found": return .failure(.authorization)
            case "insufficient_quota": return .failure(.quota)
            case "rate_limit_exceeded": return .failure(.rateLimit)
            default: return .failure(.connection)
            }
        default: return .other
        }
    }

    private static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
