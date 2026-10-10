import Foundation

struct PCMFrames {
    static let frameBytes = 9600 // 200 ms, 24 kHz mono PCM16
    static func recording(_ pcm: Data) -> [Data] {
        var frames = PCMFrames()
        var result = frames.append(pcm)
        if let tail = frames.finish() { result.append(tail) }
        return result
    }
    private var pending = Data()
    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var result: [Data] = []
        while pending.count >= Self.frameBytes {
            result.append(Data(pending.prefix(Self.frameBytes)))
            pending.removeFirst(Self.frameBytes)
        }
        return result
    }
    mutating func finish() -> Data? {
        guard !pending.isEmpty else { return nil }
        var last = pending
        last.append(Data(repeating: 0, count: Self.frameBytes - last.count))
        pending = Data()
        return last
    }
}
