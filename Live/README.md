# Interpreter Live 1.3.2 (9) — voice sharing, audio import and streamlined settings

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

## Audio attachments and translated voice

The microphone translation's OpenAI-returned WAV is preserved in memory as before
and is now also available via **Сохранить перевод** (Files document exporter) and
**Отправить перевод** (iOS share sheet for WhatsApp, Messages, etc.).
These save/share *the translated voice*, not the input microphone recording.
Original recording can still be reviewed but its export button is removed.
The temporary share WAV is deleted on the next recording or imported translation.

**Импорт аудио** opens the iOS Files picker, accepting audio types including
WAV/M4A/MP3/AAC whenever the system decoder supports them. The selected file is
decoded locally to 24 kHz mono PCM16 and streamed in chronological 200 ms frames
with the existing realtime socket; uploads are chargeable. Maximum: 60 seconds.
Imported audio is assumed to be in the selected partner language and is translated
to Russian. To use a WhatsApp voice message, first save it to Files, then import.
An inbound WhatsApp Share Extension is not part of this build.

API key is green only after a successful translation; merely saving a key is not
proof the key was accepted. The manually entered API balance and estimate after
deducting this app's usage appear in Settings. The displayed price is an estimate,
not account billing data. Preferences and PCM format text are shortened.

Voice similarity may vary with the OpenAI model and is **not voice cloning**.
The exported file uses the returned audio without further synthesis or re-translation.

## API key indicator

The API key status has three meaningful colours. Gray means saved but not yet
verified with OpenAI, green means a previous successful translation confirmed
that key, and red means the server explicitly returned `invalid_api_key`.
Network failures, quota problems, and model permission errors do not wrongly
mark the key as invalid. The last successful/rejected status persists after
relaunch for the same key via its SHA-256 fingerprint (no raw key in defaults).
Replacing or deleting the key clears the status. This does not revalidate
revoked keys silently; the next actual translation refreshes the indicator.

## File transcription (1.3.0)

Open **Транскрибация записей** from the main screen. This is separate from
Live translation and never alters its audio streaming or two-button handling.
The user chooses **Один голос** (gpt-transcribe, $0.0045/minute) for ordinary
source-language transcripts, or **Несколько голосов**
(gpt-4o-transcribe-diarize, approx. $0.006/minute) for speaker-labeled
transcripts with segment times. The second model is scheduled for retirement
on 2027-02-26; the feature must have a replacement by then.

Pick audio from iOS Files (including Apple Watch Voice Memos saved to Files).
Before any paid request, display duration, selected model, and approximate
price, and require a second user confirmation. No auto-upload.
Files <=25MB with compatible extensions are uploaded directly; larger or
long files are locally exported to consecutive M4A chunks (<=9min each)
using AVFoundation, checked against the per-file 25MB limit.
One chunk is charged at most once per processing attempt; retries are
explicit user actions. Failed or partial results are shown transparently.
The UI supports cancel, TXT export, copy, and sharing.
OpenAI processing is not free and results may contain mistakes. Especially
for split recordings, speaker A in one chunk may differ from speaker A in
another chunk. The service receives audio only after the user taps
Расшифровать and confirms. Results persist until the sheet is closed.

A successful transcription updates the saved OpenAI key's green status
and app's approximate spent balance; rejected keys turn red. Existing
gpt-realtime-translate is not modified.

Audio transcription API reference:
https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create

## Long-file picker fix (1.3.1)

The transcription sheet now uses a legible dark neutral «Выбрать аудиозапись»
button. Files selection no longer rejects Voice Memos/iCloud documents solely
because a third-party file provider did not mark their UTType as audio.
Audio filename extensions are checked before attempting local decoding.
Security-scoped document reads are coordinated through NSFileCoordinator,
outside the main actor, so a 65-minute recording can download/copy without
blocking the screen. An explicit status message is shown while preparing.
65 minutes is processed in eight parts of at most 9 minutes each.
Diarized timestamps are offset to the real elapsed position, while speaker
IDs between separate parts may still represent different people.

Selection and conversion are free and local; sending audio to OpenAI begins
only after tapping «Расшифровать» and confirming the estimated price.

## Physical-iPhone Files selection (1.3.2)

The screenshot showed `Запись.m4a`, 341 KB, duration 00:39, with the
Files information panel reporting "Аудио MPEG-4 Apple"; the earlier
65-minute memo is a different recording. Both should be selectable.

On some physical iPhones SwiftUI `.fileImporter` displays Files but a tap
does not yield a URL. Transcription and translation attachment flows now
use UIKit `UIDocumentPickerViewController(forOpeningContentTypes:asCopy:)`
with `asCopy: true` and a selection delegate instead. This gives the
application a temporary readable copy, so the preparation code no longer
re-coordinates an already copied iCloud document. The selected filename
becomes visible immediately before validation or chunking, so selection
failure and processing failure are distinct.

CI also checks that neither import entrypoint reintroduces SwiftUI's
failing picker. This is still a **physical-device regression test**:
verify that the modal closes and the chosen file appears, then verify
duration, *before* approving a chargeable transcription.


## Voice clone experiment (1.4.2 build 12; based on 1.4.1 build 11)

This branch starts from `feature/waveform-language-picker-1011`, preserving the
1.4.1 language switcher and Voice-to-Text screen. The opt-in voice clone test is
under Settings → My Voice. The existing realtime translation and audio playback
are unchanged.

The `iliasaz/chatterbox-coreml` Swift package provides on-device Chatterbox
Multilingual on iOS 18+. Large model weights are fetched from Hugging Face only
after the user taps Download. Record 25–30 seconds or import clean speech,
create on-device `my-voice-conds.safetensors`, enter Russian or German text,
and export locally generated WAV. User voice samples are not uploaded for TTS.

Research preview: CI proves compiler packaging only, not on-device speed,
voice fidelity, GPU/ANE thermal stability, or recording behavior. Verify on
an iPhone 16 Pro before enabling the voice in the translation pipeline.

Sources: https://github.com/iliasaz/chatterbox-coreml and
https://github.com/resemble-ai/chatterbox (MIT license).

## Interpreter Live 1.4.14 (24): translation voice fallback and stream audit

Only the main **gpt-realtime-translate** conversation and imported-audio paths change.
The Chatterbox local voice model, Russian proofreading, transcription, and
existing user preferences remain as in 1.4.13.

After the server completes a translation, **Озвучить текст перевода · голос iPhone**
speaks the *visible translated text* using Apple's on-device `AVSpeechSynthesizer`
in the appropriate target locale (ru-RU, de-DE, en-GB, es-ES, etc.). It does not
consume extra OpenAI API credits. It is a different voice from OpenAI's audio.
The existing original OpenAI WAV playback and export remain available.

The live PCM player checks that bytes accepted from the server were scheduled to
the audio node in exactly their original order (byte count plus rolling
fingerprint). Buffer creation or scheduling errors become visible rather than
silently losing a fragment. This audit **cannot** detect words changed inside a
valid audio response produced by the model; comparing the displayed text to the
spoken content still requires listening.

GitHub CI must verify the existing 1.4.13 safeguards plus the new stream-audit
tests and iOS builds. Device tests should verify both languages, long phrases,
pauses, imported audio, interruption/resumption, original WAV replay, and local
text speech. Successful compilation is not an on-device speech-quality test.

### Long pauses in the returned realtime voice (two field samples)

OpenAI's original audio can include very long exact-zero gaps between phrases and
around 15 seconds of digitally silent tail padding. In 1.4.14 we remove only
*consecutive exact-zero PCM16 samples beyond 650 ms* in the streaming player;
all actual nonzero speech samples and short pauses are preserved unchanged.
This is deliberately not a natural-speech VAD or a model latency fix: if an
OpenAI response arrives late or contains quiet nonzero background noise, the
client cannot safely remove that delay/segment using this zero-only approach.
`TranslationConnection` retains the original server WAV for export/replay,
without any silence editing, so A/B diagnosis stays possible. No extra paid call.
The offline silence test confirms cross-chunk caps, unchanged active speech,
unchanged short pauses, and retention of the original semantics on playback.

## 1.4.15 (25): audible, gap-reduced translation replay

The experiment in 1.4.14 shortened digital silence only while receiving the
live stream. Its **Прослушать** button still played the untouched WAV, including
multi-second pauses and server padding. Version 1.4.15 corrects that asymmetry.

**Улучшать звук OpenAI** (enabled by default, switchable in Settings) now:
- applies about +6.02 dB amplitude boost to quiet/medium-level PCM samples
  with a soft limiter to avoid integer overflow on louder sounds;
- maintains the 650-ms cap on consecutive exactly-zero gaps in initial
  stream playback; server delivery can still introduce real-time waiting;
- uses a separate, locally processed WAV for the **Прослушать** replay, with
  inter-sentence zero gaps capped at 650 ms and silent tail to 250 ms;
- leaves the server-produced translated WAV unmodified for export/sharing,
  and adds **Оригинальный голос OpenAI · без обработки** for comparison.

All local processing uses Foundation and AVFoundation without additional API
calls. Processing changes presentation volume and silence only, not the
model's selected words or its natural timbre. It cannot guarantee Apple-TTS
voice quality or fix silence *between* delayed server network events.

Run the protocol, stream integrity, silence and replay audio tests, Xcode
simulator and iPhone compilation. Re-test on an actual iPhone with both
speaker and headphones, and inspect the audio route when comparing Apple
and OpenAI voices. The branch is a draft for testing, not a production release.

## 1.4.16 (26) — Text-only audio delta diagnostics for API Support

The realtime conversation now collects timing-only metadata in memory for a
single translation session, available as **Скопировать журнал для OpenAI Support**
after session completion. It does not collect or expose API keys, microphone
audio, server PCM contents, or recognized/spoken transcript strings.

The copied report includes:
- User-local ISO-8601 start/end wall-clock timestamps (with offset), target
  language, exact non-secret `session.update` JSON, input frame 9600B/200ms.
- `session.close` send and `session.closed` receive events (or error).
- Each included audio delta's arrival wall clock, incoming bytes, zero sample
  count/ratio, sample duration, delta-to-delta receive gap; optional server
  event_id and elapsed_ms metadata when supplied by the API.
- Internal and trailing contiguous exact-zero runs in received PCM, measured
  by output sample offset, and top arrival gaps. An excerpt is automatically
  selected around the longest internal zero run and response tail.

A saved WAV alone cannot reconstruct event-arrival timestamps. Make **one new
reproducible translation in this version**, copy its diagnostic report and paste
it into the ongoing OpenAI API Support case. The report is NOT automatically
uploaded or persisted. It is replaced when the next translation starts.
The original WAV export and audio processing remain unchanged from 1.4.15.
The independent Chatterbox model and proofreading remain untouched.

## 1.4.17 (27) — input PCM level measurements only

Following OpenAI API Support's request, the event report now includes the
microphone's per-200-ms-frame RMS and peak values in dBFS, exact-zero sample
percentage and diagnostic-only "near-silent" indicator (RMS < -45 dBFS).

The input frames are still transmitted unmodified while Push-to-Talk is held,
and the last partial frame is still padded only to the usual 200ms boundary.
No voice activity detection (VAD), automatic end-of-speech gating, shortening,
muting, or transmission interruption has been implemented. Releasing the button
remains the **only** normal end-of-input trigger.

The diagnostic report includes the first five input frames, sent frames around
the wall-clock arrival window of the longest silent translated audio run, and
the final fifteen input frames before `session.close`. Input and output audio
sample offsets cannot be assumed to align directly. The input levels are
observational, not evidence of causal mapping by themselves.
No content audio or text is retained in the diagnostic report.

To report a new failure: make one Russian-to-German push-to-talk translation,
leave the conversation untouched, tap **Скопировать журнал для OpenAI Support**,
and paste the report into the current support thread. An original output WAV
can be exported separately if needed.

## 1.4.18 (28) — isolated native WebRTC experiment

A separate **WebRTC · проверить звучание без WebSocket** control on the
main screen opens a native WebRTC test page. The existing Russian ↔ partner
Push-to-Talk buttons, WebSocket transport, PCM logging, post-processing, local
Chatterbox voice, and Russian proofreading are unchanged.

Technical details:
- Same model: `gpt-realtime-translate`.
- Native RTCPeerConnection from pinned `stasel/WebRTC` package (153.0.0).
- The standard OpenAI API key stays in the existing iOS Keychain. A native
  `URLSession` request to `/v1/realtime/translations/client_secrets`
  exchanges it for a short-lived secret; only that secret goes to
  `/v1/realtime/translations/calls` for SDP exchange.
- Input is the WebRTC microphone track, initially disabled. When connected,
  press and hold the dedicated experiment button to enable audio. Releasing
  disables the track and sends `session.close` via the `oai-events` data channel.
- Translated audio arrives on WebRTC's remote audio track and is played
  directly by its audio engine. Text arrives as `session.output_transcript.delta`.
  A brief post-close buffer is allowed for the remote audio playout.
- Echo cancellation is requested using a voice-chat audio session. Use
  AirPods/headphones for initial tests because translation can start during
  recording; iPhone speaker may otherwise cause acoustic feedback.

**Experiment limitations:** This mode does not save server PCM deltas or the
original OpenAI WAV, cannot use our PCM silence compactor, and does not provide
per-sample silence diagnostics. The A/B comparison is perceptual until we
add native WebRTC decoded-audio capture. No API requests are sent until
the user explicitly enters and connects in this screen. Billing for API
translation still applies. Microphone starts transmitting only while the
experiment control is held. Dismissing the screen or backgrounding disconnects
the peer. Normal WebSocket Push-to-Talk stays fully available.

**Test plan on iPhone:**
1. Use the main WebSocket mode for Russian → German and note pause quality.
2. Open WebRTC screen, connect using same target language; use headphones.
3. Wait for "WebRTC подключён"; hold to speak and release to finish.
4. Listen for pauses, timbre, overall latency, and voice volume; compare with
   WebSocket using similar input phrases.
5. Repeat with the opposite language, explicitly disconnect between sessions.
6. Verify that closing the screen and backgrounding releases the microphone.
7. Confirm the local Chatterbox features and keychain continue to work.

Do not promote this draft to production until it compiles for an actual iPhone
and has been tested on-device for echo, capture activation, playout and session
termination. Compilation is not proof that WebRTC succeeds with the live API.

## 1.4.19 (29) — WebRTC output routing on iPhone

On-device testing confirmed WebRTC translation already runs quickly and without
obvious multi-second pauses, but output without AirPods sometimes went through
the quiet **built-in receiver** (the ear speaker), as in a phone call.

The WebRTC experiment now:
- monitors the active output route while its peer is connected;
- uses `RTCAudioSession`'s configuration lock to request
  `playAndRecord` + `voiceChat`, `defaultToSpeaker`, and Bluetooth support;
- if the route is the **built-in receiver**, explicitly requests the built-in
  loudspeaker with `overrideOutputAudioPort(.speaker)`;
- never forces loudspeaker if headphones, Bluetooth or another external output
  is currently active, because an override can also redirect microphone input;
- reports the currently selected audio destination on its experiment screen,
  with a retry control if still on the built-in receiver;
- rechecks the route on connection, microphone activation and route changes.

Speakerphone playback can create acoustic feedback if translated audio starts
while the microphone is active, so headsets remain preferable for an
uninterrupted bilingual call. Production WebSocket mode is unchanged.

Validation: compile simulator and real iPhone, then confirm physical speaker
vs built-in receiver and AirPods route preservation on-device. No new AI calls
are required to configure routing; normal translation API usage is still billed.
