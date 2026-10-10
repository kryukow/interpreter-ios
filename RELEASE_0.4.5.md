# Interpreter 0.4.5

- Edge detection requires 30 ms sustained activity instead of treating a single click as the start/end of speech. Preserve the existing 350/450 ms margins and all interior pauses. Very short clips without sustained activity remain unchanged.
- Display local player startup estimate measured from the play request to advancing playback position, excluding elapsed clip time. This does not measure acoustic speaker or Bluetooth latency.
- Tests cover a loud initial click, 4 seconds silence, quiet onset, speech, and a final click after 5 seconds silence. The user's actual four-second delay still requires device verification; no original audio file was available for analysis.
- Voice adaptation, no-charge replay, local diagnostics and background cleanup remain unchanged.
