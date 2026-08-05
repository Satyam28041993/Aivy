# Aivy Voice Home (first screen) — Architecture Review & Problem Report

**Scope reviewed:** the voice Q&A on the first tab (`AivyVoiceHomeScreen`), the session state
machine behind it, the `aivyVoiceAsk` Cloud Function, and the Google STT/TTS helpers.

**Files:**

| Layer | File |
|---|---|
| UI | `lib/features/home/presentation/aivy_voice_home_screen.dart` (1250 lines) |
| State machine | `lib/core/voice/home_voice_qa_session.dart` (519 lines) |
| Callable client | `lib/core/voice/aivy_voice_ask_service.dart` |
| TTS playback | `lib/services/google_home_voice_service.dart`, `lib/core/voice/aivy_chat_voice_coordinator.dart` |
| Upload | `lib/features/chat/data/voice_file_upload_io.dart` |
| Backend | `functions/src/aivyVoiceAsk.ts` (592 lines) |
| STT/TTS | `functions/src/googleSpeechCloud.ts` |
| Romanizer | `functions/src/romanHinglish.ts` |
| Data snapshot | `functions/src/clientStats.ts`, `functions/src/aivyProcess.ts` (`getUserMemory`) |

---

## 0. TL;DR (Hinglish)

- **Gemini Live implement hi nahi hua.** Repo me na `web_socket_channel` dependency hai, na koi
  `BidiGenerateContent` / live-model reference. Jo abhi chal raha hai wo **batch pipeline** hai:
  record → WAV file → Storage upload → callable → STT → Gemini → TTS → MP3 → Storage → download → play.
  **11 network hops per turn.**
- **Isliye slow hai.** Ek sawaal ka jawab aane me realistically **11–16 second (warm)** aur cold start
  pe **15–25 second** lagta hai. Live API pe yahi kaam **~1 second** me hota hai.
- Sirf tuning se ye theek nahi hoga. Architecture hi galat hai — batch request/response me
  barge-in (beech me tokna) kabhi possible nahi hoga.
- Iske upar **4 P0 bugs** hain jinki wajah se app "kharab" feel hota hai: cancel karne ke baad bhi
  Aivy bolti hai, Stop dabane ke 90 second baad mic apne aap on ho jaata hai, aur silence
  detection normal room noise me trigger hi nahi hota.
- UI har frame me **~1300 blurred draw calls** karta hai aur background tab me bhi chalta rehta hai
  → phone garam, frame drops, battery drain.
- Har sawaal pe **poori payments collection** Firestore se padhi jaati hai (25 rows banane ke liye).

Detail neeche.

---

## 1. What actually happens on one voice turn today

```
[ 1] tap mic  → permission + AudioSession.configure + recorder.start        ~0.3–0.6 s
[ 2] user speaks
[ 3] silence detector waits 2000 ms of quiet                                 2.0–2.1 s  (dead air)
[ 4] recorder.stop() → finalize WAV on disk
[ 5] upload WAV to Firebase Storage (India → US bucket)                      1.5–4.0 s   ~320 KB
[ 6] getDownloadURL()                                                        ~0.3 s
[ 7] callable aivyVoiceAsk (India → us-central1)          warm 0.4 s / COLD  3.0–8.0 s
        ├─ buildVoiceReportSnapshot()  (Firestore: memory + 120 tasks
        │  + 200 reminders + ENTIRE payments collection)                     0.4–3.0 s  ┐ parallel
        └─ STT: download WAV back into the function + recognize()            1.2–2.7 s  ┘
[ 8] romanizeUserFacingText() → a SECOND Gemini call                         0.8–2.0 s
[ 9] answerVoiceQuestion() → gemini-2.5-flash, thinking ON, huge prompt      3.0–8.0 s
[10] Google TTS synthesizeSpeech()                                           0.6–1.5 s
[11] save MP3 to Storage                                                     0.3–1.0 s
[12] return URL → client just_audio setUrl() downloads MP3 (US → India)      0.6–2.0 s
[13] first sound comes out of the speaker
```

**Time to first audio: ≈ 11–16 s warm, 15–25 s cold.**
The UI's own safety timer gives up at **28 s** (`home_voice_qa_session.dart:99`), which means on a
bad day the pipeline is racing its own kill switch.

For comparison, Gemini Live API with an already-open socket: end-of-speech detected server-side
(~300 ms) → first audio chunk streaming back (~500–900 ms). **≈1 second, and interruptible.**

### The core problem in one sentence

The same 8 seconds of speech crosses the Indian Ocean **four times** (audio up, audio down into
the function, MP3 up, MP3 down) and passes through **three separate model/API calls** (STT →
romanizer → Gemini → TTS) before a single sound is produced.

---

## 2. Bugs — P0 (these are what makes it feel broken)

### P0-1 · A cancelled turn still speaks

`home_voice_qa_session.dart:378-457`

`_processRecording()` never checks the generation counter (`_recordGen`) that the rest of the class
uses so carefully. Meanwhile:

- `_friendlyReset()` (`:121`) sets `phase = idle` and tells the user "Process cancel kiya gaya"
- the 28 s processing safety timer (`:99-107`) also calls `_friendlyReset()`

…but the in-flight `await _ask.ask(...)` keeps running. When it returns, line `:424` does
`_setPhase(speaking)` and `:427` plays the audio.

**Symptom:** user cancels (or waits out the timeout), screen goes idle, and 10 seconds later Aivy
suddenly starts talking over them. This alone reads as "app is broken".

### P0-2 · "Stop" hangs for 90 seconds, then randomly turns the mic on

`google_home_voice_service.dart:72-93` + `home_voice_qa_session.dart:190-199, 438-450`

`speakAndWait()` waits for `ProcessingState.completed`. But `stopSpeaking()` calls
`_player.stop()`, which puts just_audio into `ProcessingState.idle` — **never `completed`**. So the
`firstWhere` never matches and falls through to its `.timeout(Duration(seconds: 90))`.

Consequences:
1. `_processRecording` stays awaited for 90 s after the user pressed Stop.
2. When the timeout finally fires, `:438` sets phase to idle and `:444-450` re-arms the mic — so
   **the microphone switches itself on ~91 seconds after the user pressed Stop**, in hands-free mode.
3. The `speaking` safety timer (60 s, `:110`) fires first and calls `stopSpeaking()` again, so the
   two timers interleave.

**Fix:** resolve on `!s.playing && (completed || idle)`, or expose a completer that `stop()`
completes explicitly.

### P0-3 · Three different timeouts that disagree

| Layer | Timeout | File |
|---|---|---|
| UI safety timer | **28 s** | `home_voice_qa_session.dart:99` |
| Callable client | **120 s** | `aivy_voice_ask_service.dart:65` |
| Cloud Function | **120 s** | `aivyVoiceAsk.ts:408` |

The UI gives up at 28 s while the backend keeps burning Gemini + TTS + Firestore budget for another
92 seconds, and then P0-1 makes the abandoned answer play anyway. These three numbers must be
derived from one constant, with the client strictly the longest.

### P0-4 · Overlapping turns

`home_voice_qa_session.dart:124` — `_friendlyReset()` sets `_submitting = false` while
`_processRecording()` is still in flight (it is called from inside `submitRecording()`'s `try`).
The guard at `:308` therefore passes, and the user can start a second recording while the first
request is still running. Two turns then race to set `phase`, `lastAnswer`, and playback.

---

## 3. Bugs — P1

### P1-5 · The name corrections never reach the model

`functions/src/aivyVoiceAsk.ts:503-522` vs `:566`

Pass 2 builds `finalQuestion` (Ravi/baby/abhi/heavy → "Aivy") and assigns it to `question`. But the
model call passes **`question: romanizedQuestion`** — the *pre-correction* string. So ~20 regexes of
work only affect the transcript shown on screen; Gemini still receives "Ravi" / "baby".

### P1-6 · Silence detection doesn't trigger in a normal room

`home_voice_qa_session.dart:284-302`

```dart
if (amp.current < -38.0) {        // quiet → maybe submit
  ...
} else {
  _lastSpeechTime = now;          // ← resets the silence clock
}
```

Any sample at **≥ −38 dBFS** resets the clock. Typical office/room noise floor sits around
−35 to −40 dBFS, and a ceiling fan or AC puts you permanently above the threshold. Result: the
2-second timer never elapses, auto-submit never fires, and the user has to tap the mic manually —
or wait for the 45 s listening timeout.

The thresholds (−28 / −38) are hardcoded absolutes with no noise-floor calibration. They need to be
measured relative to a rolling background estimate captured in the first ~300 ms.

### P1-7 · 2 seconds of guaranteed dead air on every single turn

`home_voice_qa_session.dart:288` — a fixed 2000 ms wait after the user stops speaking, polled at
100 ms granularity, *before the upload even begins*. That's 2 s of pure latency added to an already
12 s round trip. Gemini Live's server-side VAD does this in ~200–300 ms.

### P1-8 · Fire-and-forget submit from the audio stream

`home_voice_qa_session.dart:296` — `submitRecording();` is called un-awaited inside the amplitude
listener. Any exception is unobserved. And if it early-returns because `_submitting` is already
true, `_lastSpeechTime` has already been nulled at `:292`, so the detector can never re-fire and
the session sits in `listening` until the 45 s timer.

### P1-9 · Cancelling a recording erases the conversation

`home_voice_qa_session.dart:165` — `cancelRecording()` calls `_history.clear()`. Cancelling one
mis-started recording wipes the entire multi-turn context. Almost certainly not intended.

### P1-10 · Gemini is called with no `generationConfig` at all

`functions/src/aivyVoiceAsk.ts:368-370` — the payload is literally `{ contents }`. Consequences:

- **Thinking is on by default** on `gemini-2.5-flash`. For a reply that must be "under 45 words",
  thinking tokens are pure latency. Set `thinkingConfig: { thinkingBudget: 0 }`.
- **JSON is requested in prose, not enforced.** The prompt demands strict JSON (`:331-336`) and the
  code then hand-strips ``` fences and try/catches a parse failure (`:383-392`). Use
  `responseMimeType: "application/json"` + `responseSchema` and this whole class of failure vanishes.
- No `maxOutputTokens`, no `temperature`.
- The system prompt is **inlined into the user turn** (`:351-366`) instead of the `systemInstruction`
  field — which blocks implicit prefix caching on an otherwise-identical ~1 KB preamble every turn.

### P1-11 · An entire extra Gemini round trip for romanization

`aivyVoiceAsk.ts:499` calls `romanizeUserFacingText()`, which is a **full second Gemini
`generateContent` call**. And it fires on essentially every voice turn, because STT is configured
with `languageCode: "hi-IN"` (`googleSpeechCloud.ts:113`) and therefore returns Devanagari.

This is a self-inflicted round trip: either ask the transcriber for Roman output directly, or fold
the romanization instruction into the single main call.

### P1-12 · Every question reads the entire payments collection

`aivyVoiceAsk.ts:127` → `clientStats.ts:868` → `fetchAllDocsOrderedById` (`clientStats.ts:48-63`)
pages through the **whole** `users/{uid}/payments` collection with **no upper bound** (3000 docs per
page, loop until exhausted). The result is used to produce at most **25 rows**
(`aivyVoiceAsk.ts:227`).

At 2,000 payment docs that is 2,000 Firestore document reads *per spoken question*. Latency and
cost both grow linearly with how successful the business gets. This needs a bounded query
(`where dueDateMs <= weekAhead`, `where status == open`, `limit`) or a pre-aggregated summary doc.

### P1-13 · Prompt bloat, re-sent every turn

`aivyVoiceAsk.ts:115-134, 240-267` serializes up to 120 tasks + 200 reminders + the full memory
profile + 25 payment rows into the prompt on **every** turn. Several thousand input tokens, mostly
irrelevant to the question asked, with no caching and no retrieval. Slower time-to-first-token and
a per-turn cost that scales with the user's data.

### P1-14 · Recording uncompressed WAV

`home_voice_qa_session.dart:233-240` — `AudioEncoder.wav`, 16 kHz, 16-bit mono = **32 KB/s**.
An 8-second question is ~320 KB uploaded from India to a US bucket. The same speech as Opus is
~15–20 KB — **~16× smaller**. This is seconds of upload time on mobile, for no quality gain that
STT can use.

(Note the backend already handles Opus/OGG in `pickEncodingForPath`, `googleSpeechCloud.ts:86-88`.)

### P1-15 · Wrong region for an Indian user

`lib/core/firebase/firebase_session.dart:17` → `us-central1`.
`functions/src/googleSpeechCloud.ts:18` → bucket `aivy-5c031.firebasestorage.app`.

Every turn: audio India→US, MP3 US→India, plus the callable RTT (~250–350 ms each way) and the
throughput penalty on a long-fat pipe. `asia-south1` (Mumbai) would remove most of this.

### P1-16 · No `minInstances` — cold start on the first question

`aivyVoiceAsk.ts:405-411`. The function pulls in `firebase-admin`, `@google-cloud/speech`,
`@google-cloud/text-to-speech`, and `luxon`. That's a 3–8 s cold start, and it lands on exactly the
first question of a session — the moment the user is watching the screen and forming an opinion.

---

## 4. Bugs — P2

- **P2-17 · Unbounded Storage garbage.** Every question leaves `users/{uid}/voice/ask_*.wav`
  (never deleted — only the *local* temp file is removed, `voice_file_upload_io.dart:31-36`), and
  every answer leaves `users/{uid}/tts/{uuid}.mp3` with `cacheControl: public,max-age=31536000`
  (`googleSpeechCloud.ts:282-293`). No lifecycle rule in `storage.rules`, no cleanup function.
  Storage grows forever.
- **P2-18 · TTS for a hardcoded sentence.** `aivyVoiceAsk.ts:553-562` synthesizes the same canned
  "chat section me jaaye" line through Google TTS on every trigger. Bake it once into a static asset.
- **P2-19 · Keyword-list routing.** Search intent is detected by a hardcoded 12-string keyword list
  (`:528-532`) and scheduling intent by regex (`:553`). Both are things the model should decide via
  function calling / the Google Search tool — the current approach silently misses every phrasing
  not in the list.
- **P2-20 · Two ExoPlayer instances alive for the app's lifetime** —
  `google_home_voice_service.dart:19` and `aivy_chat_voice_coordinator.dart:9`, with the home screen
  stopping one to play on the other.
- **P2-21 · `sources` is untyped.** `List<dynamic>` indexed with string keys in the widget
  (`aivy_voice_home_screen.dart:843-844`). No model class, no compile-time safety.

---

## 5. UI / rendering problems (why the screen itself feels heavy)

### R-1 · ~1,300 draw calls per frame, forever

`_SpiralGalaxyPainter.paint` (`aivy_voice_home_screen.dart:440-541`):

- 3 arms × ~346 steps = **~1,040 `drawCircle` calls** for the spiral
- **260 stars**, and *every one* of them applies `MaskFilter.blur` (`:538`) — a per-circle blur that
  cannot batch

Both `_spiralRotation` and `_twinkle` are `..repeat()` with no stop condition (`:47-54`), so this
paints at 60 fps permanently.

### R-2 · Two more full-screen blurred painters on top

`:200-247` — two `_VoiceRingsPainter` layers sized at 0.95 and 0.88 of the screen's longest side.
Each draws 12–14 stroked circles with `MaskFilter.blur` (`:652`) plus echo rings. Neither is wrapped
in a `RepaintBoundary` (only the galaxy is, `:143`), so they invalidate together.

### R-3 · `BackdropFilter` over an animating background

`:703` — `ImageFilter.blur(sigmaX: 16, sigmaY: 16)` on the transcript card. A backdrop blur must
re-sample whatever is behind it; behind it is a 60 fps galaxy. This is the single most expensive
widget on the screen and it's placed over the busiest region.

### R-4 · `setState` every 22 ms during all of the above

`_TypingText._startTyping` (`:962-978`) fires a `Timer.periodic(22ms)` that calls `setState` and
rebuilds via string concatenation (`_visibleText += ...`) — O(n²) allocations over the answer, ~45
rebuilds per second, layered on top of R-1/R-2/R-3.

### R-5 · Text and voice are desynchronized by design

The typewriter runs at a fixed 22 ms/char with **no relationship to the TTS audio**. A 200-character
answer types in 4.4 s while the audio may take 9 s (or vice versa). Every answer visibly drifts out
of sync with Aivy's voice.

### R-6 · Animations keep running on other tabs

`home_shell.dart:238` uses `IndexedStack`, which keeps all children alive. Nothing gates the four
`AnimationController`s behind `TickerMode` or a visibility check, so the galaxy, twinkle, breath and
voice-sim controllers keep ticking (and rebuilding) while the user is in Chat, Reminders, or
Settings. Constant CPU and battery drain with nothing on screen.

### R-7 · Phase change rebuilds the entire 1,250-line screen

`:65-69` — `onPhaseChanged` → `setState(() {})` on the root `State`. Every phase transition and
every error rebuilds the whole tree instead of a small `ValueListenable`-scoped subtree.

---

## 6. The Gemini Live gap

**Status: not started.** Evidence:

- `pubspec.yaml` has no `web_socket_channel` (or any WS package)
- Repo-wide grep for `BidiGenerateContent`, `live-api`, `websocket`, `*-live-*` model IDs → **zero hits**
- `AudioEncoder.pcm16bits` / `recorder.startStream()` — the streaming capture API — is used nowhere;
  all three record sites use file-based `AudioEncoder.wav`
  (`chat_screen.dart:274`, `chat_screen.dart:489`, `home_voice_qa_session.dart:235`)

What was built instead is a **batch** pipeline. That distinction matters more than any individual
bug in this document, because these capabilities are *structurally impossible* in the current design
no matter how much it is optimized:

| Capability | Batch (today) | Live API |
|---|---|---|
| Time to first audio | 11–16 s | ~1 s |
| Barge-in (interrupt Aivy by speaking) | impossible | native |
| Partial transcript while speaking | impossible | native |
| End-of-speech detection | client-side dB heuristic, 2 s fixed | server VAD, ~300 ms |
| Network round trips per turn | 11 | 1 persistent socket |
| Separate STT / TTS / romanizer calls | 3 extra calls | 0 (native audio in/out) |
| Emotional/prosodic voice | flat Neural2 MP3 | native audio dialog |
| Tool calling mid-conversation | keyword regex | native function calling |

---

## 7. Recommended target architecture

```
Flutter                                    Google
───────────────────────────────────────────────────────────────
record.startStream(pcm16, 16 kHz, mono)
        │  ~640-byte chunks, every 20 ms
        ▼
 WebSocket (opened once per session) ──────► Gemini Live API
        ▲                                    · server VAD
        │  24 kHz PCM audio chunks           · barge-in
        │  + input/output transcripts        · function calling
        │  + toolCall frames                 · Google Search tool
        ▼
 PCM player (AudioTrack / flutter_pcm_sound)
        │
        └── toolCall → callable Cloud Function → Firestore → toolResponse
```

**Auth:** mint an **ephemeral token** in a Cloud Function (the Live API's `auth_tokens.create`) and
let the client connect directly to Google. The `GEMINI_API_KEY` never leaves the backend, and there
is no relay hop in the audio path. Use a Cloud Run WebSocket relay only if you need every tool call
server-mediated — note that **callable Cloud Functions cannot hold a WebSocket**, so `aivyVoiceAsk`'s
shape cannot be reused for this.

**Grounding:** stop dumping the snapshot. Expose it as tools the model calls when it actually needs
them — `get_today_focus()`, `get_overdue()`, `get_payment_followups()`, `get_client(name)`. Each is
a thin callable over the queries that already exist in `aivyVoiceAsk.ts`. This kills P1-12, P1-13,
and P2-19 at once.

**Audio plumbing (the real implementation cost):** `record` handles capture
(`AudioEncoder.pcm16bits` + `startStream()`). Playback of raw 24 kHz PCM is the awkward part —
`just_audio` is URL/file-oriented and won't take a PCM stream. Budget for `flutter_pcm_sound`,
`flutter_soloud`, or a small platform channel over `AudioTrack`/`AVAudioEngine`.

**Model choice:** the Live models split into *native audio* (best voice quality and prosody) and
*half-cascade* (more reliable tool calling). Given how much Aivy depends on function calling, start
on half-cascade and A/B the native-audio model for voice quality. Model IDs and session limits in
the Live API move often — verify current IDs, the audio-only session cap, and the session-resumption
/ context-compression options against the live docs before committing.

---

## 8. Migration plan

**Phase 0 — stop the bleeding (1–2 days, no architecture change).** Ship the quick wins in §9.
This should take a turn from ~13 s to ~6 s and fix the four P0 bugs. Do this regardless of whether
Live happens, because it also de-risks Phase 1.

**Phase 1 — Live spike (3–5 days).** Ephemeral-token function + a throwaway Flutter screen that
opens the socket, streams mic PCM, plays PCM back. No tools, no UI polish. Goal: measure real
time-to-first-audio on an Indian 4G connection and prove the PCM playback path on a real Android
device. This is the decision gate.

**Phase 2 — tools (3–5 days).** Port the snapshot queries into 4–5 tool functions. Wire toolCall /
toolResponse. Delete the keyword search list and the regex intent blocker.

**Phase 3 — UI (2–3 days).** Rebuild the screen around the streaming phases (partial transcript,
barge-in indicator). Rewrite the painters per §9. Delete `_TypingText` — with streamed transcripts
there is real text to reveal, so a fake typewriter is no longer needed.

**Phase 4 — fallback.** Keep the current batch path behind a flag for poor networks and for
platforms where the socket fails. It becomes the degraded mode, not the primary one.

---

## 9. Quick wins (ship before Live, ~1–2 days)

| # | Change | File | Est. saving |
|---|---|---|---|
| 1 | Add a generation check in `_processRecording`; abort if `gen != _recordGen` | `home_voice_qa_session.dart:378` | fixes P0-1 |
| 2 | Resolve `speakAndWait` on `completed` **or** `idle` | `google_home_voice_service.dart:76` | fixes P0-2 |
| 3 | Derive all three timeouts from one constant, client longest | 3 files | fixes P0-3 |
| 4 | Move `_submitting = false` out of `_friendlyReset` | `home_voice_qa_session.dart:124` | fixes P0-4 |
| 5 | `AudioEncoder.opus`, 16 kHz mono | `home_voice_qa_session.dart:234` | **1–3 s** |
| 6 | Calibrate silence thresholds to a measured noise floor; drop the wait to ~900 ms | `home_voice_qa_session.dart:284` | **1.1 s** + fixes P1-6 |
| 7 | `thinkingConfig: { thinkingBudget: 0 }` + `responseMimeType`/`responseSchema` + `maxOutputTokens` | `aivyVoiceAsk.ts:368` | **2–5 s** |
| 8 | Drop the romanizer call; instruct Roman output in the main call | `aivyVoiceAsk.ts:499` | **0.8–2 s** |
| 9 | Bound the payments query (`where` + `limit`) instead of `fetchAllPayments` | `aivyVoiceAsk.ts:127` | **0.3–3 s** + big cost cut |
| 10 | `minInstances: 1` on `aivyVoiceAsk` | `aivyVoiceAsk.ts:405` | **3–8 s** on first turn |
| 11 | Move functions + bucket to `asia-south1` | `firebase_session.dart:17` | **1–2 s** |
| 12 | Move the system prompt into `systemInstruction` | `aivyVoiceAsk.ts:351` | TTFT + cache |
| 13 | Trim the snapshot to what the question needs; cap tasks/reminders at ~20 | `aivyVoiceAsk.ts:240` | TTFT + cost |
| 14 | Storage lifecycle rule: delete `voice/` and `tts/` after 7 days | GCS console | cost |
| 15 | Wrap both ring painters in `RepaintBoundary`; cut stars 260→80; drop per-star `MaskFilter.blur` | `aivy_voice_home_screen.dart:200,538` | frame time |
| 16 | Gate the controllers on `TickerMode` / route visibility | `aivy_voice_home_screen.dart:47` | battery |
| 17 | Drive the typewriter off audio position, or delete it | `aivy_voice_home_screen.dart:962` | sync + CPU |

Items 1–14 alone should bring a warm turn from ~13 s to roughly **5–6 s**. That is still 5× slower
than Live — which is the point: **the quick wins are damage control, not the fix.**

---

## 10. Verdict

The implementation is careful in places (generation counters, safety timers, STT→Gemini fallback,
keys kept off the client) — the problem is not sloppiness, it's that a **batch architecture was
built where a streaming one was planned.** Every symptom the user feels — the long wait, the
inability to interrupt, the dead air after speaking, the answer that arrives after they gave up —
traces back to that one decision, and none of them can be fully fixed without changing it.

Recommendation: **ship §9 items 1–14 this week** to make the current experience tolerable, then run
the Phase 1 Live spike to validate PCM playback and real-world latency before committing to the
full migration.
