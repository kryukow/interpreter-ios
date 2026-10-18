import Foundation

@main struct WebRTCAudioDrainMonitorTests {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
    static func main() {
        var normal = WebRTCAudioDrainMonitor(pendingBytes: 600, at: 100)
        check(normal.observe(pendingBytes: 600, at: 101) == .waiting, "Healthy buffer flagged as stalled too early")
        check(normal.observe(pendingBytes: 300, at: 102.2) == .waiting, "Draining buffer should reset stall timer")
        check(normal.observe(pendingBytes: 0, at: 102.3) == .drained, "Completed playout not detected")

        var stall = WebRTCAudioDrainMonitor(pendingBytes: 216_384, at: 200)
        check(stall.observe(pendingBytes: 216_384, at: 201.9) == .waiting, "Premature stalled state")
        check(stall.observe(pendingBytes: 216_384, at: 202.6) == .stalled(remainingBytes: 216_384),
              "Stalled WebRTC session must not lock Push-to-Talk for 80 seconds")

        var resume = WebRTCAudioDrainMonitor(pendingBytes: 800, at: 300)
        _ = resume.observe(pendingBytes: 700, at: 301.9)
        check(resume.observe(pendingBytes: 700, at: 304.3) == .waiting,
              "Progress resets the watchdog timer")
        check(resume.observe(pendingBytes: 700, at: 304.5) == .stalled(remainingBytes: 700),
              "Watchdog failed to detect a later stop")

        var capped = WebRTCAudioDrainMonitor(pendingBytes: 400, at: 400,
                                            stallInterval: 300, maxDuration: 10)
        check(capped.observe(pendingBytes: 350, at: 411) == .timedOut(remainingBytes: 350),
              "Must not remain stuck forever even if playback changes intermittently")
        print("WebRTC post-release audio-drain progress and reconnect release tests passed")
    }
}
