import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import ChatterboxCoreML

/// Isolated, opt-in on-device voice-cloning experiment.
/// Never replaces the realtime OpenAI stream or sends voice samples to a server.
/// The model weights are downloaded from Hugging Face only after a user tap.
@MainActor
final class LocalVoiceLab: ObservableObject {
    @Published private(set) var status = "Эксперимент: переводчик не изменён."
    @Published private(set) var busy = false
    @Published private(set) var downloading = false
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var modelOnDisk = false
    @Published private(set) var loaded = false
    @Published private(set) var isRecording = false
    @Published private(set) var hasReference = false
    @Published private(set) var hasVoice = false
    @Published private(set) var outputURL: URL?

    private static let repository = ModelRepository.defaultMultilingualRepoId
    private static let home = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VoiceLab", isDirectory: true)
    private static let voiceURL = home.appendingPathComponent("my-voice-conds.safetensors")
    private let maxReferenceSize = 25 * 1_024 * 1_024
    private var model: ChatterboxCoreMLModel?
    private var recorder: AVAudioRecorder?
    private var referenceURL: URL?
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?

    init() {
        modelOnDisk = ModelRepository.existingModelDirectory(
            hfHome: Self.home, repoId: Self.repository) != nil
        hasVoice = FileManager.default.fileExists(atPath: Self.voiceURL.path)
    }

    func download() {
        guard !busy else { return }
        busy = true
        downloading = true
        downloadProgress = 0
        status = "Скачиваю Core ML модель и энкодеры голоса…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.downloading = false }
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
            }
        }
    }

    func load() {
        guard !busy, modelOnDisk else { return }
        guard let directory = ModelRepository.existingModelDirectory(
            hfHome: Self.home, repoId: Self.repository)
        else { status = "Сначала скачай модель."; return }
        busy = true
        status = "Подготавливаю Core ML (первый запуск может быть долгим)…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            do {
                let stress = await RuAccentStress.makeOrFallback(
                    downloadHFHome: Self.home, hfToken: nil)
                let loadedModel = try await ChatterboxCoreMLModel.load(
                    from: directory, russianStress: stress)
                try Task.checkCancellation()
                self.model = loadedModel
                self.loaded = true
                self.status = "Модель готова. Запиши свой голос (25–30 секунд)."
            } catch is CancellationError {
                self.status = "Загрузка модели отменена."
            } catch {
                self.loaded = false
                self.status = "Не удалось загрузить модель: \(error.localizedDescription)"
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
            guard audio.record() else { throw VoiceLabError.recordingFailed }
            recorder = audio
            isRecording = true
            status = "Записываю. Говори выразительно 25–30 секунд, затем останови."
        } catch {
            status = "Микрофон: \(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        guard let audio = recorder else { return }
        let recordedDuration = audio.currentTime
        audio.stop()
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
        guard recordedDuration >= 10 else {
            try? FileManager.default.removeItem(at: audio.url)
            status = "Слишком коротко: нужно хотя бы 10 секунд, лучше 25–30."
            return
        }
        removeOldReference()
        referenceURL = audio.url
        hasReference = true
        status = "Образец готов. Создай копию своего голоса."
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
            status = "Аудиофайл импортирован. Желательно 25–30 секунд чистой речи."
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
        status = "Создаю локальную копию голоса…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            do {
                try FileManager.default.createDirectory(at: Self.home, withIntermediateDirectories: true)
                let destination = Self.voiceURL
                let temporary = Self.home.appendingPathComponent(
                    "new-\(UUID().uuidString)-conds.safetensors")
                try await Task.detached(priority: .userInitiated) {
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    let cloner = try await VoiceCloner(modelDirectory: directory)
                    try cloner.cloneVoice(from: referenceURL, to: temporary)
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                    } else {
                        try FileManager.default.moveItem(at: temporary, to: destination)
                    }
                }.value
                self.hasVoice = true
                self.status = "Голос создан. Выбери язык и нажми «Озвучить»."
            } catch {
                self.status = "Не удалось клонировать голос: \(error.localizedDescription)"
            }
        }
    }

    func speak(_ text: String, language: String) {
        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, let model, hasVoice, !phrase.isEmpty else { return }
        guard ["ru", "de"].contains(language), phrase.count <= 500 else {
            status = "Выбери язык и введи текст длиной до 500 символов."
            return
        }
        busy = true
        outputURL = nil
        player?.stop()
        player = nil
        status = "Синтезирую речь локально…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false }
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

    func cleanup() {
        task?.cancel()
        stopPlayback()
        if let recorder {
            recorder.stop()
            self.recorder = nil
        }
        isRecording = false
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
    @StateObject private var engine = LocalVoiceLab()
    @State private var language = "ru"
    @State private var phrase = "Привет! Это мой собственный голос, созданный нейросетью прямо на айфоне."
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Экспериментальный режим") {
                    Text("Твой голос создаётся и хранится на iPhone. Рабочий перевод OpenAI не изменяется.")
                    Text("Для первого запуска нужно вручную скачать большую модель Core ML через интернет. Файлы модели хранятся в памяти iPhone; синтез после загрузки работает локально.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Реализация Core ML экспериментальная: на iPhone 16 Pro скорость, нагрев и сходство голоса предстоит проверить.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("1 · Модель") {
                    if engine.modelOnDisk {
                        Label("Файлы модели найдены", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                    if !engine.loaded {
                        Button(engine.modelOnDisk ? "Проверить / докачать модель" : "Скачать Chatterbox Multilingual") {
                            engine.download()
                        }.disabled(engine.busy)
                    }
                    if engine.downloading { ProgressView(value: engine.downloadProgress) }
                    if engine.modelOnDisk && !engine.loaded {
                        Button("Загрузить модель") { engine.load() }.disabled(engine.busy)
                    }
                    if engine.loaded { Label("Модель готова", systemImage: "checkmark.circle").foregroundStyle(.green) }
                }
                Section("2 · Образец голоса") {
                    Text("Запиши 25–30 секунд собственной выразительной речи в тихом помещении. Или импортируй подходящую запись из «Файлов».")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(engine.isRecording ? "Остановить запись" : "Записать мой голос") {
                        engine.startOrStopRecording()
                    }.disabled(engine.busy)
                    Button("Импортировать аудиофайл") { importing = true }
                        .disabled(engine.busy || engine.isRecording)
                    if engine.hasReference {
                        Label("Образец подготовлен", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                        Button("Создать мой голос") { engine.clone() }
                            .disabled(engine.busy || !engine.loaded)
                    }
                    if engine.hasVoice {
                        Label("Копия голоса сохранена на iPhone", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                }
                Section("3 · Проверка озвучивания") {
                    Picker("Язык", selection: $language) {
                        Text("Русский").tag("ru")
                        Text("Deutsch").tag("de")
                    }.pickerStyle(.segmented)
                        .onChange(of: language) { _, newValue in
                            phrase = newValue == "ru"
                                ? "Привет! Это мой собственный голос, созданный нейросетью прямо на айфоне."
                                : "Guten Morgen! Ich teste meine eigene Stimme auf Deutsch."
                        }
                    TextEditor(text: $phrase).frame(minHeight: 86)
                    Button("Озвучить моим голосом") {
                        engine.speak(phrase, language: language)
                    }.disabled(engine.busy || !engine.loaded || !engine.hasVoice)
                    if engine.outputURL != nil {
                        Button("Остановить воспроизведение") { engine.stopPlayback() }
                    }
                    if let output = engine.outputURL {
                        ShareLink(item: output, preview: SharePreview("Interpreter · Мой голос"))
                    }
                }
                Section("Состояние") {
                    if engine.busy { ProgressView() }
                    Text(engine.status).font(.footnote)
                }
                Section {
                    Text("Используй только собственный голос или голос человека с разрешением. Не выдавай синтезированную речь за настоящую запись.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Link("Chatterbox Core ML · исходный код",
                         destination: URL(string: "https://github.com/iliasaz/chatterbox-coreml")!)
                }
            }
            .navigationTitle("Мой голос · тест")
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Готово") { dismiss() }
            } }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.audio, .mpeg4Audio, .wav, .mp3]) { result in
                if case .success(let url) = result { engine.importReference(url) }
            }
            .onDisappear { engine.cleanup() }
        }
        .tint(.white)
    }
}
