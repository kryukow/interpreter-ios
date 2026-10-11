# Interpreter Live 1.2.0 (4) — instant translation with four language pairs and a live waveform

The tappable header «Русский ↔ Deutsch ⇵» opens a compact native iPhone wheel picker.
Only emoji flags appear in the wheel; swiping up or down changes the language
with iOS selection haptics. The header and directional buttons display the
current language name; the selected partner persists after relaunch.
The available partner flags are:
Deutsch (de), Română (ro), English (en), Polski (pl).
Russian remains the fixed opposite language. Two explicit push-to-talk
buttons instantly point at the selected target: Russian → partner or
partner → Russian. No language detection, extra AI calls, or guessed direction.
The selected partner is kept in local app settings and defaults to Deutsch.

While pressed, AVAudioEngine records the built-in microphone (24 kHz mono PCM16)
and immediately streams 200 ms audio frames over one WebSocket to
`/v1/realtime/translations?model=gpt-realtime-translate`.
No second real-time-length upload occurs after releasing the button.
Pending microphone frames queue while the socket connects.
On release, the app drains the final frame and sends `session.close`.
It receives audio and transcript deltas until `session.closed`.

Translated audio is buffered while the microphone is active, then played
incrementally once the button is released and translation text is available,
using AVAudioPlayerNode. This prevents the phone speaker from feeding back
into the microphone. Unconfirmed audio (no transcript) is not auto-played.
Playback does not wait for the full transcript or the full `session.closed`.

The source recording is retained as original PCM data wrapped in WAV for
optional listening/export. The finished translated recording can be replayed
offline without another API request. Input noise reduction and extra
transcription are disabled. No extra paid model calls or retries.

The original dotted line becomes an active, symmetric, white waveform
with the biggest voice-driven vibration in the centre, gently tapering
towards both sides of the display while recording. It uses microphone amplitude already calculated locally
by the recorder, with no audio modification, FFT, additional inference,
or network traffic. Selecting languages and visualizing sound do not
change the 200 ms transmission pipeline.

The input cap is 60 seconds, old requests are cancelled on a new press or
backgrounding, and API key remains in the device-only Keychain.
The balance and costs are estimates, not verified OpenAI billing figures.

Build: `cd Live && xcodegen generate`, scheme `InterpreterLive`.
GitHub Actions builds simulator and iPhone unsigned IPA. It is not an
on-device integration test: latency, audio route and spoken translation must
be verified on iPhone before treating this version as production-ready.

IMPORTANT: The dedicated gpt-realtime-translate model currently only supports
13 spoken OUTPUT languages including ru/de/en. Romanian and Polish are currently
INPUT languages only. The ro/pl output directions in this draft remain blocked
on adding a separate user-approved backend; do NOT publish or merge this draft
as full four-language support based solely on CI success.

Device checks: verify the supported directions, particularly
names and short phrases. Verify that the
waveform reacts to quiet/loud speech, remains still when not recording,
and has no impact on the latency achieved by the previous release.
The offline protocol tests and CI compile do not prove live API quality.
