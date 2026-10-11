import AVFoundation
import Foundation
import UIKit

/// 24 kHz PCM16 microphone capture with live 200 ms frame delivery.
/// Audio is retained in memory for the user's optional WAV export; no voice enhancement.
@MainActor final class NativeRecorder {
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var samples = Data()
    private var pending = Data()
    private var onMeter: ((Double, Double) -> Void)?
    private var onFrame: ((Data) -> Void)?
    private var onAutomaticStop: (() -> Void)?
    private var generation = UUID()
    private var active = false

    func preparePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func begin(onMeter: @escaping (Double, Double) -> Void,
               onFrame: @escaping (Data) -> Void,
               onAutomaticStop: @escaping () -> Void) throws {
        cancel()
        let token = generation
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        if let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try session.setPreferredInput(mic)
        }
        let engine = AVAudioEngine()
        let node = engine.inputNode
        let inputFormat = node.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved,
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                sampleRate: 24_000, channels: 1,
                                                interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw RecordingError.audioFormat
        }
        self.engine = engine
        self.converter = converter
        self.onMeter = onMeter
        self.onFrame = onFrame
        self.onAutomaticStop = onAutomaticStop
        active = true
        // Copy from the real-time audio thread; resample on the main queue.
        // The completion callback on release is enqueued after these frame callbacks.
        node.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                              frameCapacity: buffer.frameLength),
                  let source = buffer.floatChannelData,
                  let destination = copy.floatChannelData else { return }
            copy.frameLength = buffer.frameLength
            let size = Int(buffer.frameLength) * MemoryLayout<Float>.size
            for channel in 0..<Int(buffer.format.channelCount) {
                memcpy(destination[channel], source[channel], size)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.generation == token else { return }
                self.consume(copy)
            }
        }
        do {
            try engine.start()
            onMeter(0, 0)
        } catch {
            cancel()
            throw error
        }
    }

    private func consume(_ input: AVAudioPCMBuffer) {
        guard active, let converter else { return }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) *
                                            24_000 / input.format.sampleRate) + 256)
        guard let target = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                             frameCapacity: max(capacity, 512)) else { return }
        var delivered = false
        var failure: NSError?
        let status = converter.convert(to: target, error: &failure) { _, state in
            if delivered { state.pointee = .noDataNow; return nil }
            delivered = true
            state.pointee = .haveData
            return input
        }
        guard failure == nil, status != .error, target.frameLength > 0,
              let channel = target.int16ChannelData?[0] else { return }
        let byteCount = Int(target.frameLength) * 2
        let room = WavePCM.maximumInputBytes - samples.count
        guard room > 0 else { return }
        let length = min(byteCount, room)
        let pcm = Data(bytes: channel, count: length)
        samples.append(pcm)
        pending.append(pcm)
        while pending.count >= WavePCM.frameBytes {
            let frame = Data(pending.prefix(WavePCM.frameBytes))
            pending.removeFirst(WavePCM.frameBytes)
            onFrame?(frame)
        }
        var peak: Float = 0
        if let values = input.floatChannelData?[0] {
            for i in 0..<Int(input.frameLength) { peak = max(peak, abs(values[i])) }
        }
        onMeter?(Double(samples.count) / 48_000, min(1, Double(peak)))
        if samples.count >= WavePCM.maximumInputBytes { onAutomaticStop?() }
    }

    /// Stops the hardware immediately and drains already queued capture callbacks
    /// on the next main queue turn before committing the last (padded) frame.
    func finish(_ completion: @escaping (Result<Data, Error>) -> Void) {
        guard active else { completion(.failure(RecordingError.noRecording)); return }
        stopHardware()
        let token = generation
        // Do not invalidate the generation until the main-queue audio frames drain.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else {
                completion(.failure(RecordingError.noRecording)); return
            }
            do {
                if !self.pending.isEmpty {
                    var tail = self.pending
                    tail.append(Data(repeating: 0,
                                     count: WavePCM.frameBytes - tail.count))
                    self.onFrame?(tail)
                }
                let wav = try WavePCM.encode(self.samples)
                self.resetCapture()
                completion(.success(wav))
            } catch {
                self.resetCapture()
                completion(.failure(error))
            }
        }
    }

    func cancel() {
        stopHardware()
        resetCapture()
    }

    private func stopHardware() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func resetCapture() {
        generation = UUID()
        active = false
        converter = nil
        samples = Data()
        pending = Data()
        onMeter = nil
        onFrame = nil
        onAutomaticStop = nil
    }

    private enum RecordingError: LocalizedError {
        case audioFormat, noRecording
        var errorDescription: String? {
            switch self {
            case .audioFormat: return "Не удалось включить аудиовход iPhone (PCM 24 кГц)."
            case .noRecording: return "Запись отсутствует или отменена."
            }
        }
    }
}
