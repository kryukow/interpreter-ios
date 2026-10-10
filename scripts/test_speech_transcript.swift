import Foundation

@main struct SpeechTranscriptTests {
    static func main() {
        var transcript = SpeechTranscript()
        precondition(transcript.receive("Я хочу", start: 0, end: 1, stable: false) == "Я хочу")
        precondition(transcript.receive("Я хочу билет.", start: 0, end: 2, stable: true) == "Я хочу билет.")
        precondition(transcript.receive("До Берлина", start: 3.2, end: 4, stable: false) == "Я хочу билет. До Берлина")
        precondition(transcript.receive("До Берлина завтра.", start: 3.2, end: 5, stable: true) == "Я хочу билет. До Берлина завтра.")
        precondition(transcript.receive("", start: nil, end: nil, stable: false) == "Я хочу билет. До Берлина завтра.")
        var revisions = SpeechTranscript()
        _ = revisions.receive("Ich brauche zwei", start: 0, end: 2, stable: false)
        precondition(revisions.receive("Ich brauche drei Tickets", start: 0, end: 3, stable: false) == "Ich brauche drei Tickets")
        var noTiming = SpeechTranscript()
        _ = noTiming.receive("Первая фраза.", start: nil, end: nil, stable: true)
        precondition(noTiming.receive("Вторая", start: nil, end: nil, stable: false) == "Первая фраза. Вторая")
        precondition(noTiming.receive("Вторая фраза.", start: nil, end: nil, stable: true) == "Первая фраза. Вторая фраза.")
        precondition(noTiming.receive("Вторая фраза.", start: nil, end: nil, stable: true) == "Первая фраза. Вторая фраза.")
        var cumulative = SpeechTranscript()
        _ = cumulative.receive("Привет", start: 0, end: 1, stable: true)
        precondition(cumulative.receive("Привет как дела", start: 0, end: 2, stable: false) == "Привет как дела")
        print("PASS: pause rollover, partial revisions, empty updates, metadata fallback, duplicate results, cumulative results")
    }
}
