import AVFoundation
import Foundation

/// Plays the PCM16 translation stream after microphone release.
/// The original server audio is retained separately for free replay.
/// The byte audit checks fidelity *after* intentional removal of long exact-zero
/// silence and optional voice gain, not semantic translation accuracy.
/// Original server WAV is untouched.
@MainActor final class LiveStreamPlayer {
    private enum PlaybackError: Error { case invalidBuffer }

    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var pending: [Data] = []
    private var released = false
    private var confirmed = false
    private var closed = false
    private var failed = false
    private var outstanding = 0
    private var integrity = StreamAudioIntegrity()
    private var silenceCompactor = DigitalSilenceCompactor()
    private var token = UUID()
    private(set) var isPlaying = false

    var enhancePlayback = true
    var onStart: (() -> Void)?
    var onEnd: (() -> Void)?
    var onError: ((String) -> Void)?

    func append(_ pcm: Data) {
        guard !closed, !failed else { return }
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2) else {
            fail("Некорректный звуковой фрагмент. Можно прослушать полный ответ или озвучить текст.")
            return
        }
        // Server audio is archived unchanged by TranslationConnection.
        // Compact only exact digital silence for real-time presentation.
        let audible = silenceCompactor.process(pcm)
        guard !audible.isEmpty else { return }
        let prepared = enhancePlayback ? TranslationPlaybackAudio.raiseSpeechLevel(audible) : audible
        integrity.receive(prepared)
        pending.append(prepared)
        flush()
    }

    func confirmTranscript(_ text: String) {
        guard !failed else { return }
        confirmed = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        flush()
    }

    func microphoneReleased() {
        guard !failed else { return }
        released = true
        flush()
    }

    func complete() {
        guard !failed else { return }
        closed = true
        flush()
        // Every PCM byte must be scheduled in its original order before we
        // consider the stream complete; never silently discard a chunk.
        if confirmed && integrity.receivedBytes > 0 && !integrity.matches {
            fail("Потоковое аудио передано в плеер не полностью. Проверь полный ответ или озвучь текст.")
            return
        }
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
        failed = false
        integrity = StreamAudioIntegrity()
        silenceCompactor = DigitalSilenceCompactor()
        isPlaying = false
    }

    private func flush() {
        guard !failed, released, confirmed, !pending.isEmpty else { return }
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
            }
            guard let node else { throw PlaybackError.invalidBuffer }
            let current = token
            for pcm in pending {
                let count = pcm.count / 2
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                      let channel = buffer.floatChannelData?[0] else {
                    throw PlaybackError.invalidBuffer
                }
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
                integrity.schedule(pcm)
            }
            pending.removeAll()
            if !isPlaying {
                node.play()
                isPlaying = true
                onStart?()
            }
        } catch {
            fail("Не удалось воспроизвести поток без потерь. Проверь полный ответ или озвучь текст.")
        }
    }

    private func fail(_ message: String) {
        guard !failed else { return }
        stop()
        failed = true
        onError?(message)
    }

    private func checkCompletion() {
        guard !failed, closed, outstanding == 0 else { return }
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
