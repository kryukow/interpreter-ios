import Foundation

@main struct InputAudioLevelTests {
    static func verify(_ ok: Bool, _ message: String) {
        if !ok { fatalError(message) }
    }
    static func frame(_ values: [Int16]) -> Data {
        Data(values.flatMap { value in
            let bits = UInt16(bitPattern: value)
            return [UInt8(bits & 255), UInt8(bits >> 8)]
        })
    }
    static func main() {
        let silence = InputAudioLevelMeter.measure(Data(repeating: 0, count: 9600))
        verify(silence.samples == 4800 && silence.zeroSamples == 4800,
               "Incorrect 200ms zero samples")
        verify(silence.rmsDBFS == nil && silence.peakDBFS == nil,
               "Digital silence should have -inf levels")

        let loud = InputAudioLevelMeter.measure(frame([32767, -32768]))
        verify(loud.samples == 2 && loud.zeroSamples == 0, "Extreme int16 sample failed")
        verify(abs((loud.rmsDBFS ?? -100)) < 0.001, "Near-full-scale RMS wrong")
        verify(abs((loud.peakDBFS ?? -100)) < 0.001, "Near-full-scale peak wrong")

        let mixed = InputAudioLevelMeter.measure(frame([0, 0, 16384, -16384]))
        verify(mixed.zeroPercent == 50, "Zero sample count incorrect")
        verify(abs((mixed.rmsDBFS ?? -100) + 9.0309) < 0.01, "RMS not calculated correctly")
        verify(abs((mixed.peakDBFS ?? -100) + 6.0206) < 0.01, "Peak not calculated correctly")
        verify(InputAudioLevelMeter.measure(Data()).samples == 0, "Empty input frame")
        print("Input PCM level metrics tests passed")
    }
}
