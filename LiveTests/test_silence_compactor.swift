import Foundation

@main struct DigitalSilenceCompactorTests {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func samples(_ values: [Int16]) -> Data {
        Data(values.flatMap { v in
            let u = UInt16(bitPattern: v)
            return [UInt8(u & 255), UInt8(u >> 8)]
        })
    }

    static func main() {
        var compact = DigitalSilenceCompactor()
        let speechA = samples([1, -100, 32767, -32768, 3])
        let speechB = samples([7, -7, 23])
        let longPause = Data(repeating: 0, count: DigitalSilenceCompactor.sampleRate * 3 * 2)
        let afterSpeech = Data(repeating: 0, count: DigitalSilenceCompactor.sampleRate * 15 * 2)
        var out = Data()
        out.append(compact.process(speechA))
        // Split silence mid-PCM delta to test that the cap is cross-chunk.
        out.append(compact.process(Data(longPause.prefix(12_000))))
        out.append(compact.process(Data(longPause.dropFirst(12_000))))
        out.append(compact.process(speechB))
        out.append(compact.process(afterSpeech))

        let kept = Data(repeating: 0, count: DigitalSilenceCompactor.retainedSilenceSamples * 2)
        let expected = speechA + kept + speechB + kept
        check(out == expected, "Speech samples or silence cap changed")
        check(compact.droppedZeroSamples == DigitalSilenceCompactor.sampleRate * 18 - DigitalSilenceCompactor.retainedSilenceSamples * 2,
              "Wrong zero-sample count")

        var short = DigitalSilenceCompactor()
        let normalGap = Data(repeating: 0, count: 9_600) // 200 ms
        check(short.process(speechA + normalGap + speechB) == speechA + normalGap + speechB,
              "Natural short pause should remain untouched")

        var nearlySilent = DigitalSilenceCompactor()
        let quietNonZero = samples([1, -1, 1, -1]) + Data(repeating: 0, count: 9_600)
        check(nearlySilent.process(quietNonZero) == quietNonZero,
              "Non-zero audio or a 200-ms silence was mishandled")

        var extra = DigitalSilenceCompactor()
        check(extra.process(Data()) == Data(), "Empty input must remain empty")
        print("Digital silence compactor tests passed")
    }
}
