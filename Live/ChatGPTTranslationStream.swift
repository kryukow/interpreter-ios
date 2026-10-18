import Foundation

// Plain-text translations have one output; no partial JSON is shown to the reader.
struct TranslationTextStream {
    private(set) var text = ""
    private(set) var completed = false

    mutating func receive(_ event: [String: Any]) throws -> Bool {
        guard !completed else { return false }
        let previous = text
        switch event["type"] as? String {
        case "response.output_text.delta":
            text += event["delta"] as? String ?? ""
        case "response.output_text.done":
            if let final = event["text"] as? String { text = final }
        case "response.completed":
            completed = true
        case "response.failed", "response.incomplete", "error", "response.refusal.delta", "response.refusal.done":
            throw Failure.message("Перевод не завершён. Попробуй ещё раз или проверь лимиты Plus.")
        default: break
        }
        guard text.utf8.count <= 200_000 else { throw Failure.message("Ответ перевода слишком большой.") }
        return text != previous
    }

    func finish() throws -> String {
        guard completed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.message("Перевод не завершён. Попробуй ещё раз.")
        }
        return text
    }
}

struct StreamedTranslation {
    let text: String
    let headersSeconds: Double
    let firstTextSeconds: Double
    let totalSeconds: Double
}
