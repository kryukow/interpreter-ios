import Foundation

@main struct WebRTCDelayedAudioGateTests {
    static func check(_ condition: Bool, _ reason: String) {
        if !condition { fatalError(reason) }
    }
    static func frame(_ gate: WebRTCDelayedAudioGate, _ src: [UInt8]) -> [UInt8] {
        var copy = src
        copy.withUnsafeMutableBytes {
            gate.process($0.baseAddress!, byteCount: $0.count)
        }
        return copy
    }
    static func main() {
        let gate = WebRTCDelayedAudioGate(capacityBytes: 4096, maxZeroBytes: 16)
        let a: [UInt8] = [10,0,20,0]
        let b: [UInt8] = [30,0,40,0]
        check(frame(gate,a) == a, "Direct-mode audio was changed")
        gate.startCapture()
        check(frame(gate,a) == [0,0,0,0], "Audio leaked while speaking")
        check(frame(gate,b) == [0,0,0,0], "Second audio leaked while speaking")
        check(gate.pendingBytes == 8, "Buffered audio missing")
        gate.startDrain()
        check(frame(gate,[0,0,0,0]) == a, "First syllable lost at release")
        check(frame(gate,[0,0,0,0]) == b, "Second syllable order changed")
        check(frame(gate,[0,0,0,0]) == [0,0,0,0], "Unexpected audio after release")
        gate.reset()
        check(frame(gate,a) == a, "Reset did not restore direct mode")

        // Silence trimming keeps at least some pause but avoids 20s tails.
        let padded = WebRTCDelayedAudioGate(capacityBytes: 2048, maxZeroBytes: 8)
        padded.startCapture()
        _ = frame(padded, a)
        for _ in 0..<100 { _ = frame(padded, [0,0,0,0]) }
        check(padded.pendingBytes == a.count + 8,
              "Long server-silent tail was retained")
        padded.startDrain()
        check(frame(padded, [0,0,0,0]) == a, "Word samples changed")
        print("WebRTC buffered Push-to-Talk PCM tests passed")
    }
}
