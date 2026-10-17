import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import ChatterboxCoreML

/// Isolated, opt-in on-device voice-cloning experiment.
/// Never replaces the realtime OpenAI stream or sends voice samples to a server.
/// The model weights are downloaded from Hugging Face only after a user tap.
@MainActor
final class LocalVoiceLab: ObservableObject {
    @Published private(set) var status = "Готово к работе."
    @Published private(set) var busy = false
    @Published private(set) var downloading = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var modelOnDisk = false
    @Published private(set) var loaded = false
    @Published private(set) var isRecording = false
    @Published private(set) var recordingElapsed: TimeInterval = 0
    static let recordingLimit: TimeInterval = 30
    @Published private(set) var hasReference = false
    @Published private(set) var hasVoice = false
    @Published private(set) var outputURL: URL?
    @Published private(set) var isSynthesizing = false
    @Published private(set) var modelError: String?

    private static let repository = ModelRepository.defaultMultilingualRepoId
    private static let home = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VoiceLab", isDirectory: true)
    private static let voiceURL = home.appendingPathComponent("my-voice-conds.safetensors")
    private let maxReferenceSize = 25 * 1_024 * 1_024
    private var model: ChatterboxCoreMLModel?
    private var recorder: AVAudioRecorder?
    private var recordingClock: Task<Void, Never>?
    private var referenceURL: URL?
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    private var activeOperation: Operation = .idle
    private enum Operation: Equatable { case idle, downloading, loading, cloning, speaking }

    init() {
        modelOnDisk = ModelRepository.existingModelDirectory(
            hfHome: Self.home, repoId: Self.repository) != nil
        hasVoice = FileManager.default.fileExists(atPath: Self.voiceURL.path)
    }

    func download() {
        guard !busy else { return }
        modelError = nil
        busy = true
        activeOperation = .downloading
        downloading = true
        downloadProgress = 0
        status = "Скачиваю Core ML модель и энкодеры голоса…"
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.busy = false
                self.downloading = false
                self.activeOperation = .idle
            }
            do {
                try FileManager.default.createDirectory(at: Self.home, withIntermediateDirectories: true)
                let result = try await ModelRepository.download(
                    repoId: Self.repository,
                    hfHome: Self.home,
                    matching: ModelRepository.multilingualInferenceGlobs + ModelRepository.cloningGlobs
                ) { fraction in
                    Task { @MainActor [weak self] in
                        self?.downloadProgress = min(1, max(0, fraction))
                    }
                }
                try Task.checkCancellation()
                guard !result.isPartiallyApplied, result.stillStale.isEmpty,
                      FileManager.default.fileExists(atPath:
                        result.directory.appendingPathComponent("perceiver_query.npy").path)
                else { throw VoiceLabError.incompleteModel }
                self.modelOnDisk = true
                self.status = "Модель скачана. Нажми «Загрузить модель»."
            } catch is CancellationError {
                self.status = "Загрузка прервана. Её можно повторить."
            } catch {
                self.status = "Ошибка загрузки: \(error.localizedDescription)"
                self.modelError = self.status
            }
        }
    }

    /// Prepares an existing on-device model without accessing the microphone
    /// or the paid realtime translation API. Explicit loading uses the same
    /// cache, so the screen and the home page never load duplicate instances.
    func warmupIfAvailable() {
        guard modelOnDisk, hasVoice, !loaded, !busy else { return }
        load(silent: true)
    }

    func load(silent: Bool = false) {
        guard !busy, !loaded, modelOnDisk else { return }
        guard let directory = ModelRepository.existingModelDirectory(
            hfHome: Self.home, repoId: Self.repository)
        else { status = "Сначала скачай модель."; return }
        modelError = nil
        busy = true
        activeOperation = .loading
        let hadLoadedBefore = UserDefaults.standard.bool(forKey: "live.voiceModelLoadedBefore")
        status = hadLoadedBefore
            ? "Восстанавливаю модель из локального кэша…"
            : "Первая подготовка модели может занять некоторое время…"
        task = Task(priority: silent ? .utility : .userInitiated) { [weak self] in
            guard let self else { return }
            defer {
                self.busy = false
                self.activeOperation = .idle
            }
            do {
                let stress = await RuAccentStress.makeOrFallback(
                    downloadHFHome: Self.home, hfToken: nil)
                try Task.checkCancellation()
                let loadedModel = try await ChatterboxCoreMLModel.load(
                    from: directory, russianStress: stress)
                try Task.checkCancellation()
                self.model = loadedModel
                self.loaded = true
                UserDefaults.standard.set(true, forKey: "live.voiceModelLoadedBefore")
                self.status = "Модель готова."
            } catch is CancellationError {
                self.status = "Подготовка модели остановлена."
            } catch {
                self.loaded = false
                self.status = "Не удалось загрузить модель: \(error.localizedDescription)"
                self.modelError = self.status
            }
        }
    }

    func startOrStopRecording() {
        guard !busy else { return }
        if isRecording { stopRecording(); return }
        Task { [weak self] in
            guard let self else { return }
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission {
                    continuation.resume(returning: $0)
                }
            }
            guard granted else {
                self.status = "Разреши доступ к микрофону в настройках iPhone."
                return
            }
            self.beginRecording()
        }
    }

    private func beginRecording() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("my-voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let audio = try AVAudioRecorder(url: file, settings: settings)
            // The recorder itself enforces the 30-second deadline even when UI
            // animation is delayed or the device briefly suspends the view.
            guard audio.record(forDuration: Self.recordingLimit) else {
                throw VoiceLabError.recordingFailed
            }
            recorder = audio
            isRecording = true
            recordingElapsed = 0
            status = "Идёт запись. Автостоп через 30 секунд."
            recordingClock?.cancel()
            recordingClock = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                    guard let self, self.isRecording else { return }
                    self.recordingElapsed = min(audio.currentTime, Self.recordingLimit)
                    // A manual stop or AVAudioRecorder's own duration limit
                    // must both finalize the sample and update the UI.
                    if !audio.isRecording || audio.currentTime >= Self.recordingLimit {
                        self.stopRecording()
                        return
                    }
                }
            }
        } catch {
            status = "Микрофон: \(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        guard let audio = recorder else { return }
        let recordedDuration = max(recordingElapsed, audio.currentTime)
        recordingClock?.cancel()
        recordingClock = nil
        audio.stop()
        recorder = nil
        isRecording = false
        recordingElapsed = 0
        try? AVAudioSession.sharedInstance().setActive(false)
        guard recordedDuration >= 10 else {
            try? FileManager.default.removeItem(at: audio.url)
            status = "Слишком коротко: нужно хотя бы 10 секунд, лучше 15–20."
            return
        }
        removeOldReference()
        referenceURL = audio.url
        hasReference = true
        status = recordedDuration > VoiceReferenceClip.maximumSeconds
            ? "Образец готов. Для клонирования возьму первые 20 секунд."
            : "Образец готов. Создай копию своего голоса."
    }

    func importReference(_ url: URL) {
        guard !busy, !isRecording else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= maxReferenceSize else {
                throw VoiceLabError.referenceSize
            }
            let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("voice-import-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: url, to: target)
            removeOldReference()
            referenceURL = target
            hasReference = true
            status = "Аудиофайл импортирован. Для клонирования используются до 20 секунд речи."
        } catch {
            status = "Не удалось импортировать запись: \(error.localizedDescription)"
        }
    }

    func clone() {
        guard !busy, loaded, let referenceURL,
              let directory = ModelRepository.existingModelDirectory(
                hfHome: Self.home, repoId: Self.repository)
        else { status = "Сначала загрузи модель и запиши голос."; return }
        busy = true
        activeOperation = .cloning
        status = "Создаю локальную копию голоса…"
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.busy = false
                self.activeOperation = .idle
            }
            do {
                try FileManager.default.createDirectory(at: Self.home, withIntermediateDirectories: true)
                let destination = Self.voiceURL
                let temporary = Self.home.appendingPathComponent(
                    "new-\(UUID().uuidString)-conds.safetensors")
                let clipped = try await Task.detached(priority: .userInitiated) {
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    let prepared = try VoiceReferenceClip.prepare(referenceURL)
                    defer {
                        if prepared.clipped {
                            try? FileManager.default.removeItem(at: prepared.url)
                        }
                    }
                    try Task.checkCancellation()
                    let cloner = try await VoiceCloner(modelDirectory: directory)
                    try cloner.cloneVoice(from: prepared.url, to: temporary)
                    try Task.checkCancellation()
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                    } else {
                        try FileManager.default.moveItem(at: temporary, to: destination)
                    }
                    return prepared.clipped
                }.value
                self.hasVoice = true
                self.removeOldReference()
                self.status = clipped
                    ? "Голос создан из первых 20 секунд. Теперь можно озвучивать текст."
                    : "Голос создан. Выбери язык и нажми «Озвучить»."
            } catch {
                self.status = "Не удалось клонировать голос: \(error.localizedDescription)"
            }
        }
    }

    func speak(_ text: String, language: String) {
        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, let model, hasVoice, !phrase.isEmpty else { return }
        guard VoiceSynthesisLanguage.supports(language), phrase.count <= 500 else {
            status = "Выбери язык и введи текст до 500 символов."
            return
        }
        busy = true
        activeOperation = .speaking
        isSynthesizing = true
        outputURL = nil
        player?.stop()
        player = nil
        status = "Синтезирую речь локально…"
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isSynthesizing = false
                self.busy = false
                self.activeOperation = .idle
            }
            do {
                let options = GenerationOptions.multilingual(
                    language: language, exaggeration: 0.5, cfgWeight: 0.5)
                let audio = try await model.generate(
                    phrase, voice: Self.voiceURL, options: options)
                try Task.checkCancellation()
                let file = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Interpreter-my-voice-\(UUID().uuidString).wav")
                try AudioOutput.writeWAV(audio, to: file)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                let player = try AVAudioPlayer(contentsOf: file)
                guard player.play() else { throw VoiceLabError.playbackFailed }
                self.player = player
                self.outputURL = file
                self.status = "Готово. Результат можно прослушать и сохранить."
            } catch is CancellationError {
                self.status = "Озвучивание отменено."
            } catch {
                self.status = "Ошибка синтеза: \(error.localizedDescription)"
            }
        }
    }

    func stopPlayback() { player?.stop(); player = nil }

    /// Replay the completed WAV already stored on the iPhone; no extra voice
    /// generation or OpenAI API request. Each tap restarts the clip at 0:00.
    func replayLastAudio() {
        guard !busy, let outputURL else { return }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            self.outputURL = nil
            stopPlayback()
            status = "Аудиофайл больше недоступен. Озвучь текст повторно."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            stopPlayback()
            let replay = try AVAudioPlayer(contentsOf: outputURL)
            replay.currentTime = 0
            replay.prepareToPlay()
            guard replay.play() else { throw VoiceLabError.playbackFailed }
            player = replay
            status = "Повторно воспроизвожу готовое аудио."
        } catch {
            status = "Не удалось воспроизвести аудио: \(error.localizedDescription)"
        }
    }

    func deleteVoice() {
        guard !busy else { return }
        do {
            if FileManager.default.fileExists(atPath: Self.voiceURL.path) {
                try FileManager.default.removeItem(at: Self.voiceURL)
            }
            hasVoice = false
            removeOldReference()
            outputURL = nil
            stopPlayback()
            status = "Сохранённая копия голоса удалена с iPhone."
        } catch {
            status = "Не удалось удалить копию голоса: \(error.localizedDescription)"
        }
    }

    func cleanup() {
        // Closing the voice sheet must not discard an already warming model.
        // Cancel interactive generation, but let passive model preparation
        // finish while the parent Interpreter Live screen is still active.
        if activeOperation == .speaking || activeOperation == .cloning {
            task?.cancel()
        }
        stopPlayback()
        recordingClock?.cancel()
        recordingClock = nil
        if let recorder {
            recorder.stop()
            self.recorder = nil
        }
        isRecording = false
        recordingElapsed = 0
        removeOldReference()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func removeOldReference() {
        if let referenceURL { try? FileManager.default.removeItem(at: referenceURL) }
        referenceURL = nil
        hasReference = false
    }

    private enum VoiceLabError: LocalizedError {
        case recordingFailed, referenceSize, incompleteModel, playbackFailed
        var errorDescription: String? {
            switch self {
            case .recordingFailed: return "Не удалось начать запись."
            case .referenceSize: return "Образец должен быть аудиофайлом размером до 25 МБ."
            case .incompleteModel: return "Скачаны не все файлы модели. Повтори загрузку."
            case .playbackFailed: return "Не удалось воспроизвести готовый звук."
            }
        }
    }
}

struct LocalVoiceLabView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var engine: LocalVoiceLab
    @State private var language = "ru"
    @State private var phrase = VoiceSynthesisLanguage.sample(for: "ru") ?? ""
    @FocusState private var textEditorFocused: Bool
    @State private var importing = false
    @State private var confirmingVoiceDeletion = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Модель") {
                    if engine.modelOnDisk {
                        Label("Файлы модели найдены", systemImage: "checkmark.circle")
                            .foregroundStyle(.primary)
                        if engine.loaded {
                            Label("Модель готова", systemImage: "checkmark.circle")
                                .foregroundStyle(.primary)
                        } else if engine.busy && !engine.downloading {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Подготовка модели")
                                    .font(.subheadline)
                                LocalModelLoadingLine()
                                    .frame(height: 8)
                                    .accessibilityLabel("Идёт подготовка модели")
                                Text("Подготавливаю модель на iPhone…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                        } else {
                            Button(engine.modelError == nil ? "Загрузить модель" : "Повторить подготовку") {
                                engine.load()
                            }
                        }
                    } else {
                        Button("Скачать Chatterbox Multilingual") { engine.download() }
                            .disabled(engine.busy)
                        if engine.downloading {
                            ProgressView(value: engine.downloadProgress)
                                .tint(.white)
                        }
                    }
                    if let error = engine.modelError {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Мой голос") {
                    if !engine.hasVoice {
                        Button(engine.isRecording ? "Остановить запись" : "Записать мой голос") {
                            textEditorFocused = false
                            engine.startOrStopRecording()
                        }.disabled(engine.busy)
                        if engine.isRecording {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Label("Запись", systemImage: "record.circle")
                                        .foregroundStyle(.red)
                                    Spacer()
                                    Text(String(format: "%02d:%02d / 00:30",
                                                Int(engine.recordingElapsed) / 60,
                                                Int(engine.recordingElapsed) % 60))
                                        .monospacedDigit()
                                }
                                .font(.subheadline.weight(.semibold))
                                ProgressView(value: engine.recordingElapsed,
                                             total: LocalVoiceLab.recordingLimit)
                                    .tint(.red)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        Button("Импортировать аудиофайл") { importing = true }
                            .disabled(engine.busy || engine.isRecording)
                        if engine.hasReference {
                            Label("Образец подготовлен", systemImage: "checkmark.circle")
                                .foregroundStyle(.white)
                            Button("Создать мой голос") { engine.clone() }
                                .disabled(engine.busy || !engine.loaded)
                        }
                    } else {
                        Label("Копия голоса сохранена на iPhone",
                              systemImage: "checkmark.circle")
                            .foregroundStyle(.white)
                        Button("Удалить мою копию голоса", role: .destructive) {
                            confirmingVoiceDeletion = true
                        }.disabled(engine.busy)
                    }
                }
                Section {
                    Picker("Язык озвучивания", selection: $language) {
                        ForEach(VoiceSynthesisLanguage.all) { item in
                            Text(item.name).tag(item.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: language) { oldValue, newValue in
                        // Preserve custom text; replace only the old demonstration phrase.
                        let previousSample = VoiceSynthesisLanguage.sample(for: oldValue)
                        if phrase.isEmpty || phrase == previousSample {
                            phrase = VoiceSynthesisLanguage.sample(for: newValue) ?? phrase
                        }
                    }
                    TextEditor(text: $phrase)
                        .focused($textEditorFocused)
                        .frame(minHeight: 86)
                    Button("Озвучить моим голосом") {
                        textEditorFocused = false
                        engine.speak(phrase, language: language)
                    }.disabled(engine.busy || !engine.loaded || !engine.hasVoice)
                    if engine.outputURL != nil {
                        Button("Повторить аудио") {
                            engine.replayLastAudio()
                        }
                        .disabled(engine.busy)
                    }
                    if let output = engine.outputURL {
                        ShareLink(item: output, preview: SharePreview("Interpreter · Мой голос")) {
                            Label("Сохранить / отправить", systemImage: "square.and.arrow.up")
                        }
                    }
                } header: {
                    HStack(spacing: 10) {
                        Text("Озвучивание")
                        Spacer(minLength: 8)
                        if engine.isSynthesizing {
                            LocalSynthesisHeaderMotion()
                                .frame(width: 100, height: 24)
                                .accessibilityHidden(true)
                                .transition(.opacity)
                        }
                    }
                } footer: {
                    Text("Chatterbox Multilingual · Core ML · локально на iPhone")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                        .padding(.bottom, 12)
                        .accessibilityLabel("Локальная модель Chatterbox Multilingual, Core ML")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Текст → голос")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        textEditorFocused = false
                        dismiss()
                    }
                }
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.audio, .mpeg4Audio, .wav, .mp3]) { result in
                if case .success(let url) = result { engine.importReference(url) }
            }
            .confirmationDialog("Удалить сохранённую копию голоса с iPhone?",
                                isPresented: $confirmingVoiceDeletion) {
                Button("Удалить голос", role: .destructive) { engine.deleteVoice() }
            }
            .onDisappear {
                textEditorFocused = false
                engine.cleanup()
            }
        }
        .tint(.white)
    }
}


/// Lightweight waveform shown ONLY while local speech synthesis is running.
/// A single Canvas redraws at most 24 times per second (no individual animated
/// SwiftUI views for each bar). Motion is reduced for accessibility.
private struct LocalSynthesisWave: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(0.10))
                .frame(width: 180, height: 28)
                .blur(radius: 20)

            TimelineView(.animation(
                minimumInterval: reduceMotion ? 1 : 1.0 / 24.0,
                paused: reduceMotion
            )) { timeline in
                Canvas(opaque: false) { context, size in
                    let barCount = 43
                    let spacing = size.width / CGFloat(barCount)
                    let barWidth = min(3.2, spacing * 0.57)
                    let phase = reduceMotion
                        ? 0.0
                        : timeline.date.timeIntervalSinceReferenceDate
                    for index in 0..<barCount {
                        let position = Double(index)
                        let centre = Double(barCount - 1) / 2.0
                        let envelope = pow(max(0.10, 1.0 - abs(position - centre) / (centre + 1)), 1.55)
                        let amplitude = abs(sin(phase * 2.4 + position * 0.83) *
                                            cos(phase * 1.35 + position * 0.27))
                        let height = CGFloat(4.5 + envelope * (13.0 + amplitude * 60.0))
                        let x = CGFloat(index) * spacing + (spacing - barWidth) / 2
                        let y = (size.height - height) / 2
                        let rect = CGRect(x: x, y: y, width: barWidth, height: height)
                        let opacity = 0.42 + envelope * 0.58
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: barWidth / 2),
                            with: .color(Color.white
                                .opacity(opacity))
                        )
                    }
                }
            }
        }
    }
}


/// A compact monochrome pixel impulse. Only created while synthesis is active.
/// Squares rise one after another with a soft centre-weighted envelope.
private struct LocalSynthesisHeaderMotion: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(
            minimumInterval: reduceMotion ? 1 : 1.0 / 24.0,
            paused: reduceMotion
        )) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<17, id: \.self) { index in
                    let centre = 8.0
                    let envelope = pow(max(0, 1 - abs(Double(index) - centre) / 9), 1.25)
                    let progress = reduceMotion ? 0.0 :
                        (time / 1.55 - Double(index) * 0.063 / 1.55)
                            .truncatingRemainder(dividingBy: 1)
                    let cycle = progress < 0 ? progress + 1 : progress
                    let lift = cycle < 0.24 ? cycle / 0.24 :
                        cycle < 0.43 ? (0.43 - cycle) / 0.19 : 0
                    let displacement = CGFloat((3 + 9 * envelope) * max(0, lift))
                    RoundedRectangle(cornerRadius: 0.6)
                        .fill(Color.white.opacity(reduceMotion ? 0.65 : (0.30 + 0.70 * max(0, lift))))
                        .frame(width: 4, height: 4)
                        .offset(y: -displacement)
                }
            }
            .frame(width: 100, height: 24)
        }
    }
}

/// Indeterminate progress: moving white impulse, without invented percentage.
private struct LocalModelLoadingLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(
            minimumInterval: reduceMotion ? 1 : 1.0 / 24.0,
            paused: reduceMotion
        )) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let position = reduceMotion ? 0.5 : (0.5 + 0.5 * sin(time * 2.0))
            GeometryReader { geometry in
                let impulseWidth = max(28, geometry.size.width * 0.28)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.16)).frame(height: 3)
                    Capsule()
                        .fill(Color.white.opacity(0.95))
                        .frame(width: impulseWidth, height: 3)
                        .offset(x: (geometry.size.width - impulseWidth) * position)
                }
                .frame(height: geometry.size.height)
            }
        }
    }
}
