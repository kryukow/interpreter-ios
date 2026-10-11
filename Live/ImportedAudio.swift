import AVFoundation
import Foundation

/// Converts an audio attachment picked from Files into the same PCM16/24 kHz
/// mono transport format as the microphone. Does not write any source copy.
enum ImportedAudio {
    enum Failure: LocalizedError {
        case unsupported, tooLong, tooShort, conversion
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Не удалось открыть этот аудиофайл. Попробуй WAV, M4A, AAC или MP3."
            case .tooLong: return "Максимальная длительность аудиофайла — 60 секунд."
            case .tooShort: return "Аудиофайл слишком короткий для перевода."
            case .conversion: return "Не удалось преобразовать звук в PCM 24 кГц · моно."
            }
        }
    }

    static func read(url: URL) throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw Failure.unsupported }

        let inputFormat = file.processingFormat
        guard inputFormat.sampleRate > 0,
              Double(file.length) / inputFormat.sampleRate <= 60.01 else {
            throw Failure.tooLong
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 24_000,
            channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw Failure.conversion
        }

        var pcm = Data()
        while file.framePosition < file.length {
            let requested = min(4096, file.length - file.framePosition)
            guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                                frameCapacity: AVAudioFrameCount(requested)) else {
                throw Failure.conversion
            }
            do { try file.read(into: input) }
            catch { throw Failure.unsupported }
            guard input.frameLength > 0 else { break }

            // Account for resampling while preserving exact channel/sample format.
            let capacity = AVAudioFrameCount(
                ceil(Double(input.frameLength) * 24_000 / inputFormat.sampleRate) + 512
            )
            guard let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: max(512, capacity)
            ) else { throw Failure.conversion }

            var consumed = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, state in
                guard !consumed else {
                    state.pointee = .noDataNow
                    return nil
                }
                consumed = true
                state.pointee = .haveData
                return input
            }
            guard conversionError == nil, status != .error,
                  let channel = output.int16ChannelData?[0] else {
                throw Failure.conversion
            }
            if output.frameLength > 0 {
                pcm.append(Data(bytes: channel, count: Int(output.frameLength) * 2))
            }
            guard pcm.count <= WavePCM.maximumInputBytes else { throw Failure.tooLong }
        }
        guard pcm.count >= 4_800 else { throw Failure.tooShort }
        return pcm
    }
}
