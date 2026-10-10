# Interpreter 0.4.0: personal iPhone voice translation test

The existing ChatGPT-plan mode remains the default. Settings lets the owner opt into a separate paid audio mode using exactly `gpt-realtime-translate` at `/v1/realtime/translations`.

## Install and enable

The workflow builds an unsigned IPA. Sign with your existing personal certificate and compatible provisioning profile in Feather. Keep the same bundle identity to preserve the app's own ChatGPT session when updating.

1. Create a personal project API key at https://platform.openai.com/api-keys. Do not paste it into chats or commit it. It must have access to Realtime translation; an API balance alone does not prove model access.
2. On the iPhone, open Interpreter settings, paste the key into the secure field under “Голосовой перевод API” and save it. It is stored in this app's device-only Keychain, separate from the existing ChatGPT session.
3. Select “Голосовой перевод API · тест”. Tap Русский to produce German, or Deutsch to produce Russian. Speak and tap the same button again to finish. A minute is the automatic per-recording maximum.
4. The translation transcript arrives as you speak. Playback uses the audio returned by OpenAI, after recording ends and the server confirms `session.closed`. The input microphone and output speaker never run together. This first test is turn-taking, not simultaneous hands-free interpretation.
5. “Остановить” cancels capture, network and playback; backgrounding does the same. There are no automatic reconnects or silent retries of paid audio. Switching modes clears the previous result.

## Cost and privacy

Official model price checked 2026-10-10: $0.034 per minute of audio. Actual billing, tax and project access are determined by OpenAI. The app shows submitted input duration and time to first transcript/audio delta, not account balance or guaranteed billed cost. Silence during recording is transmitted to preserve timing. Optional source transcription is not enabled, so no separate Whisper transcription model is requested. No local audio files or transcript history are stored; replay audio exists only in memory.

This personal prototype connects from the owner's iPhone using the key they supply. It embeds no key, certificate or account data in the IPA or repository and needs no always-on computer or hosted service. For distributing to other users, replace personal key entry with a backend issuing short-lived credentials.

## On-device acceptance (not proven by compilation)

- Both directions: a simple statement, a question, names, numbers, a negation, and an instruction that must be translated rather than answered.
- Say a sentence, pause for two seconds, then continue. Earlier transcript fragments must remain.
- Compare clear voice with mumbling: the model receives actual audio, but cannot reliably recover inaudible words.
- Confirm OpenAI speech plays after the second tap and can replay without another API request.
- Stop while connecting, recording, draining and playing; background the app; return and start again. No late result from the old session may appear.
- Deny microphone permission; use an invalid/revoked key, insufficient credits, unavailable model and interrupted internet. Incomplete audio must not play and retry must remain possible.
- Let the minute limit expire. Capture ends, pending output drains with a 25-second cap, and the connection closes. Observe API usage on the official dashboard.

References:
- https://developers.openai.com/api/docs/guides/realtime-translation
- https://developers.openai.com/api/docs/models/gpt-realtime-translate
- https://developers.openai.com/api/reference/resources/realtime/translation-client-events
- https://developers.openai.com/api/reference/resources/realtime/translation-server-events
