import SwiftUI
import AVFoundation

@MainActor final class VoicePreferences: ObservableObject {
    @Published var russian: String = UserDefaults.standard.string(forKey: "voice.ru") ?? "" {
        didSet { UserDefaults.standard.set(russian, forKey: "voice.ru") }
    }
    @Published var german: String = UserDefaults.standard.string(forKey: "voice.de") ?? "" {
        didSet { UserDefaults.standard.set(german, forKey: "voice.de") }
    }
    @Published var rate: Double = UserDefaults.standard.object(forKey: "voice.rate") as? Double ?? 0.48 {
        didSet { UserDefaults.standard.set(rate, forKey: "voice.rate") }
    }
    @Published private(set) var available: [AVSpeechSynthesisVoice] = []
    init() { refresh() }
    func refresh() { available = AVSpeechSynthesisVoice.speechVoices() }
    func voices(for language: String) -> [AVSpeechSynthesisVoice] {
        let prefix = String(language.prefix(2)).lowercased()
        return available.filter { $0.language.lowercased().hasPrefix(prefix + "-") }.sorted {
            if $0.quality.rawValue != $1.quality.rawValue { return $0.quality.rawValue > $1.quality.rawValue }
            if ($0.language == language) != ($1.language == language) { return $0.language == language }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let chosen = language.hasPrefix("ru") ? russian : german
        let list = voices(for: language)
        return list.first { $0.identifier == chosen } ?? list.first ?? AVSpeechSynthesisVoice(language: language)
    }
    static func quality(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return "Премиум"
        case .enhanced: return "Повышенное качество"
        default: return "Обычный"
        }
    }
    var speechRate: Float { Float(min(0.60, max(0.35, rate))) }
}

struct VoiceSettingsView: View {
    @ObservedObject var preferences: VoicePreferences
    @State private var preview = AVSpeechSynthesizer()
    @State private var message = ""
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Section("Голоса перевода") {
            voicePicker("Русский", locale: "ru-RU", selection: $preferences.russian)
            voicePicker("Deutsch", locale: "de-DE", selection: $preferences.german)
            Text("Автоматически выбирается лучший доступный голос: сначала премиум, затем повышенного качества.")
                .font(.footnote).foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text("Скорость речи")
                Slider(value: $preferences.rate, in: 0.35...0.60, step: 0.01)
                HStack { Text("Медленнее"); Spacer(); Text("Быстрее") }.font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Послушать русский") { sample("Привет! Теперь можно выбрать более естественный голос для перевода.", locale: "ru-RU") }
                Spacer()
                Button("Deutsch hören") { sample("Hallo! Du kannst jetzt eine angenehmere Stimme für die Übersetzung auswählen.", locale: "de-DE") }
            }.buttonStyle(.borderless)
            Button("Остановить образец") { preview.stopSpeaking(at: .immediate) }
            Button("Обновить голоса") { preferences.refresh() }
            if !message.isEmpty { Text(message).font(.footnote) }
            if !preferences.voices(for: "ru-RU").contains(where: { $0.quality != .default }) ||
               !preferences.voices(for: "de-DE").contains(where: { $0.quality != .default }) {
                Text("Для одного из языков доступен только обычный голос. Загрузи улучшенный голос в настройках iPhone, затем вернись сюда и обнови список.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Link("Как загрузить качественные голоса Apple", destination: URL(string: "https://support.apple.com/en-us/111798")!)
        }
        .onAppear { preferences.refresh() }
        .onDisappear { preview.stopSpeaking(at: .immediate) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { preferences.refresh() }
            else { preview.stopSpeaking(at: .immediate) }
        }
        .onChange(of: preferences.russian) { _, _ in preview.stopSpeaking(at: .immediate) }
        .onChange(of: preferences.german) { _, _ in preview.stopSpeaking(at: .immediate) }
        .onChange(of: preferences.rate) { _, _ in preview.stopSpeaking(at: .immediate) }
    }
    private func voicePicker(_ title: String, locale: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(title, selection: selection) {
                Text("Автоматически · лучшее качество").tag("")
                ForEach(preferences.voices(for: locale), id: \.identifier) { voice in
                    Text("\(voice.name) · \(VoicePreferences.quality(voice)) · \(voice.language)").tag(voice.identifier)
                }
                if !selection.wrappedValue.isEmpty,
                   !preferences.voices(for: locale).contains(where: { $0.identifier == selection.wrappedValue }) {
                    Text("Выбранный голос недоступен").tag(selection.wrappedValue)
                }
            }
            if let current = preferences.voice(for: locale) {
                Text("Сейчас: \(current.name) · \(VoicePreferences.quality(current))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func sample(_ text: String, locale: String) {
        preview.stopSpeaking(at: .immediate)
        preferences.refresh()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio); try session.setActive(true)
            guard let voice = preferences.voice(for: locale) else { throw Failure.message("Голос для этого языка недоступен.") }
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice; utterance.rate = preferences.speechRate
            utterance.pitchMultiplier = 1.0
            message = "\(voice.name) · \(VoicePreferences.quality(voice))"
            preview.speak(utterance)
        } catch { message = error.localizedDescription }
    }
}
