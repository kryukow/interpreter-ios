import Foundation

/// An atomic snapshot of *unplayed* WebRTC render PCM. No additional network
/// request is needed to play these samples after the peer has closed.
struct WebRTCBufferedPCM {
    let bytes: Data
    let sampleRate: Int
    let channels: Int

    /// Canonical little-endian RIFF/WAV: PCM signed 16-bit, interleaved channels.
    /// The sample rate and channel count come from the actual RTC playout node,
    /// never from an assumption about the remote translation model.
    func wavData() -> Data? {
        let bytesPerFrame = channels * 2
        guard (channels == 1 || channels == 2),
              (8_000...192_000).contains(sampleRate),
              bytesPerFrame > 0,
              !bytes.isEmpty,
              bytes.count.isMultiple(of: bytesPerFrame),
              bytes.count < Int(UInt32.max) - 44 else { return nil }
        let sampleBytes = UInt32(bytes.count)
        var wav = Data(capacity: 44 + bytes.count)
        func add16(_ v: UInt16) {
            var value = v.littleEndian
            withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) }
        }
        func add32(_ v: UInt32) {
            var value = v.littleEndian
            withUnsafeBytes(of: &value) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: "RIFF".utf8)
        add32(sampleBytes + 36)
        wav.append(contentsOf: "WAVEfmt ".utf8)
        add32(16)
        add16(1)
        add16(UInt16(channels))
        add32(UInt32(sampleRate))
        add32(UInt32(sampleRate * bytesPerFrame))
        add16(UInt16(bytesPerFrame))
        add16(16)
        wav.append(contentsOf: "data".utf8)
        add32(sampleBytes)
        wav.append(bytes)
        return wav
    }
}
