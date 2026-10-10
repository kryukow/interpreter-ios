import Foundation

@main struct Tests {
    static func tone(_ value: Int16, seconds: Double) -> Data {
        let bits = UInt16(bitPattern: value)
        return Data((0..<Int(seconds * 24000)).flatMap { _ in [UInt8(bits & 255), UInt8(bits >> 8)] })
    }
    static func main() {
        let lead = tone(0, seconds: 3), tail = tone(0, seconds: 10)
        let quiet = tone(16, seconds: 0.2), speech = tone(1200, seconds: 1)
        var original = lead; original.append(quiet); original.append(speech); original.append(tail)
        let clip = PlaybackClip.trim(original)
        precondition(abs(clip.leading - 2.65) < 0.00001)
        precondition(abs(clip.trailing - 9.55) < 0.00001)
        let start = Int((clip.leading * 24000).rounded()) * 2
        precondition(clip.pcm == original.subdata(in: start..<(start + clip.pcm.count)))
        precondition(clip.pcm.count == Int(2 * 24000 * 2), "keep quiet onset and both margins")
        var pauses = speech; pauses.append(tone(0, seconds: 2)); pauses.append(quiet)
        precondition(PlaybackClip.trim(pauses).pcm == pauses, "keep interior silence and quiet ending")
        let silence = tone(0, seconds: 4)
        precondition(PlaybackClip.trim(silence).pcm == silence)
        precondition(PlaybackClip.trim(Data()).pcm.isEmpty)
        var noisy = tone(100, seconds: 3); noisy.append(speech); noisy.append(tone(100, seconds: 10))
        let adapted = PlaybackClip.trim(noisy)
        precondition(abs(adapted.leading - 2.65) < 0.00001 && abs(adapted.trailing - 9.55) < 0.00001)
        let short = tone(-32768, seconds: 0.01)
        precondition(PlaybackClip.trim(short).pcm == short, "safe negative PCM extremes")
        print("PASS playback clip: both edges, low-level floor, quiet words, internal pauses, exact PCM preservation")
    }
}
