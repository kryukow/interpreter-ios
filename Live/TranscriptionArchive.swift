import Foundation

/// One resumable transcript is kept locally in Application Support.
/// No audio or text is uploaded anywhere except the selected OpenAI transcription call.
struct SavedTranscriptJob: Codable {
    var folderName: String
    var filename: String
    var duration: Double
    var partNames: [String]
    var partSeconds: [Double]
    var mode: String
    var hint: String
    var completed: [Int: String]
    var languages: [String]
    var unknownCharges: [Int]
}

enum TranscriptionArchive {
    private static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    private static var index: URL {
        support.appendingPathComponent("InterpreterTranscript-current.json")
    }

    static func read() -> (SavedTranscriptJob, PreparedTranscription)? {
        guard let data = try? Data(contentsOf: index),
              let saved = try? JSONDecoder().decode(SavedTranscriptJob.self, from: data),
              saved.folderName.hasPrefix("Interpreter-Transcript-"),
              saved.partNames.count == saved.partSeconds.count,
              !saved.partNames.isEmpty else { return nil }
        let folder = support.appendingPathComponent(saved.folderName, isDirectory: true)
        let parts = zip(saved.partNames, saved.partSeconds).map { name, seconds in
            PreparedTranscription.Part(url: folder.appendingPathComponent(name), seconds: seconds)
        }
        guard parts.allSatisfy({ $0.url.deletingLastPathComponent() == folder &&
            FileManager.default.fileExists(atPath: $0.url.path) }) else { return nil }
        return (saved, PreparedTranscription(folder: folder, filename: saved.filename,
                                            duration: saved.duration, parts: parts))
    }

    static func make(_ prepared: PreparedTranscription,
                     mode: TranscriptionMode,
                     hint: TranscriptionLanguageHint) -> SavedTranscriptJob {
        SavedTranscriptJob(folderName: prepared.folder.lastPathComponent,
                           filename: prepared.filename, duration: prepared.duration,
                           partNames: prepared.parts.map { $0.url.lastPathComponent },
                           partSeconds: prepared.parts.map(\.seconds),
                           mode: mode.rawValue, hint: hint.rawValue,
                           completed: [:], languages: [], unknownCharges: [])
    }

    static func write(_ saved: SavedTranscriptJob) throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: index, options: .atomic)
    }

    static func remove(_ saved: SavedTranscriptJob) {
        try? FileManager.default.removeItem(at: index)
        let folder = support.appendingPathComponent(saved.folderName, isDirectory: true)
        if folder.lastPathComponent.hasPrefix("Interpreter-Transcript-") {
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
