import SwiftUI
import AVFoundation
import SafariServices
import UIKit

@main struct InterpreterApp: App {
    var body: some Scene { WindowGroup { InterpreterView().preferredColorScheme(.dark) } }
}

@MainActor final class Conversation: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum Phase { case idle, starting, listening, finishing, translating, playing }
    @Published var phase: Phase = .idle
    @Published var source = ""
    @Published var translation = ""
    @Published var restored = ""
    @Published var language = "ru"
    @Published var message = "Выбери язык и произнеси фразу"
    @Published var models: [ModelChoice] = []
    @Published var account = ""
    @Published var model = UserDefaults.standard.string(forKey: "model") ?? ""
    @Published var realtimeMode = UserDefaults.standard.bool(forKey: "realtimeMode")
    @Published var realtimeStats = ""
    private let realtime = RealtimeTranslation()
    private var realtimeAudio: Data?
    private let capture = SpeechCapture()
    let voices = VoicePreferences()
    private let speaker = AVSpeechSynthesizer()
    private var activeUtterance: AVSpeechUtterance?
    private var work: Task<Void, Never>?
    private var epoch = UUID()
    override init() { super.init(); speaker.delegate = self; account = (try? SessionStore.load())?.email ?? "" }
    var busy: Bool { phase != .idle }
    func tap(_ language: String) {
        if realtimeMode { tapRealtime(language); return }
        if phase == .listening {
            phase = .finishing; message = "Завершаю распознавание…"
            capture.finish { [weak self] error in self?.recognized(error) }
            return
        }
        guard phase == .idle else { return }
        self.language = language; source = ""; translation = ""; restored = ""
        phase = .starting; message = "Включаю микрофон…"
        let token = epoch
        work = Task {
            do {
                try await capture.start(locale: language == "ru" ? "ru-RU" : "de-DE",
                    onText: { [weak self] text in self?.source = text },
                    onEnd: { [weak self] error in self?.recognized(error) })
                guard epoch == token else { return }
                phase = .listening; message = "Слушаю. Нажми кнопку ещё раз, чтобы перевести"
            } catch {
                guard epoch == token else { return }
                capture.cancel(); phase = .idle; message = error.localizedDescription
            }
        }
    }
    private func recognized(_ error: Error?) {
        guard phase == .listening || phase == .finishing || phase == .starting else { return }
        phase = .idle
        if let error { message = "Распознавание: " + error.localizedDescription; return }
        translate()
    }
    func translate() {
        guard phase == .idle, !realtimeMode else { return }
        let text = source, target = language == "ru" ? "German" : "Russian"
        let sourceLanguage = language == "ru" ? "Russian" : "German"
        let token = epoch
        phase = .translating; translation = ""; restored = ""; message = "Восстанавливаю смысл…"
        work = Task {
            do {
                guard let stored = try SessionStore.load() else { throw Failure.message("Войди в ChatGPT в настройках.") }
                let session = try await OpenAI.refresh(stored)
                let repaired = try await Translation.restore(text, language: sourceLanguage, model: model, session: session)
                try Task.checkCancellation()
                guard epoch == token else { return }
                restored = repaired; message = "Перевожу…"
                let result = try await Translation.run(repaired, target: target, model: model, session: session) { [weak self] update in
                    guard let self, self.epoch == token else { return }; self.translation = update
                }
                guard epoch == token else { return }
                translation = result; phase = .idle; speak()
            } catch {
                guard epoch == token else { return }
                // Partial output is never presented or spoken as a completed translation.
                translation = ""; phase = .idle; message = error.localizedDescription
            }
        }
    }
    func speak() {
        guard phase == .idle else { return }
        if realtimeMode { speakRealtime(); return }
        guard !translation.isEmpty else { return }
        voices.refresh()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            guard let voice = voices.voice(for: language == "ru" ? "de-DE" : "ru-RU") else {
                throw Failure.message("Голос озвучки недоступен. Перевод показан на экране.")
            }
            let utterance = AVSpeechUtterance(string: translation); utterance.voice = voice
            utterance.rate = voices.speechRate
            utterance.pitchMultiplier = 1.0
            activeUtterance = utterance
            phase = .playing; message = "Звучит перевод"; speaker.speak(utterance)
        } catch { message = error.localizedDescription }
    }
    func cancel() {
        epoch = UUID(); work?.cancel(); work = nil; capture.cancel()
        realtime.cancel()
        activeUtterance = nil
        speaker.stopSpeaking(at: .immediate)
        if phase == .translating { translation = "" }
        phase = .idle; message = "Остановлено"
    }
    private func tapRealtime(_ language: String) {
        if phase == .listening {
            guard self.language == language else { return }
            phase = .finishing; message = "Завершаю голосовой перевод…"; realtime.finish(); return
        }
        guard phase == .idle else { return }
        self.language = language; source = ""; translation = ""; restored = ""
        realtimeAudio = nil; realtimeStats = ""
        phase = .starting; message = "Подключаю голосовой перевод…"
        let token = epoch
        work = Task {
            do {
                guard let key = try RealtimeKeyStore.load(), !key.isEmpty else {
                    throw Failure.message("Добавь API-ключ в настройках → Голосовой перевод API.")
                }
                let result = try await realtime.run(key: key, target: language == "ru" ? "de" : "ru",
                    onReady: { [weak self] in
                        guard let self, self.epoch == token else { return }
                        self.phase = .listening; self.message = "Слушаю. Нажми этот язык ещё раз — прозвучит перевод"
                    }, onFinishing: { [weak self] in
                        guard let self, self.epoch == token else { return }
                        self.phase = .finishing; self.message = "Получаю окончание голосового перевода…"
                    }, onText: { [weak self] text in
                        guard let self, self.epoch == token else { return }
                        self.translation = text
                    })
                guard epoch == token else { return }
                translation = result.text; realtimeAudio = result.audio
                realtimeStats = String(format: "Отправлено %.1f с аудио", result.inputSeconds)
                if let delay = result.firstOutputSeconds { realtimeStats += String(format: " · Первый ответ %.1f с", delay) }
                phase = .idle; speakRealtime()
            } catch {
                guard epoch == token else { return }
                realtime.cancel(); realtimeAudio = nil; translation = ""
                phase = .idle; message = error.localizedDescription
            }
        }
    }
    private func speakRealtime() {
        guard let audio = realtimeAudio else { return }
        do {
            phase = .playing; message = "Звучит голосовой перевод OpenAI"
            let token = epoch
            try realtime.play(audio) { [weak self] in
                guard let self, self.epoch == token else { return }
                self.phase = .idle; self.message = "Готово. Выбери язык следующей фразы"
            }
        } catch { phase = .idle; message = error.localizedDescription }
    }
    var canReplay: Bool { realtimeMode ? realtimeAudio != nil : !translation.isEmpty }
    func modeChanged() {
        cancel(); source = ""; translation = ""; restored = ""; realtimeAudio = nil; realtimeStats = ""
        UserDefaults.standard.set(realtimeMode, forKey: "realtimeMode")
        message = realtimeMode ? "Голосовой перевод API · выбери язык" : "Выбери язык и произнеси фразу"
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.phase == .playing, self.activeUtterance === utterance else { return }
            self.activeUtterance = nil
            self.phase = .idle; self.message = "Готово. Выбери язык следующей фразы"
        }
    }
    func loadModels() async throws {
        guard let stored = try SessionStore.load() else { throw Failure.message("Сначала войди в ChatGPT.") }
        let session = try await OpenAI.refresh(stored)
        account = session.email; models = try await OpenAI.models(session)
        if !models.contains(where: { $0.id == model }) { model = models.first?.id ?? "" }
        UserDefaults.standard.set(model, forKey: "model")
    }
}

struct InterpreterView: View {
    @StateObject private var vm = Conversation()
    @State private var settings = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("keepScreenAwake") private var keepScreenAwake = true
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("INTERPRETER").font(.caption).tracking(4).foregroundStyle(.secondary)
                        Text("Русский ↔ Deutsch").font(.title2.bold())
                    }
                    Spacer()
                    Button { settings = true } label: { Image(systemName: "gearshape.fill").font(.title2) }
                        .disabled(vm.busy).accessibilityLabel("Настройки")
                }
                Image(systemName: vm.phase == .listening ? "waveform" : "waveform.circle").font(.system(size: 52)).foregroundStyle(.mint)
                Text(vm.message).font(.headline).multilineTextAlignment(.center).frame(minHeight: 60)
                Text(vm.realtimeMode ? "Голосовой перевод API · платный тест" : "Перевод через подписку ChatGPT")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    languageButton("Русский", language: "ru")
                    languageButton("Deutsch", language: "de")
                }
                Text("Нажми язык → скажи фразу → нажми ещё раз").font(.footnote).foregroundStyle(.secondary)
                if vm.busy { Button("Остановить") { vm.cancel() }.buttonStyle(.bordered) }
                VStack(alignment: .leading, spacing: 12) {
                    if vm.realtimeMode {
                        Text("ГОЛОС → ПЕРЕВОД").font(.caption).foregroundStyle(.secondary)
                        Text("Модель переводит непосредственно аудио. Текст появится по мере перевода, голос прозвучит после завершения записи.").font(.footnote).foregroundStyle(.secondary)
                        if !vm.realtimeStats.isEmpty { Text(vm.realtimeStats).font(.footnote).foregroundStyle(.secondary) }
                    } else {
                    Text("УСЛЫШАЛА · \(vm.language == "ru" ? "РУССКИЙ" : "DEUTSCH")").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $vm.source).frame(minHeight: 90).scrollContentBackground(.hidden).disabled(vm.busy)
                    HStack {
                        Button("Перевести текст") { vm.translate() }.disabled(vm.busy || vm.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Spacer()
                        if !vm.source.isEmpty { Text("Можно исправить").font(.caption).foregroundStyle(.secondary) }
                    }
                    Divider()
                    if !vm.restored.isEmpty {
                        Text("ПОНЯЛА ПО СМЫСЛУ").font(.caption).foregroundStyle(.secondary)
                        Text(vm.restored).textSelection(.enabled)
                        Divider()
                    }
                    }
                    Text("ПЕРЕВОД").font(.caption).foregroundStyle(.secondary)
                    Text(vm.translation.isEmpty ? "—" : vm.translation).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Прослушать снова") { vm.speak() }.disabled(vm.busy || !vm.canReplay)
                }.padding(20).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24))
            }.padding(24)
        }.background(Color(red: 0.035, green: 0.06, blue: 0.09))
        .sheet(isPresented: $settings) { SettingsView(vm: vm) }
        .onAppear { updateScreenAwake() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: keepScreenAwake) { _, _ in updateScreenAwake() }
        .onChange(of: vm.realtimeMode) { _, _ in vm.modeChanged() }
        .onChange(of: vm.source) { _, _ in if !vm.busy { vm.restored = ""; vm.translation = "" } }
        .onChange(of: scenePhase) { _, phase in
            updateScreenAwake()
            if phase == .background { vm.cancel() }
        }
    }
    private func updateScreenAwake() {
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwake && scenePhase == .active
    }
    func languageButton(_ title: String, language: String) -> some View {
        Button { vm.tap(language) } label: {
            VStack(spacing: 12) {
                Image(systemName: vm.phase == .listening && vm.language == language ? "stop.fill" : "mic.fill").font(.system(size: 36))
                Text(title).font(.headline)
            }.frame(maxWidth: .infinity).padding(.vertical, 28)
                .background(language == "ru" ? Color.mint : Color.cyan, in: RoundedRectangle(cornerRadius: 26)).foregroundStyle(.black)
        }.disabled(vm.busy && !(vm.phase == .listening && vm.language == language))
    }
}

struct SettingsView: View {
    @AppStorage("keepScreenAwake") private var keepScreenAwake = true
    @ObservedObject var vm: Conversation
    @StateObject private var login = Login()
    @State private var busy = false
    @State private var message = ""
    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var keyMessage = ""
    @State private var removeKey = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Режим перевода") {
                    Picker("Использовать", selection: $vm.realtimeMode) {
                        Text("Подписка ChatGPT").tag(false)
                        Text("Голосовой перевод API · тест").tag(true)
                    }
                    Text(vm.realtimeMode ? "Голос отправляется в OpenAI. Модель gpt-realtime-translate возвращает перевод и собственный голос. Оплата из баланса API, отдельно от подписки." : "Распознавание Apple, перевод текста через подписку ChatGPT, озвучка голосом iPhone.").font(.footnote)
                }
                Section("Голосовой перевод API") {
                    Text(keySaved ? "API-ключ сохранён на этом iPhone" : "API-ключ ещё не добавлен").font(.footnote)
                    SecureField("Вставь API-ключ OpenAI", text: $apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Сохранить API-ключ") {
                        do { try RealtimeKeyStore.save(apiKey); apiKey = ""; keySaved = true; keyMessage = "Сохранено" }
                        catch { keyMessage = error.localizedDescription }
                    }.disabled(apiKey.isEmpty)
                    if keySaved { Button("Удалить API-ключ", role: .destructive) { removeKey = true } }
                    Link("Создать ключ на сайте OpenAI", destination: URL(string: "https://platform.openai.com/api-keys")!)
                    Link("Баланс и расходы API", destination: URL(string: "https://platform.openai.com/settings/organization/billing/overview")!)
                    Text("Ориентир тарифа модели: $0,034 за минуту аудио. Одна запись — максимум 60 секунд. Счётчик длительности не является банковским балансом; фактические списания смотри на сайте OpenAI.").font(.footnote)
                    Text("Ключ вводится только здесь и хранится в защищённом хранилище iPhone. Записи и переводы в приложении не сохраняются. Сервер и включённый компьютер не нужны.").font(.footnote)
                    if !keyMessage.isEmpty { Text(keyMessage).font(.footnote) }
                }
                Section("Экран") {
                    Toggle("Не гасить экран", isOn: $keepScreenAwake)
                    Text("Экран остаётся включённым, пока Interpreter открыт. При сворачивании обычная автоблокировка возвращается.").font(.footnote)
                }
                if !vm.realtimeMode { VoiceSettingsView(preferences: vm.voices) }
                Section("ChatGPT") {
                    Text(vm.account.isEmpty ? "Вход не выполнен" : vm.account)
                    Button("Войти через ChatGPT") {
                        busy = true
                        Task {
                            defer { busy = false }
                            do { try await login.signIn(); try await vm.loadModels(); message = "Подключено" }
                            catch { message = error.localizedDescription }
                        }
                    }.disabled(busy)
                    Button("Обновить список моделей") {
                        busy = true
                        Task { defer { busy = false }; do { try await vm.loadModels() } catch { message = error.localizedDescription } }
                    }.disabled(busy)
                    Picker("Модель", selection: $vm.model) {
                        Text("Выбери модель").tag("")
                        ForEach(vm.models) { Text($0.name).tag($0.id) }
                    }.disabled(busy)
                    Text(message.isEmpty ? login.message : message).font(.footnote)
                }
                Section {
                    Text("В режиме подписки восстановление смысла и перевод выполняются двумя запросами через лимиты ChatGPT. Аудио в OpenAI не отправляется: туда уходит только текст. В голосовом режиме API в OpenAI передаётся аудио.")
                    Text("Распознавание выполняется на устройстве, если язык поддерживается. Иначе iPhone может использовать сервер Apple. Качество проверим на реальных фразах.")
                }.font(.footnote)
            }.navigationTitle("Настройки")
                .toolbar { Button("Готово") { dismiss() }.disabled(busy) }
                .interactiveDismissDisabled(busy)
                .sheet(isPresented: Binding(get: { login.browserURL != nil }, set: { _ in })) {
                    if let url = login.browserURL { LoginBrowser(url: url).interactiveDismissDisabled() }
                }
                .onChange(of: vm.model) { _, value in UserDefaults.standard.set(value, forKey: "model") }
                .onDisappear { apiKey = "" }
                .confirmationDialog("Удалить API-ключ с этого iPhone?", isPresented: $removeKey, titleVisibility: .visible) {
                    Button("Удалить ключ", role: .destructive) {
                        do { try RealtimeKeyStore.remove(); keySaved = false; keyMessage = "Ключ удалён" }
                        catch { keyMessage = error.localizedDescription }
                    }
                    Button("Отмена", role: .cancel) {}
                }
                .task {
                    keySaved = ((try? RealtimeKeyStore.load()) ?? nil) != nil
                    guard !vm.account.isEmpty, !busy else { return }
                    busy = true
                    defer { busy = false }
                    do { try await vm.loadModels() } catch { message = error.localizedDescription }
                }
        }
    }
}
struct LoginBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
