import Foundation

@main struct WebRTCLocalTailTests {
    static func check(_ ok: Bool, _ message: String) {
        if !ok { fatalError(message) }
    }

    @discardableResult
    static func render(_ gate: WebRTCDelayedAudioGate, _ data: [UInt8]) -> [UInt8] {
        var output = data
        output.withUnsafeMutableBytes {
            _ = gate.process($0.baseAddress!, byteCount: $0.count)
        }
        return output
    }

    static func u16(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | Int(b[i+1]) << 8
    }
    static func u32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | Int(b[i+1]) << 8 |
        Int(b[i+2]) << 16 | Int(b[i+3]) << 24
    }

    static func main() {
        let gate = WebRTCDelayedAudioGate(capacityBytes: 1024, maxZeroBytes: 16)
        gate.setOutputPCMFormat(sampleRate: 48_000, channels: 2)
        gate.startCapture()
        let a: [UInt8] = [1,0,2,0]
        let b: [UInt8] = [3,0,4,0]
        check(render(gate, a) == [0,0,0,0], "Capture leaked samples")
        check(render(gate, b) == [0,0,0,0], "Capture leaked second chunk")
        check(gate.pendingBytes == 8, "Capture did not buffer both chunks")
        gate.startDrain()
        check(render(gate, [0,0,0,0]) == a, "First chunk was not played in order")
        // A stalled WebRTC source stops invoking the render callback here.
        let remaining = gate.consumeRemainingPCM()
        check(remaining != nil, "Tail snapshot was empty")
        guard let remaining else { return }
        check(Array(remaining.bytes.prefix(4)) == b, "Tail lost or reordered second chunk")
        check(gate.pendingBytes == 0, "Tail was not atomically removed")
        check(gate.consumeRemainingPCM() == nil, "Tail was played twice")

        guard let wav = remaining.wavData() else {
            fatalError("Valid WebRTC stereo PCM could not be converted to WAV")
        }
        let header = [UInt8](wav.prefix(44))
        check(String(decoding: header[0..<4], as: UTF8.self) == "RIFF", "RIFF marker")
        check(String(decoding: header[8..<12], as: UTF8.self) == "WAVE", "WAVE marker")
        check(u16(header, 22) == 2, "Stereo channel count was lost")
        check(u32(header, 24) == 48_000, "WebRTC sample rate was ignored")
        check(u16(header, 34) == 16, "Not signed PCM16")
        check(u32(header, 40) == remaining.bytes.count, "WAV length is incorrect")
        check(Array(wav.dropFirst(44)) == Array(remaining.bytes), "PCM altered during WAV conversion")

        let mono = WebRTCBufferedPCM(bytes: Data([7,0,8,0]),
                                      sampleRate: 44_100, channels: 1)
        guard let monoWav = mono.wavData() else { fatalError("Mono WAV unavailable") }
        check(u32([UInt8](monoWav), 24) == 44_100, "Wrong mono sample rate")
        check(WebRTCBufferedPCM(bytes: Data([1,2]), sampleRate: 0, channels: 1).wavData() == nil,
              "Unknown format must not be played at invented sample rate")
        check(WebRTCBufferedPCM(bytes: Data([1,2]), sampleRate: 48_000, channels: 2).wavData() == nil,
              "Misaligned multichannel PCM must be refused")
        print("Local WebRTC PCM tail snapshot and exact RIFF/WAV conversion passed")
    }
}
