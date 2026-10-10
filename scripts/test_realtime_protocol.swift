import Foundation

@main struct Tests {
    static func main() throws {
        let configuration = try JSONSerialization.jsonObject(with: Data(try RealtimeProtocol.configuration(target: "de").utf8)) as! [String: Any]
        precondition(configuration["type"] as? String == "session.update")
        let session = configuration["session"] as! [String: Any]
        let audio = session["audio"] as! [String: Any]
        precondition((audio["output"] as! [String: Any])["language"] as? String == "de")
        precondition((audio["input"] as! [String: Any])["transcription"] == nil, "no second billed transcription model")
        let russian = try JSONSerialization.jsonObject(with: Data(try RealtimeProtocol.configuration(target: "ru").utf8)) as! [String: Any]
        let ruAudio = (russian["session"] as! [String: Any])["audio"] as! [String: Any]
        precondition((ruAudio["output"] as! [String: Any])["language"] as? String == "ru", "German input requests Russian output")
        let updatedRU = try RealtimeProtocol.event(Data("{\"type\":\"session.updated\",\"session\":{\"model\":\"gpt-realtime-translate\",\"audio\":{\"output\":{\"language\":\"ru\"}}}}".utf8))
        guard case .updated("ru") = updatedRU else { fatalError("Russian confirmation lost") }
        let pcm = Data([0, 0, 255, 127, 0, 128, 1, 0])
        let appended = try JSONSerialization.jsonObject(with: Data(try RealtimeProtocol.append(pcm).utf8)) as! [String: Any]
        precondition(appended["type"] as? String == "session.input_audio_buffer.append")
        precondition(Data(base64Encoded: appended["audio"] as! String) == pcm)
        var transcript = ""
        for delta in ["Als ", "wir zusam", "men gingen."] {
            let event = try RealtimeProtocol.event(JSONSerialization.data(withJSONObject: ["type": "session.output_transcript.delta", "delta": delta, "elapsed_ms": 200]))
            guard case .transcript(let text) = event else { fatalError("wrong transcript event") }
            transcript += text
        }
        precondition(transcript == "Als wir zusammen gingen.", "append every delta without added spaces or elapsed_ms deduplication")
        let event = try RealtimeProtocol.event(JSONSerialization.data(withJSONObject: ["type": "session.output_audio.delta", "delta": pcm.base64EncodedString(), "sample_rate": 24000, "channels": 1]))
        guard case .audio(let decoded) = event else { fatalError("wrong audio event") }
        precondition(decoded == pcm)
        let wav = try RealtimeProtocol.wav(pcm)
        precondition(wav.count == pcm.count + 44)
        precondition(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        precondition(wav.suffix(pcm.count) == pcm)
        precondition(Array(wav[24..<28]) == [192, 93, 0, 0], "24 kHz little endian WAV")
        for invalid in ["{\"type\":\"session.output_audio.delta\",\"delta\":\"bad!\"}", "{\"type\":\"session.output_audio.delta\",\"delta\":\"AAA=\",\"sample_rate\":48000}"] {
            do { _ = try RealtimeProtocol.event(Data(invalid.utf8)); fatalError("accepted invalid audio") } catch {}
        }
        do { _ = try RealtimeProtocol.configuration(target: "xx"); fatalError("accepted unknown direction") } catch {}
        let failure = try RealtimeProtocol.event(Data("{\"type\":\"error\",\"error\":{\"code\":\"insufficient_quota\",\"message\":\"private secret\"}}".utf8))
        guard case .failure(let text) = failure else { fatalError("wrong error event") }
        precondition(!text.contains("private secret"))
        guard case .closed = try RealtimeProtocol.event(Data("{\"type\":\"session.closed\"}".utf8)) else { fatalError("missing completion") }
        print("PASS: translation protocol, WAV, completion")
    }
}
