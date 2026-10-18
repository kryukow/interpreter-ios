import Foundation

/// Locally shortens only **exactly zero-valued** PCM16 samples from the
/// already translated OpenAI audio. Non-zero samples are never altered.
/// The original WAV remains untouched in TranslationConnection.
struct DigitalSilenceCompactor {
    static let sampleRate = 24_000
    static let retainedSilenceSamples = sampleRate * 65 / 100 // 650 ms

    private var continuousZeroSamples = 0
    private(set) var droppedZeroSamples = 0

    /// Takes interleaved mono PCM16 little-endian at 24 kHz.
    /// State is retained between arbitrary server delta boundaries.
    mutating func process(_ pcm: Data) -> Data {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2) else { return pcm }
        let bytes = [UInt8](pcm)
        var output = Data()
        output.reserveCapacity(pcm.count)
        var position = 0

        while position < bytes.count {
            let zero = bytes[position] == 0 && bytes[position + 1] == 0
            let start = position
            repeat {
                position += 2
            } while position < bytes.count &&
                (bytes[position] == 0 && bytes[position + 1] == 0) == zero

            let samples = (position - start) / 2
            if zero {
                let allowed = max(0, Self.retainedSilenceSamples - continuousZeroSamples)
                let keep = min(allowed, samples)
                if keep > 0 {
                    output.append(contentsOf: bytes[start..<(start + keep * 2)])
                }
                continuousZeroSamples += samples
                droppedZeroSamples += samples - keep
            } else {
                continuousZeroSamples = 0
                output.append(contentsOf: bytes[start..<position])
            }
        }
        return output
    }

    var removedSeconds: Double {
        Double(droppedZeroSamples) / Double(Self.sampleRate)
    }
}
