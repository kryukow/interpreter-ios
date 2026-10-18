import Foundation

/// Inspect a PCM16 mono frame's level for diagnostics only.
/// The audio is never retained, filtered, or altered.
enum InputAudioLevelMeter {
    struct Measurement {
        let samples: Int
        let zeroSamples: Int
        let rmsDBFS: Double?
        let peakDBFS: Double?
        var zeroPercent: Double {
            samples == 0 ? 0 : 100 * Double(zeroSamples) / Double(samples)
        }
        static func printed(_ value: Double?) -> String {
            guard let value else { return "-inf" }
            return String(format: "%.1f", value)
        }
    }

    static func measure(_ pcm: Data) -> Measurement {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2) else {
            return Measurement(samples: 0, zeroSamples: 0, rmsDBFS: nil, peakDBFS: nil)
        }
        let b = [UInt8](pcm)
        var total = 0.0
        var peak = 0
        var zeros = 0
        for i in stride(from: 0, to: b.count, by: 2) {
            let value = Int32(Int16(bitPattern: UInt16(b[i]) | (UInt16(b[i + 1]) << 8)))
            let a = Int(abs(value))
            if a == 0 { zeros += 1 }
            peak = max(peak, a)
            total += Double(a) * Double(a)
        }
        let count = b.count / 2
        let rms = sqrt(total / Double(count)) / 32768.0
        let maximum = Double(peak) / 32768.0
        return Measurement(samples: count, zeroSamples: zeros,
            rmsDBFS: rms > 0 ? 20 * log10(rms) : nil,
            peakDBFS: maximum > 0 ? 20 * log10(maximum) : nil)
    }
}
