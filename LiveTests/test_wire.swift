import Foundation

@main struct WireTests {
    static func expect(_ value: Bool, _ message: String) {
        if !value { fatalError(message) }
    }
    static func rejected(_ operation: () throws -> Void, _ message: String) {
        do { try operation(); fatalError(message) } catch { }
    }
    static func main() throws {
        let pcm = Data((0..<19_202).map { UInt8(truncatingIfNeeded: $0 * 37) })
        let wav = try WavePCM.encode(pcm)
        expect(try WavePCM.decode(wav) == pcm, "WAV round trip changed samples")
        let frames = try WavePCM.frames(pcm)
        expect(frames.map(\.count) == [9_600, 9_600, 2], "Short final frame padded or lost")
        expect(frames.reduce(into: Data()) { $0.append($1) } == pcm, "Frame ordering or samples changed")
        let exact = try WavePCM.frames(Data(pcm.prefix(19_200)))
        expect(exact.map(\.count) == [9_600, 9_600], "Exact boundary produced extra frame")
        let backing = Data(repeating: 11, count: 2) + pcm
        expect(try WavePCM.frames(backing.dropFirst(2)).reduce(into: Data()) { $0.append($1) } == pcm,
               "Non-zero Data indices corrupted frames")
        rejected({ _ = try WavePCM.frames(Data([1])) }, "Odd PCM accepted")
        rejected({ _ = try WavePCM.frames(Data()) }, "Empty PCM accepted")
        rejected({ _ = try WavePCM.frames(Data(repeating: 0, count: WavePCM.maximumInputBytes + 2)) },
                 "Overlong input accepted")
        rejected({ _ = try WavePCM.decode(Data(wav.dropLast())) }, "Truncated WAV accepted")
        var stereo = wav; stereo[22] = 2
        rejected({ _ = try WavePCM.decode(stereo) }, "Stereo accepted as mono")
        var wrongRate = wav; wrongRate[24] = 0
        rejected({ _ = try WavePCM.decode(wrongRate) }, "Incorrect rate accepted")
        var floating = wav; floating[20] = 3
        rejected({ _ = try WavePCM.decode(floating) }, "Float PCM accepted as int16")
        var oddData = wav; oddData[40] = 1; oddData[41] = 0; oddData[42] = 0; oddData[43] = 0
        rejected({ _ = try WavePCM.decode(oddData) }, "Odd data chunk accepted")
        var hugeChunk = wav
        for index in 40..<44 { hugeChunk[index] = 255 }
        rejected({ _ = try WavePCM.decode(hugeChunk) }, "Out-of-bounds chunk accepted")

        // A WAV recorder may add metadata. Unknown padded chunks must not alter PCM.
        let metadata = Data([74, 85, 78, 75, 3, 0, 0, 0, 9, 8, 7, 0]) // JUNK, size 3 + padding
        var decorated = wav
        decorated.insert(contentsOf: metadata, at: 12)
        let riffSize = UInt32(decorated.count - 8)
        for shift in 0..<4 { decorated[4 + shift] = UInt8((riffSize >> (shift * 8)) & 255) }
        expect(try WavePCM.decode(decorated) == pcm, "Metadata scan changed PCM")

        for target in ["ru", "de"] {
            let config = try JSONSerialization.jsonObject(with: Data(TranslationWire.configuration(target: target).utf8)) as! [String: Any]
            expect(config["type"] as? String == "session.update", "Wrong config event")
            let session = config["session"] as! [String: Any]
            let audio = session["audio"] as! [String: Any]
            let input = audio["input"] as! [String: Any]
            let output = audio["output"] as! [String: Any]
            expect(input["noise_reduction"] is NSNull, "Noise reduction not explicitly off")
            expect(input["transcription"] is NSNull, "Extra transcription not explicitly off")
            expect(output["language"] as? String == target, "Wrong target language")
            let created = Data("{\"type\":\"session.created\",\"session\":{\"model\":\"gpt-realtime-translate\"}}".utf8)
            if case .created = try TranslationWire.event(created) { } else { fatalError("Created not parsed") }
            let updated = Data("{\"type\":\"session.updated\",\"session\":{\"model\":\"gpt-realtime-translate\",\"audio\":{\"output\":{\"language\":\"\(target)\"}}}}".utf8)
            if case .updated(let actual) = try TranslationWire.event(updated) {
                expect(actual == target, "Server confirmation mismatch")
            } else { fatalError("Updated not parsed") }
        }
        rejected({ _ = try TranslationWire.configuration(target: "fr") }, "Unsupported target accepted")
        rejected({ _ = try TranslationWire.event(Data("{\"type\":\"session.created\",\"session\":{\"model\":\"other\"}}".utf8)) },
                 "Wrong model accepted")
        let append = try JSONSerialization.jsonObject(with: Data(TranslationWire.append(frames[2]).utf8)) as! [String: Any]
        expect(Data(base64Encoded: append["audio"] as! String) == frames[2], "Append changed short tail")
        let audioEvent = Data("{\"type\":\"session.output_audio.delta\",\"delta\":\"\(pcm.base64EncodedString())\"}".utf8)
        if case .audio(let received) = try TranslationWire.event(audioEvent) {
            expect(received == pcm, "Variable-length server delta truncated")
        } else { fatalError("Audio not parsed") }
        let textEvent = Data("{\"type\":\"session.output_transcript.delta\",\"delta\":\" Wort\"}".utf8)
        if case .text(let delta) = try TranslationWire.event(textEvent) {
            expect(delta == " Wort", "Transcript boundary changed")
        } else { fatalError("Text not parsed") }
        print("Fresh translation wire tests passed")
    }
}
