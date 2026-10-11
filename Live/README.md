# Interpreter Live 1.0.0 (1)

New API-only iPhone application. Bundle identifier `org.interpreter.live`.
Old `App/` Swift files are excluded entirely; only the existing icon asset catalog is reused.

Native AVAudioRecorder creates mono 24 kHz PCM16 WAV through the built-in microphone.
Press starts recording after permission; haptic signals successful start. Release stops the
recorder synchronously. Release while permission is pending never starts a later recording.
Limit: 60 seconds. Native audio is not normalized, gated, trimmed, or supplemented with silence.

Dedicated `/v1/realtime/translations?model=gpt-realtime-translate` only.
One fresh connection per phrase and target language, input noise reduction and transcription off.
Immutable PCM uploads in 200 ms frames, with an unchanged short final frame. `session.close`
flushes output; receive until `session.closed`. No retries, prompts, tools, subscription login,
Apple Speech, Apple synthesis, or automatic extra model requests.

The recording indicator and elapsed seconds exist only while recording. Upload shows its own
byte/duration progress with microphone off. Cost estimate counts transmitted samples once;
initial platform balance is entered manually. Replay is local, untrimmed AVAudioPlayer output.

Temporary recording files are removed after reading/cancel. Latest input/output bytes stay in
memory; exporting WAV is an explicit user action. Unique new Keychain service; no key migration.
Background/inactive scene cancels microphone, sender, websocket and playback.

Build with `cd Live && xcodegen generate`, then scheme `InterpreterLive`.
Offline protocol checks: `swiftc Live/TranslationWire.swift LiveTests/test_wire.swift -o wire-tests`.
Real microphone and bilingual translation quality require an iPhone test, not just compilation.

References:
- https://developers.openai.com/api/docs/guides/realtime-translation
- https://developers.openai.com/api/reference/resources/realtime/translation-client-events
- https://developers.openai.com/api/docs/models/gpt-realtime-translate
