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
    @State private var document: RecordingDocument?
    @State private var exportError = false
    @AppStorage("live.keepAwake") private var keepAwake = true
    @AppStorage("live.partnerLanguage") private var partnerCode = "de"
    @State private var showLanguageWheel = false
    @State private var wheelSelection = "de"
    @Environment(\.scenePhase) private var scenePhase
    private var partner: PartnerLanguage { PartnerLanguage.current(partnerCode) }
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("INTERPRETER LIVE").font(.caption2).tracking(3).foregroundStyle(.secondary)
                    Button {
                        guard model.phase == .idle else { return }
                        wheelSelection = partnerCode
                        showLanguageWheel = true
                    } label: {
                        HStack(spacing: 8) {
                            Text("Русский ↔ \(partner.name)")
                                .font(.title2.bold())
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(model.phase != .idle)
                    .accessibilityLabel("Выбрать языки разговора: русский и \(partner.name)")
                }
                Spacer()
                Button { model.stopAll(); settings = true } label: {
                    Image(systemName: "gearshape.fill").font(.title2)
                }.disabled(model.busy).accessibilityLabel("Настройки")
            }
            Image(systemName: "infinity").font(.system(size: 52, weight: .light))
            MicrophoneWaveform(levels: model.levels, recording: model.phase == .recording)
            VStack(spacing: 5) {
                Text(model.message).font(.headline).multilineTextAlignment(.center)
                if model.phase == .recording {
                    Text(String(format: "● %.1f с", model.elapsed)).font(.caption.monospacedDigit())
                }
            }.frame(minHeight: 56)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ОСТАТОК · ПРИМЕРНО").font(.caption2).foregroundStyle(.secondary)
                    Text(model.remainder).font(.title3.monospacedDigit().bold())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("РАСХОД НОВОГО ПРИЛОЖЕНИЯ").font(.caption2).foregroundStyle(.secondary)
                    Text(String(format: "$%.4f", model.spent)).font(.subheadline.monospacedDigit())
                }
            }.padding(16).background(Color(white: 0.07), in: RoundedRectangle(cornerRadius: 22))
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
                    if model.translatedWave != nil {
                        Button(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Проверить звук ответа · бесплатно" : "Прослушать снова · бесплатно") { model.replay() }.disabled(model.busy)
                    }
                    if let wave = model.recordedWave {
                        Button("Послушать свою запись · бесплатно") { model.review() }.disabled(model.busy)
                        Button("Сохранить WAV") {
                            document = RecordingDocument(data: wave); exporting = true
                        }.disabled(model.busy)
                    }
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
        .sheet(isPresented: $showLanguageWheel) {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        showLanguageWheel = false
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.headline.weight(.bold))
                            .frame(width: 42, height: 42)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                    .accessibilityLabel("Готово")
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)

                Picker("Язык", selection: $wheelSelection) {
                    ForEach(PartnerLanguage.allCases) { choice in
                        Text(choice.flag)
                            .font(.system(size: 42))
                            .tag(choice.rawValue)
                            .accessibilityLabel(choice.name)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .frame(height: 182)
                .clipped()
                .sensoryFeedback(.selection, trigger: wheelSelection)
                .onChange(of: wheelSelection) { _, newValue in
                    if PartnerLanguage(rawValue: newValue) != nil { partnerCode = newValue }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
            .presentationBackground(Color(white: 0.075))
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .wav,
                      defaultFilename: "Interpreter-Live-recording") { result in
            if case .failure(let error) = result,
               (error as NSError).code != NSUserCancelledError { exportError = true }
            document = nil
        }
        .alert("Не удалось сохранить WAV", isPresented: $exportError) { Button("Готово", role: .cancel) {} }
        .onAppear { updateAwake() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false; model.background() }
        .onChange(of: keepAwake) { _, _ in updateAwake() }
        .onChange(of: scenePhase) { _, phase in
            updateAwake()
            if phase != .active { model.background() }
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
                    Text("Отдельное приложение для платной модели OpenAI. Подписка ChatGPT и голоса iPhone здесь не используются.").font(.footnote)
                }
                Section("API-ключ") {
                    Text(model.keySaved ? "Ключ сохранён на этом iPhone" : "Добавь API-ключ OpenAI").font(.footnote)
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
                    TextField("Текущий баланс в долларах", text: $balance).keyboardType(.decimalPad)
                    Button("Указать остаток") {
                        notice = model.setBalance(balance) ? "Остаток обновлён" : "Введи сумму, например 9,80"
                        balance = ""
                    }
                    Link("Баланс и расходы OpenAI", destination: URL(string: "https://platform.openai.com/settings/organization/billing/overview")!)
                    Text("Счётчик приблизительный: $0,034 за минуту отправленного аудио. Он учитывает только это новое приложение. Фактический баланс — на сайте OpenAI. Повторное прослушивание бесплатно.").font(.footnote)
                }
                Section("Экран") { Toggle("Не гасить экран", isOn: $keepAwake) }
                Section("Запись") {
                    Text("Микрофон iPhone: WAV/PCM 24 кГц, моно, до 60 секунд. Каждые 200 мс звук передаётся OpenAI во время разговора. После отпускания отправляется только остаток, затем включается озвучивание перевода.").font(.footnote)
                    Text("Последняя запись и ответ находятся только в памяти. WAV сохраняется в «Файлы» по твоей кнопке. При уходе из приложения запись, соединение и плеер останавливаются.").font(.footnote)
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
