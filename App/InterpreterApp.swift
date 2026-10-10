import SwiftUI
import AVFoundation
import SafariServices

@main struct InterpreterApp: App {
    var body: some Scene { WindowGroup { InterpreterView().preferredColorScheme(.dark) } }
}

@MainActor final class Conversation: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum Phase { case idle, starting, listening, finishing, translating, playing }
    @Published var phase: Phase = .idle
    @Published var source = ""
    @Published var translation = ""
    @Published var language = "ru"
    @Published var message = "Выбери язык и произнеси фразу"
    @Published var models: [ModelChoice] = []
    @Published var account = ""
    @Published var model = UserDefaults.standard.string(forKey: "model") ?? ""
    private let capture = SpeechCapture()
    private let speaker = AVSpeechSynthesizer()
    private var activeUtterance: AVSpeechUtterance?
    private var work: Task<Void, Never>?
    private var epoch = UUID()
    override init() { super.init(); speaker.delegate = self; account = (try? SessionStore.load())?.email ?? "" }
    var busy: Bool { phase != .idle }
    func tap(_ language: String) {
        if phase == .listening {
            phase = .finishing; message = "Завершаю распознавание…"
            capture.finish { [weak self] error in self?.recognized(error) }
            return
        }
        guard phase == .idle else { return }
        self.language = language; source = ""; translation = ""
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
        guard phase == .idle else { return }
        let text = source, target = language == "ru" ? "German" : "Russian"
        let token = epoch
        phase = .translating; translation = ""; message = "Перевожу…"
        work = Task {
            do {
                guard let stored = try SessionStore.load() else { throw Failure.message("Войди в ChatGPT в настройках.") }
                let session = try await OpenAI.refresh(stored)
                let result = try await Translation.run(text, target: target, model: model, session: session) { [weak self] update in
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
        guard phase == .idle, !translation.isEmpty else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            guard let voice = AVSpeechSynthesisVoice(language: language == "ru" ? "de-DE" : "ru-RU") else {
                throw Failure.message("Голос озвучки недоступен. Перевод показан на экране.")
            }
            let utterance = AVSpeechUtterance(string: translation); utterance.voice = voice
            activeUtterance = utterance
            phase = .playing; message = "Звучит перевод"; speaker.speak(utterance)
        } catch { message = error.localizedDescription }
    }
    func cancel() {
        epoch = UUID(); work?.cancel(); work = nil; capture.cancel()
        activeUtterance = nil
        speaker.stopSpeaking(at: .immediate)
        if phase == .translating { translation = "" }
        phase = .idle; message = "Остановлено"
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
                HStack(spacing: 16) {
                    languageButton("Русский", language: "ru")
                    languageButton("Deutsch", language: "de")
                }
                Text("Нажми язык → скажи фразу → нажми ещё раз").font(.footnote).foregroundStyle(.secondary)
                if vm.busy { Button("Остановить") { vm.cancel() }.buttonStyle(.bordered) }
                VStack(alignment: .leading, spacing: 12) {
                    Text("УСЛЫШАЛА · \(vm.language == "ru" ? "РУССКИЙ" : "DEUTSCH")").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $vm.source).frame(minHeight: 90).scrollContentBackground(.hidden).disabled(vm.busy)
                    HStack {
                        Button("Перевести текст") { vm.translate() }.disabled(vm.busy || vm.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Spacer()
                        if !vm.source.isEmpty { Text("Можно исправить").font(.caption).foregroundStyle(.secondary) }
                    }
                    Divider()
                    Text("ПЕРЕВОД").font(.caption).foregroundStyle(.secondary)
                    Text(vm.translation.isEmpty ? "—" : vm.translation).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Прослушать снова") { vm.speak() }.disabled(vm.busy || vm.translation.isEmpty)
                }.padding(20).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24))
            }.padding(24)
        }.background(Color(red: 0.035, green: 0.06, blue: 0.09))
        .sheet(isPresented: $settings) { SettingsView(vm: vm) }
        .onChange(of: scenePhase) { _, phase in if phase == .background { vm.cancel() } }
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
    @ObservedObject var vm: Conversation
    @StateObject private var login = Login()
    @State private var busy = false
    @State private var message = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
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
                    Text("Перевод использует лимиты твоей подписки ChatGPT. Аудио в OpenAI не отправляется: туда уходит только распознанный текст.")
                    Text("Распознавание выполняется на устройстве, если язык поддерживается. Иначе iPhone может использовать сервер Apple. Качество проверим на реальных фразах.")
                }.font(.footnote)
            }.navigationTitle("Настройки")
                .toolbar { Button("Готово") { dismiss() }.disabled(busy) }
                .interactiveDismissDisabled(busy)
                .sheet(isPresented: Binding(get: { login.browserURL != nil }, set: { _ in })) {
                    if let url = login.browserURL { LoginBrowser(url: url).interactiveDismissDisabled() }
                }
                .onChange(of: vm.model) { _, value in UserDefaults.standard.set(value, forKey: "model") }
                .task {
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
