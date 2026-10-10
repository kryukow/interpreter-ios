# Interpreter 0.4.1

- Hold either language button; wait for the ready vibration, speak, release to finish and hear translation.
- Releasing during connection cancels safely. Moving the finger off the button cancels the phrase.
- A new hold interrupts playback or pending translation. No separate Stop button.
- Live API mode hides subscription account and model selection.
- Set the current API balance manually in Settings. This device estimates spending from submitted audio at $0.034/minute, including cancelled phrases. Replaying audio sends no request. The estimate is not an official OpenAI balance.
- Monochrome design matching the black/white icon; microphone amplitude history during recording, gentle waiting animation while connecting or translating.
- Verify on an iPhone: quick release before ready, long hold/release, interrupted playback, switching languages, leaving the screen, and balance persistence. CI compilation cannot verify real touch handling or audio routing.
