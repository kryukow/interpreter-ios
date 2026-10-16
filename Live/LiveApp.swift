import SwiftUI
import UniformTypeIdentifiers
import UIKit

@main struct InterpreterLiveApp: App {
    var body: some Scene { WindowGroup { LiveView().preferredColorScheme(.dark) } }
}

private var liveVersion: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    return "Interpreter Live \(version) (\(build))"
}

struct LiveView: View {
    @StateObject private var model = LiveSession()
    @State private var settings = false
    @State private var exporting = false
    @State private var importing = false
    @State private var showTranscription = false
    @State private var document: RecordingDocument?
    @State private var exportError = false
    @State private var importError: String?
    @AppStorage("live.keepAwake") private var keepAwake = true
    @AppStorage("live.partnerLanguage") private var partnerCode = "de"
    @State private var orbitActive = false
    @State private var orbitDragStart = 0
    @State private var orbitStarted = false
    @State private var orbitHide: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    private var partner: PartnerLanguage { PartnerLanguage.current(partnerCode) }
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("INTERPRETER LIVE").font(.caption2).tracking(3).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text("Русский ↔").font(.title2.bold()).fixedSize()
                        Text(partner.name)
                            .font(.title2.bold())
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .contentShape(Rectangle())
                            .gesture(languageDrag)
                            .accessibilityLabel("Иностранный язык: \(partner.name). Проведи влево или вправо")
                            .accessibilityAddTraits(.isButton)
                    }
                }
                Spacer()
                Button { model.stopAll(); settings = true } label: {
                    Image(systemName: "gearshape.fill").font(.title2)
                }.disabled(model.busy).accessibilityLabel("Настройки")
            }
            ZStack {
                Image(systemName: "infinity")
                    .font(.system(size: 52, weight: .light))
                    .opacity(orbitActive ? 0.08 : 1)
                    .scaleEffect(orbitActive ? 1.45 : 1)
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(PartnerLanguage.allCases) { choice in
                            Button {
                                selectLanguage(choice)
                                scheduleOrbitHide(after: 0.55)
                            } label: {
                                Text(choice.flag)
                                    .font(.system(size: choice == partner ? 32 : 25))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 51)
                                    .background(choice == partner ? Color.white : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 15))
                                    .opacity(choice == partner ? 1 : 0.50)
                                    .scaleEffect(choice == partner ? 1.04 : 0.90)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(choice.name)
                        }
                    }
                    Text(partner.flag + " " + partner.name + " · выбрано")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .opacity(orbitActive ? 1 : 0)
                .scaleEffect(orbitActive ? 1 : 0.94)
                .allowsHitTesting(orbitActive && model.phase == .idle)
            }
            .frame(height: 72)
            .animation(.spring(response: 0.34, dampingFraction: 0.83), value: orbitActive)
            .sensoryFeedback(.selection, trigger: partnerCode)
            MicrophoneWaveform(levels: model.levels, recording: model.phase == .recording)
            VStack(spacing: 5) {
                Text(model.message).font(.headline).multilineTextAlignment(.center)
                if model.phase == .recording {
                    Text(String(format: "● %.1f с", model.elapsed)).font(.caption.monospacedDigit())
                }
            }.frame(minHeight: 56)
            BalanceSummary(account: model)
            HStack(spacing: 16) {
                talk("Русский", language: "ru", target: "→ \(partner.uppercaseName)")
                talk(partner.buttonName, language: partner.rawValue, target: "→ РУССКИЙ")
            }.frame(height: 145)
            Text("Держи → вибросигнал → говори → отпусти")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("ГОЛОСОВОЙ ПЕРЕВОД · API").font(.caption).foregroundStyle(.secondary)
                    Text(model.text.isEmpty ? "—" : model.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !model.details.isEmpty { Text(model.details).font(.caption).foregroundStyle(.secondary) }
                    if let translation = model.translatedWave {
                        Button("Прослушать снова") { model.replay() }.disabled(model.busy)
                        Button("Сохранить перевод") {
                            document = RecordingDocument(data: translation)
                            exporting = true
                        }.disabled(model.busy)
                        if let url = model.shareURL {
                            ShareLink(item: url, preview: SharePreview("Голосовой перевод")) {
                                Label("Отправить перевод", systemImage: "square.and.arrow.up")
                            }
                            .disabled(model.busy)
                        }
                    }
                    if model.recordedWave != nil {
                        Button("Послушать свою запись") { model.review() }.disabled(model.busy)
                    }
                    Button {
                        importing = true
                    } label: {
                        Label("Импорт аудио", systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.busy)
                    Button {
                        showTranscription = true
                    } label: {
                        Label("Транскрибация записей", systemImage: "text.quote")
                    }
                    .disabled(model.busy)
                    if model.recordedWave == nil {
                        Text("Онлайн-перевод начинается во время удержания кнопки. После отпускания ждём только оставшуюся часть ответа. Звук микрофона записывается без усиления.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(18).background(Color(white: 0.055), in: RoundedRectangle(cornerRadius: 22))
            }.frame(maxHeight: .infinity)
            Text(liveVersion).font(.caption2).foregroundStyle(.secondary)
        }.padding(.horizontal, 24).padding(.vertical, 12)
        .background(Color.black).tint(.white)
        .sheet(isPresented: $settings) { LiveSettings(model: model) }
        .sheet(isPresented: $showTranscription) { TranscriptionView(account: model) }
        .sheet(isPresented: $importing) {
            RecordingDocumentPicker(
                onSelected: { url in
                    importing = false
                    Task { @MainActor in
                        do { try await model.importAudio(url, partner: partner.rawValue) }
                        catch { importError = error.localizedDescription }
                    }
                },
                onCancelled: { importing = false }
            )
            .ignoresSafeArea()
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .wav,
                      defaultFilename: "Interpreter-Live-translation") { result in
            if case .failure(let error) = result,
               (error as NSError).code != NSUserCancelledError { exportError = true }
            document = nil
        }
        .alert("Не удалось сохранить перевод", isPresented: $exportError) { Button("Готово", role: .cancel) {} }
        .alert("Импорт аудио", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("Понятно", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .onAppear { updateAwake() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; model.background() }
        .onChange(of: keepAwake) { _, _ in updateAwake() }
        .onChange(of: scenePhase) { _, phase in
            updateAwake()
            if phase != .active { model.background() }
        }
    }
    private var languageDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard model.phase == .idle else { return }
                if !orbitStarted {
                    orbitHide?.cancel()
                    orbitDragStart = PartnerLanguage.allCases.firstIndex(of: partner) ?? 0
                    orbitStarted = true
                    withAnimation { orbitActive = true }
                }
                let offset = Int((-value.translation.width / 57).rounded())
                let index = min(max(orbitDragStart + offset, 0), PartnerLanguage.allCases.count - 1)
                selectLanguage(PartnerLanguage.allCases[index])
            }
            .onEnded { value in
                orbitStarted = false
                scheduleOrbitHide(after: abs(value.translation.width) < 8 ? 3.5 : 0.45)
            }
    }

    private func selectLanguage(_ choice: PartnerLanguage) {
        guard model.phase == .idle else { return }
        partnerCode = choice.rawValue
    }

    private func scheduleOrbitHide(after seconds: Double) {
        orbitHide?.cancel()
        orbitHide = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation { orbitActive = false }
        }
    }

    private func talk(_ title: String, language: String, target: String) -> some View {
        PressButton(title: title, subtitle: target, pressed: model.held == language,
                    enabled: !model.busy || model.held == language,
                    begin: { model.begin(language, partner: partner.rawValue) }, end: { model.end(language) },
                    cancel: { model.abortPress(language) }).frame(maxWidth: .infinity)
    }
    private func updateAwake() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake && scenePhase == .active
    }
}

/// One visual readout backed by the same LiveSession in both feature screens.
struct BalanceSummary: View {
    @ObservedObject var account: LiveSession

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ОБЩИЙ ОСТАТОК API · ПРИМЕРНО")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(account.remainder).font(.title3.monospacedDigit().bold())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("ОБЩИЙ РАСХОД")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(String(format: "$%.4f", account.spent))
                        .font(.subheadline.monospacedDigit())
                }
            }
            Divider().overlay(Color.white.opacity(0.08))
            HStack {
                Text("Перевод · новые расходы")
                Spacer()
                Text(String(format: "$%.4f", account.translationSpent))
            }
            HStack {
                Text("Транскрибация · новые расходы")
                Spacer()
                Text(String(format: "$%.4f", account.transcriptionSpent))
            }
            .padding(.bottom, 1)
            if account.lowBalance {
                Label("Предполагаемый остаток меньше $1 · проверь баланс OpenAI",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text("Локальная оценка, не банковский баланс. Старые расходы включены в общий итог.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .font(.caption.monospacedDigit())
        .padding(16)
        .background(Color(white: 0.07), in: RoundedRectangle(cornerRadius: 22))
    }
}

struct RecordingDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.wav] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct LiveSettings: View {
    @ObservedObject var model: LiveSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("live.keepAwake") private var keepAwake = true
    @State private var key = ""
    @State private var balance = ""
    @State private var notice = ""
    @State private var deleteKey = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Голосовой перевод") {
                    Text("gpt-realtime-translate")
                    Text("Отдельная платная модель OpenAI для голосового перевода.").font(.footnote)
                }
                Section("API-ключ") {
                    HStack(spacing: 10) {
                        Image(systemName: model.keyStatus.symbol)
                        Text(model.keyStatus.title)
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(model.keyVerified ? Color.green :
                                     model.keyStatusIsRejected ? Color.red : Color.secondary)
                    SecureField("Вставь API-ключ", text: $key)
                        .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Вставить из буфера") { key = UIPasteboard.general.string ?? "" }
                    Button("Сохранить ключ") {
                        do { try model.saveKey(key); key = ""; notice = "Ключ сохранён" }
                        catch { notice = error.localizedDescription }
                    }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.keySaved { Button("Удалить ключ", role: .destructive) { deleteKey = true } }
                    Link("Создать ключ OpenAI", destination: URL(string: "https://platform.openai.com/api-keys")!)
                    Text("Ключ хранится в защищённом хранилище iPhone. Старый ключ автоматически не переносится.").font(.footnote)
                }
                Section("Баланс API") {
                    HStack {
                        Text("Указанный остаток")
                        Spacer()
                        Text(model.enteredBalanceText).monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Сейчас · приблизительно")
                        Spacer()
                        Text(model.remainder).monospacedDigit().bold()
                    }
                    TextField("Обновить остаток, $", text: $balance).keyboardType(.decimalPad)
                    Button("Указать остаток") {
                        notice = model.setBalance(balance) ? "Остаток обновлён" : "Введи сумму, например 9,80"
                        balance = ""
                    }
                    Link("Баланс и расходы OpenAI", destination: URL(string: "https://platform.openai.com/settings/organization/billing/overview")!)
                    Text("≈ $0,034 за минуту отправленного аудио.").font(.footnote)
                }
                Section("Экран") { Toggle("Экран всегда включён", isOn: $keepAwake) }
                Section("Формат передачи аудио") {
                    Text("PCM16 · 24 кГц · моно · порции по 200 мс").font(.footnote)
                }
                if !notice.isEmpty { Section { Text(notice).font(.footnote) } }
                Section { Text(liveVersion).foregroundStyle(.secondary) }
            }.navigationTitle("Настройки")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { key = ""; dismiss() } } }
                .confirmationDialog("Удалить сохранённый API-ключ?", isPresented: $deleteKey) {
                    Button("Удалить", role: .destructive) {
                        do { try model.removeKey(); notice = "Ключ удалён" } catch { notice = error.localizedDescription }
                    }
                }
                .onDisappear { key = "" }
        }.tint(.white)
    }
}
