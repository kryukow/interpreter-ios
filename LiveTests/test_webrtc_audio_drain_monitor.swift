import Foundation

@main struct WebRTCAudioDrainMonitorTests {
    static func check(_ condition: Bool, _ reason: String) {
        if !condition { fatalError(reason) }
    }

    static func main() {
        var normal = WebRTCAudioDrainMonitor(pendingBytes: 600, renderedBytes: 0, at: 100)
        check(normal.observe(pendingBytes: 600, renderedBytes: 100, at: 101) == .waiting,
              "Rendered audio is advancing even when FIFO size is constant")
        check(normal.observe(pendingBytes: 300, renderedBytes: 400, at: 102.2) == .waiting,
              "Draining must reset stall timer")
        check(normal.observe(pendingBytes: 0, renderedBytes: 700, at: 102.3) == .drained,
              "Completed playout not detected")

        var stall = WebRTCAudioDrainMonitor(pendingBytes: 1_386_624, renderedBytes: 0, at: 200)
        check(stall.observe(pendingBytes: 1_386_624, renderedBytes: 0, at: 201.9) == .waiting,
              "Premature stalled state")
        check(stall.observe(pendingBytes: 1_386_624, renderedBytes: 0, at: 202.6) ==
              .stalled(remainingBytes: 1_386_624),
              "A stopped render callback must be detected")

        var sameFIFO = WebRTCAudioDrainMonitor(pendingBytes: 800, renderedBytes: 0, at: 300)
        check(sameFIFO.observe(pendingBytes: 800, renderedBytes: 400, at: 302.1) == .waiting,
              "A stable pending count must NOT trigger false-stalled if audio is playing")
        check(sameFIFO.observe(pendingBytes: 800, renderedBytes: 600, at: 304.3) == .waiting,
              "Continued rendering must reset the timer")
        check(sameFIFO.observe(pendingBytes: 800, renderedBytes: 600, at: 306.9) ==
              .stalled(remainingBytes: 800),
              "Stop after last playback progress must be noticed")

        var capped = WebRTCAudioDrainMonitor(pendingBytes: 400, renderedBytes: 0,
                                            at: 400, stallInterval: 300, maxDuration: 10)
        check(capped.observe(pendingBytes: 350, renderedBytes: 100, at: 411) ==
              .timedOut(remainingBytes: 350),
              "Maximum wait guard is required")
        print("WebRTC rendered-byte watchdog: active, stalled and capped tests passed")
    }
}
