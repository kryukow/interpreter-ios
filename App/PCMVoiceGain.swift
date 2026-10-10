import Foundation

// Operates on 24 kHz little-endian PCM16; never changes sample count or timing.
struct PCMVoiceGain {
    private var previousGain = 1.0
    private(set) var maximumGain = 1.0
    mutating func process(_ pcm: Data, enabled: Bool) -> Data {
        guard enabled, !pcm.isEmpty, pcm.count % 2 == 0 else { return pcm }
        let bytes = Array(pcm)
        let samples = stride(from: 0, to: bytes.count, by: 2).map { i in
            Double(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8))
        }
        let rms = sqrt(samples.reduce(0.0) { $0 + $1 * $1 } / Double(samples.count)) / 32768
        let peak = samples.map { abs($0) }.max()! / 32768
        // Do not turn digital silence or a nearly silent noise floor into speech.
        guard rms >= 0.001, peak > 0 else { previousGain = 1; return pcm }
        let headroom = max(1, 0.85 / peak)
        let gain = max(1, min(8, 0.05 / rms, headroom))
        guard gain > 1 else { previousGain = 1; return pcm }
        let start = min(previousGain, headroom)
        var output = bytes
        for i in samples.indices {
            // Smooth the gain transition over 20 ms, bounded by this frame's peak.
            let progress = min(1, Double(i + 1) / 480)
            let applied = start + (gain - start) * progress
            let value = Int16(max(-32768, min(32767, (samples[i] * applied).rounded())))
            let bits = UInt16(bitPattern: value)
            output[2 * i] = UInt8(bits & 255); output[2 * i + 1] = UInt8(bits >> 8)
            maximumGain = max(maximumGain, applied)
        }
        previousGain = gain
        return Data(output)
    }
}
