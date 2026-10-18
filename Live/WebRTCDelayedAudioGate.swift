import Foundation

/// Real-time-safe in-place PCM delay used only by the experimental custom
/// WebRTC audio device. The producer/consumer run in the *same* audio render
/// callback; a short lock synchronizes mode changes from the UI thread.
/// No network roundtrip or second model request is involved.
final class WebRTCDelayedAudioGate {
    enum Mode { case direct, capture, drain }
    private let lock = NSLock()
    private var mode: Mode = .direct
    private var bytes: [UInt8]
    private var readIndex = 0
    private var writeIndex = 0
    private var used = 0
    private var capturedBytes = 0
    private var droppedBytes = 0
    private var zeroRunBytes = 0
    private let maxZeroBytes: Int

    init(capacityBytes: Int = 48_000 * 2 * 2 * 65,
         maxZeroBytes: Int = 48_000 * 2 * 2 * 1) {
        bytes = [UInt8](repeating: 0, count: max(capacityBytes, 1024))
        self.maxZeroBytes = maxZeroBytes
    }

    func startCapture() {
        lock.lock()
        readIndex = 0
        writeIndex = 0
        used = 0
        capturedBytes = 0
        droppedBytes = 0
        zeroRunBytes = 0
        mode = .capture
        lock.unlock()
    }

    func startDrain() {
        lock.lock()
        if mode == .capture { mode = .drain }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        mode = .direct
        used = 0
        zeroRunBytes = 0
        lock.unlock()
    }

    var pendingBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return used
    }

    var hasOverflowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return droppedBytes > 0
    }

    /// Called on WebRTC's AVAudioSourceNode render thread.
    /// Input/output are interleaved 16-bit PCM; the caller supplies exact bytes.
    @discardableResult
    func process(_ pointer: UnsafeMutableRawPointer, byteCount: Int) -> Bool {
        guard byteCount > 0 else { return false }
        lock.lock()
        defer { lock.unlock() }

        let input = pointer.assumingMemoryBound(to: UInt8.self)
        var hasSignal = false
        var i = 0
        while i + 1 < byteCount {
            if input[i] != 0 || input[i + 1] != 0 {
                hasSignal = true
                break
            }
            i += 2
        }
        if mode == .direct { return hasSignal }
        if hasSignal { zeroRunBytes = 0 }
        else { zeroRunBytes += byteCount }

        // Keep up to 1 second of contiguous zeros between speech fragments.
        // A server-emitted trailing zero run cannot exhaust memory or prolong
        // the delayed playback for 20+ seconds.
        if hasSignal || zeroRunBytes <= maxZeroBytes {
            for i in 0..<byteCount {
                if used == bytes.count {
                    droppedBytes += byteCount - i
                    break
                }
                bytes[writeIndex] = input[i]
                writeIndex += 1
                if writeIndex == bytes.count { writeIndex = 0 }
                used += 1
                capturedBytes += 1
            }
        }

        if mode == .capture {
            memset(pointer, 0, byteCount)
            return false
        }
        var audible = false
        for i in 0..<byteCount {
            if used > 0 {
                input[i] = bytes[readIndex]
                if input[i] != 0 { audible = true }
                readIndex += 1
                if readIndex == bytes.count { readIndex = 0 }
                used -= 1
            } else {
                input[i] = 0
            }
        }
        return audible
    }
}
