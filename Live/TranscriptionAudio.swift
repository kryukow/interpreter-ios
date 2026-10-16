import Foundation
import AVFoundation

struct PreparedTranscription {
    struct Part {
        let url: URL
        let seconds: Double
    }
    let folder: URL
    let filename: String
    let duration: Double
    let parts: [Part]

    func cleanup() { try? FileManager.default.removeItem(at: folder) }
}

/// File selection is explicit. Copy security-scoped/iCloud files locally, then
/// compress/split when necessary to respect the 25 MB transcription upload limit.
enum TranscriptionAudio {
    enum FileError: LocalizedError {
        case unsupported, empty, duration, compression, tooLarge, access
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Выбери аудиозапись M4A, MP3, WAV, MP4, AAC или CAF. Этот файл не является поддерживаемым аудио."
            case .access: return "Не удалось получить запись из «Файлов». Если файл в iCloud, сначала загрузи его на iPhone и повтори."
            case .empty: return "Выбран пустой аудиофайл."
            case .duration: return "Не удалось определить длительность записи."
            case .compression: return "Не удалось подготовить сжатый аудиофайл M4A."
            case .tooLarge: return "После сжатия один из фрагментов превышает лимит OpenAI — 25 МБ."
            }
        }
    }

    static func prepare(_ source: URL) async throws -> PreparedTranscription {
        let granted = source.startAccessingSecurityScopedResource()
        defer { if granted { source.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Interpreter-Transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try Task.checkCancellation()
            let name = source.lastPathComponent.isEmpty ? "recording.m4a" : source.lastPathComponent
            let safeName = name.replacingOccurrences(of: "/", with: "_")
            let supportedExtensions: Set<String> = [
                "m4a", "mp3", "mp4", "mpeg", "mpga", "wav", "aac", "caf", "aiff", "aif",
                "flac", "ogg", "opus", "webm"
            ]
            guard supportedExtensions.contains((safeName as NSString).pathExtension.lowercased()) else {
                throw FileError.unsupported
            }
            let copy = folder.appendingPathComponent(safeName)
            // A file-provider URL may be a lazy iCloud download. Coordinated
            // reading asks Files to make the bytes available before copying.
            // This runs off the main actor so even a 65-minute recording
            // cannot freeze the picker/UI while downloading or copying.
            var coordinationError: NSError?
            var copyingError: Error?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readableURL in
                do {
                    try FileManager.default.copyItem(at: readableURL, to: copy)
                } catch {
                    copyingError = error
                }
            }
            if coordinationError != nil || copyingError != nil { throw FileError.access }
            try Task.checkCancellation()
            let bytes = try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? NSNumber
            guard let bytes, bytes.intValue > 0 else { throw FileError.empty }

            let asset = AVURLAsset(url: copy)
            let time = try await asset.load(.duration)
            let seconds = time.seconds
            guard seconds.isFinite, seconds > 0 else { throw FileError.duration }

            let extensionName = copy.pathExtension.lowercased()
            let accepted = ["mp3", "mp4", "mpeg", "mpga", "m4a", "wav", "webm"].contains(extensionName)
            if seconds <= 540, bytes.intValue <= TranscriptionWire.maxBytes, accepted {
                return PreparedTranscription(folder: folder, filename: name,
                                             duration: seconds, parts: [.init(url: copy, seconds: seconds)])
            }

            // Chunks shorter than ten minutes bound the returned diarization text
            // and prevent large uncompressed Watch voice recordings from exceeding 25 MB.
            let chunkLength = TranscriptionWire.chunkSeconds
            var parts: [PreparedTranscription.Part] = []
            var position = 0.0
            while position < seconds - 0.01 {
                try Task.checkCancellation()
                let length = min(chunkLength, seconds - position)
                let output = folder.appendingPathComponent("part-\(parts.count + 1).m4a")
                guard let exporter = AVAssetExportSession(
                    asset: asset, presetName: AVAssetExportPresetAppleM4A
                ) else { throw FileError.compression }
                exporter.outputURL = output
                exporter.outputFileType = .m4a
                exporter.timeRange = CMTimeRange(
                    start: CMTime(seconds: position, preferredTimescale: 600),
                    duration: CMTime(seconds: length, preferredTimescale: 600)
                )
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        exporter.exportAsynchronously {
                            if exporter.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: exporter.error ?? FileError.compression)
                            }
                        }
                    }
                } onCancel: {
                    exporter.cancelExport()
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
                guard let size = attributes[.size] as? NSNumber,
                      size.intValue > 0, size.intValue <= TranscriptionWire.maxBytes else {
                    throw FileError.tooLarge
                }
                parts.append(.init(url: output, seconds: length))
                position += length
            }
            guard !parts.isEmpty else { throw FileError.empty }
            return PreparedTranscription(folder: folder, filename: name,
                                         duration: seconds, parts: parts)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}
