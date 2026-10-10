# Interpreter 0.4.4 diagnostic build

Both directions reportedly returned no translation in 0.4.3. Root cause is not yet established from a screenshot.

- No automatic playback or success status when a completed response contains no translation text. Keep the unmodified model response for explicit free local inspection; no retry or secondary paid request.
- Show requested and server-confirmed direction, and whether the submitted converted PCM contains sound.
- Optional on-device microphone transcript using the same audio tap when Speech permission and local language support already exist. It is diagnostic only; translation still receives original PCM, with no Apple network recognition fallback.
- Version/build are visible at the bottom of the main screen and in Settings.
- Guard a reused player's completion callback while it is already replaying.
- CI verifies both target configurations and Russian session confirmation, edge preservation, transcript handling, budget, and both iOS builds. Real API quality and microphone capture must be checked on the iPhone.
