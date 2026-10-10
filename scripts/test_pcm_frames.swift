import Foundation

@main struct Tests {
    static func main() {
        var frames = PCMFrames()
        let source = Data((0..<25000).map { UInt8($0 % 256) })
        var sent: [Data] = []
        for start in stride(from: 0, to: source.count, by: 2048) {
            sent += frames.append(source.subdata(in: start..<min(start + 2048, source.count)))
        }
        if let last = frames.finish() { sent.append(last) }
        precondition(sent.count == 3 && sent.allSatisfy { $0.count == 9600 })
        let combined = sent.reduce(into: Data()) { $0.append($1) }
        precondition(combined.prefix(source.count) == source)
        precondition(combined.suffix(combined.count - source.count).allSatisfy { $0 == 0 })
        precondition(frames.finish() == nil)
        let recorded = PCMFrames.recording(source)
        precondition(recorded == sent, "complete recording uses identical exact PCM packets")
        precondition(PCMFrames.recording(Data()).isEmpty)
        var exact = PCMFrames()
        precondition(exact.append(Data(repeating: 1, count: 9600)).count == 1 && exact.finish() == nil)
        print("PASS PCM frames: arbitrary microphone chunks, exact order, bounded tail padding, no duplicate flush")
    }
}
