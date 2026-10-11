import SwiftUI
import AVFoundation
import UIKit

@MainActor final class LiveSession: NSObject, ObservableObject, AVAudioPlayerDelegate {
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
    @Published private(set) var keySaved = false
    @Published private(set) var spent = UserDefaults.standard.double(forKey: "live.spent")
    @Published private(set) var credit: Double? = UserDefaults.standard.object(forKey: "live.credit") as? Double
    private let recorder = NativeRecorder()
    private let connection = TranslationConnection()
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var player: AVAudioPlayer?
    private var playWatch: Task<Void, Never>?
    private var direction = "ru"
    var busy: Bool { phase != .idle && phase != .playing }
    var remainder: String { credit.map { String(format: "≈ $%.3f", max(0, $0 - spent)) } ?? "—" }
    override init() {
        super.init()
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
        stopPlayer(); connection.cancel(); operation?.cancel()
        generation = UUID()
        let token = generation
        direction = language; held = language; phase = .arming
        elapsed = 0; levels = Array(repeating: 0, count: 40)
        text = ""; details = ""; recordedWave = nil; translatedWave = nil
        message = "Готовлю микрофон · пока не говори"
        operation = Task { [weak self] in
            guard let self else { return }
            let allowed = await self.recorder.preparePermission()
            guard !Task.isCancelled, self.generation == token, self.held == language else { return }
            guard allowed else {
                self.held = nil; self.phase = .idle
                self.message = "Разреши микрофон в настройках iPhone"; return
            }
            do {
                try self.recorder.begin(onMeter: { [weak self] seconds, level in
                    guard let self, self.generation == token, self.phase == .recording else { return }
                    self.elapsed = seconds
                    self.levels.removeFirst(); self.levels.append(level)
                }, onAutomaticStop: { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.end(language)
                })
                self.phase = .recording; self.message = "Запись · говори, затем отпусти"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                guard self.generation == token else { return }
                self.recorder.cancel(); self.held = nil; self.phase = .idle
                self.message = "Не удалось начать запись. Проверь разрешение микрофона."
            }
        }
    }
    func end(_ language: String) {
        guard held == language else { return }
        held = nil
        if phase == .arming {
            generation = UUID(); operation?.cancel(); recorder.cancel()
            phase = .idle; message = "Запись не началась. Удерживай до вибросигнала."
            return
        }
        guard phase == .recording else { return }
        // Stop the hardware synchronously, before starting any upload task.
        do {
            let wave = try recorder.finish()
            let pcm = try WavePCM.decode(wave)
            recordedWave = try WavePCM.encode(pcm)
            elapsed = Double(pcm.count) / 48000
            details = String(format: "Записано %.1f с · без обработки", elapsed)
            guard pcm.count >= 4800 else { phase = .idle; message = "Запись слишком короткая"; return }
            phase = .connecting; message = "Микрофон выключен · подключаю перевод"
            let token = generation
            operation = Task { [weak self] in
                guard let self else { return }
                do {
                    guard let key = try LiveKey.read() else { throw LiveKey.KeyError.invalid }
                    var submitted = 0
                    let reply = try await self.connection.run(key: key, pcm: pcm,
                        target: language == "ru" ? "de" : "ru", onText: { [weak self] text in
                            guard let self, self.generation == token else { return }
                            self.text = text
                        }, onProgress: { [weak self] count in
                            guard let self, self.generation == token else { return }
                            let added = max(0, count - submitted)
                            submitted = count
                            self.spent += Double(added) / 48000 / 60 * 0.034
                            UserDefaults.standard.set(self.spent, forKey: "live.spent")
                            self.phase = .sending
                            self.message = String(format: "Отправка · %.1f / %.1f с\nМикрофон выключен", Double(submitted) / 48000, self.elapsed)
                        }, onWaiting: { [weak self] in
                            guard let self, self.generation == token else { return }
                            self.phase = .waiting; self.message = "Запись отправлена · ожидаю перевод"
                        })
                    guard !Task.isCancelled, self.generation == token else { return }
                    self.text = reply.text
                    self.translatedWave = reply.audio.isEmpty ? nil : reply.audio
                    self.phase = .idle
                    self.details += "\n" + (language == "ru" ? "Русский → Deutsch" : "Deutsch → Русский") + " · ответ завершён"
                    if !reply.audio.isEmpty { self.play(reply.audio, source: false) }
                    else { self.message = reply.text.isEmpty ? "Модель не вернула перевод. Запись можно проверить бесплатно." : "Получен текст перевода, без звука" }
                } catch {
                    guard self.generation == token else { return }
                    self.phase = .idle
                    self.message = error is CancellationError ? "Остановлено" : (error as? LocalizedError)?.errorDescription ?? "Соединение прервалось. Запись доступна для проверки."
                }
            }
        } catch {
            recorder.cancel(); phase = .idle
            message = (error as? LocalizedError)?.errorDescription ?? "Не удалось прочитать запись микрофона"
        }
    }
    func abortPress(_ language: String) {
        guard held == language else { return }
        stopAll(); message = "Запись отменена"
    }
    func stopAll() {
        generation = UUID(); operation?.cancel(); operation = nil
        recorder.cancel(); connection.cancel(); stopPlayer()
        held = nil; phase = .idle
    }
    func background() { stopAll(); message = "Готово · удерживай кнопку языка" }
    func replay() { if let audio = translatedWave, !busy { play(audio, source: false) } }
    func review() { if let audio = recordedWave, !busy { play(audio, source: true) } }
    private func play(_ audio: Data, source: Bool) {
        stopPlayer()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let player = try AVAudioPlayer(data: audio)
            guard player.prepareToPlay() else { throw CocoaError(.fileReadCorruptFile) }
            self.player = player; player.delegate = self; player.volume = 1
            guard player.play() else { throw CocoaError(.fileReadCorruptFile) }
            phase = .playing; message = source ? "Звучит твоя запись · бесплатно" : "Звучит перевод · бесплатно"
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
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard self.player === player else { return }
            self.stopPlayer(); self.phase = .idle
            self.message = flag ? "Готово · удерживай кнопку языка" : "Не удалось завершить воспроизведение"
        }
    }
}
