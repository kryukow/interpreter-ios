# Interpreter 0.4.3

- Prepare a new PCM/WAV clip excluding low-level leading and trailing audio rather than seeking past leading silence in the original clip. Keep 350 ms before first detected sound and 450 ms after last detected sound; preserve interior pauses and original retained samples.
- Conservative low-floor adaptation capped at -48 dBFS. Edge detection is heuristic; actual phrases and audio routes must be evaluated on an iPhone. Completely silent clips remain unchanged.
- Display detected excluded duration before and after speech for local diagnosis. No audio is stored on disk or sent again.
- Enable replay during API playback; pressing replay restarts the prepared local player, without an API request. Complete playback state before re-preparing the player.
- Keep foreground playback session ready; background/new capture cleanup from 0.4.2 remains.
- Device checks: leading delay, trailing delay, first/last quiet syllables, replay while playing, internal pauses, background and Bluetooth route.
