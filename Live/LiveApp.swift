import SwiftUI
import UniformTypeIdentifiers
import UIKit

@main struct InterpreterLiveApp: App {
    var body: some Scene { WindowGroup { LiveView().preferredColorScheme(.dark) } }
}

private var liveVersion: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    return "Interpreter Live \(version) (\(build))"
}

struct LiveView: View {
    @StateObject private var model = LiveSession()
    @StateObject private var voiceLab = LocalVoiceLab()
    @State private var settings = false
    @State private var exporting = false
    @State private var importing = false
    @State private var showTranscription = false
    @State private var showVoiceLab = false
    @State private var document: RecordingDocument?
    @State private var exportError = false
    @State private var importError: String?
    @AppStorage("live.keepAwake") private var keepAwake = true
    @AppStorage("live.voiceWarmupEnabled") private var voiceWarmupEnabled = true
    @State private var voiceWarmupTask: Task<Void, Never>?
    @State private var voiceWarmupAttempted = false
    @AppStorage("live.partnerLanguage") private var partnerCode = "de"
    @State private var orbitActive = false
    @State private var orbitDragStart = 0
    @State private var orbitStarted = false
    @State private var orbitHide: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    private var partner: PartnerLanguage { PartnerLanguage.current(partnerCode) }
    private var languages: [PartnerLanguage] { PartnerLanguage.allCases }

    var body: some View {
        ScrollView {
            VStack(spacing: 11) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("INTERPRETER LIVE")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(3.2)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 7) {
                            Text("Русский ↔")
                                .font(.title2.bold())
                                .fixedSize()
                            Text(partner.name)
                                .font(.title2.bold())
                                .lineLimit(1)
                                .minimumScaleFactor(0.73)
                                .contentShape(Rectangle())
                                .gesture(languageDrag)
                                .accessibilityLabel("Язык: \(partner.name). Проведи пальцем влево или вправо")
                                .accessibilityAddTraits(.isButton)
                        }
                    }
                    Spacer(minLength: 6)
                    Button { model.stopAll(); settings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.title2.weight(.medium))
                            .frame(width: 36, height: 36)
                    }
                    .disabled(model.busy)
                    .accessibilityLabel("Настройки")
                }
                .padding(.top, 12)

                ZStack {
                    Image(systemName: "infinity")
                        .font(.system(size: 76, weight: .light))
                        .opacity(orbitActive ? 0.10 : 1)
                        .scaleEffect(orbitActive ? 1.7 : 1)
                        .accessibilityHidden(true)

                    ForEach(languages) { choice in
                        let distance = cyclicDistance(for: choice)
                        let active = distance == 0
                        Button {
                            selectLanguage(choice)
                            scheduleOrbitHide(after: 0.65)
                        } label: {
                            Text(choice.shortCode)
                                .font(.system(size: active ? 24 : 19, weight: .bold))
                                .foregroundStyle(active ? Color.black : Color.white)
                                .frame(width: active ? 65 : 47, height: active ? 58 : 50)
                                .background(
                                    active ? Color(white: 0.91) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 18)
                                )
                                .opacity(active ? 1 : abs(distance) == 1 ? 0.72 : 0.28)
                                .scaleEffect(active ? 1 : abs(distance) == 1 ? 0.90 : 0.70)
                        }
                        .buttonStyle(.plain)
                        .offset(x: CGFloat(distance) * 70)
                        .opacity(orbitActive ? 1 : 0)
                        .allowsHitTesting(orbitActive && model.phase == .idle)
                        .accessibilityLabel(choice.name)
                    }
                    Text("\(partner.shortCode) · \(partner.name) · выбрано")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .offset(y: 49)
                        .opacity(orbitActive ? 1 : 0)
                }
                .frame(height: 123)
                .animation(.spring(response: 0.33, dampingFraction: 0.83), value: orbitActive)
                .animation(.spring(response: 0.29, dampingFraction: 0.85), value: partnerCode)
                .sensoryFeedback(.selection, trigger: partnerCode)

                MicrophoneWaveform(levels: model.levels, recording: model.phase == .recording)
                    .frame(height: 23)

                VStack(spacing: 3) {
                    Text(model.message == "Удерживай кнопку нужного языка" ? "Готово" : model.message)
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if model.phase == .recording {
                        Text(String(format: "● %.1f с", model.elapsed))
                            .font(.caption.monospacedDigit())
                    }
                }
                .frame(minHeight: 27)

                BalanceSummary(account: model)

                HStack(spacing: 12) {
                    talk("Русский", language: "ru", target: "→ \(partner.uppercaseName)")
                    talk(partner.buttonName, language: partner.rawValue, target: "→ РУССКИЙ")
                }
                .frame(height: 136)

                HStack(spacing: 10) {
                    HomeFeatureTile(title: "Голос → текст",
                                    subtitle: "Транскрибация",
                                    kind: .speechToText) {
                        showTranscription = true
                    }
                    HomeFeatureTile(title: "Текст → голос",
                                    subtitle: "Мой голос",
                                    kind: .textToSpeech) {
                        showVoiceLab = true
                    }
                }
                .disabled(model.busy)

                HStack {
                    Button {
                        importing = true
                    } label: {
                        Label("Импорт аудио", systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.busy)
                    Spacer()
                    Text(liveVersion)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                if !model.text.isEmpty || !model.details.isEmpty ||
                   model.recordedWave != nil || model.translatedWave != nil {
                    VStack(alignment: .leading, spacing: 11) {
                        if !model.text.isEmpty {
                            Text(model.text).font(.subheadline)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !model.details.isEmpty {
                            Text(model.details).font(.caption).foregroundStyle(.secondary)
                        }
                        if model.translatedWave != nil {
                            HStack {
                                Button("Прослушать") { model.replay() }
                                Button("Сохранить перевод") {
                                    if let translated = model.translatedWave {
                                        document = RecordingDocument(data: translated)
                                        exporting = true
                                    }
                                }
                                if let url = model.shareURL {
                                    ShareLink(item: url) { Label("Отправить", systemImage: "square.and.arrow.up") }
                                }
                            }
                            .font(.caption)
                            .disabled(model.busy)
                        }
                        if model.recordedWave != nil {
                            Button("Послушать свою запись") { model.review() }
                                .font(.caption)
                                .disabled(model.busy)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.075), in: RoundedRectangle(cornerRadius: 16))
                }

            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(Color.black)
        .tint(.white)
        .sheet(isPresented: $settings) { LiveSettings(model: model) }
        .sheet(isPresented: $showTranscription) { TranscriptionView(account: model) }
        .sheet(isPresented: $showVoiceLab) { LocalVoiceLabView(engine: voiceLab) }
        .sheet(isPresented: $importing) {
            RecordingDocumentPicker(
                onSelected: { url in
                    importing = false
                    Task { @MainActor in
                        do { try await model.importAudio(url, partner: partner.rawValue) }
                        catch { importError = error.localizedDescription }
                    }
                },
                onCancelled: { importing = false }
            )
            .ignoresSafeArea()
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .wav,
                      defaultFilename: "Interpreter-Live-translation") { result in
            if case .failure(let error) = result,
               (error as NSError).code != NSUserCancelledError { exportError = true }
            document = nil
        }
        .alert("Не удалось сохранить перевод", isPresented: $exportError) {
            Button("Готово", role: .cancel) {}
        }
        .alert("Импорт аудио", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("Понятно", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .onAppear {
            updateAwake()
            scheduleVoiceWarmup()
        }
        .onDisappear {
            voiceWarmupTask?.cancel()
            orbitHide?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
            model.background()
        }
        .onChange(of: keepAwake) { _, _ in updateAwake() }
        .onChange(of: voiceWarmupEnabled) { _, enabled in
            if enabled { scheduleVoiceWarmup() }
            else { voiceWarmupTask?.cancel() }
        }
        .onChange(of: scenePhase) { _, phase in
            updateAwake()
            if phase != .active {
                voiceWarmupTask?.cancel()
                model.background()
            } else {
                scheduleVoiceWarmup()
            }
        }
    }

    /// Circular positions keep the selected language at the exact centre.
    private func cyclicDistance(for choice: PartnerLanguage) -> Int {
        guard let center = languages.firstIndex(of: partner),
              let index = languages.firstIndex(of: choice) else { return 0 }
        let distance = (index - center + languages.count) % languages.count
        return distance <= languages.count / 2 ? distance : distance - languages.count
    }

    /// Only the foreign language label captures gestures. Russian never moves.
    private var languageDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard model.phase == .idle else { return }
                if !orbitStarted {
                    orbitHide?.cancel()
                    orbitDragStart = languages.firstIndex(of: partner) ?? 0
                    orbitStarted = true
                    withAnimation { orbitActive = true }
                }
                let steps = Int((-value.translation.width / 52).rounded())
                let n = (orbitDragStart + steps % languages.count + languages.count) % languages.count
                selectLanguage(languages[n])
            }
            .onEnded { value in
                orbitStarted = false
                scheduleOrbitHide(after: abs(value.translation.width) < 8 ? 3.5 : 0.6)
            }
    }

    private func selectLanguage(_ choice: PartnerLanguage) {
        guard model.phase == .idle else { return }
        partnerCode = choice.rawValue
    }

    private func scheduleOrbitHide(after seconds: Double) {
        orbitHide?.cancel()
        orbitHide = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation { orbitActive = false }
        }
    }

    private func talk(_ title: String, language: String, target: String) -> some View {
        PressButton(title: title, subtitle: target, pressed: model.held == language,
                    enabled: !model.busy || model.held == language,
                    begin: { model.begin(language, partner: partner.rawValue) },
                    end: { model.end(language) },
                    cancel: { model.abortPress(language) })
            .frame(maxWidth: .infinity)
    }

    /// Prepare the previously downloaded local voice weights opportunistically.
    /// Never delay the live translator, open the microphone, or preload while
    /// iOS requests low power / is thermally stressed. No repeated hot loop.
    private func scheduleVoiceWarmup() {
        voiceWarmupTask?.cancel()
        guard voiceWarmupEnabled,
              !voiceWarmupAttempted,
              voiceLab.modelOnDisk,
              voiceLab.hasVoice,
              !voiceLab.loaded,
              !ProcessInfo.processInfo.isLowPowerModeEnabled
        else { return }
        voiceWarmupTask = Task { @MainActor in
            // Let the translator finish launching and give the user a chance
            // to begin a press-to-talk turn before using heavy Core ML.
            for _ in 0..<18 {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
                guard !Task.isCancelled,
                      voiceWarmupEnabled,
                      scenePhase == .active,
                      !voiceLab.loaded,
                      !ProcessInfo.processInfo.isLowPowerModeEnabled
                else { return }
                if showVoiceLab { return } // visible sheet offers a manual load
                let thermal = ProcessInfo.processInfo.thermalState
                guard thermal != .serious && thermal != .critical else { return }
                if model.phase == .idle && !model.busy && !voiceLab.busy {
                    voiceWarmupAttempted = true
                    voiceLab.warmupIfAvailable()
                    return
                }
            }
        }
    }

    private func updateAwake() {
        UIApplication.shared.isIdleTimerDisabled = keepAwake && scenePhase == .active
    }
}

/// Paired, matte graphite home entry points; custom vector artwork is drawn
/// natively with Canvas so it scales crisply and needs no raster assets.
private enum HomeFeatureKind: Equatable {
    case speechToText
    case textToSpeech
}

private struct HomeFeatureTile: View {
    let title: String
    let subtitle: String
    let kind: HomeFeatureKind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                HomeFeatureGlyph(kind: kind)
                    .frame(width: 33, height: 35)
                    .frame(width: 43, height: 47)
                    .background(
                        LinearGradient(
                            colors: [Color(white: 0.31), Color(white: 0.14)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 13)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 13)
                            .strokeBorder(Color.white.opacity(0.09))
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(Color(white: 0.63))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 87, alignment: .leading)
            .padding(.horizontal, 9)
            .background(Color(white: 0.095),
                        in: RoundedRectangle(cornerRadius: 17))
            .overlay(
                RoundedRectangle(cornerRadius: 17)
                    .strokeBorder(Color.white.opacity(0.16))
            )
            .contentShape(RoundedRectangle(cornerRadius: 17))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + ", " + subtitle)
    }
}

/// Left: a speaking human profile, incoming sound, and text lines.
/// Right: written text followed by a speaker with outgoing sound.
/// Both are original SF-style line illustrations, independent of the
/// microphone and existing live-translation processing pipeline.
private struct HomeFeatureGlyph: View {
    let kind: HomeFeatureKind

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 48
            var drawing = context
            drawing.translateBy(
                x: (size.width - scale * 48) / 2,
                y: (size.height - scale * 48) / 2
            )
            drawing.scaleBy(x: scale, y: scale)

            var strokes = Path()
            switch kind {
            case .speechToText:
                strokes.move(to: CGPoint(x: 30, y: 5))
                strokes.addLines([
                    CGPoint(x: 24, y: 13), CGPoint(x: 22, y: 20),
                    CGPoint(x: 27, y: 25), CGPoint(x: 34, y: 26),
                    CGPoint(x: 29, y: 30), CGPoint(x: 32, y: 35),
                    CGPoint(x: 25, y: 37), CGPoint(x: 25, y: 43),
                    CGPoint(x: 34, y: 43)
                ])
                strokes.move(to: CGPoint(x: 17, y: 19))
                strokes.addQuadCurve(to: CGPoint(x: 17, y: 34),
                                     control: CGPoint(x: 11, y: 26))
                strokes.move(to: CGPoint(x: 12, y: 15))
                strokes.addQuadCurve(to: CGPoint(x: 12, y: 38),
                                     control: CGPoint(x: 2, y: 27))
                for (y, width) in [(18.0, 7.0), (24.0, 7.0), (30.0, 5.0)] {
                    strokes.move(to: CGPoint(x: 38, y: y))
                    strokes.addLine(to: CGPoint(x: 38 + width, y: y))
                }
                drawing.fill(
                    Path(ellipseIn: CGRect(x: 34, y: 10, width: 2.6, height: 2.6)),
                    with: .color(.white)
                )
            case .textToSpeech:
                for (y, width) in [(11.0, 19.0), (18.0, 15.0),
                                   (25.0, 15.0), (32.0, 11.0)] {
                    strokes.move(to: CGPoint(x: 5, y: y))
                    strokes.addLine(to: CGPoint(x: 5 + width, y: y))
                }
                strokes.move(to: CGPoint(x: 27, y: 20))
                strokes.addLines([
                    CGPoint(x: 33, y: 20), CGPoint(x: 41, y: 14),
                    CGPoint(x: 41, y: 35), CGPoint(x: 33, y: 29),
                    CGPoint(x: 27, y: 29), CGPoint(x: 27, y: 20)
                ])
                strokes.move(to: CGPoint(x: 44, y: 18))
                strokes.addQuadCurve(to: CGPoint(x: 44, y: 31),
                                     control: CGPoint(x: 50, y: 24.5))
            }
            drawing.stroke(
                strokes,
                with: .color(.white),
                style: StrokeStyle(lineWidth: 2.4,
                                   lineCap: .round,
                                   lineJoin: .round)
            )
        }
    }
}

/// Compact, shared balance: live translation and transcription use the SAME LiveSession.
struct BalanceSummary: View {
    @ObservedObject var account: LiveSession

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ОСТАТОК · ПРИМЕРНО")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(account.remainder).font(.title3.monospacedDigit().bold())
            }
            Spacer(minLength: 3)
            VStack(alignment: .trailing, spacing: 4) {
                Text("РАСХОД ПРИЛОЖЕНИЯ")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(String(format: "$%.4f", account.spent))
                    .font(.subheadline.monospacedDigit())
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color(white: 0.08), in: RoundedRectangle(cornerRadius: 17))
        .accessibilityElement(children: .combine)
    }
}

struct RecordingDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.wav] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct LiveSettings: View {
    @ObservedObject var model: LiveSession
    @Environment(\.dismiss) private var dismiss
    @AppStorage("live.keepAwake") private var keepAwake = true
    @AppStorage("live.voiceWarmupEnabled") private var voiceWarmupEnabled = true
    @AppStorage("live.russianProofreadingEnabled") private var russianProofreadingEnabled = true
    @State private var key = ""
    @State private var balance = ""
    @State private var notice = ""
    @State private var deleteKey = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Голосовой перевод") {
                    Text("gpt-realtime-translate")
                    Text("Отдельная платная модель OpenAI для голосового перевода.").font(.footnote)
                }
                Section("API-ключ") {
                    HStack(spacing: 10) {
                        Image(systemName: model.keyStatus.symbol)
                        Text(model.keyStatus.title)
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(model.keyVerified ? Color.green :
                                     model.keyStatusIsRejected ? Color.red : Color.secondary)
                    SecureField("Вставь API-ключ", text: $key)
                        .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Вставить из буфера") { key = UIPasteboard.general.string ?? "" }
                    Button("Сохранить ключ") {
                        do { try model.saveKey(key); key = ""; notice = "Ключ сохранён" }
                        catch { notice = error.localizedDescription }
                    }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.keySaved { Button("Удалить ключ", role: .destructive) { deleteKey = true } }
                    Link("Создать ключ OpenAI", destination: URL(string: "https://platform.openai.com/api-keys")!)
                    Text("Ключ хранится в защищённом хранилище iPhone. Старый ключ автоматически не переносится.").font(.footnote)
                }
                Section("Баланс API") {
                    HStack {
                        Text("Указанный остаток")
                        Spacer()
                        Text(model.enteredBalanceText).monospacedDigit().foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Сейчас · приблизительно")
                        Spacer()
                        Text(model.remainder).monospacedDigit().bold()
                    }
                    TextField("Обновить остаток, $", text: $balance).keyboardType(.decimalPad)
                    Button("Указать остаток") {
                        notice = model.setBalance(balance) ? "Остаток обновлён" : "Введи сумму, например 9,80"
                        balance = ""
                    }
                    Link("Баланс и расходы OpenAI", destination: URL(string: "https://platform.openai.com/settings/organization/billing/overview")!)
                    Text("≈ $0,034 за минуту отправленного аудио.").font(.footnote)
                }
                Section("Экран") { Toggle("Экран всегда включён", isOn: $keepAwake) }
                Section("Локальная модель") {
                    Toggle("Подготавливать мой голос при запуске", isOn: $voiceWarmupEnabled)
                }
                Section("Текст → голос") {
                    Toggle("Исправлять русский перед озвучиванием", isOn: $russianProofreadingEnabled)
                    Text("Исправленный текст можно проверить и изменить перед озвучиванием. Оригинал сохраняется. Корректура использует лимиты подключённого ChatGPT.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Формат передачи аудио") {
                    Text("PCM16 · 24 кГц · моно · порции по 200 мс").font(.footnote)
                }
                if !notice.isEmpty { Section { Text(notice).font(.footnote) } }
                Section { Text(liveVersion).foregroundStyle(.secondary) }
            }.navigationTitle("Настройки")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { key = ""; dismiss() } } }
                .confirmationDialog("Удалить сохранённый API-ключ?", isPresented: $deleteKey) {
                    Button("Удалить", role: .destructive) {
                        do { try model.removeKey(); notice = "Ключ удалён" } catch { notice = error.localizedDescription }
                    }
                }
                .onDisappear { key = "" }
        }.tint(.white)
    }
}
