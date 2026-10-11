import AVFoundation
import Foundation

@MainActor final class NativeRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var meterTask: Task<Void, Never>?
    private var automaticStop: (() -> Void)?
    private var generation = UUID()
    private var recordingFailed = false

    func preparePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func begin(onMeter: @escaping (Double, Double) -> Void,
               onAutomaticStop: @escaping () -> Void) throws {
        cancel()
        let token = generation
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try session.setPreferredInput(builtIn)
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Interpreter-native-\(UUID().uuidString).wav")
            recordingURL = url
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 24_000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            self.recorder = recorder
            automaticStop = onAutomaticStop
            guard recorder.prepareToRecord(), recorder.record(forDuration: 60) else {
                throw RecordingError.cannotStart
            }
            onMeter(0, 0)
            meterTask = Task { [weak self, weak recorder] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled, let self, let recorder,
                          self.generation == token, self.recorder === recorder,
                          recorder.isRecording else { return }
                    recorder.updateMeters()
                    let level = min(1, max(0, pow(10, Double(recorder.averagePower(forChannel: 0)) / 20)))
                    onMeter(recorder.currentTime, level)
                }
            }
        } catch {
            cancel()
            throw error
        }
    }

    func finish() throws -> Data {
        guard let recorder, let url = recordingURL else { throw RecordingError.noRecording }
        let failed = recordingFailed
        generation = UUID()
        meterTask?.cancel(); meterTask = nil
        automaticStop = nil
        self.recorder = nil
        recorder.delegate = nil
        recorder.stop()
        defer {
            removeRecordingFile()
            deactivateSession()
        }
        guard !failed else { throw RecordingError.failedRecording }
        let wav = try Data(contentsOf: url)
        guard !wav.isEmpty else { throw RecordingError.emptyRecording }
        return wav
    }

    func cancel() {
        generation = UUID()
        meterTask?.cancel(); meterTask = nil
        automaticStop = nil
        recordingFailed = false
        let previous = recorder
        recorder = nil
        previous?.delegate = nil
        previous?.stop()
        removeRecordingFile()
        deactivateSession()
    }

    private func removeRecordingFile() {
        guard let url = recordingURL else { return }
        recordingURL = nil
        // This URL is assigned only when this instance creates its unique recording.
        try? FileManager.default.removeItem(at: url)
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            self.recordingFailed = self.recordingFailed || !flag
            self.meterTask?.cancel(); self.meterTask = nil
            let callback = self.automaticStop
            self.automaticStop = nil
            callback?()
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        audioRecorderDidFinishRecording(recorder, successfully: false)
    }

    private enum RecordingError: LocalizedError {
        case cannotStart, noRecording, emptyRecording, failedRecording
        var errorDescription: String? {
            switch self {
            case .cannotStart: return "Не удалось начать запись микрофона."
            case .noRecording: return "Запись микрофона отсутствует."
            case .emptyRecording: return "Микрофон вернул пустую запись."
            case .failedRecording: return "Запись микрофона завершилась с ошибкой. Попробуй ещё раз."
            }
        }
    }
}
