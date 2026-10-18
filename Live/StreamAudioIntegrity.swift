import Foundation

/// Tracks the exact ordered PCM16 bytes received from OpenAI and submitted to
/// the streaming audio player. It cannot verify translation semantics.
struct StreamAudioIntegrity {
    private static let offset: UInt64 = 0xcbf29ce484222325
    private static let prime: UInt64 = 0x100000001b3

    private(set) var receivedBytes = 0
    private(set) var scheduledBytes = 0
    private var receivedFingerprint = offset
    private var scheduledFingerprint = offset

    mutating func receive(_ pcm: Data) {
        receivedBytes += pcm.count
        receivedFingerprint = Self.fold(pcm, into: receivedFingerprint)
    }

    mutating func schedule(_ pcm: Data) {
        scheduledBytes += pcm.count
        scheduledFingerprint = Self.fold(pcm, into: scheduledFingerprint)
    }

    var matches: Bool {
        receivedBytes == scheduledBytes && receivedFingerprint == scheduledFingerprint
    }

    private static func fold(_ data: Data, into initial: UInt64) -> UInt64 {
        var hash = initial
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* prime
        }
        return hash
    }
}
