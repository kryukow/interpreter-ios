import SwiftUI
import AVFoundation
import UIKit
import CryptoKit

@MainActor final class LiveSession: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    enum Phase { case idle, arming, recording, connecting, sending, waiting, playing }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var held: String?
    @Published private(set) var message = "Удерживай кнопку нужного языка"
    @Published private(set) var text = ""
    @Published private(set) var details = ""
    @Published private(set) var elapsed = 0.0
    @Published private(set) var levels = Array(repeating: 0.0, count: 40)
    @Published private(set) var recordedWave: Data?
    @Published private(set) var translatedWave: Data?
    @Published private(set) var translationComplete = false
    @Published private(set) var keySaved = false
    @Published private(set) var spent = UserDefaults.standard.double(forKey: "live.spent")
    @Published private(set) var credit: Double? = UserDefaults.standard.object(forKey: "live.credit") as? Double
    private let recorder = NativeRecorder()
    private let connection = TranslationConnection()
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var player: AVAudioPlayer?
    private var livePlayer: LiveStreamPlayer?
    private let textSynthesizer = AVSpeechSynthesizer()
    private var textUtterance: AVSpeechUtterance?
    private var streamPlaybackIssue: String?
    private var playWatch: Task<Void, Never>?
    private var direction = "ru"
    var busy: Bool { phase != .idle && phase != .playing }
    var remainder: String { credit.map { String(format: "≈ $%.3f", max(0, $0 - spent)) } ?? "—" }
    override init() {
        super.init()
        textSynthesizer.delegate = self
        refreshKey()
    }
    func refreshKey() { keySaved = (try? LiveKey.read()) != nil }
    func saveKey(_ value: String) throws { try LiveKey.save(value); refreshKey() }
    func removeKey() throws { try LiveKey.remove(); refreshKey() }
    func setBalance(_ value: String) -> Bool {
        guard let amount = Double(value.replacingOccurrences(of: ",", with: ".")), amount.isFinite,
              amount >= 0, amount <= 1_000_000 else { return false }
        credit = amount + spent
        UserDefaults.standard.set(amount + spent, forKey: "live.credit")
        return true
    }
    func begin(_ language: String) {
        guard held == nil, !busy, ["ru", "de"].contains(language) else { return }
        guard keySaved else { message = "Сначала добавь API-ключ в настройках"; return }
        stopPlayer()
        stopTextSpeech()
        livePlayer?.stop()
        livePlayer = nil
        connection.cancel()
        operation?.cancel()
        generation = UUID()
        let token = generation
        direction = language; held = language; phase = .arming
        elapsed = 0; levels = Array(repeating: 0, count: 40)
        text = ""; details = ""; recordedWave = nil; translatedWave = nil
        translationComplete = false; streamPlaybackIssue = nil
        message = "Готовлю микрофон · пока не говори"
        operation = Task { [weak self] in
            guard let self else { return }
            let allowed = await self.recorder.preparePermission()
            guard !Task.isCancelled, self.generation == token, self.held == language else { return }
            guard allowed else {
                self.held = nil; self.phase = .idle
                self.message = "Разреши микрофон в настройках iPhone"
                return
            }
            do {
                guard let key = try LiveKey.read() else { throw LiveKey.KeyError.invalid }
                let stream = LiveStreamPlayer()
                stream.onStart = { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.phase = .playing
                    self.message = "Звучит перевод · можно слушать сразу"
                }
                stream.onEnd = { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.phase = .idle
                    self.message = self.streamPlaybackIssue ?? "Готово · удерживай кнопку языка"
                }
                stream.onError = { [weak self] error in
                    guard let self, self.generation == token else { return }
                    self.streamPlaybackIssue = error
                    if self.phase == .playing { self.phase = .idle }
                    self.message = error
                }
                self.livePlayer = stream

                try self.recorder.begin(onMeter: { [weak self] seconds, level in
                    guard let self, self.generation == token, self.phase == .recording else { return }
                    self.elapsed = seconds
                    self.levels.removeFirst(); self.levels.append(level)
                }, onFrame: { [weak self] pcm in
                    guard let self, self.generation == token else { return }
                    self.connection.append(pcm)
                }, onAutomaticStop: { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.end(language)
                })
                self.phase = .recording
                self.message = "Запись + онлайн-перевод · говори, затем отпусти"
                UINotificationFeedbackGenerator().notificationOccurred(.success)

                var submitted = 0
                try self.connection.start(key: key, target: language == "ru" ? "de" : "ru",
                    onText: { [weak self] value in
                        guard let self, self.generation == token else { return }
                        self.text = value
                        self.livePlayer?.confirmTranscript(value)
                    }, onAudio: { [weak self] delta in
                        guard let self, self.generation == token else { return }
                        self.livePlayer?.append(delta)
                    }, onProgress: { [weak self] count in
                        guard let self, self.generation == token else { return }
                        let added = max(0, count - submitted)
                        submitted = count
                        self.spent += Double(added) / 48_000 / 60 * 0.034
                        UserDefaults.standard.set(self.spent, forKey: "live.spent")
                        if self.phase == .sending || self.phase == .connecting {
                            self.message = "Отправляю последние фрагменты · микрофон выключен"
                        }
                    }, onWaiting: { [weak self] in
                        guard let self, self.generation == token else { return }
                        if self.phase != .playing {
                            self.phase = .waiting
                            self.message = "Запись завершена · ожидаю остаток перевода"
                        }
                    }, onFinished: { [weak self] result in
                        guard let self, self.generation == token else { return }
                        switch result {
                        case .success(let reply):
                            self.text = reply.text
                            self.translatedWave = reply.audio.isEmpty ? nil : reply.audio
                            self.translationComplete = !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            self.livePlayer?.confirmTranscript(reply.text)
                            self.details += "\n" + (language == "ru" ? "Русский → Deutsch" : "Deutsch → Русский") + " · ответ завершён"
                            self.livePlayer?.complete()
                            if self.livePlayer?.isPlaying == true {
                                self.phase = .playing
                            } else {
                                self.phase = .idle
                                self.message = self.streamPlaybackIssue ?? (reply.text.isEmpty
                                    ? "Модель не вернула перевод. Запись можно проверить бесплатно."
                                    : (reply.audio.isEmpty ? "Получен только текст перевода" : "Готово · удерживай кнопку языка"))
                            }
                        case .failure(let error):
                            self.recorder.cancel()
                            self.livePlayer?.stop()
                            self.held = nil; self.phase = .idle
                            self.message = (error as? LocalizedError)?.errorDescription
                                ?? "Соединение прервалось. Проверь запись и повтори."
                        }
                    })
            } catch {
                guard self.generation == token else { return }
                self.recorder.cancel(); self.connection.cancel(); self.livePlayer?.stop()
                self.held = nil; self.phase = .idle
                self.message = (error as? LocalizedError)?.errorDescription
                    ?? "Не удалось начать запись или подключить перевод"
            }
        }
    }

    func end(_ language: String) {
        guard held == language else { return }
        held = nil
        if phase == .arming {
            generation = UUID(); operation?.cancel(); recorder.cancel(); connection.cancel()
            phase = .idle; message = "Запись не началась. Удерживай до вибросигнала."
            return
        }
        guard phase == .recording else { return }
        phase = .sending
        message = "Микрофон выключен · завершаю передачу"
        let token = generation
        recorder.finish { [weak self] result in
            guard let self, self.generation == token else { return }
            switch result {
            case .success(let wave):
                do {
                    let pcm = try WavePCM.decode(wave)
                    self.recordedWave = wave
                    self.elapsed = Double(pcm.count) / 48_000
                    self.details = String(format: "Записано %.1f с · передавалось во время речи", self.elapsed)
                    self.details += "\nЗапись " + String(SHA256.hash(data: pcm).map { String(format: "%02x", $0) }.joined().prefix(12))
                    guard pcm.count >= 4_800 else {
                        self.connection.cancel(); self.livePlayer?.stop()
                        self.phase = .idle; self.message = "Запись слишком короткая"
                        return
                    }
                    self.livePlayer?.microphoneReleased()
                    self.connection.finishInput()
                    if self.phase != .playing {
                        self.phase = .waiting
                        self.message = "Микрофон выключен · завершаю перевод"
                    }
                } catch {
                    self.connection.cancel(); self.livePlayer?.stop()
                    self.phase = .idle
                    self.message = "Не удалось сохранить запись микрофона"
                }
            case .failure(let error):
                self.connection.cancel(); self.livePlayer?.stop()
                self.phase = .idle
                self.message = (error as? LocalizedError)?.errorDescription
                    ?? "Не удалось завершить запись"
            }
        }
    }
    func abortPress(_ language: String) {
        guard held == language else { return }
        stopAll(); message = "Запись отменена"
    }
    func stopAll() {
        generation = UUID(); operation?.cancel(); operation = nil
        recorder.cancel(); connection.cancel(); livePlayer?.stop(); livePlayer = nil; stopPlayer(); stopTextSpeech()
        held = nil; phase = .idle
    }
    func background() { stopAll(); message = "Готово · удерживай кнопку языка" }
    func replay() { if let audio = translatedWave, !busy { livePlayer?.stop(); play(audio, source: false) } }
    func review() { if let audio = recordedWave, !busy { livePlayer?.stop(); play(audio, source: true) } }

    /// Free on-device fallback: speaks exactly the visible translation text.
    /// This does not regenerate the translation or call the OpenAI API.
    func speakText() {
        guard translationComplete, !busy, held == nil else { return }
        let prepared = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prepared.isEmpty else { return }
        livePlayer?.stop()
        stopPlayer()
        stopTextSpeech()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let locale = direction == "ru" ? "de-DE" : "ru-RU"
            guard let voice = AVSpeechSynthesisVoice(language: locale) else {
                phase = .idle
                message = "Системный голос для выбранного языка недоступен на iPhone."
                return
            }
            let utterance = AVSpeechUtterance(string: prepared)
            utterance.voice = voice
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            textUtterance = utterance
            phase = .playing
            message = "Звучит текст перевода · системный голос iPhone · бесплатно"
            textSynthesizer.speak(utterance)
        } catch {
            phase = .idle
            message = "Не удалось включить системное озвучивание iPhone."
        }
    }

    private func stopTextSpeech() {
        textUtterance = nil
        if textSynthesizer.isSpeaking { textSynthesizer.stopSpeaking(at: .immediate) }
    }

    private func play(_ audio: Data, source: Bool) {
        stopTextSpeech()
        stopPlayer()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let player = try AVAudioPlayer(data: audio)
            guard player.prepareToPlay() else { throw CocoaError(.fileReadCorruptFile) }
            self.player = player; player.delegate = self; player.volume = 1
            guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
            phase = .playing; message = source ? "Звучит твоя запись · бесплатно" : (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Исходный звук ответа · перевод не подтверждён" : "Звучит перевод · бесплатно")
            playWatch = Task { [weak self, weak player] in
                try? await Task.sleep(nanoseconds: UInt64((player?.duration ?? 0) + 5) * 1_000_000_000)
                guard !Task.isCancelled, let self, let player, self.player === player else { return }
                self.stopPlayer(); self.phase = .idle; self.message = "Готово · удерживай кнопку языка"
            }
        } catch {
            stopPlayer(); phase = .idle; message = "Не удалось воспроизвести запись. Проверь вывод звука iPhone."
        }
    }
    private func stopPlayer() {
        playWatch?.cancel(); playWatch = nil
        player?.delegate = nil; player?.stop(); player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.textUtterance === utterance else { return }
            self.textUtterance = nil
            self.phase = .idle
            self.message = "Готово · удерживай кнопку языка"
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.textUtterance === utterance else { return }
            self.textUtterance = nil
            self.phase = .idle
            self.message = "Озвучивание остановлено"
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.stopPlayer(); self.phase = .idle
            self.message = flag ? "Готово · удерживай кнопку языка" : "Не удалось завершить воспроизведение"
        }
    }
}
