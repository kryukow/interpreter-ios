import Foundation

@main struct TranslationEventDiagnosticsTests {
    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
    static func main() throws {
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let config = #"{"type":"session.update","session":{"audio":{"output":{"language":"de"}}}}"#
        var recorder = TranslationEventDiagnostics(target: "de", configuration: config,
                                                   startedAt: base, uptime: 100)
        recorder.note("session.created", date: base, uptime: 100.05)
        let input = Data(repeating: 0, count: 9_600)
        recorder.inputFrameSent(input, date: base.addingTimeInterval(0.1), uptime: 100.1)
        recorder.inputFrameSent(Data(repeating: 0x40, count: 9_600),
                                date: base.addingTimeInterval(2), uptime: 102)
        recorder.closeSent(date: base.addingTimeInterval(0.2), uptime: 100.2)
        let silent = Data(repeating: 0, count: 2 * 24_000)
        let voiced = Data([10, 0, 255, 255])
        let firstRaw = Data(#"{"type":"session.output_audio.delta","event_id":"evt-test","elapsed_ms":200}"#.utf8)
        recorder.audio(silent, rawEvent: firstRaw, date: base.addingTimeInterval(1), uptime: 101)
        recorder.audio(voiced, rawEvent: Data(#"{"type":"session.output_audio.delta"}"#.utf8),
                       date: base.addingTimeInterval(3), uptime: 103)
        recorder.audio(silent, rawEvent: Data(#"{"type":"session.output_audio.delta"}"#.utf8),
                       date: base.addingTimeInterval(3.2), uptime: 103.2)
        recorder.closedReceived(date: base.addingTimeInterval(3.5), uptime: 103.5)
        let report = recorder.report(outcome: "success", date: base.addingTimeInterval(3.5),
                                     uptime: 103.5)
        require(report.contains("session.close sent: true; session.closed received: true"), "Close handshake missing")
        require(report.contains("arrival_gap_ms=2000.0"), "Wall-clock audio gap missing")
        require(report.contains("all_zero=true"), "Silent delta not detected")
        require(report.contains("rms_dBFS=-inf") && report.contains("peak_dBFS=-inf"),
                "Zero microphone frame level missing")
        require(report.contains("near_silent_lt_-45dBFS=true"), "Silence indicator missing")
        require(report.contains("input.frame #2") && report.contains("near_silent_lt_-45dBFS=false"),
                "Voiced input frame missing")
        require(report.contains("Input near-silent frames (RMS < -45 dBFS, diagnostic only): 1/2"),
                "Input frame summary missing")
        require(report.contains("event_id=evt-test"), "Optional event ID missing")
        require(report.contains("server_elapsed_ms=200"), "Optional server elapsed missing")
        require(report.contains("internal") && report.contains("trailing"), "Cross-chunk zero run missing")
        require(report.contains("session.update JSON: "+config), "Exact config missing")
        require(report.contains("input PCM bytes: 19200"), "Input frame count missing")
        require(!report.contains("Bearer ") && !report.contains("transcript.delta: "), "Sensitive content leaked")
        print("Realtime event diagnostics tests passed")
    }
}
