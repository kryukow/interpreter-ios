import AVFoundation
import Foundation

/// Caps the reference BEFORE it enters the fixed-shape Core ML voice encoders.
/// The source recording is never modified, and existing saved voices are untouched.
/// The model uses 24 kHz and 16 kHz paths. Twenty seconds is safely below the
/// 640,000-sample upper bound even at the higher 24 kHz rate.
enum VoiceReferenceClip {
    static let maximumSeconds = 20.0

    struct Prepared {
        let url: URL
        let clipped: Bool
    }

    static func limitedFrameCount(sampleRate: Double, totalFrames: Int64) -> Int64 {
        guard sampleRate.isFinite, sampleRate > 0, totalFrames > 0 else { return 0 }
        let limit = Int64((sampleRate * maximumSeconds).rounded(.down))
        return min(totalFrames, limit)
    }

    static func prepare(_ originalURL: URL) throws -> Prepared {
        let audio = try AVAudioFile(forReading: originalURL)
        let format = audio.processingFormat
        let frameLimit = limitedFrameCount(
            sampleRate: format.sampleRate,
            totalFrames: audio.length
        )
        guard frameLimit > 0 else { throw ClipError.invalidAudio }
        guard frameLimit < audio.length else {
            // Leave short clips exactly as they are, without re-encoding.
            return Prepared(url: originalURL, clipped: false)
        }
        guard frameLimit <= Int64(UInt32.max),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameLimit)
              )
        else { throw ClipError.invalidAudio }

        try audio.read(into: buffer, frameCount: AVAudioFrameCount(frameLimit))
        guard buffer.frameLength > 0 else { throw ClipError.invalidAudio }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-reference-\(UUID().uuidString).wav")
        do {
            // Explicit 32-bit PCM WAV. The cloner decodes and resamples this
            // locally to its 24/16 kHz model inputs.
            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: format.sampleRate,
                channels: format.channelCount,
                interleaved: false
            ) else { throw ClipError.invalidAudio }
            let output = try AVAudioFile(
                forWriting: temporaryURL,
                settings: outputFormat.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try output.write(from: buffer)
            return Prepared(url: temporaryURL, clipped: true)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    enum ClipError: LocalizedError {
        case invalidAudio
        var errorDescription: String? {
            "Не удалось подготовить образец голоса. Проверь аудиофайл или запиши его заново."
        }
    }
}
