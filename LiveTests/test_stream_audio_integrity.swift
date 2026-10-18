import Foundation

@main struct StreamAudioIntegrityTests {
    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func main() {
        let first = Data([0, 1, 2, 3])
        let second = Data([4, 5, 6, 7])

        var normal = StreamAudioIntegrity()
        normal.receive(first)
        normal.receive(second)
        normal.schedule(first)
        normal.schedule(second)
        expect(normal.matches, "In-order stream was rejected")
        expect(normal.receivedBytes == 8 && normal.scheduledBytes == 8, "Byte count changed")

        var missing = StreamAudioIntegrity()
        missing.receive(first)
        missing.receive(second)
        missing.schedule(first)
        expect(!missing.matches, "Missing audio was accepted")

        var reordered = StreamAudioIntegrity()
        reordered.receive(first)
        reordered.receive(second)
        reordered.schedule(second)
        reordered.schedule(first)
        expect(!reordered.matches, "Reordered audio was accepted")

        var changed = StreamAudioIntegrity()
        changed.receive(first)
        changed.schedule(Data([0, 1, 9, 3]))
        expect(!changed.matches, "Changed PCM data was accepted")

        print("Stream audio integrity tests passed")
    }
}
