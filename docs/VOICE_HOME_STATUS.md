# Voice Home — current status (this branch)

## What was wrong on `main`

`main` still had the **batch** pipeline (record WAV → Storage → `aivyVoiceAsk` → STT → Gemini → TTS → Storage → play). That is why answers felt like **~2 minutes** (or timed out / never arrived).

Your Gemini Live work lived on `cursor/gemini-live-phase1-8350` but was **never merged**. The last fix there (`8660a0a`) also explained **“listens but never replies”** on web/mobile:

- Mic was recorded at **24 kHz** while Gemini Live expects **16 kHz input**
- Web playback used `flutter_soloud` (needs COOP/COEP); now uses **Web Audio API**

## What this branch brings in

1. **Gemini Live** continuous voice (Firebase AI Logic) with business tool calling
2. Web-compatible PCM playback + correct 16 kHz mic
3. Hosting **no-cache** headers so stale Flutter web builds stop masking deploys
4. Legacy `aivyVoiceAsk` speed/correctness fixes (parallel romanize, safer name hints, audioUrl ownership check, TTS failure non-fatal)
5. UX/reliability: cancel races, Stop-while-processing, clearer mic labels, conversation clear, pause animations off-tab

## How to use

1. Tap **Start** → Gemini Live session connects → speak naturally
2. Tap **End** to close the session
3. Long-press the green **Live** pill → fall back to purana (slow) upload pipeline
4. Android: register App Check **debug token** (logcat) if Live connect fails with App Check errors
5. Firebase Console → **AI Logic** must be enabled for the project

See also: `VOICE_HOME_REVIEW.md`, `VOICE_HOME_NEXT_STEPS.md`.
