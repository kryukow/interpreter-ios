import SwiftUI
import UniformTypeIdentifiers

@MainActor final class TranscriptionSession: ObservableObject {
    enum Stage { case idle, preparing, ready, processing, complete }

    @Published var mode: TranscriptionMode = .single
    @Published private(set) var stage: Stage = .idle
    @Published private(set) var filename = ""
    @Published private(set) var duration: Double = 0
    @Published private(set) var progress = ""
    @Published private(set) var transcript = ""
    @Published private(set) var detectedLanguages: [String] = []
    @Published private(set) var errorMessage: String?
    private var prepared: PreparedTranscription?
    private var task: Task<Void, Never>?
    private var requestID = UUID()

    var estimatedPrice: Double { mode.price(for: duration) }
    var ready: Bool { stage == .ready && prepared != nil }
    var working: Bool { stage == .preparing || stage == .processing }

    func selectFile(_ url: URL) {
        reset()
        let token = requestID
        stage = .preparing
        progress = "Подготавливаю аудиозапись"
        task = Task {
            do {
                let selection = try await TranscriptionAudio.prepare(url)
                guard requestID == token, !Task.isCancelled else {
                    selection.cleanup()
                    return
                }
                prepared = selection
                filename = selection.filename
                duration = selection.duration
                stage = .ready
                progress = selection.parts.count > 1
                    ? "Запись будет обработана по частям: \(selection.parts.count)"
                    : "Готово к расшифровке"
            } catch {
                guard requestID == token else { return }
                stage = .idle
                progress = ""
                errorMessage = error.localizedDescription
            }
        }
    }

    func start(account: LiveSession) {
        guard ready, let selection = prepared else { return }
        guard let key = try? LiveKey.read(), !key.isEmpty else {
            errorMessage = "Сначала добавь API-ключ в настройках."
            return
        }
        let token = requestID
        let selectedMode = mode
        stage = .processing
        transcript = ""
        detectedLanguages = []
        errorMessage = nil
        task = Task {
            var completedParts: [String] = []
            for (index, part) in selection.parts.enumerated() {
                do {
                    try Task.checkCancellation()
                    guard requestID == token else { return }
                    progress = "Расшифровываю часть \(index + 1) из \(selection.parts.count)"
                    let data = try Data(contentsOf: part.url, options: .mappedIfSafe)
                    let boundary = "Interpreter" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    let request = try TranscriptionWire.request(
                        file: data, filename: part.url.lastPathComponent,
                        key: key, mode: selectedMode, boundary: boundary
                    )
                    let (answerData, rawResponse) = try await URLSession.shared.data(for: request)
                    try Task.checkCancellation()
                    guard requestID == token else { return }
                    guard let response = rawResponse as? HTTPURLResponse else {
                        throw TranscriptWireError.unavailable
                    }
                    guard (200...299).contains(response.statusCode) else {
                        throw TranscriptionWire.serverError(answerData, status: response.statusCode)
                    }
                    let answer = try TranscriptionWire.parse(answerData, mode: selectedMode)
                    account.transcriptionKeyAccepted()
                    account.addTranscriptionEstimate(selectedMode.price(for: part.seconds))
                    detectedLanguages = Array(Set(detectedLanguages + answer.languages)).sorted()
                    completedParts.append(
                        answer.formatted(mode: selectedMode,
                                         partNumber: index + 1,
                                         showPart: selection.parts.count > 1)
                    )
                    transcript = completedParts.joined(separator: "\n\n")
                } catch is CancellationError {
                    return
                } catch {
                    guard requestID == token else { return }
                    if let error = error as? TranscriptWireError, case .invalidKey = error {
                        account.transcriptionKeyRejected()
                    }
                    errorMessage = error.localizedDescription
                    stage = completedParts.isEmpty ? .ready : .complete
                    progress = completedParts.isEmpty ? "Можно повторить попытку" :
                        "Часть расшифровки получена. Остальные фрагменты не завершены."
                    return
                }
            }
            guard requestID == token else { return }
            stage = .complete
            progress = "Расшифровка готова"
        }
    }

    func reset() {
        requestID = UUID()
        task?.cancel()
        task = nil
        prepared?.cleanup()
        prepared = nil
        stage = .idle
        filename = ""
        duration = 0
        progress = ""
        transcript = ""
        detectedLanguages = []
        errorMessage = nil
    }
}
