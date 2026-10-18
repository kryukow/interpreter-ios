import Foundation

@main struct PlaybackTests {
    static func test(_ ok: Bool, _ message: String) {
        if !ok { fatalError(message) }
    }
    static func samples(_ list: [Int16]) -> Data {
        Data(list.flatMap { v in let n = UInt16(bitPattern: v); return [UInt8(n & 255), UInt8(n >> 8)] })
    }
    static func main() throws {
        let voice = samples([100, -100, 300, -300, 1000, -1000])
        let raised = TranslationPlaybackAudio.raiseSpeechLevel(voice)
        test(raised == samples([200, -200, 600, -600, 2000, -2000]), "Quiet voice gain is not 2x")

        let loud = samples([30_000, -30_000, Int16.max, Int16.min])
        let safe = TranslationPlaybackAudio.raiseSpeechLevel(loud)
        test(safe.count == loud.count, "Gain changed sample count")
        let signal = [UInt8](safe)
        for i in stride(from: 0, to: signal.count, by: 2) {
            let word = UInt16(signal[i]) | UInt16(signal[i+1]) << 8
            let value = Int32(Int16(bitPattern: word))
            test(abs(value) <= 32767, "Loud signal overflow")
        }

        let pause = Data(repeating: 0, count: 24_000 * 3 * 2)
        let tail = Data(repeating: 0, count: 24_000 * 12 * 2)
        let full = voice + pause + voice + tail
        let original = try WavePCM.encode(full)
        let improved = try TranslationPlaybackAudio.improvedReplayWAV(original)
        test(try WavePCM.decode(original) == full, "Original voice was modified")
        let inside = try WavePCM.decode(improved)
        let expected = raised
            + Data(repeating: 0, count: DigitalSilenceCompactor.retainedSilenceSamples * 2)
            + raised
            + Data(repeating: 0, count: DigitalSilenceCompactor.sampleRate / 4 * 2)
        test(inside == expected, "Pause/tail reduction or voice preservation failed")

        var damaged = original
        damaged[24] = 0
        do {
            _ = try TranslationPlaybackAudio.improvedReplayWAV(damaged)
            fatalError("Invalid WAV accepted")
        } catch TranslationPlaybackAudio.ProcessingError.unsupportedWave {}

        print("Translation playback and soft limiter tests passed")
    }
}
