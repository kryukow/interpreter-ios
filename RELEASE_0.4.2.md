# Interpreter 0.4.2

- Reuse the prepared in-memory player for replay. Keep its playback session active while Interpreter is foregrounded after playback; starting microphone capture or backgrounding releases it.
- Detect near-digital leading silence in received PCM. Start playback 250 ms before the first detected sound; preserve the complete original clip and all interior pauses. Very quiet speech uses a conservative threshold, and an all-silent clip is unchanged.
- No new network request or API charge on replay. Voice adaptation is unchanged.
- Device acceptance: compare repeat latency with the previous build, listen for intact first syllables on quiet phrases, background during playback, then reopen and replay; start a new recording after playback. Audio-route startup can still vary on Bluetooth.
