import AVFoundation
import Speech

@MainActor final class SpeechCapture {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var tapped = false
    private var generation = UUID()
    private var deadline: Task<Void, Never>?
    private var transcript = SpeechTranscript()

    func start(locale: String, onText: @escaping (String) -> Void,
               onEnd: @escaping (Error?) -> Void, onLevel: @escaping (Double) -> Void) async throws {
        cancel()
        transcript = SpeechTranscript()
        let token = generation
        let auth = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        guard auth == .authorized, mic else { throw Failure.message("Разреши микрофон и распознавание речи в настройках iPhone.") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            throw Failure.message("Распознавание этого языка сейчас недоступно.")
        }
        self.recognizer = recognizer
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Apple may use its server when on-device recognition is unavailable.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true
            let first = result?.bestTranscription.segments.first?.timestamp
            let last = result?.bestTranscription.segments.last
            let end = last.map { $0.timestamp + $0.duration }
            let stable = result?.speechRecognitionMetadata != nil
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if let text {
                    onText(self.transcript.receive(text, start: first, end: end, stable: stable))
                }
                if final || error != nil {
                    self.cancel()
                    onEnd(error)
                }
            }
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            cancel(); throw Failure.message("Микрофон недоступен.")
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var power = 0.0
            for index in 0..<Int(buffer.frameLength) { power += Double(samples[index]) * Double(samples[index]) }
            let level = min(1, sqrt(power / Double(buffer.frameLength)) * 8)
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }; onLevel(level)
            }
        }
        tapped = true
        do { engine.prepare(); try engine.start() } catch { cancel(); throw error }
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 55_000_000_000)
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.finish(onTimeout: onEnd)
        }
    }
    func finish(onTimeout: @escaping (Error?) -> Void) {
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        request?.endAudio()
        deadline?.cancel()
        let token = generation
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.cancel(); onTimeout(nil)
        }
    }
    func cancel() {
        generation = UUID(); deadline?.cancel(); deadline = nil
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        task?.cancel(); task = nil; request = nil; recognizer = nil
    }
}
