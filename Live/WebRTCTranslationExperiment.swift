import AVFoundation
import Foundation
import SwiftUI
import UIKit
import WebRTC

/// Isolated WebRTC experiment. Does not touch the production WebSocket
/// translation path, its PCM player, WAV capture, or account ledger.
@MainActor final class WebRTCTranslationExperiment: NSObject, ObservableObject {
    enum Phase {
        case idle, connecting, ready, speaking, finishing, finished, failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "Подключение не начато"
    @Published private(set) var transcript = ""
    @Published private(set) var diagnostic = ""
    @Published private(set) var targetLanguage = "de"

    var canTalk: Bool { phase == .ready }
    var isSpeaking: Bool { phase == .speaking }

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    private var peer: RTCPeerConnection?
    private var events: RTCDataChannel?
    private var microphoneTrack: RTCAudioTrack?
    private var connectingTask: Task<Void, Never>?
    private var generation = UUID()
    private var lastEventAt: Date?
    private var startedAt: Date?
    private var beganSpeakingAt: Date?
    private var finishedSpeakingAt: Date?
    private var firstTextAt: Date?
    private var didConnect = false
    private var channelOpen = false
    private var receivedEvents = 0
    private var remoteAudioTracks = 0

    func connect(target: String) {
        guard phase == .idle || phase == .finished || phase == .failed else { return }
        disconnect()
        targetLanguage = target
        phase = .connecting
        status = "Открываю WebRTC · пока не говори"
        transcript = ""
        diagnostic = ""
        startedAt = Date()
        let token = generation
        connectingTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw ExperimentError.microphone
                }
                guard self.generation == token, !Task.isCancelled else { return }
                let key = try LiveKey.read()
                let secret = try await Self.fetchShortLivedSecret(key: key, target: target)
                guard self.generation == token, !Task.isCancelled else { return }

                try AVAudioSession.sharedInstance().setCategory(
                    .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth]
                )
                try AVAudioSession.sharedInstance().setActive(true)
                let config = RTCConfiguration()
                config.sdpSemantics = .unifiedPlan
                // OpenAI answer contains the ICE candidates. Avoid third-party
                // STUN servers in this proof of concept.
                let constraints = RTCMediaConstraints(
                    mandatoryConstraints: nil,
                    optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue]
                )
                guard let pc = Self.factory.peerConnection(
                    with: config, constraints: constraints, delegate: self
                ) else { throw ExperimentError.peerCreation }
                self.peer = pc
                let source = Self.factory.audioSource(with: RTCMediaConstraints(
                    mandatoryConstraints: nil, optionalConstraints: nil
                ))
                let track = Self.factory.audioTrack(with: source, trackId: "input-audio")
                track.isEnabled = false // Never record until the user presses Talk.
                self.microphoneTrack = track
                _ = pc.add(track, streamIds: ["interpreter-input"])
                let channelConfig = RTCDataChannelConfiguration()
                channelConfig.isOrdered = true
                guard let channel = pc.dataChannel(forLabel: "oai-events", configuration: channelConfig)
                else { throw ExperimentError.dataChannel }
                channel.delegate = self
                self.events = channel

                let offer = try await Self.createOffer(pc)
                guard self.generation == token else { return }
                try await Self.setLocal(pc, offer)
                guard self.generation == token else { return }
                let answerSDP = try await Self.exchangeSDP(offer.sdp, secret: secret)
                guard self.generation == token else { return }
                try await Self.setRemote(pc, RTCSessionDescription(type: .answer, sdp: answerSDP))
                guard self.generation == token else { return }
                self.status = "WebRTC согласован · ожидаю подключение аудио"
                self.refreshReadiness()
            } catch {
                guard self.generation == token else { return }
                self.fail(error)
            }
        }
    }

    func beginSpeaking() {
        guard phase == .ready else { return }
        microphoneTrack?.isEnabled = true
        beganSpeakingAt = Date()
        phase = .speaking
        status = "Говори · перевод может звучать сразу · отпусти кнопку для завершения"
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func endSpeaking() {
        guard phase == .speaking else { return }
        microphoneTrack?.isEnabled = false
        finishedSpeakingAt = Date()
        phase = .finishing
        status = "Микрофон отключён · завершаю перевод"
        guard let events, events.readyState == .open else {
            fail(ExperimentError.dataChannel)
            return
        }
        let ok = events.sendData(RTCDataBuffer(
            data: Data(#"{"type":"session.close"}"#.utf8), isBinary: false
        ))
        if !ok { fail(ExperimentError.sessionClose) }
    }

    func disconnect() {
        generation = UUID()
        connectingTask?.cancel()
        connectingTask = nil
        microphoneTrack?.isEnabled = false
        events?.delegate = nil
        events?.close()
        peer?.delegate = nil
        peer?.close()
        events = nil
        peer = nil
        microphoneTrack = nil
        channelOpen = false
        didConnect = false
        receivedEvents = 0
        remoteAudioTracks = 0
        lastEventAt = nil
        startedAt = nil
        beganSpeakingAt = nil
        finishedSpeakingAt = nil
        firstTextAt = nil
        phase = .idle
        status = "Отключено"
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func refreshReadiness() {
        guard phase == .connecting, didConnect, channelOpen else { return }
        phase = .ready
        status = "WebRTC подключён · удерживай кнопку и говори"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func fail(_ error: Error) {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        disconnect()
        phase = .failed
        status = "Ошибка WebRTC: " + text
    }

    private func received(_ data: Data) {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        receivedEvents += 1
        lastEventAt = Date()
        switch type {
        case "session.output_transcript.delta":
            if firstTextAt == nil { firstTextAt = Date() }
            let delta = event["delta"] as? String ?? ""
            guard transcript.utf8.count + delta.utf8.count < 100_000 else { return }
            transcript += delta
        case "session.closed":
            // The server has flushed its output. Allow receiver audio playout
            // an additional moment before closing the peer.
            let snapshot = summary()
            diagnostic = snapshot
            phase = .finished
            status = "Сеанс завершён · сравни звучание с WebSocket"
            microphoneTrack?.isEnabled = false
            let token = generation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self, self.generation == token else { return }
                self.events?.delegate = nil
                self.events?.close()
                self.peer?.close()
                self.events = nil
                self.peer = nil
                self.microphoneTrack = nil
                try? AVAudioSession.sharedInstance().setActive(
                    false, options: .notifyOthersOnDeactivation
                )
            }
        case "error":
            let serverError = event["error"] as? [String: Any]
            let code = serverError?["code"] as? String ?? "unknown"
            fail(ExperimentError.server(code))
        default: break
        }
    }

    private func summary() -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func stamp(_ date: Date?) -> String { date.map { iso.string(from: $0) } ?? "—" }
        return [
            "Interpreter Live WebRTC diagnostic (metadata only)",
            "model=gpt-realtime-translate target=\(targetLanguage)",
            "start=\(stamp(startedAt))",
            "push_to_talk_begin=\(stamp(beganSpeakingAt))",
            "push_to_talk_end=\(stamp(finishedSpeakingAt))",
            "first_transcript_event=\(stamp(firstTextAt))",
            "last_event=\(stamp(lastEventAt))",
            "received_data_channel_events=\(receivedEvents)",
            "remote_audio_tracks=\(remoteAudioTracks)",
            "session.closed=true",
            "Remote WebRTC audio is played by WebRTC (not stored as PCM/WAV)."
        ].joined(separator: "\n")
    }

    private static func fetchShortLivedSecret(key: String, target: String) async throws -> String {
        guard ["ru", "de", "en", "ro", "es", "pl"].contains(target) else {
            throw ExperimentError.language
        }
        let url = URL(string: "https://api.openai.com/v1/realtime/translations/client_secrets")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "session": [
                "model": "gpt-realtime-translate",
                "audio": [
                    "input": ["noise_reduction": NSNull(), "transcription": NSNull()],
                    "output": ["language": target]
                ]
            ]
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw ExperimentError.secretRequest
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExperimentError.secretRequest
        }
        let nested = parsed["client_secret"] as? [String: Any]
        guard let secret = (parsed["client_secret"] as? String)
            ?? (nested?["value"] as? String) ?? (parsed["value"] as? String),
              !secret.isEmpty else { throw ExperimentError.secretRequest }
        return secret
    }

    private static func exchangeSDP(_ offer: String, secret: String) async throws -> String {
        var request = URLRequest(url: URL(
            string: "https://api.openai.com/v1/realtime/translations/calls"
        )!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(offer.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let answer = String(data: data, encoding: .utf8),
              answer.hasPrefix("v=0") else { throw ExperimentError.sdp }
        return answer
    }

    private static func createOffer(_ pc: RTCPeerConnection) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            pc.offer(for: RTCMediaConstraints(
                mandatoryConstraints: [
                    kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue
                ], optionalConstraints: nil
            )) { sdp, error in
                if let sdp { continuation.resume(returning: sdp) }
                else { continuation.resume(throwing: error ?? ExperimentError.sdp) }
            }
        }
    }

    private static func setLocal(_ pc: RTCPeerConnection, _ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    private static func setRemote(_ pc: RTCPeerConnection, _ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    private enum ExperimentError: LocalizedError {
        case microphone, peerCreation, dataChannel, sessionClose, secretRequest, sdp, language
        case server(String)

        var errorDescription: String? {
            switch self {
            case .microphone: "Разреши доступ к микрофону в настройках iPhone"
            case .peerCreation: "Не удалось создать WebRTC-соединение"
            case .dataChannel: "Нет канала событий WebRTC"
            case .sessionClose: "Не удалось отправить session.close"
            case .secretRequest: "OpenAI не выдал временный ключ WebRTC — проверь доступ API"
            case .sdp: "Не удалось согласовать WebRTC с OpenAI"
            case .language: "Выбранный язык недоступен"
            case .server(let code): "Ответ OpenAI: \(code)"
            }
        }
    }
}

extension WebRTCTranslationExperiment: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        Task { @MainActor [weak self] in self?.remoteAudioTracks += stream.audioTracks.count }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didChange newState: RTCIceConnectionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch newState {
            case .connected, .completed:
                self.didConnect = true
                self.refreshReadiness()
            case .failed, .disconnected:
                if self.phase == .ready || self.phase == .speaking {
                    self.fail(ExperimentError.peerCreation)
                }
            default: break
            }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection,
                                    didOpen dataChannel: RTCDataChannel) {}
}

extension WebRTCTranslationExperiment: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor [weak self] in
            guard let self, self.events === dataChannel else { return }
            self.channelOpen = dataChannel.readyState == .open
            self.refreshReadiness()
        }
    }

    nonisolated func dataChannel(_ dataChannel: RTCDataChannel,
                                  didReceiveMessageWith buffer: RTCDataBuffer) {
        let value = buffer.data
        Task { @MainActor [weak self] in
            guard let self, self.events === dataChannel else { return }
            self.received(value)
        }
    }
}
