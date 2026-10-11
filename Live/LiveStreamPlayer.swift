import AVFoundation
import Foundation

/// Plays each translated PCM16 delta as soon as the microphone has stopped.
/// The original PCM stream is kept by TranslationConnection for free replay.
@MainActor final class LiveStreamPlayer {
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var pending: [Data] = []
    private var released = false
    private var confirmed = false
    private var closed = false
    private var outstanding = 0
    private var token = UUID()
    private(set) var isPlaying = false
    var onStart: (() -> Void)?
    var onEnd: (() -> Void)?

    func append(_ pcm: Data) {
        guard !closed, !pcm.isEmpty, pcm.count % 2 == 0 else { return }
        pending.append(pcm)
        flush()
    }

    func confirmTranscript(_ text: String) {
        confirmed = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        flush()
    }

    func microphoneReleased() {
        released = true
        flush()
    }

    func complete() {
        closed = true
        flush()
        checkCompletion()
    }

    func stop() {
        token = UUID()
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
        pending.removeAll()
        outstanding = 0
        released = false
        confirmed = false
        closed = false
        isPlaying = false
    }

    private func flush() {
        // Never feed the translated speaker output back into the microphone.
        // Also avoid auto-playing audio when the server never returned translation text.
        guard released, confirmed, !pending.isEmpty else { return }
        do {
            if node == nil {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
                let newEngine = AVAudioEngine()
                let newNode = AVAudioPlayerNode()
                newEngine.attach(newNode)
                newEngine.connect(newNode, to: newEngine.mainMixerNode, format: format)
                try newEngine.start()
                engine = newEngine
                node = newNode
                newNode.play()
                isPlaying = true
                onStart?()
            }
            guard let node else { return }
            let current = token
            for pcm in pending {
                let count = pcm.count / 2
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let channel = buffer.floatChannelData?[0] else { continue }
                buffer.frameLength = AVAudioFrameCount(count)
                pcm.withUnsafeBytes { raw in
                    for i in 0..<count {
                        let sample = raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                        channel[i] = Float(Int16(littleEndian: sample)) / 32768.0
                    }
                }
                outstanding += 1
                node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.token == current else { return }
                        self.outstanding -= 1
                        self.checkCompletion()
                    }
                }
            }
            pending.removeAll()
        } catch {
            stop()
            onEnd?()
        }
    }

    private func checkCompletion() {
        guard closed, outstanding == 0 else { return }
        if isPlaying {
            node?.stop()
            engine?.stop()
            node = nil
            engine = nil
            isPlaying = false
            onEnd?()
        }
    }
}
