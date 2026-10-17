import Foundation

/// Language tags supported by the current Chatterbox Multilingual v2/Core ML model.
/// All options share the same downloaded weights and saved cloned voice.
struct VoiceSynthesisLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    let sample: String
    var id: String { code }

    static let all: [VoiceSynthesisLanguage] = [
        .init(code: "ru", name: "Русский", sample: "Привет! Это мой собственный голос, созданный прямо на телефоне."),
        .init(code: "de", name: "Deutsch", sample: "Guten Morgen! Ich teste meine eigene Stimme auf Deutsch."),
        .init(code: "en", name: "English", sample: "Hello! This is my own voice speaking English."),
        .init(code: "es", name: "Español", sample: "Hola, buenos días. Estoy probando mi propia voz."),
        .init(code: "fr", name: "Français", sample: "Bonjour ! Je teste ma propre voix en français."),
        .init(code: "pl", name: "Polski", sample: "Dzień dobry! Sprawdzam swój własny głos."),
        .init(code: "it", name: "Italiano", sample: "Buongiorno! Sto provando la mia voce."),
        .init(code: "pt", name: "Português", sample: "Olá, bom dia! Estou a testar a minha própria voz."),
        .init(code: "nl", name: "Nederlands", sample: "Goedemorgen! Ik test mijn eigen stem."),
        .init(code: "sv", name: "Svenska", sample: "God morgon! Jag testar min egen röst."),
        .init(code: "da", name: "Dansk", sample: "Godmorgen! Jeg afprøver min egen stemme."),
        .init(code: "no", name: "Norsk", sample: "God morgen! Jeg prøver min egen stemme."),
        .init(code: "fi", name: "Suomi", sample: "Hyvää huomenta! Kokeilen omaa ääntäni."),
        .init(code: "tr", name: "Türkçe", sample: "Günaydın! Kendi sesimi deniyorum."),
        .init(code: "el", name: "Ελληνικά", sample: "Καλημέρα! Δοκιμάζω τη δική μου φωνή."),
        .init(code: "ar", name: "العربية", sample: "مرحباً! أنا أجرب صوتي الخاص."),
        .init(code: "he", name: "עברית", sample: "שלום! אני בודק את הקול שלי."),
        .init(code: "hi", name: "हिन्दी", sample: "नमस्ते! मैं अपनी आवाज़ की जाँच कर रहा हूँ।"),
        .init(code: "zh", name: "中文", sample: "你好！我正在测试自己的声音。"),
        .init(code: "ja", name: "日本語", sample: "こんにちは。自分の声を試しています。"),
        .init(code: "ko", name: "한국어", sample: "안녕하세요! 제 목소리를 시험하고 있습니다."),
        .init(code: "ms", name: "Bahasa Melayu", sample: "Selamat pagi! Saya sedang menguji suara saya sendiri."),
        .init(code: "sw", name: "Kiswahili", sample: "Habari za asubuhi! Ninajaribu sauti yangu mwenyewe.")
    ]

    static func sample(for code: String) -> String? {
        all.first(where: { $0.code == code })?.sample
    }

    static func supports(_ code: String) -> Bool {
        all.contains(where: { $0.code == code })
    }
}
