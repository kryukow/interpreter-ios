import Foundation

/// A clear, user-facing distinction: ordinary transcript or speaker-labelled conversation.
enum TranscriptionMode: String, CaseIterable, Identifiable {
    case single, group
    var id: String { rawValue }
    var title: String { self == .single ? "Один голос" : "Несколько голосов" }
    var model: String { self == .single ? "gpt-transcribe" : "gpt-4o-transcribe-diarize" }
    var pricePerMinute: Double { self == .single ? 0.0045 : 0.006 }
    var explanation: String {
        self == .single
            ? "Обычная расшифровка речи на исходном языке, без разделения участников."
            : "Диалог или встреча: реплики, примерное время и разные говорящие."
    }
    func price(for duration: Double) -> Double {
        max(0, duration) / 60 * pricePerMinute
    }
}

/// Audio language hints. The diarization model accepts one language only;
/// multilingual hints are supported by gpt-transcribe.
enum TranscriptionLanguageHint: String, CaseIterable, Identifiable {
    case ru, de, en, es, ro, pl, ruDE, ruEN, ruES, ruRO, ruPL, automatic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ru: return "Только русский"
        case .de: return "Только немецкий"
        case .en: return "Только английский"
        case .es: return "Только испанский"
        case .ro: return "Только румынский"
        case .pl: return "Только польский"
        case .ruDE: return "Русский + немецкий"
        case .ruEN: return "Русский + английский"
        case .ruES: return "Русский + испанский"
        case .ruRO: return "Русский + румынский"
        case .ruPL: return "Русский + польский"
        case .automatic: return "Автоопределение"
        }
    }
    var languages: [String] {
        switch self {
        case .ru: return ["ru"]
        case .de: return ["de"]
        case .en: return ["en"]
        case .es: return ["es"]
        case .ro: return ["ro"]
        case .pl: return ["pl"]
        case .ruDE: return ["ru", "de"]
        case .ruEN: return ["ru", "en"]
        case .ruES: return ["ru", "es"]
        case .ruRO: return ["ru", "ro"]
        case .ruPL: return ["ru", "pl"]
        case .automatic: return []
        }
    }
    var isMultilingual: Bool { languages.count > 1 }
}

struct TranscriptSegment: Equatable {
    let speaker: String
    let start: Double
    let end: Double
    let text: String
}

struct TranscriptResult {
    let text: String
    let segments: [TranscriptSegment]
    let languages: [String]

    func formatted(mode: TranscriptionMode, partNumber: Int = 1,
                   showPart: Bool = false, offsetSeconds: Double = 0) -> String {
        let title = showPart ? "Часть \(partNumber)\n" : ""
        if mode == .single || segments.isEmpty { return title + text }
        return title + segments.map { segment in
            let absolute = Int(max(0, segment.start + offsetSeconds))
            let minutes = absolute / 60
            let seconds = absolute % 60
            return String(format: "[%02d:%02d] %@: %@", minutes, seconds,
                          segment.speaker, segment.text)
        }.joined(separator: "\n\n")
    }
}

enum TranscriptWireError: LocalizedError {
    case fileTooLarge, emptyFile, malformedResponse, noText, invalidKey, access, quota, unavailable,
         server(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: return "Аудиофайл превышает 25 МБ. Нужна сжатая запись или разделение."
        case .emptyFile: return "Аудиофайл пуст или повреждён."
        case .malformedResponse: return "OpenAI вернул неожиданный формат результата."
        case .noText: return "В записи не удалось распознать речь."
        case .invalidKey: return "OpenAI отклонил API-ключ."
        case .access: return "Недостаточно прав для выбранной модели OpenAI."
        case .quota: return "Недостаточно баланса API или достигнут лимит."
        case .unavailable: return "Нет связи с OpenAI. Проверь интернет и попробуй ещё раз."
        case .server(let message): return message
        }
    }
}

enum TranscriptionWire {
    static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    static let maxBytes = 25_000_000 // API's 25 MB upload cap, decimal to be safe.
    static let chunkSeconds = 180.0
    static func expectedChunks(durationSeconds: Double) -> Int {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return 0 }
        return Int(ceil(durationSeconds / chunkSeconds))
    }

    static func request(file: Data, filename: String, key: String,
                        mode: TranscriptionMode, boundary: String,
                        hint: TranscriptionLanguageHint = .ru) throws -> URLRequest {
        guard !file.isEmpty else { throw TranscriptWireError.emptyFile }
        guard file.count <= maxBytes else { throw TranscriptWireError.fileTooLarge }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180
        var body = Data()
        func form(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        form("model", mode.model)
        if mode == .group {
            form("response_format", "diarized_json")
            form("chunking_strategy", "auto")
            // Diarization supports singular 'language' only.
            // For a two-language recording, leave language unset rather than incorrectly
            // forcing one language and risking unwanted transliteration.
            if hint.languages.count == 1, let language = hint.languages.first {
                form("language", language)
            }
        } else {
            // gpt-transcribe accepts languages[], not singular language.
            for language in hint.languages { form("languages[]", language) }
        }
        let safeName = filename.replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
        let mimetype: String
        switch (safeName as NSString).pathExtension.lowercased() {
        case "wav": mimetype = "audio/wav"
        case "mp3", "mpga", "mpeg": mimetype = "audio/mpeg"
        case "mp4", "m4a": mimetype = "audio/mp4"
        case "ogg": mimetype = "audio/ogg"
        case "webm": mimetype = "audio/webm"
        case "flac": mimetype = "audio/flac"
        default: mimetype = "application/octet-stream"
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: \(mimetype)\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    static func parse(_ data: Data, mode: TranscriptionMode) throws -> TranscriptResult {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            throw TranscriptWireError.malformedResponse
        }
        let segments: [TranscriptSegment]
        if mode == .group {
            guard let raw = object["segments"] as? [[String: Any]] else {
                throw TranscriptWireError.malformedResponse
            }
            segments = raw.compactMap { value in
                guard let text = value["text"] as? String,
                      let start = value["start"] as? Double,
                      let end = value["end"] as? Double else { return nil }
                return TranscriptSegment(speaker: value["speaker"] as? String ?? "Говорящий",
                                         start: start, end: end, text: text)
            }
            guard segments.count == raw.count else { throw TranscriptWireError.malformedResponse }
        } else {
            segments = []
        }
        let languages = (object["languages"] as? [[String: Any]] ?? [])
            .compactMap { $0["code"] as? String }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, segments.isEmpty {
            throw TranscriptWireError.noText
        }
        return TranscriptResult(text: text, segments: segments, languages: languages)
    }

    static func serverError(_ data: Data, status: Int) -> TranscriptWireError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let details = json?["error"] as? [String: Any]
        let code = details?["code"] as? String ?? ""
        let message = details?["message"] as? String ?? ""
        if code == "invalid_api_key" { return .invalidKey }
        if status == 401 || status == 403 { return .access }
        if code == "insufficient_quota" { return .quota }
        if status == 429 { return .server("Лимит запросов OpenAI. Попробуй позже.") }
        if status == 413 { return .fileTooLarge }
        // Avoid displaying raw server errors that could contain technical details/secrets.
        if status == 400 {
            return .server(message.isEmpty ? "OpenAI не принял формат аудио или параметры запроса."
                : "OpenAI не принял файл. Проверь формат и длительность.")
        }
        return .unavailable
    }
}
