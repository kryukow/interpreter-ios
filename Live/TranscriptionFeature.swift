import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor final class TranscriptionSession: ObservableObject {
    enum Stage { case idle, preparing, ready, processing, complete }

    @Published var mode: TranscriptionMode = .single
    @Published var languageHint: TranscriptionLanguageHint = .ru
    @Published private(set) var stage: Stage = .idle
    @Published private(set) var filename = ""
    @Published private(set) var duration: Double = 0
    @Published private(set) var progress = ""
    @Published private(set) var transcript = ""
    @Published private(set) var detectedLanguages: [String] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var finishedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var uncertainCount = 0

    private var prepared: PreparedTranscription?
    private var saved: SavedTranscriptJob?
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var currentRequestIndex: Int?
    private var restored = false

    var estimatedPrice: Double { mode.price(for: duration) }
    var remainingPrice: Double {
        guard let prepared, let saved else { return estimatedPrice }
        return prepared.parts.enumerated()
            .filter { saved.completed[$0.offset] == nil }
            .reduce(0) { $0 + mode.price(for: $1.element.seconds) }
    }
    var ready: Bool { stage == .ready && prepared != nil }
    var working: Bool { stage == .preparing || stage == .processing }
    var hasIncomplete: Bool { finishedCount > 0 && finishedCount < totalCount }

    func restore() {
        guard !restored else { return }
        restored = true
        guard let (archive, selection) = TranscriptionArchive.read() else { return }
        prepared = selection
        saved = archive
        mode = TranscriptionMode(rawValue: archive.mode) ?? .single
        languageHint = TranscriptionLanguageHint(rawValue: archive.hint) ?? .ru
        filename = archive.filename
        duration = archive.duration
        stage = archive.completed.count == selection.parts.count ? .complete : .ready
        refreshTranscript()
        progress = stage == .complete ? "Расшифровка готова и сохранена на iPhone" :
            "Сохранено \(finishedCount) из \(totalCount) частей · можно продолжить"
        if uncertainCount > 0 {
            errorMessage = "У \(uncertainCount) запроса нет подтверждённого ответа. OpenAI мог списать за них средства; повтор запускается только вручную."
        }
    }

    func selectFile(_ url: URL) {
        pause()
        let previous = saved
        prepared = nil
        saved = nil
        filename = url.lastPathComponent
        duration = 0
        finishedCount = 0
        totalCount = 0
        uncertainCount = 0
        transcript = ""
        detectedLanguages = []
        errorMessage = nil
        let token = requestID
        stage = .preparing
        progress = "Файл выбран · сжимаю и сохраняю части на iPhone"
        task = Task {
            do {
                let selection = try await TranscriptionAudio.prepare(url)
                guard requestID == token, !Task.isCancelled else {
                    selection.cleanup()
                    return
                }
                var archive = TranscriptionArchive.make(selection, mode: mode, hint: languageHint)
                do { try TranscriptionArchive.write(archive) }
                catch { selection.cleanup(); throw error }
                if let previous { TranscriptionArchive.removeAudioOnly(previous) }
                prepared = selection
                saved = archive
                filename = selection.filename
                duration = selection.duration
                totalCount = selection.parts.count
                stage = .ready
                progress = "Подготовлено \(totalCount) частей · можно начать"
            } catch {
                guard requestID == token else { return }
                stage = .idle
                errorMessage = error.localizedDescription
                progress = "Не удалось подготовить запись"
            }
        }
    }

    func start(account: LiveSession) {
        guard ready, let selection = prepared, var archive = saved else { return }
        guard let key = try? LiveKey.read(), !key.isEmpty else {
            errorMessage = "Сначала добавь API-ключ в настройках."
            return
        }
        // Never mix speaker/text mode or language settings between already paid parts.
        guard archive.completed.isEmpty ||
                (archive.mode == mode.rawValue && archive.hint == languageHint.rawValue) else {
            errorMessage = "Для продолжения нужны прежние режим и язык записи."
            return
        }
        archive.mode = mode.rawValue
        archive.hint = languageHint.rawValue
        do { try TranscriptionArchive.write(archive) }
        catch { errorMessage = "Не удалось сохранить задание на iPhone: \(error.localizedDescription)"; return }
        saved = archive
        let token = requestID
        let selectedMode = mode
        let selectedHint = languageHint
        stage = .processing
        errorMessage = nil
        task = Task {
            for (index, part) in selection.parts.enumerated() {
                guard saved?.completed[index] == nil else { continue }
                do {
                    try Task.checkCancellation()
                    guard requestID == token else { return }
                    currentRequestIndex = index
                    progress = "Расшифровываю \(index + 1) из \(selection.parts.count) · готово \(finishedCount)"
                    let data = try Data(contentsOf: part.url, options: .mappedIfSafe)
                    let boundary = "Interpreter" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    let request = try TranscriptionWire.request(
                        file: data, filename: part.url.lastPathComponent, key: key,
                        mode: selectedMode, boundary: boundary, hint: selectedHint
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
                    var next = saved ?? archive
                    // Part identity is independent of retry count. Never charge a saved part twice.
                    let formatted = answer.formatted(
                        mode: selectedMode, partNumber: index + 1,
                        showPart: selection.parts.count > 1,
                        offsetSeconds: selection.parts.prefix(index).reduce(0) { $0 + $1.seconds }
                    )
                    next.completed[index] = formatted
                    next.languages = Array(Set(next.languages + answer.languages)).sorted()
                    next.unknownCharges.removeAll { $0 == index }
                    try TranscriptionArchive.write(next)
                    saved = next
                    account.addTranscriptionEstimate(
                        selectedMode.price(for: part.seconds),
                        id: next.folderName + "/" + selectedMode.rawValue + "/" + String(index)
                    )
                    currentRequestIndex = nil
                    refreshTranscript()
                } catch is CancellationError {
                    return
                } catch {
                    guard requestID == token else { return }
                    if let wireError = error as? TranscriptWireError,
                       case .invalidKey = wireError { account.transcriptionKeyRejected() }
                    // A timeout/network interruption cannot establish whether the server billed.
                    if let urlError = error as? URLError,
                       [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(urlError.code) {
                        markUnknown(index)
                    }
                    currentRequestIndex = nil
                    stage = .ready
                    errorMessage = (error as? URLError)?.code == .timedOut
                        ? "Время ожидания истекло. Уже готовые части сохранены. Повтор следующей части может быть платным."
                        : error.localizedDescription
                    progress = "Готово \(finishedCount) из \(totalCount) · продолжение вручную"
                    return
                }
            }
            guard requestID == token else { return }
            currentRequestIndex = nil
            stage = .complete
            progress = "Расшифровка готова · \(finishedCount) частей сохранено"
        }
    }

    private func refreshTranscript() {
        guard let saved else { return }
        totalCount = saved.partNames.count
        finishedCount = saved.completed.count
        uncertainCount = saved.unknownCharges.count
        transcript = saved.completed.keys.sorted().compactMap { saved.completed[$0] }
            .joined(separator: "\n\n")
        detectedLanguages = saved.languages
    }

    private func markUnknown(_ index: Int) {
        guard var archive = saved, archive.completed[index] == nil else { return }
        if !archive.unknownCharges.contains(index) { archive.unknownCharges.append(index) }
        try? TranscriptionArchive.write(archive)
        saved = archive
        refreshTranscript()
    }

    /// Leave persisted audio and completed results intact when dismissing the sheet.
    func pause() {
        if stage == .processing, let index = currentRequestIndex { markUnknown(index) }
        requestID = UUID()
        task?.cancel()
        task = nil
        currentRequestIndex = nil
        if stage == .processing { stage = .ready }
        if stage == .preparing { stage = .idle }
    }

    func reportError(_ message: String) { errorMessage = message }

    func clearSaved() {
        pause()
        if let saved { TranscriptionArchive.remove(saved) }
        saved = nil
        prepared = nil
        stage = .idle
        filename = ""
        duration = 0
        progress = ""
        transcript = ""
        detectedLanguages = []
        errorMessage = nil
        finishedCount = 0
        totalCount = 0
        uncertainCount = 0
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

                    BalanceSummary(account: account)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Сколько людей разговаривает?").font(.headline)
                        Picker("Режим", selection: $session.mode) {
                            Text("Один голос").tag(TranscriptionMode.single)
                            Text("Несколько голосов").tag(TranscriptionMode.group)
                        }
                        .pickerStyle(.segmented)
                        .disabled(session.working || session.finishedCount > 0)
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
                        Divider()
                        Text("Какие языки звучат в записи?").font(.headline)
                        Picker("Подсказка языка", selection: $session.languageHint) {
                            ForEach(TranscriptionLanguageHint.allCases) { hint in
                                Text(hint.label).tag(hint)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.white)
                        .disabled(session.working || session.finishedCount > 0)
                        Text(session.mode == .group && session.languageHint.isMultilingual
                             ? "В режиме нескольких голосов OpenAI принимает подсказку только одного языка. Для пары языков оставляем автоопределение."
                             : "Подсказка помогает сохранить язык оригинала. Это расшифровка, не перевод.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                                Text(String(format: "Осталось ≈ $%.3f", session.remainingPrice))
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
                        if session.totalCount > 0 {
                            ProgressView(value: Double(session.finishedCount), total: Double(session.totalCount))
                                .tint(.green)
                            Text("Готово: \(session.finishedCount) из \(session.totalCount)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if session.uncertainCount > 0 {
                            Label("Неопределённых по оплате запросов: \(session.uncertainCount). Перед повтором проверь баланс OpenAI.",
                                  systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if let error = session.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote).foregroundStyle(.red)
                        }

                        Button {
                            showConfirmation = true
                        } label: {
                            Label(session.hasIncomplete ? "Продолжить с неготовой части" : "Расшифровать",
                                  systemImage: "text.alignleft")
                                .frame(maxWidth: .infinity)
                                .padding(10)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!session.ready)
                        if !session.filename.isEmpty && !session.working {
                            Button("Удалить сохранённую запись и результат", role: .destructive) {
                                session.clearSaved()
                            }
                            .font(.footnote)
                        }
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
                        Button("Приостановить") { session.pause() }
                    }
                }
            }
            // SwiftUI fileImporter on some real iPhones shows Files but never
            // returns the selected URL. Use UIKit's copy-mode picker instead.
            // Audio and data cover M4A (including Apple Watch Voice Memos).
            .sheet(isPresented: $importing) {
                RecordingDocumentPicker(
                    onSelected: { selectedURL in
                        importing = false
                        session.selectFile(selectedURL)
                    },
                    onCancelled: { importing = false }
                )
                .ignoresSafeArea()
            }
            .fileExporter(isPresented: $exporting, document: document,
                          contentType: .plainText,
                          defaultFilename: "Interpreter-Transcription") { _ in
                document = nil
            }
            .confirmationDialog("Отправить аудио в OpenAI?",
                                isPresented: $showConfirmation,
                                titleVisibility: .visible) {
                Button(String(format: "Обработать неготовые части · ≈ $%.3f", session.remainingPrice)) {
                    session.start(account: account)
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Модель: \(session.mode.model). Запись: \(durationLabel). Осталось частей: \(session.totalCount - session.finishedCount). Повтор части после тайм-аута может быть списан повторно.")
            }
            .onAppear { session.restore() }
            .onDisappear { session.pause() }
        }
        .tint(.white)
        .preferredColorScheme(.dark)
    }

    private var durationLabel: String {
        let seconds = Int(session.duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}


/// A dedicated UIKit picker replaces SwiftUI's fileImporter, which can fail
/// to dispatch its selection on physical iPhone devices.
struct RecordingDocumentPicker: UIViewControllerRepresentable {
    let onSelected: (URL) -> Void
    let onCancelled: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelected: onSelected, onCancelled: onCancelled)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let m4a = UTType(filenameExtension: "m4a")
        var types: [UTType] = [.audio, .data]
        if let m4a { types.append(m4a) }
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: types,
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSelected: (URL) -> Void
        let onCancelled: () -> Void
        init(onSelected: @escaping (URL) -> Void,
             onCancelled: @escaping () -> Void) {
            self.onSelected = onSelected
            self.onCancelled = onCancelled
        }
        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onCancelled()
                return
            }
            onSelected(url)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancelled()
        }
    }
}
