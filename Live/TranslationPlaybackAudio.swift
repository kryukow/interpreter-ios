import Foundation

/// Optional, strictly local playback processing of gpt-realtime-translate audio.
/// Never applies to the stored, exported, or shared original OpenAI WAV.
enum TranslationPlaybackAudio {
    private static let boost = 2.0
    private static let knee = 28_000.0
    private static let ceiling = 32_767.0

    /// About +6 dB for quiet and medium-level speech. A soft limiter prevents
    /// overflow of louder material while avoiding a hard clipping transition.
    static func raiseSpeechLevel(_ pcm: Data) -> Data {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2) else { return pcm }
        let input = [UInt8](pcm)
        var result = Data(capacity: pcm.count)
        for i in stride(from: 0, to: input.count, by: 2) {
            let bits = UInt16(input[i]) | (UInt16(input[i + 1]) << 8)
            let sample = Double(Int16(bitPattern: bits))
            let level = abs(sample * boost)
            let limited = level <= knee ? level :
                knee + (ceiling - knee) * (1 - exp(-(level - knee) / (ceiling - knee)))
            let signed = (sample < 0 ? -limited : limited).rounded()
            let value = Int16(clamping: Int32(signed))
            let out = UInt16(bitPattern: value)
            result.append(UInt8(out & 255))
            result.append(UInt8(out >> 8))
        }
        return result
    }

    /// For the default replay, use the exact original server WAV to produce
    /// a separate playable version, keeping all non-zero speech samples in
    /// the same order and shortening long exact-zero silent gaps.
    static func improvedReplayWAV(_ wav: Data) throws -> Data {
        let pcm = try payloadOfCanonicalWave(wav)
        var compactor = DigitalSilenceCompactor()
        var compacted = compactor.process(pcm)

        // At the end of a *complete* response, 250 ms is enough of a tail.
        // Keep longer pauses within the sentence up to 650 ms.
        let endBytes = [UInt8](compacted)
        var last = endBytes.count
        while last >= 2 && endBytes[last - 1] == 0 && endBytes[last - 2] == 0 {
            last -= 2
        }
        let maxTailBytes = DigitalSilenceCompactor.sampleRate / 4 * 2
        if endBytes.count - last > maxTailBytes {
            compacted = Data(endBytes.prefix(last + maxTailBytes))
        }
        return try WavePCM.encode(raiseSpeechLevel(compacted))
    }

    private static func payloadOfCanonicalWave(_ wav: Data) throws -> Data {
        let bytes = [UInt8](wav)
        guard bytes.count >= 46,
            Array(bytes[0..<4]) == Array("RIFF".utf8),
            Array(bytes[8..<12]) == Array("WAVE".utf8),
            Array(bytes[12..<16]) == Array("fmt ".utf8),
            Array(bytes[36..<40]) == Array("data".utf8),
            read16(bytes, 20) == 1, read16(bytes, 22) == 1,
            read32(bytes, 24) == 24_000, read16(bytes, 34) == 16,
            read32(bytes, 40) == bytes.count - 44,
            read32(bytes, 4) == bytes.count - 8,
            (bytes.count - 44).isMultiple(of: 2) else {
            throw ProcessingError.unsupportedWave
        }
        return Data(bytes.dropFirst(44))
    }

    private static func read16(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i + 1]) << 8)
    }

    private static func read32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)
    }

    enum ProcessingError: Error { case unsupportedWave }
}
