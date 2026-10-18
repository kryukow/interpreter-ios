import SwiftUI
import UIKit

/// Separate experimental screen: the existing Push-to-Talk buttons still use
/// WebSockets, and all existing import, replay and Chatterbox features remain.
struct WebRTCExperimentView: View {
    @StateObject private var engine = WebRTCTranslationExperiment()
    @State private var target = "de"
    @State private var holding = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("WebRTC · эксперимент")
                    .font(.title2.bold())
                Text("Та же модель gpt-realtime-translate, но голос передаётся через WebRTC. Основной WebSocket остаётся без изменений.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Toggle("Озвучивать только после отпускания", isOn: $engine.playbackAfterRelease)
                    .font(.subheadline.weight(.medium))
                    .disabled(engine.phase != .idle &&
                              engine.phase != .finished &&
                              engine.phase != .failed)
                Text(engine.playbackAfterRelease
                    ? "Как в привычном Push-to-Talk: пока держишь кнопку — тишина. После отпускания звучит накопленный голос OpenAI с начала, без потери первых слов."
                    : "Живой режим: перевод OpenAI звучит параллельно твоей речи.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Язык результата")
                        .font(.headline)
                    Picker("Переводить на", selection: $target) {
                        Text("Deutsch").tag("de")
                        Text("Русский").tag("ru")
                        Text("English").tag("en")
                        Text("Español").tag("es")
                    }
                    .pickerStyle(.segmented)
                    .disabled(engine.phase != .idle &&
                              engine.phase != .finished &&
                              engine.phase != .failed)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label(engine.status, systemImage: statusIcon)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 7) {
                        Image(systemName: "speaker.wave.2")
                        Text("Аудиовыход: " + engine.audioOutput)
                            .font(.caption.weight(.medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    if engine.canRetrySpeaker && engine.audioOutput.contains("Разговорный") {
                        Button("Включить громкий динамик iPhone") {
                            engine.configureAudioOutput()
                        }
                        .font(.caption.weight(.semibold))
                    }
                    if let issue = engine.speakerRoutingIssue {
                        Text(issue).font(.caption).foregroundStyle(.orange)
                    }
                    Text("Без наушников используем громкий динамик iPhone. С AirPods звук остаётся в наушниках. При одновременной речи и воспроизведении возможен акустический отклик.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 14))

                if engine.phase == .connecting || engine.phase == .ready ||
                    engine.phase == .speaking || engine.phase == .finishing {
                    HStack {
                        Spacer()
                        Button("Отключить") {
                            holding = false
                            engine.disconnect()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Text(engine.phase == .finished
                    ? "Для новой фразы нажми большую кнопку. Создадим новый сеанс только по твоему действию — без автоматических подключений и лишнего времени API."
                    : engine.phase == .finishing
                    ? "Подожди окончания звука. Если WebRTC перестал воспроизводить очередь, ожидание автоматически завершится."
                    : engine.playbackAfterRelease
                    ? "Подключись большой кнопкой, затем удерживай микрофон и говори. После отпускания перевод воспроизводится с начала."
                    : "Подключись большой кнопкой, затем удерживай микрофон и говори. В живом режиме перевод может звучать одновременно с речью.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if engine.phase == .finished || engine.phase == .failed || engine.phase == .idle {
                    Button {
                        holding = false
                        engine.connect(target: target)
                    } label: {
                        VStack(spacing: 9) {
                            Image(systemName: engine.phase == .finished
                                ? "arrow.clockwise.circle" : "network")
                                .font(.system(size: 32, weight: .medium))
                            Text(engine.phase == .finished ? "НОВАЯ ФРАЗА" :
                                 engine.phase == .failed ? "ПОВТОРИТЬ ПОДКЛЮЧЕНИЕ" :
                                 "ПОДКЛЮЧИТЬ WEBRTC")
                                .font(.subheadline.bold())
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 132)
                        .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 24))
                        .contentShape(RoundedRectangle(cornerRadius: 24))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Начинает новое подключение для следующей фразы")
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24)
                            .fill(engine.isSpeaking ? Color(red: 0.38, green: 0.13, blue: 0.16)
                                  : Color(white: 0.18))
                        VStack(spacing: 9) {
                            Image(systemName: engine.isSpeaking ? "waveform" : "mic")
                                .font(.system(size: 31, weight: .medium))
                            Text(engine.isSpeaking ? "ГОВОРИ" :
                                 engine.phase == .finishing ? "ВОСПРОИЗВОЖУ ПЕРЕВОД" :
                                 engine.phase == .connecting ? "ПОДКЛЮЧАЮ WEBRTC…" :
                                 "УДЕРЖИВАЙ ДЛЯ РЕЧИ")
                                .font(.subheadline.bold())
                        }
                    }
                    .frame(height: 132)
                    .opacity(engine.canTalk || engine.isSpeaking ? 1 : 0.4)
                    .contentShape(RoundedRectangle(cornerRadius: 24))
                    .onLongPressGesture(minimumDuration: 0, maximumDistance: 130,
                                        pressing: { pressed in
                        if !pressed {
                            if holding {
                                holding = false
                                engine.endSpeaking()
                            }
                        } else if engine.canTalk && !holding {
                            holding = true
                            engine.beginSpeaking()
                        }
                    }, perform: {})
                }

                if !engine.transcript.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Текст перевода").font(.headline)
                        Text(engine.transcript)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !engine.diagnostic.isEmpty {
                    Button {
                        UIPasteboard.general.string = engine.diagnostic
                    } label: {
                        Label("Копировать отчёт WebRTC", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    Text(engine.diagnostic)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                Text("Тестовая функция: аудио сохраняется только во временном PCM-буфере памяти для последующего воспроизведения и не экспортируется. Запрос к OpenAI один. Тарификация API действует.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
        }
        .navigationTitle("WebRTC")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { engine.disconnect() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { engine.disconnect() }
        }
    }

    private var statusIcon: String {
        switch engine.phase {
        case .ready: return "checkmark.circle"
        case .speaking: return "waveform"
        case .connecting, .finishing: return "hourglass"
        case .failed: return "exclamationmark.triangle"
        case .idle, .finished: return "network"
        }
    }
}
