# Voice Home — pick-up checklist

Handoff notes for resuming the Voice Home work on another machine.
Full analysis and reasoning: [`VOICE_HOME_REVIEW.md`](VOICE_HOME_REVIEW.md).

## Where things stand

- Review is **complete**. Nothing has been fixed yet — no production code was changed.
- Branch: `claude/gemini-voice-chat-review-9smq2k`
- Only two files differ from `main`: `docs/VOICE_HOME_REVIEW.md` and `README.md`.

## Get set up

```bash
git clone https://github.com/Satyam28041993/Aivy.git
cd Aivy
git checkout claude/gemini-voice-chat-review-9smq2k

flutter pub get
cd functions && npm install && cd ..
```

Checks (per `AGENTS.md`): `flutter analyze`, `flutter test`, and in `functions/`:
`npm run build`, `npm test`. Note `flutter analyze` already reports pre-existing
info/warning issues on `main` — those are not from this work.

Secrets (`GEMINI_API_KEY` etc.) live in Firebase Secret Manager / `functions/.env`,
which is gitignored. Vitest does not need them; deploying functions does.

## Phase A — ordered work queue

Do them in this order; 1 and 2 are the highest value per line changed.

| # | Task | Where | Effort |
| --- | --- | --- | --- |
| 1 | **Validate `audioUrl` belongs to the caller.** Reject any path not starting with `users/{uid}/` before the Admin SDK downloads it. | `functions/src/aivyVoiceAsk.ts:431`, `functions/src/googleSpeechCloud.ts:59-75` | ~5 lines |
| 2 | **Stop refusing legitimate questions.** Wire `isWhoToCallAnalyticsQuestionText()` into the voice path, the way `aivyProcess.ts:2629` already does. | `functions/src/aivyVoiceAsk.ts:553` | ~5 lines |
| 3 | **Delete the destructive name regexes** (`अभी`, `रवि`, `Ravi`, `baby`, `heavy`, `ivy`). Replace with STT `speechContexts` phrase hints. | `functions/src/aivyVoiceAsk.ts:468-516`, `functions/src/googleSpeechCloud.ts:110-117` | ~30 lines |
| 4 | **Drop the romanize round trip.** Have the answer prompt return a romanized transcript in the JSON it already emits. Saves 0.8–2.0 s/turn. | `functions/src/aivyVoiceAsk.ts:499`, `:331-335` | ~20 lines |
| 5 | **Fix cancel/timeout races.** Capture `gen = _recordGen` in `_processRecording` and bail after every `await`; make `_friendlyReset` bump `_recordGen`. | `lib/core/voice/home_voice_qa_session.dart:121-134`, `:378-457` | ~15 lines |
| 6 | **Return TTS audio inline as base64** instead of writing to Storage and re-downloading. Answers are ~40 KB. | `functions/src/googleSpeechCloud.ts:243-296`, `lib/services/google_home_voice_service.dart:51-69` | ~40 lines |
| 7 | **Record Opus instead of WAV** (`AudioEncoder.opus`). Backend already handles `.opus`/`.ogg`. | `lib/core/voice/home_voice_qa_session.dart:233-240`, `lib/features/chat/data/voice_file_upload_io.dart:20-22` | ~10 lines |
| 8 | **`minInstances: 1`** on `aivyVoiceAsk` to kill the 3–8 s cold start. | `functions/src/aivyVoiceAsk.ts:406-411` | 1 line |
| 9 | **Cache the data snapshot** per uid (30–60 s) and bound `fetchAllPayments` to open/recent dues. | `functions/src/aivyVoiceAsk.ts:101-268`, `functions/src/clientStats.ts:868-874` | ~40 lines |
| 10 | **Adaptive silence threshold** from the ambient noise floor instead of hard-coded −28/−38 dB. Shorten the 2000 ms window to ~800 ms. | `lib/core/voice/home_voice_qa_session.dart:274-303` | ~40 lines |
| 11 | **Cut the UI paint cost.** Pre-render galaxy + starfield once via `ui.PictureRecorder`, drop per-star `MaskFilter.blur`, add `TickerMode` gating so the screen stops animating on other tabs. | `lib/features/home/presentation/aivy_voice_home_screen.dart:439-541`, `:573-678`, `lib/features/home/presentation/home_shell.dart:237` | ~120 lines |
| 12 | **Storage lifecycle rule** — delete `users/*/voice/**` and `users/*/tts/**` after 1–7 days. | GCS console / `gsutil lifecycle` | config only |

Expected result after Phase A: a typical turn drops from ~7 s to ~3 s, transcripts stop
being corrupted, and questions about reminders start working.

## Phase B — Gemini Live

Only start this once Phase A is merged; several Phase A fixes (1, 2, 9) carry over, the
rest get deleted by the migration.

The Live API needs a persistent bidirectional socket, so **Cloud Functions callables
cannot host it**. Two options, compared in `VOICE_HOME_REVIEW.md` §16:

- **Ephemeral token + direct client socket** — recommended, lowest latency, key stays off
  the APK. Needs `web_socket_channel` and `record`'s `startStream` for raw PCM.
- **Cloud Run relay** — more server-side control, one extra hop. Must be Cloud Run.

Once on Live, these can be deleted outright: separate STT, separate TTS, the silence/VAD
detection, the hands-free loop timer, and the speaking/listening handoff in the phase
state machine — the protocol handles all of it, including barge-in.

Also move the Firestore snapshot from "paste the whole database into every prompt" to
Live **tool declarations** (`get_todays_reminders`, `get_pending_payments`,
`get_client_dues`) so the model fetches data only when it needs it.
