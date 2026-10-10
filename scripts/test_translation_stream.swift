import Foundation

enum Failure: Error { case message(String) }

@main struct StreamTests {
    static func rejected(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Expected stream rejection") } catch { }
    }
    static func main() throws {
        var stream = TranslationTextStream()
        let changed = try stream.receive(["type": "response.output_text.delta", "delta": "Продаю "])
        precondition(changed)
        precondition(stream.text == "Продаю " && !stream.completed)
        _ = try stream.receive(["type": "response.output_text.delta", "delta": "беговую дорожку.\n- 1–16 км/ч"])
        precondition(stream.text.contains("\n- 1–16 км/ч"))
        rejected { _ = try stream.finish() }
        _ = try stream.receive(["type": "response.output_text.done", "text": "Готовый перевод 🫶"])
        precondition(stream.text == "Готовый перевод 🫶")
        _ = try stream.receive(["type": "response.completed"])
        let final = try stream.finish()
        precondition(final == "Готовый перевод 🫶")
        _ = try stream.receive(["type": "response.output_text.delta", "delta": "лишний текст"])
        precondition(stream.text == final)
        for kind in ["response.failed", "response.incomplete", "error", "response.refusal.delta", "response.refusal.done"] {
            var broken = TranslationTextStream()
            _ = try broken.receive(["type": "response.output_text.delta", "delta": "Незаконченный перевод"])
            rejected { _ = try broken.receive(["type": kind]) }
        }
        var empty = TranslationTextStream()
        _ = try empty.receive(["type": "response.completed"])
        rejected { _ = try empty.finish() }
        var large = TranslationTextStream()
        rejected { _ = try large.receive(["type": "response.output_text.delta", "delta": String(repeating: "я", count: 100_001)]) }
        print("PASS: incremental Cyrillic text, paragraphs, final reconciliation, incomplete/refused/empty/oversized streams")
    }
}

