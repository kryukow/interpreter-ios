import Foundation

struct TranslationReply {
    let text: String
    /// Complete response WAV. Empty when the service supplied text only.
    let audio: Data
}

@MainActor final class TranslationConnection {
    private var generation = UUID()
    private var currentSocket: URLSessionWebSocketTask?
    private var currentSender: Task<Void, Never>?

    func cancel() {
        generation = UUID()
        currentSender?.cancel(); currentSender = nil
        currentSocket?.cancel(with: .goingAway, reason: nil); currentSocket = nil
    }

    func run(key: String, pcm: Data, target: String,
             onText: @escaping @MainActor (String) -> Void,
             onProgress: @escaping @MainActor (Int) -> Void,
             onWaiting: @escaping @MainActor () -> Void) async throws -> TranslationReply {
        try Task.checkCancellation()
        let frames = try WavePCM.frames(pcm)
        let update = try TranslationWire.configuration(target: target)
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw WireError.authorization }
        cancel()
        let token = generation
        var request = URLRequest(url: TranslationWire.endpoint)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 110
        let session = URLSession(configuration: config)
        let socket = session.webSocketTask(with: request)
        currentSocket = socket
        var sender: Task<Void, Never>?
        var watchdog: Task<Void, Never>?
        var timedOut = false
        var sendError: Error?
        var sentBytes = 0
        var closeRequested = false
        var configured = false
        var created = false
        var text = ""
        var audio = Data()

        func armTimeout(_ seconds: Double) {
            watchdog?.cancel()
            watchdog = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                catch { return }
                timedOut = true
                sender?.cancel()
                socket.cancel(with: .goingAway, reason: nil)
            }
        }

        defer {
            watchdog?.cancel(); sender?.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
            if generation == token { currentSocket = nil; currentSender = nil }
        }
        socket.resume()
        armTimeout(20)

        do {
            return try await withTaskCancellationHandler {
                while true {
                    try Task.checkCancellation()
                    guard generation == token else { throw CancellationError() }
                    let message = try await socket.receive()
                    try Task.checkCancellation()
                    guard generation == token else { throw CancellationError() }
                    let data: Data
                    switch message {
                    case .string(let value): data = Data(value.utf8)
                    case .data(let value): data = value
                    @unknown default: throw WireError.invalidResponse
                    }
                    switch try TranslationWire.event(data) {
                    case .created:
                        guard !created else { throw WireError.invalidResponse }
                        created = true
                        try await socket.send(.string(update))
                    case .updated(let language):
                        guard created, language == target else { throw WireError.configuration }
                        guard !configured else { continue }
                        configured = true
                        armTimeout(Double(pcm.count) / Double(WavePCM.bytesPerSecond) + 40)
                        sender = Task { @MainActor in
                            do {
                                for (index, frame) in frames.enumerated() {
                                    try Task.checkCancellation()
                                    guard self.generation == token else { throw CancellationError() }
                                    try await socket.send(.string(try TranslationWire.append(frame)))
                                    try Task.checkCancellation()
                                    guard self.generation == token else { throw CancellationError() }
                                    sentBytes += frame.count
                                    onProgress(sentBytes)
                                    // Preserve source time rather than dumping a whole phrase at once.
                                    if index < frames.count - 1 {
                                        try await Task.sleep(nanoseconds: 200_000_000)
                                    }
                                }
                                try Task.checkCancellation()
                                guard self.generation == token else { throw CancellationError() }
                                closeRequested = true
                                try await socket.send(.string("{\"type\":\"session.close\"}"))
                                try Task.checkCancellation()
                                guard self.generation == token else { throw CancellationError() }
                                onWaiting()
                            } catch {
                                sendError = error
                                socket.cancel(with: .goingAway, reason: nil)
                            }
                        }
                        currentSender = sender
                    case .text(let delta):
                        guard configured else { throw WireError.invalidResponse }
                        text += delta
                        guard text.utf8.count <= 100_000 else { throw WireError.invalidResponse }
                        onText(text)
                    case .audio(let delta):
                        guard configured, audio.count + delta.count <= WavePCM.maximumOutputBytes else {
                            throw WireError.invalidResponse
                        }
                        audio.append(delta)
                    case .closed:
                        guard configured, closeRequested else { throw WireError.connection }
                        await sender?.value
                        try Task.checkCancellation()
                        guard generation == token else { throw CancellationError() }
                        if let sendError { throw sendError }
                        guard sentBytes == pcm.count else { throw WireError.sending }
                        return TranslationReply(text: text, audio: audio.isEmpty ? Data() : try WavePCM.encode(audio))
                    case .failure(let error): throw error
                    case .other: break
                    }
                }
            } onCancel: {
                // This closure owns only this request's socket; never cancel a newer run.
                socket.cancel(with: .goingAway, reason: nil)
            }
        } catch {
            if Task.isCancelled || generation != token { throw CancellationError() }
            if timedOut { throw WireError.timedOut }
            if sendError is CancellationError { throw CancellationError() }
            if sendError != nil { throw WireError.sending }
            if let known = error as? WireError { throw known }
            throw WireError.connection
        }
    }
}
