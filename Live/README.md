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
