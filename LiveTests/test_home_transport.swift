import Foundation

@main struct LiveTransportTests {
    static func main() {
        assert(LiveTransport(rawValue: "websocket") == .webSocket)
        assert(LiveTransport(rawValue: "webrtc") == .webRTC)
        for partner in PartnerLanguage.allCases {
            assert(LiveTranslationDirection.output(forSource: "ru", partner: partner) == partner.rawValue)
            assert(LiveTranslationDirection.output(forSource: partner.rawValue, partner: partner) == "ru")
            assert(LiveTranslationDirection.output(forSource: "invalid", partner: partner) == nil)
        }
        assert(LiveTransport.webSocket.title == "WebSocket")
        assert(LiveTransport.webRTC.title == "WebRTC")
        print("Home transport routing preserves both language directions")
    }
}
