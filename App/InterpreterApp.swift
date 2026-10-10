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
    @Published var reviewResponse = false
    @Published var reviewingOriginal = false
    @Published var playbackTiming = ""
    @Published var canReviewInput = false
    @Published var heldLanguage: String?
    @Published var soundLevels = Array(repeating: CGFloat(0), count: 40)
    private func addLevel(_ level: Double) {
        soundLevels.removeFirst(); soundLevels.append(CGFloat(min(1, max(0, level))))
    }
    @Published var budget: AudioBudget = {
        guard let data = UserDefaults.standard.data(forKey: "audioBudget.v1"),
              let budget = try? JSONDecoder().decode(AudioBudget.self, from: data) else { return AudioBudget() }
        return budget
    }()
    private let realtime = RealtimeTranslation()
    private var realtimeAudio: Data?
    private var originalRealtimeAudio: Data?
    private var submittedRealtimeAudio: Data?
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
                    onText: { [weak self] text in
                        guard let self, self.epoch == token else { return }; self.source = text
                    },
                    onEnd: { [weak self] error in
                        guard let self, self.epoch == token else { return }; self.recognized(error)
                    },
                    onLevel: { [weak self] level in
                        guard let self, self.epoch == token else { return }; self.addLevel(level)
                    })
                guard epoch == token else { return }
                phase = .listening; message = "Говори. Отпусти кнопку, чтобы перевести"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                guard epoch == token else { return }
                capture.cancel(); heldLanguage = nil; phase = .idle; message = error.localizedDescription
            }
        }
    }
    private func recognized(_ error: Error?) {
        guard phase == .listening || phase == .finishing || phase == .starting else { return }
        heldLanguage = nil; phase = .idle
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
        guard phase == .idle || (realtimeMode && phase == .playing) else { return }
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
        soundLevels = Array(repeating: 0, count: 40)
        heldLanguage = nil
        epoch = UUID(); work?.cancel(); work = nil; capture.cancel()
        realtime.cancel()
        activeUtterance = nil
        speaker.stopSpeaking(at: .immediate)
        if phase == .translating { translation = "" }
        phase = .idle; message = "Остановлено"
    }
    func holdBegin(_ language: String) {
        guard heldLanguage == nil else { return }
        if busy { cancel() }
        heldLanguage = language
        tap(language)
    }
    func holdEnd(_ language: String) {
        guard heldLanguage == language else { return }
        heldLanguage = nil
        if phase == .starting {
            cancel(); message = "Удерживай кнопку до вибросигнала, затем говори"; return
        }
        guard phase == .listening else { return }
        phase = .finishing; message = "Завершаю перевод…"
        if realtimeMode { realtime.finish() }
        else { capture.finish { [weak self] error in self?.recognized(error) } }
    }
    func holdCancel(_ language: String) {
        guard heldLanguage == language else { return }
        cancel(); message = "Запись отменена. Удерживай кнопку, чтобы начать снова"
    }
    private func recordAudio(_ bytes: Int) {
        budget.record(bytes: bytes)
        if let data = try? JSONEncoder().encode(budget) { UserDefaults.standard.set(data, forKey: "audioBudget.v1") }
    }
    func setBudget(_ text: String) -> Bool {
        guard budget.setRemaining(text) else { return false }
        if let data = try? JSONEncoder().encode(budget) { UserDefaults.standard.set(data, forKey: "audioBudget.v1") }
        return true
    }
    var balanceLabel: String {
        if let amount = budget.remaining { return String(format: "≈ $%.3f", amount) }
        return "Не задан"
    }
    private func tapRealtime(_ language: String) {
        if phase == .listening {
            guard self.language == language else { return }
            phase = .finishing; message = "Завершаю голосовой перевод…"; realtime.finish(); return
        }
        guard phase == .idle else { return }
        self.language = language; source = ""; translation = ""; restored = ""
        realtimeAudio = nil; originalRealtimeAudio = nil; reviewResponse = false; reviewingOriginal = false; realtimeStats = ""
        submittedRealtimeAudio = nil; canReviewInput = false
        phase = .starting; message = "Подключаю голосовой перевод…"
        let token = epoch
        work = Task {
            do {
                try Task.checkCancellation()
                guard let key = try RealtimeKeyStore.load(), !key.isEmpty else {
                    throw Failure.message("Добавь API-ключ в настройках → Голосовой перевод API.")
                }
                let result = try await realtime.run(key: key, source: language, target: language == "ru" ? "de" : "ru",
                    onReady: { [weak self] in
                        guard let self, self.epoch == token else { return }
                        self.phase = .listening; self.message = "Говори. Отпусти кнопку — прозвучит перевод"
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    }, onFinishing: { [weak self] in
                        guard let self, self.epoch == token else { return }
                        self.phase = .finishing; self.message = "Получаю окончание голосового перевода…"
                    }, onText: { [weak self] text in
                        guard let self, self.epoch == token else { return }
                        self.translation = text
                    }, onSubmitted: { [weak self] bytes in
                        guard let self, self.epoch == token else { return }; self.recordAudio(bytes)
                    },
                    onLevel: { [weak self] level in
                        guard let self, self.epoch == token else { return }; self.addLevel(level)
                    }, onInputText: { [weak self] text in
                        guard let self, self.epoch == token else { return }; self.source = text
                    })
                guard epoch == token else { return }
                translation = result.text; realtimeAudio = result.audio
                originalRealtimeAudio = result.originalAudio; reviewResponse = result.needsReview
                submittedRealtimeAudio = result.submittedAudio; canReviewInput = submittedRealtimeAudio != nil
                realtimeStats = (language == "ru" ? "Русский → Deutsch · подтверждено OpenAI" : "Deutsch → Русский · подтверждено OpenAI")
                realtimeStats += String(format: "\nОтправлено %.1f с аудио", result.inputSeconds)
                realtimeStats += String(format: " · Записано %.1f с", result.capturedSeconds)
                if let delay = result.firstOutputSeconds { realtimeStats += String(format: " · Первый ответ %.1f с", delay) }
                realtimeStats += String(format: "\nПропущено тихих краёв: до %.1f с · после %.1f с", result.removedLeading, result.removedTrailing)
                realtimeStats += "\nОтвет завершён сервером · Частей текста: \(result.transcriptParts) · звука: \(result.audioParts)"
                if reviewResponse {
                    realtimeStats += result.inputLevel < 0.001 ? "\nОтправленный звук микрофона почти беззвучный." : "\nВ отправленном аудио есть звук. Текст перевода от OpenAI не получен."
                }
                heldLanguage = nil; phase = .idle
                if reviewResponse {
                    realtimeAudio = nil
                    message = "OpenAI не вернул текст перевода. Можно проверить исходный звук ответа без нового запроса."
                } else { speakRealtime() }
            } catch {
                guard epoch == token else { return }
                realtime.cancel(); realtimeAudio = nil; translation = ""
                heldLanguage = nil; phase = .idle; message = error.localizedDescription
            }
        }
    }
    private func speakRealtime() {
        guard let audio = reviewingOriginal ? originalRealtimeAudio : realtimeAudio else { return }
        do {
            phase = .playing; message = reviewingOriginal ? "Звучит исходный ответ OpenAI" : "Звучит голосовой перевод OpenAI"
            let token = epoch
            playbackTiming = ""
            try realtime.play(audio, onStarted: { [weak self] delay in
                guard let self, self.epoch == token else { return }
                self.playbackTiming = String(format: "Запуск плеера: %.2f с", delay)
            }, onFailed: { [weak self] error in
                guard let self, self.epoch == token else { return }; self.phase = .idle; self.message = error
            }) { [weak self] in
                guard let self, self.epoch == token else { return }
                self.phase = .idle; self.message = self.reviewResponse ? "Перевод не получен. Можно начать новую фразу." : "Готово. Выбери язык следующей фразы"
            }
        } catch { phase = .idle; message = error.localizedDescription }
    }
    func playOriginal() {
        guard phase == .idle || phase == .playing, originalRealtimeAudio != nil else { return }
        reviewingOriginal = true; speakRealtime()
    }
    func replay() { reviewingOriginal = false; speak() }
    func playSubmitted() {
        guard phase == .idle || phase == .playing, let audio = submittedRealtimeAudio else { return }
        do {
            phase = .playing; message = "Звучит запись, отправленная в OpenAI"
            let token = epoch
            try realtime.play(audio, onStarted: { [weak self] delay in
                guard let self, self.epoch == token else { return }
                self.playbackTiming = String(format: "Запуск плеера: %.2f с", delay)
            }, onFailed: { [weak self] error in
                guard let self, self.epoch == token else { return }; self.phase = .idle; self.message = error
            }) { [weak self] in
                guard let self, self.epoch == token else { return }
                self.phase = .idle; self.message = self.reviewResponse ? "Запись проверена. Перевод не получен." : "Запись проверена. Можно прослушать перевод или начать новую фразу."
            }
        } catch { phase = .idle; message = error.localizedDescription }
    }
    var canReplay: Bool { realtimeMode ? realtimeAudio != nil : !translation.isEmpty }
    func modeChanged() {
        cancel(); source = ""; translation = ""; restored = ""; realtimeAudio = nil; originalRealtimeAudio = nil; reviewResponse = false; realtimeStats = ""
        submittedRealtimeAudio = nil; canReviewInput = false
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
                Image(systemName: vm.phase == .listening ? "waveform" : "infinity").font(.system(size: 52, weight: .light)).foregroundStyle(.white)
                SoundWave(levels: vm.phase == .listening ? vm.soundLevels : Array(repeating: 0, count: 40),
                          waiting: vm.phase == .starting || vm.phase == .finishing || vm.phase == .translating)
                Text(vm.message).font(.headline).multilineTextAlignment(.center).frame(minHeight: 60)
                Text(vm.realtimeMode ? "LIVE · ГОЛОСОВОЙ ПЕРЕВОД" : "ПОДПИСКА CHATGPT")
                    .font(.caption).foregroundStyle(.secondary)
                if vm.realtimeMode {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("ОСТАТОК · ПРИМЕРНО").font(.caption2).foregroundStyle(.secondary)
                            Text(vm.balanceLabel).font(.title3.monospacedDigit().weight(.semibold))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) {
                            Text("РАСХОД ПРИЛОЖЕНИЯ").font(.caption2).foregroundStyle(.secondary)
                            Text(String(format: "$%.4f", vm.budget.spent)).font(.subheadline.monospacedDigit())
                        }
                    }.padding(18).background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 22))
                }
                HStack(spacing: 16) {
                    languageButton("Русский", language: "ru")
                    languageButton("Deutsch", language: "de")
                }
                Text("Держи → дождись вибросигнала → говори → отпусти").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 12) {
                    if vm.realtimeMode {
                        Text("ГОЛОС → ПЕРЕВОД").font(.caption).foregroundStyle(.secondary)
                        Text("Модель переводит непосредственно аудио. Текст появится по мере перевода, голос прозвучит после завершения записи.").font(.footnote).foregroundStyle(.secondary)
                        if !vm.realtimeStats.isEmpty { Text(vm.realtimeStats).font(.footnote).foregroundStyle(.secondary) }
                        if !vm.source.isEmpty {
                            Text("ПРОВЕРКА МИКРОФОНА · \(vm.language == "ru" ? "РУССКИЙ" : "DEUTSCH")").font(.caption).foregroundStyle(.secondary)
                            Text(vm.source).font(.footnote).textSelection(.enabled)
                            Text("Распознано на iPhone. OpenAI получает исходный голос.").font(.caption2).foregroundStyle(.secondary)
                        }
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
                    Button("Прослушать снова") { vm.replay() }.disabled((vm.busy && !(vm.realtimeMode && vm.phase == .playing)) || !vm.canReplay)
                    if vm.realtimeMode && !vm.playbackTiming.isEmpty {
                        Text(vm.playbackTiming).font(.caption2).foregroundStyle(.secondary)
                    }
                    if vm.realtimeMode && vm.reviewResponse {
                        Button("Проверить исходный ответ · бесплатно") { vm.playOriginal() }.disabled(vm.busy && vm.phase != .playing)
                        Text("В ответе нет текста перевода. Исходный звук сохранён в памяти без обрезки; он может содержать тишину.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if vm.realtimeMode && vm.canReviewInput {
                        Button("Послушать отправленную запись · бесплатно") { vm.playSubmitted() }.disabled(vm.busy && vm.phase != .playing)
                        Text("Это точная запись, отправленная в этой фразе. Прослушивание на iPhone, без нового запроса.").font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(20).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24))
                Text(appVersion).font(.caption2).foregroundStyle(.secondary)
            }.padding(24)
        }.background(Color.black).tint(.white)
        .sheet(isPresented: $settings) { SettingsView(vm: vm) }
        .onAppear { updateScreenAwake() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: keepScreenAwake) { _, _ in updateScreenAwake() }
        .onChange(of: vm.realtimeMode) { _, _ in vm.modeChanged() }
        .onChange(of: vm.source) { _, _ in if !vm.realtimeMode && !vm.busy { vm.restored = ""; vm.translation = "" } }
        .onChange(of: scenePhase) { _, phase in
            updateScreenAwake()
            if phase == .background { vm.cancel() }
        }
    }
    private func updateScreenAwake() {
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwake && scenePhase == .active
    }
    func languageButton(_ title: String, language: String) -> some View {
        HoldToTalkButton(title: title, subtitle: language == "ru" ? "→ DEUTSCH" : "→ РУССКИЙ",
            active: vm.heldLanguage == language,
            onBegin: { vm.holdBegin(language) }, onEnd: { vm.holdEnd(language) },
            onCancel: { vm.holdCancel(language) })
            .frame(maxWidth: .infinity).frame(height: 170)
    }
}

private var appVersion: String {
    let info = Bundle.main.infoDictionary ?? [:]
    return "Interpreter \(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"
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
    @State private var balanceInput = ""
    @State private var balanceMessage = ""
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
                if vm.realtimeMode {
                    Section("Счётчик расходов") {
                        LabeledContent("Примерный остаток", value: vm.balanceLabel)
                        LabeledContent("Расход приложения", value: String(format: "$%.4f", vm.budget.spent))
                        TextField("Текущий остаток на сайте, USD", text: $balanceInput).keyboardType(.decimalPad)
                        Button("Установить текущий остаток") {
                            if vm.setBudget(balanceInput) { balanceInput = ""; balanceMessage = "Остаток обновлён" }
                            else { balanceMessage = "Введи сумму в долларах, например 9,90" }
                        }.disabled(balanceInput.isEmpty)
                        Text("Один раз укажи фактический остаток с сайта. После пополнения обнови его здесь. Приложение вычитает оценку по отправленному аудио, включая отменённые фразы. Озвучивание сохранённого перевода повторно бесплатно. Это локальная оценка, а не баланс, полученный от OpenAI.").font(.footnote)
                        if !balanceMessage.isEmpty { Text(balanceMessage).font(.footnote) }
                    }
                }
                Section("Экран") {
                    Toggle("Не гасить экран", isOn: $keepScreenAwake)
                    Text("Экран остаётся включённым, пока Interpreter открыт. При сворачивании обычная автоблокировка возвращается.").font(.footnote)
                }
                if !vm.realtimeMode { VoiceSettingsView(preferences: vm.voices) }
                if !vm.realtimeMode { Section("ChatGPT") {
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
                } }
                Section {
                    Text("В режиме подписки восстановление смысла и перевод выполняются двумя запросами через лимиты ChatGPT. Аудио в OpenAI не отправляется: туда уходит только текст. В голосовом режиме API в OpenAI передаётся аудио.")
                    Text("Распознавание выполняется на устройстве, если язык поддерживается. Иначе iPhone может использовать сервер Apple. Качество проверим на реальных фразах.")
                }.font(.footnote)
                Section { Text(appVersion).font(.caption).foregroundStyle(.secondary) }
            }.navigationTitle("Настройки").tint(.white)
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
                    guard !vm.realtimeMode, !vm.account.isEmpty, !busy else { return }
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
