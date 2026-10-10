# Interpreter 0.3.0 — Russian ↔ German

iPhone prototype. Two explicit language buttons replace automatic direction guessing and duplicate paid audio channels.

1. Open Settings and sign in through the official ChatGPT page. Choose a model from the account's list.
2. Tap Русский or Deutsch, speak, and tap the same button again.
3. Apple Speech recognizes the selected language. The resulting text is translated using ChatGPT plan usage via Responses, then spoken by the iPhone.
4. Correct the source text and retry if needed. Cancel remains available during recording, recognition, translation, and playback.

No separate OpenAI API key or paid server is configured. Subscription limits still apply. Apple Speech uses on-device recognition where supported; otherwise it may send audio to Apple. Only text is sent to OpenAI. Account tokens stay in this app's private, device-only Keychain. Source phrases are not saved to disk.

Interpreter has its own OAuth registration and app-private Keychain service. It does not access sessions belonging to other applications.

## Build and installation

The macOS workflow compiles a simulator build and a real-device build, tests stream completion/refusal/failure handling, and packages an **unsigned** IPA. Sign it with your personal certificate and compatible provisioning profile in Feather before installation. There is no certificate, signing password, or private key in this repository or workflow.

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Interpreter.xcodeproj -scheme Interpreter -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Current validation

Source prepared on Windows. Xcode compilation, sign-in, model entitlement, speech recognition quality, and voice playback on the actual iPhone are **not yet verified**. The model list is a catalog, not proof of inference access. First publication should trigger the workflow; only a successful build confirms compilation.

On-device acceptance: test both directions, short words, names, numbers, quiet and noisy environments; deny microphone permission; cancel recording and translation; retry after a failed request; background the app; verify that playback is never captured by the microphone. Check transcription separately from translation.
