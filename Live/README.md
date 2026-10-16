# Interpreter Live 1.1.0 (3) — lower-latency streaming

Two press-and-hold buttons: Russian → German and German → Russian.

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

The input cap is 60 seconds, old requests are cancelled on a new press or
backgrounding, and API key remains in the device-only Keychain.
The balance and costs are estimates, not verified OpenAI billing figures.

Build: `cd Live && xcodegen generate`, scheme `InterpreterLive`.
GitHub Actions builds simulator and iPhone unsigned IPA. It is not an
on-device integration test: latency, audio route and spoken translation must
be verified on iPhone before treating this version as production-ready.

## Experimental on-device voice cloning (1.1.1, build 4)

The **My Voice · experiment** screen is isolated from the realtime pipeline.
It uses the external MIT-licensed `iliasaz/chatterbox-coreml` Swift package,
which converts Resemble AI Chatterbox multilingual into an Apple Silicon runtime.
The user must explicitly download the large Core ML model to the app's document
sandbox before first use. No model weights are bundled with the unsigned IPA.

User flow: Download multilingual inference + five cloning encoders → Load →
record 25–30 seconds or import an audio file → create a local conditioning voice →
enter Russian or German text → generate, play and share WAV. The voice conditioning
file is stored under `Documents/VoiceLab`; temporary source recordings are removed
when the experimental sheet closes. The OpenAI streaming API and its audio playback
remain unchanged. No audio recording is sent to Hugging Face or the TTS provider.

This is a research preview, not a proven real-time feature. Test download/storage,
model loading, sound quality, interruptions, thermal performance, and time-to-first-
audio on an **iPhone 16 Pro** before considering a translation voice switch.
The app and package have not been verified on real hardware by this change.

Sources and license: https://github.com/iliasaz/chatterbox-coreml
and https://github.com/resemble-ai/chatterbox (MIT); model files are downloaded
from https://huggingface.co/iliasaz/chatterbox-multilingual-coreml .
