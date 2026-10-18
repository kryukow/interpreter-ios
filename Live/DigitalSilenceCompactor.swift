import Foundation

/// Shortens only exactly zero-valued PCM16 samples, without touching a
/// single non-zero speech sample. Unlike truncating a silent run from the
/// front, it retains quiet space on *both* sides of a long phrase boundary.
///
/// The trailing zero context is held until the next non-zero sample (or
/// finish), which also handles arbitrary network chunk boundaries.
/// The server's original WAV is never modified.
struct DigitalSilenceCompactor {
    static let sampleRate = 24_000
    static let precedingSilenceSamples = sampleRate * 45 / 100 // 450 ms after preceding word
    static let followingSilenceSamples = sampleRate * 40 / 100 // 400 ms before next word
    static let retainedSilenceSamples = precedingSilenceSamples + followingSilenceSamples

    private var continuousZeroSamples = 0
    private var bufferedTrailingZeros = 0
    private(set) var droppedZeroSamples = 0

    mutating func process(_ pcm: Data) -> Data {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2) else { return pcm }
        let bytes = [UInt8](pcm)
        var output = Data()
        output.reserveCapacity(pcm.count)
        var i = 0

        while i < bytes.count {
            let silent = bytes[i] == 0 && bytes[i + 1] == 0
            let start = i
            repeat {
                i += 2
            } while i < bytes.count && (bytes[i] == 0 && bytes[i + 1] == 0) == silent

            let samples = (i - start) / 2
            if silent {
                let headRoom = max(0, Self.precedingSilenceSamples - continuousZeroSamples)
                let keepNow = min(headRoom, samples)
                if keepNow > 0 {
                    output.append(contentsOf: bytes[start..<(start + keepNow * 2)])
                }
                let remainder = samples - keepNow
                let oldTail = bufferedTrailingZeros
                bufferedTrailingZeros = min(Self.followingSilenceSamples, oldTail + remainder)
                droppedZeroSamples += oldTail + remainder - bufferedTrailingZeros
                continuousZeroSamples += samples
            } else {
                if bufferedTrailingZeros > 0 {
                    output.append(Data(repeating: 0, count: bufferedTrailingZeros * 2))
                }
                bufferedTrailingZeros = 0
                continuousZeroSamples = 0
                output.append(contentsOf: bytes[start..<i])
            }
        }
        return output
    }

    /// Flushes the reserved trailing quiet space when no new phrase follows.
    /// Call only once when the complete server audio stream ends.
    mutating func finish() -> Data {
        let count = bufferedTrailingZeros
        bufferedTrailingZeros = 0
        return Data(repeating: 0, count: count * 2)
    }

    var removedSeconds: Double {
        Double(droppedZeroSamples) / Double(Self.sampleRate)
    }
}
