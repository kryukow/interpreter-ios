import Foundation

/// Text-only, privacy-conscious troubleshooting for one translation session.
/// Never retains the API key, microphone PCM, translated PCM, or transcript text.
/// Only timing, sample counts, protocol event names and public session options.
struct TranslationEventDiagnostics {
    private struct AudioDelta {
        let index: Int
        let sampleStart: Int
        let sampleEnd: Int
        let line: String
    }
    private struct ZeroRun {
        let start: Int
        let end: Int
        var samples: Int { end - start }
    }

    private let startedAt: Date
    private let startUptime: TimeInterval
    private let target: String
    private let configuration: String
    private var lines: [String] = []
    private var deltas: [AudioDelta] = []
    private var totalSamples = 0
    private var zeroSamples = 0
    private var zeroStart: Int?
    private var zeroRuns: [ZeroRun] = []
    private var lastDeltaUptime: TimeInterval?
    private var arrivalGaps: [(Double, String)] = []
    private var inputFrames = 0
    private var inputBytes = 0
    private var endedAt: Date?
    private var sawSessionClose = false
    private var sawSessionClosed = false

    init(target: String, configuration: String,
         startedAt: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.target = target
        self.configuration = configuration
        self.startedAt = startedAt
        self.startUptime = uptime
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func stamp(_ date: Date, _ uptime: TimeInterval) -> String {
        String(format: "%@  +%.0fms", Self.timestamp(date), (uptime - startUptime) * 1000)
    }

    mutating func note(_ name: String, date: Date = Date(),
                       uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if lines.count < 900 { lines.append("\(stamp(date, uptime))  \(name)") }
    }

    mutating func inputFrameSent(byteCount: Int) {
        inputFrames += 1
        inputBytes += byteCount
    }

    mutating func closeSent(date: Date = Date(),
                            uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        sawSessionClose = true
        note("session.close SENT; input_frames=\(inputFrames) input_bytes=\(inputBytes)", date: date, uptime: uptime)
    }

    mutating func closedReceived(date: Date = Date(),
                                 uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        sawSessionClosed = true
        note("session.closed RECEIVED", date: date, uptime: uptime)
    }

    /// Log each audio delta with the packet arrival time and the *sample* zero ratio.
    /// A gap between arrival times is not the same as zeros inside PCM.
    mutating func audio(_ pcm: Data, rawEvent: Data,
                        date: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let sampleCount = pcm.count / 2
        let begin = totalSamples
        let bytes = [UInt8](pcm)
        var zerosHere = 0
        var index = 0
        while index + 1 < bytes.count {
            let isZero = bytes[index] == 0 && bytes[index + 1] == 0
            if isZero {
                zerosHere += 1
                if zeroStart == nil { zeroStart = totalSamples }
            } else if let start = zeroStart {
                zeroRuns.append(ZeroRun(start: start, end: totalSamples))
                zeroStart = nil
            }
            totalSamples += 1
            index += 2
        }
        zeroSamples += zerosHere
        let gap = lastDeltaUptime.map { (uptime - $0) * 1000 }
        lastDeltaUptime = uptime
        let metadata = (try? JSONSerialization.jsonObject(with: rawEvent)) as? [String: Any]
        let id = (metadata?["event_id"] as? String).map { " event_id=\($0)" } ?? ""
        let serverElapsed = (metadata?["elapsed_ms"] as? NSNumber).map {
            " server_elapsed_ms=\($0)"
        } ?? ""
        let percent = sampleCount == 0 ? 0.0 : (Double(zerosHere) / Double(sampleCount)) * 100
        let gapText = gap.map { String(format: " arrival_gap_ms=%.1f", $0) } ?? ""
        let desc = String(format: "session.output_audio.delta #%-3d bytes=%d audio_ms=%.1f zero_samples=%d/%d zero_pct=%.1f all_zero=%@ audio_offset_s=%.3f",
                          deltas.count + 1, pcm.count, Double(sampleCount) / 24, zerosHere,
                          sampleCount, percent, zerosHere == sampleCount ? "true" : "false",
                          Double(begin) / 24_000)
            + gapText + id + serverElapsed
        if deltas.count < 900 {
            deltas.append(AudioDelta(index: deltas.count, sampleStart: begin,
                                     sampleEnd: totalSamples, line: stamp(date, uptime) + "  " + desc))
        }
        if let gap, gap >= 500 {
            arrivalGaps.append((gap, stamp(date, uptime) + "  before audio.delta #\(deltas.count)"))
        }
        if deltas.count == 900 { note("Audio event log capped at 900 deltas") }
    }

    /// Call before any reset/cancel, including on error.
    mutating func report(outcome: String, date: Date = Date(),
                         uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String {
        endedAt = date
        if let start = zeroStart {
            zeroRuns.append(ZeroRun(start: start, end: totalSamples))
            zeroStart = nil
        }
        let candidates = zeroRuns.filter { $0.samples >= 12_000 }
            .sorted { $0.samples > $1.samples }
        let mainInternal = candidates.first(where: { $0.end < totalSamples })
        let longest = mainInternal ?? candidates.first
        let zeroReport = candidates.prefix(6).map {
            String(format: "  output %.3fs .. %.3fs; %.3fs exactly-zero PCM; %@",
                   Double($0.start) / 24_000, Double($0.end) / 24_000,
                   Double($0.samples) / 24_000,
                   $0.end == totalSamples ? "trailing" : "internal")
        }
        let majorGaps = arrivalGaps.sorted { $0.0 > $1.0 }.prefix(6).map {
            String(format: "  %.1f ms at %@", $0.0, $0.1)
        }
        let focus = longest.map { run in
            (max(0, run.start - 4 * 24_000), min(totalSamples, run.end + 4 * 24_000))
        }
        let chosen = deltas.filter { item in
            item.index < 4 || item.index >= max(0, deltas.count - 12) ||
            (focus.map { item.sampleEnd >= $0.0 && item.sampleStart <= $0.1 } ?? false)
        }
        var result = [
            "Interpreter Live — gpt-realtime-translate event diagnostic",
            "Metadata only: no speech, transcript, API key or raw PCM included.",
            "Session start: \(Self.timestamp(startedAt))",
            "Session end: \(Self.timestamp(date))",
            "Target language: \(target)",
            "Input: PCM16 24kHz mono; 9600 bytes per 200ms frame",
            "Input frames sent: \(inputFrames); input PCM bytes: \(inputBytes)",
            "session.close sent: \(sawSessionClose); session.closed received: \(sawSessionClosed)",
            "Outcome: \(outcome)",
            "Exact session.update JSON: \(configuration)",
            "Output: PCM16 24kHz mono",
            String(format: "Output: %d deltas; %d bytes; %.3f seconds of audio; %d/%d samples exactly zero (%.2f%%)",
                   deltas.count, totalSamples * 2, Double(totalSamples) / 24_000,
                   zeroSamples, totalSamples,
                   totalSamples > 0 ? Double(zeroSamples) / Double(totalSamples) * 100 : 0),
            "Zero-sample runs >= 500ms (sample offset, not wall clock):"
        ]
        result.append(contentsOf: zeroReport.isEmpty ? ["  none"] : zeroReport)
        result.append("Largest wall-clock gaps between received audio.delta events >= 500ms:")
        result.append(contentsOf: majorGaps.isEmpty ? ["  none"] : majorGaps)
        result.append("Other session events:")
        result.append(contentsOf: lines.map { "  " + $0 })
        result.append("Audio delta excerpt: first four, ~4s around largest internal zero run, final twelve:")
        result.append(contentsOf: chosen.map { "  " + $0.line })
        result.append("IMPORTANT: original WAV content zeros and arrival-time gaps are distinct phenomena; neither alone establishes the server's internal cause.")
        return result.joined(separator: "\n")
    }
}
