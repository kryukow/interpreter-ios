import Foundation

/// Tracks actual FIFO playback progress after a terminal WebRTC translation event.
/// It must not wait for the full 80-second safeguard if the audio render callback
/// has stopped consuming bytes: a common side effect of session.close.
struct WebRTCAudioDrainMonitor {
    enum Result: Equatable {
        case waiting
        case drained
        case stalled(remainingBytes: Int)
        case timedOut(remainingBytes: Int)
    }

    private let start: TimeInterval
    private let maxDuration: TimeInterval
    private let stallInterval: TimeInterval
    private var lastProgress: TimeInterval
    private var previousPending: Int

    init(pendingBytes: Int, at time: TimeInterval,
         stallInterval: TimeInterval = 2.5,
         maxDuration: TimeInterval = 80) {
        start = time
        lastProgress = time
        previousPending = max(0, pendingBytes)
        self.stallInterval = stallInterval
        self.maxDuration = maxDuration
    }

    mutating func observe(pendingBytes: Int, at time: TimeInterval) -> Result {
        let pending = max(0, pendingBytes)
        if pending == 0 { return .drained }
        if pending != previousPending {
            previousPending = pending
            lastProgress = time
        }
        if time - start >= maxDuration {
            return .timedOut(remainingBytes: pending)
        }
        if time - lastProgress >= stallInterval {
            return .stalled(remainingBytes: pending)
        }
        return .waiting
    }
}
