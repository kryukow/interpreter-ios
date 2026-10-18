import Foundation

/// The transport selector changes only the translation engine.
/// Both engines use the same fixed Russian ↔ partner language direction.
enum LiveTransport: String, CaseIterable, Identifiable {
    case webSocket = "websocket"
    case webRTC = "webrtc"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .webSocket: return "WebSocket"
        case .webRTC: return "WebRTC"
        }
    }
}

enum LiveTranslationDirection {
    /// Russian button: Russian -> selected language.
    /// Partner button: selected language -> Russian.
    static func output(forSource source: String, partner: PartnerLanguage) -> String? {
        switch source {
        case "ru": return partner.rawValue
        case partner.rawValue: return "ru"
        default: return nil
        }
    }
}
