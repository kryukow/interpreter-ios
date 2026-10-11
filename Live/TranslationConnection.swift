import Foundation

struct TranslationReply {
    let text: String
    /// Complete response WAV for free replay. Empty for text-only results.
    let audio: Data
}

/// A single WebSocket translation session per held phrase.
/// Microphone audio enters the outgoing queue in real time, not after release.
@MainActor final class TranslationConnection {
    private var generation = UUID()
    private var currentSocket: URLSessionWebSocketTask?
    private var currentSession: URLSession?
    private var receiver: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var frames: [Data] = []
    private var ready = false
    private var inputEnded = false
    private var closeSent = false
    private var sentBytes = 0
    private var receivedBytes = 0
    private var text = ""
    private var audio = Data()
    private var onText: ((String) -> Void)?
    private var onAudio: ((Data) -> Void)?
    private var onProgress: ((Int) -> Void)?
    private var onWaiting: (() -> Void)?
    private var onFinished: ((Result<TranslationReply, Error>) -> Void)?

    func cancel() {
        generation = UUID()
        sender?.cancel()
        receiver?.cancel()
        watchdog?.cancel()
        currentSocket?.cancel(with: .goingAway, reason: nil)
        currentSession?.invalidateAndCancel()
        receiver = nil; sender = nil; watchdog = nil
        currentSocket = nil; currentSession = nil
        frames.removeAll()
        ready = false; inputEnded = false; closeSent = false
        sentBytes = 0; receivedBytes = 0
        text = ""; audio = Data()
        onText = nil; onAudio = nil; onProgress = nil
        onWaiting = nil; onFinished = nil
    }

    func start(key: String, target: String,
               onText: @escaping (String) -> Void,
               onAudio: @escaping (Data) -> Void,
               onProgress: @escaping (Int) -> Void,
               onWaiting: @escaping () -> Void,
               onFinished: @escaping (Result<TranslationReply, Error>) -> Void) throws {
        let update = try TranslationWire.configuration(target: target)
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WireError.authorization
        }
        cancel()
        let token = generation
        self.onText = onText; self.onAudio = onAudio
        self.onProgress = onProgress; self.onWaiting = onWaiting
        self.onFinished = onFinished

        var request = URLRequest(url: TranslationWire.endpoint)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config)
        let socket = session.webSocketTask(with: request)
        currentSession = session
        currentSocket = socket
        socket.resume()
        armTimeout(20, token: token)

        receiver = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled, self.generation == token {
                    let message = try await socket.receive()
                    guard !Task.isCancelled, self.generation == token else { return }
                    let data: Data
                    switch message {
                    case .string(let value): data = Data(value.utf8)
                    case .data(let value): data = value
                    @unknown default: throw WireError.invalidResponse
                    }
                    switch try TranslationWire.event(data) {
                    case .created:
                        try await socket.send(.string(update))
                    case .updated(let targetLanguage):
                        guard targetLanguage == target else { throw WireError.configuration }
                        self.ready = true
                        self.armTimeout(100, token: token)
                        self.pump(token)
                    case .text(let delta):
                        self.text += delta
                        guard self.text.utf8.count <= 100_000 else { throw WireError.invalidResponse }
                        self.onText?(self.text)
                    case .audio(let pcm):
                        guard self.audio.count + pcm.count <= WavePCM.maximumOutputBytes else {
                            throw WireError.invalidResponse
                        }
                        self.audio.append(pcm)
                        self.onAudio?(pcm)
                    case .closed:
                        guard self.closeSent, self.sentBytes == self.receivedBytes else {
                            throw WireError.sending
                        }
                        let wave = self.audio.isEmpty || self.audio.allSatisfy({ $0 == 0 })
                            ? Data() : try WavePCM.encode(self.audio)
                        self.complete(.success(TranslationReply(text: self.text, audio: wave)), token: token)
                        return
                    case .failure(let error): throw error
                    case .other: break
                    }
                }
            } catch {
                guard self.generation == token else { return }
                self.complete(.failure(error is WireError ? error : WireError.connection), token: token)
            }
        }
    }

    /// Frames must be exactly 200 ms of PCM16 mono/24 kHz.
    func append(_ pcm: Data) {
        guard !inputEnded, pcm.count == WavePCM.frameBytes,
              receivedBytes + pcm.count <= WavePCM.maximumInputBytes + WavePCM.frameBytes else { return }
        frames.append(pcm)
        receivedBytes += pcm.count
        pump(generation)
    }

    func finishInput() {
        guard !inputEnded else { return }
        inputEnded = true
        pump(generation)
    }

    private func pump(_ token: UUID) {
        guard ready, sender == nil, let socket = currentSocket,
              !closeSent, generation == token else { return }
        sender = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled, self.generation == token {
                    if !self.frames.isEmpty {
                        let frame = self.frames.removeFirst()
                        try await socket.send(.string(try TranslationWire.append(frame)))
                        guard self.generation == token else { return }
                        self.sentBytes += frame.count
                        self.onProgress?(self.sentBytes)
                    } else if self.inputEnded {
                        self.closeSent = true
                        try await socket.send(.string("{\"type\":\"session.close\"}"))
                        guard self.generation == token else { return }
                        self.armTimeout(35, token: token)
                        self.onWaiting?()
                        break
                    } else {
                        break
                    }
                }
                if self.generation == token {
                    self.sender = nil
                    if !self.frames.isEmpty || (self.inputEnded && !self.closeSent) {
                        self.pump(token)
                    }
                }
            } catch {
                guard self.generation == token else { return }
                self.complete(.failure(WireError.sending), token: token)
            }
        }
    }

    private func armTimeout(_ seconds: Double, token: UUID) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            guard let self, self.generation == token else { return }
            self.complete(.failure(WireError.timedOut), token: token)
        }
    }

    private func complete(_ result: Result<TranslationReply, Error>, token: UUID) {
        guard generation == token else { return }
        let callback = onFinished
        cancel()
        callback?(result)
    }
}
