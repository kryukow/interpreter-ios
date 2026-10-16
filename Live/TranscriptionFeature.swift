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
        progress = "Получаю файл из «Файлов» · длинная запись может готовиться несколько минут"
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
                                         showPart: selection.parts.count > 1,
                                         offsetSeconds: selection.parts.prefix(index)
                                             .reduce(0) { $0 + $1.seconds })
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

    func reportError(_ message: String) { errorMessage = message }
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

struct TranscriptTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let content: String
    init(content: String) { self.content = content }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let content = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.content = content
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(content.utf8))
    }
}

struct TranscriptionView: View {
    @ObservedObject var account: LiveSession
    @StateObject private var session = TranscriptionSession()
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var showConfirmation = false
    @State private var exporting = false
    @State private var document: TranscriptTextDocument?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Транскрибация", systemImage: "waveform.badge.mic")
                            .font(.title2.bold())
                        Text("Записи Apple Watch, диктофона и WhatsApp. Длинные записи тоже поддерживаются.")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Сколько людей разговаривает?").font(.headline)
                        Picker("Режим", selection: $session.mode) {
                            Text("Один голос").tag(TranscriptionMode.single)
                            Text("Несколько голосов").tag(TranscriptionMode.group)
                        }
                        .pickerStyle(.segmented)
                        .disabled(session.working)
                        Text(session.mode.explanation)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text(session.mode.model).font(.caption.monospaced())
                            Spacer()
                            Text(String(format: "≈ $%.4f/мин", session.mode.pricePerMinute))
                                .font(.caption.monospacedDigit())
                        }
                        .foregroundStyle(.secondary)
                        if session.mode == .group {
                            Text("Говорящие обозначаются буквами. Если длинный файл разделён, буквы могут начинаться заново в каждой части.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 20))

                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            importing = true
                        } label: {
                            Label(session.filename.isEmpty ? "Выбрать аудиозапись" : "Выбрать другой файл",
                                  systemImage: "waveform.badge.plus")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(Color(white: 0.22),
                                            in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .disabled(session.working)
                        .opacity(session.working ? 0.55 : 1)
                        .accessibilityHint("Открыть Файлы iPhone, включая записи Apple Watch")

                        if !session.filename.isEmpty {
                            Text(session.filename).font(.subheadline).lineLimit(2)
                            HStack {
                                Text(durationLabel)
                                Spacer()
                                Text(String(format: "Примерно $%.3f", session.estimatedPrice))
                                    .bold().monospacedDigit()
                            }
                            .font(.subheadline)
                        }
                        if !session.progress.isEmpty {
                            HStack(spacing: 8) {
                                if session.working { ProgressView().tint(.white) }
                                Text(session.progress).font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let error = session.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(.red)
                        }

                        Button {
                            showConfirmation = true
                        } label: {
                            Label("Расшифровать", systemImage: "text.alignleft")
                                .frame(maxWidth: .infinity)
                                .padding(10)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!session.ready)
                        Text("Списание происходит через твой API-ключ OpenAI. Итоговая сумма может отличаться от предварительной оценки.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(Color(white: 0.075), in: RoundedRectangle(cornerRadius: 20))

                    if !session.transcript.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Результат").font(.headline)
                            if !session.detectedLanguages.isEmpty {
                                Text("Языки: " + session.detectedLanguages.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(session.transcript)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                Button("Копировать") {
                                    UIPasteboard.general.string = session.transcript
                                }
                                Button("Сохранить TXT") {
                                    document = TranscriptTextDocument(content: session.transcript)
                                    exporting = true
                                }
                                ShareLink(item: session.transcript) {
                                    Label("Отправить", systemImage: "square.and.arrow.up")
                                }
                            }
                            .font(.footnote)
                        }
                        .padding(16)
                        .background(Color(white: 0.085), in: RoundedRectangle(cornerRadius: 20))
                    }
                }
                .padding(18)
            }
            .background(Color.black)
            .navigationTitle("Аудиозаписи")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
                if session.working {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Отменить") { session.reset() }
                    }
                }
            }
            // Some Apple Watch/Voice Memos recordings from iCloud Drive are not
            // advertised by Files as UTType.audio. Permit document selection,
            // then validate audio in TranscriptionAudio before any API request.
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else {
                        session.reportError("Файл не выбран.")
                        return
                    }
                    session.selectFile(url)
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError {
                        session.reportError(error.localizedDescription)
                    }
                }
            }
            .fileExporter(isPresented: $exporting, document: document,
                          contentType: .plainText,
                          defaultFilename: "Interpreter-Transcription") { _ in
                document = nil
            }
            .confirmationDialog("Отправить аудио в OpenAI?",
                                isPresented: $showConfirmation,
                                titleVisibility: .visible) {
                Button(String(format: "Расшифровать · ≈ $%.3f", session.estimatedPrice)) {
                    session.start(account: account)
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Модель: \(session.mode.model). Запись: \(durationLabel). Отправка платная.")
            }
            .onDisappear { session.reset() }
        }
        .tint(.white)
        .preferredColorScheme(.dark)
    }

    private var durationLabel: String {
        let seconds = Int(session.duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
