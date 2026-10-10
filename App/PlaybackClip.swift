import Foundation

enum PlaybackClip {
    struct Result { let pcm: Data; let leading: Double; let trailing: Double }
    static func trim(_ pcm: Data, sampleRate: Int = 24000) -> Result {
        guard !pcm.isEmpty, pcm.count % 2 == 0, sampleRate > 0 else {
            return Result(pcm: pcm, leading: 0, trailing: 0)
        }
        let bytes = [UInt8](pcm), frames = bytes.count / 2
        let window = max(1, sampleRate / 100)
        var levels: [(start: Int, end: Int, rms: Double, peak: Int)] = []
        for start in stride(from: 0, to: frames, by: window) {
            let end = min(frames, start + window)
            var power = 0.0, peak = 0
            for index in start..<end {
                let value = Int(Int16(bitPattern: UInt16(bytes[index * 2]) | UInt16(bytes[index * 2 + 1]) << 8))
                peak = max(peak, abs(value)); power += Double(value) * Double(value)
            }
            levels.append((start, end, sqrt(power / Double(end - start)), peak))
        }
        // Adapt only to a very low floor, never raise the speech threshold above
        // 128/32768 (-48 dBFS). Keep generous margins for quiet consonants.
        let sorted = levels.map { $0.rms }.sorted()
        let floor = sorted[(sorted.count - 1) / 10]
        let threshold = max(8, min(128, floor * 3))
        let audible = levels.filter { $0.rms > threshold || Double($0.peak) > threshold * 4 }
        guard let first = audible.first, let last = audible.last else {
            return Result(pcm: pcm, leading: 0, trailing: 0)
        }
        let start = max(0, first.start - sampleRate * 35 / 100)
        let end = min(frames, last.end + sampleRate * 45 / 100)
        return Result(pcm: pcm.subdata(in: start * 2..<end * 2),
                      leading: Double(start) / Double(sampleRate),
                      trailing: Double(frames - end) / Double(sampleRate))
    }
}
