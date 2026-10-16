import Foundation

/// The only conversation partners shown in Interpreter Live.
/// Russian is the fixed second language, so direction stays explicit.
enum PartnerLanguage: String, CaseIterable, Identifiable {
    case de, ro, en, es, pl

    var id: String { rawValue }
    var name: String {
        switch self {
        case .de: return "Deutsch"
        case .ro: return "Română"
        case .en: return "English"
        case .es: return "Español"
        case .pl: return "Polski"
        }
    }
    var flag: String {
        switch self {
        case .de: return "🇩🇪"
        case .ro: return "🇷🇴"
        case .en: return "🇬🇧"
        case .es: return "🇪🇸"
        case .pl: return "🇵🇱"
        }
    }
    var buttonName: String { name }
    var uppercaseName: String { name.uppercased() }

    /// The explicit microphone source and translated output directions.
    func outputCode(whenSourceIsRussian: Bool) -> String {
        whenSourceIsRussian ? rawValue : "ru"
    }

    static func current(_ value: String) -> PartnerLanguage {
        PartnerLanguage(rawValue: value) ?? .de
    }
}
