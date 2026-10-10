import Foundation

// Speech can return only the latest utterance after a pause, while revisions
// within an utterance must still replace its provisional text.
struct SpeechTranscript {
    private var completed: [String] = []
    private var current = ""
    private var lastEnd: Double?
    private var settled = false

    mutating func receive(_ text: String, start: Double?, end: Double?, stable: Bool) -> String {
        let next = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return value }
        let laterAudio = start.map { first in lastEnd.map { first > $0 + 0.05 } ?? false } ?? false
        let afterSettled = settled && !stable && next != current && !next.hasPrefix(current)
        if !current.isEmpty && (laterAudio || afterSettled) {
            completed.append(current)
            current = ""
            lastEnd = nil
        }
        current = next
        if let end, end > 0 { lastEnd = end }
        settled = stable
        return value
    }

    var value: String { (completed + [current]).filter { !$0.isEmpty }.joined(separator: " ") }
}
