import AVFoundation
import Foundation

@MainActor final class RealtimeTranslation: NSObject, AVAudioPlayerDelegate {
    struct Result { let text: String; let audio: Data; let originalAudio: Data; let submittedAudio: Data?; let needsReview: Bool; let inputLevel: Double; let removedLeading: Double; let removedTrailing: Double; let inputSeconds: Double; let capturedSeconds: Double; let transcriptParts: Int; let audioParts: Int; let boostEnabled: Bool; let maximumInputGain: Double; let firstOutputSeconds: Double? }
    private let microphone = RealtimeMicrophone()
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var sending: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()
    private var player: AVAudioPlayer?
    private var preparedAudio: Data?
    private var playbackSessionActive = false
    private var playbackFinished: (() -> Void)?
    private var playbackWatch: Task<Void, Never>?

    func run(key: String, source: String, target: String, onReady: @escaping () -> Void,
             onFinishing: @escaping () -> Void, onText: @escaping (String) -> Void,
             onSubmitted: @escaping (Int) -> Void, onLevel: @escaping (Double) -> Void,
             onUploadProgress: @escaping (Double, Double) -> Void,
             onSubmittedAudio: @escaping (Data) -> Void, onWaiting: @escaping () -> Void,
             onInputText: @escaping (String) -> Void) async throws -> Result {
        try Task.checkCancellation()
        cancel()
        let token = generation
        var inputBytes = 0
        var inputLevel = 0.0
        var submittedPCM = Data()
        var capturedBytes = 0, transcriptParts = 0, audioParts = 0
        var closeRequested = false
        // Match the independent Windows control: complete the recording before
        // opening a paid session. Send immutable PCM, with no gain processing.
        var recording = Data()
        do {
            let chunks = try await microphone.start(locale: source == "ru" ? "ru-RU" : "de-DE", onInputText: onInputText)
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            onReady()
            for try await chunk in chunks {
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                guard recording.count + chunk.count <= RealtimeProtocol.maximumSeconds * RealtimeProtocol.bytesPerSecond else {
                    throw Failure.message("Запись превышает допустимую длительность.")
                }
                recording.append(chunk)
                let level = chunk.withUnsafeBytes { raw -> Double in
                    let samples = raw.bindMemory(to: Int16.self)
                    guard !samples.isEmpty else { return 0 }
                    let power = samples.reduce(0.0) { $0 + pow(Double($1) / 32768, 2) }
                    return min(1, sqrt(power / Double(samples.count)) * 8)
                }
                inputLevel = max(inputLevel, level); onLevel(level)
            }
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            microphone.stop()
            guard !recording.isEmpty else { throw Failure.message("В записи нет звука. Удерживай кнопку и говори после вибросигнала.") }
            capturedBytes = recording.count
            onFinishing()
        } catch {
            if generation == token { microphone.stop() }
            throw error
        }
        let packets = PCMFrames.recording(recording)
        var request = URLRequest(url: RealtimeProtocol.endpoint)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 100
        let session = URLSession(configuration: configuration), socket = session.webSocketTask(with: request)
        self.session = session; self.socket = socket
        socket.resume()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.microphone.stop(); socket.cancel(with: .goingAway, reason: nil)
        }
        var configured = false, text = "", audio = Data(), started: Date?, firstOutput: Double?, completed = false
        defer {
            if generation == token {
                microphone.stop(); sending?.cancel(); sending = nil; timeout?.cancel(); timeout = nil
                self.socket = nil; self.session = nil
            }
            socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel()
        }
        do {
            while !completed {
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                let message = try await socket.receive()
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                let data: Data
                switch message {
                case .string(let string): data = Data(string.utf8)
                case .data(let bytes): data = bytes
                @unknown default: throw RealtimeProtocol.ProtocolError.invalidEvent
                }
                switch try RealtimeProtocol.event(data) {
                case .created:
                    try await socket.send(.string(try RealtimeProtocol.configuration(target: target)))
                    try Task.checkCancellation()
                    guard generation == token else { throw CancellationError() }
                case .updated(let language):
                    guard !configured else { continue }
                    guard language == target else { throw Failure.message("OpenAI не подтвердил нужный язык перевода.") }
                    timeout?.cancel()
                    configured = true; started = Date()
                    sending = Task { [weak self] in
                        guard let self else { return }
                        do {
                            for frame in packets {
                                try Task.checkCancellation()
                                guard self.generation == token else { throw CancellationError() }
                                try await socket.send(.string(try RealtimeProtocol.append(frame)))
                                try Task.checkCancellation()
                                guard self.generation == token else { throw CancellationError() }
                                inputBytes += frame.count; submittedPCM.append(frame); onSubmitted(frame.count)
                                onUploadProgress(Double(inputBytes) / Double(RealtimeProtocol.bytesPerSecond),
                                                 Double(packets.count * PCMFrames.frameBytes) / Double(RealtimeProtocol.bytesPerSecond))
                                // Same 200 ms pacing as the confirmed working PC control.
                                try await Task.sleep(nanoseconds: 200_000_000)
                            }
                            guard self.generation == token, !Task.isCancelled else { return }
                            onSubmittedAudio(try RealtimeProtocol.wav(submittedPCM))
                            closeRequested = true
                            try await socket.send(.string("{\"type\":\"session.close\"}"))
                            try Task.checkCancellation()
                            guard self.generation == token else { throw CancellationError() }
                            onWaiting()
                            self.armTimeout(socket, token: token, seconds: 25)
                        } catch {
                            guard self.generation == token, !Task.isCancelled else { return }
                            socket.cancel(with: .goingAway, reason: nil)
                        }
                    }
                    // A stalled send/receive must not leave an open paid session indefinitely.
                    armTimeout(socket, token: token, seconds: 90)
                case .transcript(let delta):
                    transcriptParts += 1
                    if firstOutput == nil, let started { firstOutput = Date().timeIntervalSince(started) }
                    text += delta
                    guard text.utf8.count <= 100_000 else { throw Failure.message("Слишком длинный ответ голосового перевода.") }
                    onText(text)
                case .audio(let delta):
                    audioParts += 1
                    if firstOutput == nil, let started { firstOutput = Date().timeIntervalSince(started) }
                    guard audio.count + delta.count <= 12_000_000 else { throw Failure.message("Слишком длинный голосовой ответ.") }
                    audio.append(delta)
                case .closed:
                    guard configured else { throw Failure.message("OpenAI закрыл сессию до начала перевода.") }
                    guard closeRequested else { throw Failure.message("Сессия завершилась до отправки всей записи. Ответ не используется как полный перевод.") }
                    await sending?.value
                    try Task.checkCancellation()
                    guard generation == token else { throw CancellationError() }
                    guard inputBytes >= capturedBytes else { throw Failure.message("Запись отправлена не полностью. Ответ не используется как полный перевод.") }
                    completed = true
                case .failure(let message): throw Failure.message(message)
                case .other: break
                }
            }
            guard !audio.isEmpty else { throw Failure.message("Голосовой перевод не получен. Попробуй короткую чёткую фразу.") }
            let clip = PlaybackClip.trim(audio)
            let original = try RealtimeProtocol.wav(audio)
            let needsReview = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let submittedAudio = !submittedPCM.isEmpty ? try RealtimeProtocol.wav(submittedPCM) : nil
            // Do not trim an untranslated response. Preserve it for free local review.
            return Result(text: text, audio: try RealtimeProtocol.wav(clip.pcm),
                          originalAudio: original, submittedAudio: submittedAudio, needsReview: needsReview, inputLevel: inputLevel,
                          removedLeading: clip.leading, removedTrailing: clip.trailing,
                          inputSeconds: Double(inputBytes) / Double(RealtimeProtocol.bytesPerSecond),
                          capturedSeconds: Double(capturedBytes) / Double(RealtimeProtocol.bytesPerSecond),
                          transcriptParts: transcriptParts, audioParts: audioParts,
                          boostEnabled: false, maximumInputGain: 1, firstOutputSeconds: firstOutput)
        } catch let error as Failure { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled || generation != token { throw CancellationError() }
            throw Failure.message("Голосовое соединение прервалось. Проверь интернет, API-ключ, доступ к модели и баланс. Незавершённый перевод не озвучен.")
        }
    }
    private func armTimeout(_ socket: URLSessionWebSocketTask, token: UUID, seconds: UInt64) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.microphone.stop(); socket.cancel(with: .goingAway, reason: nil)
        }
    }
    func finish() { microphone.stop() }
    func play(_ audio: Data, onStarted: @escaping (Double) -> Void,
              onFailed: @escaping (String) -> Void, onFinished: @escaping () -> Void) throws {
        let requested = ProcessInfo.processInfo.systemUptime
        microphone.stop()
        let session = AVAudioSession.sharedInstance()
        if !playbackSessionActive {
            try session.setCategory(.playback, mode: .spokenAudio); try session.setActive(true)
            playbackSessionActive = true
        }
        let player: AVAudioPlayer
        if let cached = self.player, preparedAudio == audio { player = cached }
        else {
            player = try AVAudioPlayer(data: audio)
            guard player.prepareToPlay() else { throw Failure.message("Не удалось подготовить голосовой перевод.") }
            preparedAudio = audio
        }
        playbackWatch?.cancel()
        if player.isPlaying { player.pause() }
        player.currentTime = 0
        player.delegate = self; self.player = player; playbackFinished = onFinished
        guard player.play() else { self.player = nil; playbackFinished = nil; throw Failure.message("Не удалось воспроизвести голос OpenAI.") }
        playbackWatch?.cancel()
        playbackWatch = Task { [weak self, weak player] in
            var reported = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, let self, let player, self.player === player else { return }
                if !reported, player.currentTime > 0.02 {
                    reported = true
                    onStarted(max(0, ProcessInfo.processInfo.systemUptime - requested - player.currentTime))
                }
                // isPlaying can be false while an audio route starts. Never
                // interpret that transient as completion or rewind the clip.
                if reported, !player.isPlaying, player.currentTime >= player.duration - 0.03 {
                    self.finishPlayback(player); return
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - requested
                if (!reported && elapsed > 12) || elapsed > player.duration + 20 {
                    self.cancel()
                    onFailed("Плеер не начал или не завершил воспроизведение. Проверь вывод звука iPhone.")
                    return
                }
            }
        }
    }
    func cancel() {
        generation = UUID(); microphone.stop(); sending?.cancel(); sending = nil
        timeout?.cancel(); timeout = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
        player?.stop(); player = nil; playbackFinished = nil
        preparedAudio = nil; playbackSessionActive = false
        playbackWatch?.cancel(); playbackWatch = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.finishPlayback(player)
        }
    }
    private func finishPlayback(_ player: AVAudioPlayer) {
        guard self.player === player, !player.isPlaying, playbackFinished != nil else { return }
        playbackWatch?.cancel(); playbackWatch = nil
        let callback = playbackFinished; playbackFinished = nil
        callback?()
        player.currentTime = 0; player.prepareToPlay()
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }
}
