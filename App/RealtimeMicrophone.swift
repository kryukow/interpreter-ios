import AVFoundation
import Speech

@MainActor final class RealtimeMicrophone {
    private var engine: AVAudioEngine?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var deadline: Task<Void, Never>?
    private var diagnosticTask: SFSpeechRecognitionTask?
    private var diagnosticRecognizer: SFSpeechRecognizer?
    private var diagnosticRequest: SFSpeechAudioBufferRecognitionRequest?
    private var generation = UUID()

    func start(locale: String, onInputText: @escaping (String) -> Void) async throws -> AsyncThrowingStream<Data, Error> {
        stop()
        let token = generation
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        guard allowed else { throw Failure.message("Разреши микрофон в настройках iPhone.") }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        let engine = AVAudioEngine()
        let input = engine.inputNode, format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: target) else {
            throw Failure.message("Не удалось открыть микрофон для голосового перевода.")
        }
        var streamContinuation: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(128)) { streamContinuation = $0 }
        let delivery = streamContinuation!
        continuation = delivery
        // Optional microphone check, strictly on-device and never a second API call.
        var diagnostic: SFSpeechAudioBufferRecognitionRequest?
        if SFSpeechRecognizer.authorizationStatus() == .authorized,
           let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
           recognizer.isAvailable, recognizer.supportsOnDeviceRecognition {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
            diagnostic = request; diagnosticRequest = request
            diagnosticRecognizer = recognizer
            diagnosticTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
                guard let text = result?.bestTranscription.formattedString else { return }
                Task { @MainActor in
                    guard let self, self.generation == token else { return }; onInputText(text)
                }
            }
        }
        let diagnosticBuffer = diagnostic
        // The converter is confined to the audio tap, never used on another thread.
        var totalBytes = 0
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            diagnosticBuffer?.append(buffer)
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * target.sampleRate / format.sampleRate) + 64)
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var supplied = false, conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return buffer
            }
            guard status != .error, conversionError == nil else {
                delivery.finish(throwing: Failure.message("Не удалось преобразовать звук микрофона.")); return
            }
            guard output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
            let remaining = RealtimeProtocol.maximumSeconds * RealtimeProtocol.bytesPerSecond - totalBytes
            let count = min(Int(output.frameLength) * 2, max(0, remaining))
            if count > 0 {
                totalBytes += count
                let bytes = Data(bytes: samples, count: count)
                if case .dropped = delivery.yield(bytes) {
                    delivery.finish(throwing: Failure.message("Интернет не успевает передавать звук. Попробуй снова при устойчивом соединении."))
                }
            }
            if totalBytes >= RealtimeProtocol.maximumSeconds * RealtimeProtocol.bytesPerSecond { delivery.finish() }
        }
        self.engine = engine
        do { engine.prepare(); try engine.start() } catch { stop(); throw error }
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
        return stream
    }
    func stop() {
        generation = UUID()
        diagnosticRequest?.endAudio(); diagnosticTask?.cancel()
        diagnosticTask = nil; diagnosticRequest = nil; diagnosticRecognizer = nil
        deadline?.cancel(); deadline = nil
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        engine = nil
        continuation?.finish(); continuation = nil
    }
}
