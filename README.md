# Interpreter 0.4.0 — Russian ↔ German

Adds an opt-in personal iPhone test of `gpt-realtime-translate`: direct microphone audio to OpenAI, translated transcript and OpenAI speech, two explicit directions, one-minute capture cap, cancellation and device-only Keychain API-key entry. Existing ChatGPT subscription mode stays available and remains the default. See [REALTIME_TEST.md](REALTIME_TEST.md) for setup, costs, privacy and on-device acceptance. No paid request has been made by CI; compile and protocol tests do not prove account access or acoustic quality.

Voice settings choose the best installed voice automatically (premium, then enhanced, then compact), or let you select a voice separately for Russian and German. Listen to samples and adjust the rate before translating. Download additional voices through iPhone Settings; the app refreshes its list when returning to the foreground. An unavailable saved voice falls back to the best installed voice of the same language.

iPhone prototype. Two explicit language buttons replace automatic direction guessing and duplicate paid audio channels.

1. Open Settings and sign in through the official ChatGPT page. Choose a model from the account's list.
2. Tap Русский or Deutsch, speak, and tap the same button again.
3. Apple Speech recognizes the selected language. The resulting text is translated using ChatGPT plan usage via Responses, then spoken by the iPhone.
4. Correct the source text and retry if needed. Cancel remains available during recording, recognition, translation, and playback.

In the subscription mode no separate OpenAI API key is needed. Subscription limits still apply. Apple Speech uses on-device recognition where supported; otherwise it may send audio to Apple. Only text is sent to OpenAI in that mode. The optional realtime test instead sends microphone audio using a personal API key and charges the API balance separately. Account tokens and the separately entered key stay in this app's private, device-only Keychain. Source phrases are not saved to disk.

Interpreter has its own OAuth registration and app-private Keychain service. It does not access sessions belonging to other applications.

## Build and installation

The macOS workflow compiles a simulator build and a real-device build, tests stream completion/refusal/failure handling, and packages an **unsigned** IPA. Sign it with your personal certificate and compatible provisioning profile in Feather before installation. There is no certificate, signing password, or private key in this repository or workflow.

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Interpreter.xcodeproj -scheme Interpreter -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Current validation

Version 0.3.0 compiled for simulator and iPhone and passed stream tests. Its sign-in and translation were confirmed by the owner on iPhone. Version 0.3.1 adds configurable installed voices; compilation is verified by its workflow, and actual voice availability and sound quality still require testing on the device. The model list is a catalog, not proof of inference access.

On-device acceptance: test both directions, short words, names, numbers, quiet and noisy environments; deny microphone permission; cancel recording and translation; retry after a failed request; background the app; verify that playback is never captured by the microphone. Check transcription separately from translation.
