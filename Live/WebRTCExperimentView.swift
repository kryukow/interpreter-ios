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
                Text("Та же модель gpt-realtime-translate, но iPhone получает перевод как живую аудиодорожку WebRTC. Основной WebSocket остаётся без изменений.")
                    .font(.subheadline)
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

                HStack {
                    Button {
                        engine.connect(target: target)
                    } label: {
                        Label("Подключить WebRTC", systemImage: "network")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(engine.phase == .connecting || engine.phase == .ready ||
                              engine.phase == .speaking || engine.phase == .finishing)
                    Spacer()
                    Button("Отключить") { engine.disconnect() }
                        .buttonStyle(.bordered)
                }

                Text("После подключения удерживай кнопку для записи. Микрофон включается только при удержании; отпускание отправляет session.close.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ZStack {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(engine.isSpeaking ? Color(red: 0.38, green: 0.13, blue: 0.16)
                              : Color(white: 0.18))
                    VStack(spacing: 9) {
                        Image(systemName: engine.isSpeaking ? "waveform" : "mic")
                            .font(.system(size: 31, weight: .medium))
                        Text(engine.isSpeaking ? "ГОВОРИ" : "УДЕРЖИВАЙ ДЛЯ РЕЧИ")
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
                Text("Тестовая функция: без сохранения входной и выходной аудиодорожки. Тарификация OpenAI API действует. Для сравнения сначала проверь такой же текст в основном WebSocket-режиме.")
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
