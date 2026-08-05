# Aivy Voice Home (first screen) — Review Report

Scope of this review: the voice chat on the app's **first tab** (`HomeShell` index 0).

Files reviewed:

| Layer | File |
| --- | --- |
| UI | `lib/features/home/presentation/aivy_voice_home_screen.dart` (1250 lines) |
| State machine | `lib/core/voice/home_voice_qa_session.dart` (519 lines) |
| Callable client | `lib/core/voice/aivy_voice_ask_service.dart` |
| TTS playback | `lib/services/google_home_voice_service.dart`, `lib/core/voice/google_voice_service.dart`, `lib/core/voice/aivy_chat_voice_coordinator.dart` |
| Upload | `lib/features/chat/data/voice_file_upload_io.dart` |
| Backend | `functions/src/aivyVoiceAsk.ts`, `functions/src/googleSpeechCloud.ts`, `functions/src/romanHinglish.ts`, `functions/src/webSearch.ts`, `functions/src/intentDetection.ts` |

---

## 0. Headline finding: Gemini Live was planned, but nothing of it was built

There is **no Gemini Live API code anywhere in this repository**. Verified by searching the
whole tree (Dart + TypeScript + pubspec + package.json) for every marker the Live API requires:

- `bidiGenerateContent` — 0 hits
- `WebSocket` / `web_socket_channel` — 0 hits
- `gemini-live-*` / `native-audio` model ids — 0 hits
- Any streaming audio transport — 0 hits

`pubspec.yaml` has no WebSocket dependency, and `functions/package.json` has no
`@google/genai` (the only SDK that speaks the Live protocol). What actually shipped is a
**classic batch request/response pipeline**, not a live session. That single fact explains
almost all of the "bahut slow, bahut bekar" feeling — the architecture is wrong for the goal,
not just badly tuned.

**What was built (per turn):**

```
mic stop → WAV file → Firebase Storage upload
        → callable aivyVoiceAsk (cold start possible)
        → function downloads the WAV back from Storage
        → Google STT sync recognize (whole file at once)
        → Gemini call #1  (romanize Devanagari → Hinglish)
        → Gemini call #2  (answer, with full data snapshot re-sent)
        → Google TTS synthesize whole MP3
        → write MP3 to Storage
        → return URL
        → client downloads MP3 over HTTPS
        → ExoPlayer prepares → playback starts
```

That is **11 sequential steps and ~7 separate network legs** before the user hears one word.

**What Gemini Live would have been:** one persistent WebSocket, mic PCM streamed up
continuously, model audio streamed back down, first audio out in ~300–800 ms, with barge-in
(user can interrupt mid-sentence) built into the protocol.

---

## 1. Latency budget — why it feels so slow

Per-turn estimate for the current pipeline (10-second question, 4G, India → us-central1):

| Step | Typical | Worst case |
| --- | --- | --- |
| Record finalize + file flush | 100 ms | 300 ms |
| **WAV upload to Storage** (see §2 — uncompressed) | 800 ms | 2500 ms |
| Cloud Function cold start (no `minInstances`) | ~150 ms warm | **3000–8000 ms cold** |
| Firestore snapshot build (runs parallel with STT) | 300 ms | 2000 ms+ |
| Function downloads WAV back from Storage | 200 ms | 500 ms |
| Google STT `recognize` (sync, whole file) | 600 ms | 1500 ms |
| **Gemini call #1 — romanize** (avoidable, see §3) | 800 ms | 2000 ms |
| **Gemini call #2 — answer** (huge prompt, see §4) | 1500 ms | 4000 ms |
| Google TTS synthesize | 500 ms | 1200 ms |
| Write MP3 to Storage | 200 ms | 600 ms |
| Client downloads MP3 + player prepare | 500 ms | 1500 ms |
| **Total to first spoken word** | **~6–8 s** | **~15–20 s** |

The client's own safety timer admits this: `home_voice_qa_session.dart:99` gives up after
**28 seconds** of processing. Nobody writes a 28-second timeout for a fast pipeline.

**The biggest single wins available without rewriting to Live:**

1. Delete the romanize call (§3) — saves 0.8–2.0 s, every turn.
2. Return the MP3 as base64 inline in the callable response instead of Storage round-trip (§5) — saves ~0.7–2.1 s.
3. Record Opus instead of WAV (§2) — saves ~0.6–2.0 s on upload.
4. Set `minInstances: 1` on `aivyVoiceAsk` — removes the 3–8 s cold-start cliff.
5. Cache the data snapshot (§4) — removes an unbounded Firestore scan per turn.

Those five alone realistically take a typical turn from ~7 s to ~3 s. Getting under 1 s
requires Gemini Live.

---

## 2. Client records uncompressed WAV — 4× more upload than needed

`home_voice_qa_session.dart:233-240`

```dart
await _recorder.start(
  const RecordConfig(
    encoder: AudioEncoder.wav,   // uncompressed PCM
    sampleRate: 16000,
    numChannels: 1,
  ),
  path: _tempPath!,
);
```

16 kHz × 16-bit × mono = **32 KB per second**. A 10-second question = **320 KB uploaded**
over mobile data. `AudioEncoder.opus` at the same quality would be ~8 KB/s → **80 KB**.
Google STT supports `OGG_OPUS` natively, and `googleSpeechCloud.ts:86-88` already handles
`.opus`/`.ogg`. The encoder is simply set to the most expensive option.

Side note: `pickEncodingForPath` returns `LINEAR16` for `.wav`, but the `record` plugin
writes a 44-byte RIFF header. With an explicit `LINEAR16` encoding those header bytes are
handed to the recognizer as audio. In practice Google tolerates it, but it is not correct
and can produce a click / dropped first phoneme.

---

## 3. An entire extra Gemini round-trip runs on every single turn, for nothing

`aivyVoiceAsk.ts:499`

```ts
const romanizedQuestion = await romanizeUserFacingText(question, geminiKey);
```

STT is configured with `languageCode: "hi-IN"` (`googleSpeechCloud.ts:113`), so the
transcript is **always in Devanagari**. `romanizeUserFacingText` fires on any Devanagari
input — meaning a **full second Gemini API call, serially, before the answer call, on 100%
of turns**, purely to convert script.

This is unnecessary. The answering model is `gemini-2.5-flash`, which reads Devanagari
perfectly. The romanization only exists so the *transcript shown on screen* is in Latin
letters — and that could be handled by asking the answer prompt to echo back a romanized
transcript in the same JSON it already returns, at zero extra latency.

**Cost:** ~0.8–2.0 s and one extra billed Gemini call per question.

---

## 4. Full business database is re-read and re-sent to the model on every question

`aivyVoiceAsk.ts:115-134` — `buildVoiceReportSnapshot` runs per turn and reads:

- up to 120 pending tasks
- up to 200 pending reminders
- the user memory profile
- **`fetchAllPayments(uid)` — the entire `payments` collection, unbounded**

`fetchAllPayments` → `fetchAllDocsOrderedById` (`clientStats.ts:48-63`) is a paginated loop
that keeps fetching until the collection is exhausted. For a business with a few thousand
payment documents, that is several seconds of Firestore reads and real per-read cost — **on
every single spoken sentence**, including "hi Aivy" and "how are you".

The resulting JSON is then stringified and pasted into the prompt (`aivyVoiceAsk.ts:298`,
`:356`) with **no caching and no context caching** — so the same tens of KB are re-tokenized
by Gemini every turn. High input tokens = higher latency and higher bill.

**Fix:** in-memory cache the snapshot per uid for 30–60 s (voice turns come in bursts), and
bound the payments read to open/recent dues only.

---

## 5. TTS takes the slowest possible path back to the user

`googleSpeechCloud.ts:243-296` synthesizes the MP3, **writes it to Firebase Storage**, then
returns a download URL. The client then **downloads it again** over HTTPS and hands it to
ExoPlayer.

The answers are capped at "under 45 words" by the prompt (`aivyVoiceAsk.ts:329`) — that's
roughly 8–10 seconds of speech, about **40 KB of MP3**. That fits trivially in the callable
response as base64. The Storage write + client re-download adds **~0.7–2.1 s for zero
benefit**, plus a storage object that is never deleted (§10).

Google TTS also supports streaming synthesis, which the code does not use.

---

## 6. 🐞 Name "corrections" are actively destroying transcripts

`aivyVoiceAsk.ts:468-490` and `:503-516` run two passes of blind global regex replacement.
Several of these are dangerous:

```ts
{ pattern: /अभी/g,  replacement: "Aivy" },   // line 479
{ pattern: /अभि/g,  replacement: "Aivy" },   // line 476
{ pattern: /रवि/g,  replacement: "Aivy" },   // line 478
{ pattern: /रावी/g, replacement: "Aivy" },   // line 477
{ pattern: /\b(ravi|Ravi|rawi|Rawi|raavi|Raavi)\b/gi, replacement: "Aivy" },  // line 505
```

- **`अभी` means "now"** — one of the most common words in spoken Hindi. "अभी कॉल करना है"
  ("need to call right now") silently becomes "Aivy कॉल करना है". Every sentence containing
  "abhi" is corrupted.
- **`रवि` / `Ravi` is an extremely common Indian client name.** For a marketing manager
  whose whole app is about client follow-ups, "Ravi ko call karna hai" becomes
  "Aivy ko call karna hai". The assistant then answers about the wrong thing and looks
  broken.
- `baby`, `heavy`, `ivy` are also globally replaced (`:485-488`, `:508`).

The correct fix for "STT mishears my assistant's name" is **Speech Adaptation / phrase hints**
on the recognizer (`speechContexts` with `"Aivy"`, `"Prakruti Graphic"`, and the user's real
client names boosted), *not* post-hoc string surgery on the user's words. Currently the STT
config has **no phrase hints at all**.

---

## 7. 🐞 The pass-2 corrections never reach the model (dead code)

`aivyVoiceAsk.ts:518-522` computes `finalQuestion` through the Hinglish correction list and
assigns it to `question`. But two lines later:

```ts
const result = await answerVoiceQuestion({
  geminiKey,
  question: romanizedQuestion,   // ← line 566: PRE-correction value
  ...
});
```

The model is given `romanizedQuestion` — the value from *before* the second correction pass —
while the client is returned `transcript: question` (the corrected one). So the screen shows
one thing and the AI answered a different thing. Whatever pass 2 was meant to fix, it does not
reach the answer.

---

## 8. 🐞 Asking about reminders/meetings gets refused — the screen's own purpose is blocked

`aivyVoiceAsk.ts:553`

```ts
if (looksLikeReminderSchedulingLine(qLower, question)) {
  // "Sir, ... Is kaam ke liye aap chat section me jaaye."
```

`looksLikeReminderSchedulingLine` starts with `hasReminderKeyword` (`intentDetection.ts:75-77`),
which returns `true` for **any text containing the word "remind" or "reminder"**.

So on a screen whose stated job is *"answer from live report + memory data"*:

| User says | What happens |
| --- | --- |
| "Aaj ke reminders kya hain?" | ❌ Blocked → "go to chat section" |
| "Kitne reminders pending hain?" | ❌ Blocked |
| "Kal 5 baje ki meeting kiski hai?" | ❌ Blocked (branch 3: date + time + `meet`) |

Meanwhile `functions/src/aivyProcess.ts:2629` guards exactly this case with
`isWhoToCallAnalyticsQuestionText()` — the "this is a question, not a scheduling command"
exemption. **The voice path never calls it.** The guard exists in the codebase and was simply
not wired into `aivyVoiceAsk`.

This makes the feature feel useless even when it is fast.

---

## 9. 🐞 Cancel and timeout don't actually cancel — Aivy speaks after you stopped her

Three related race conditions in `home_voice_qa_session.dart`:

**(a) `_friendlyReset` does not invalidate the in-flight request.**
`_friendlyReset` (`:121-134`) clears state and sets phase to `idle`, but it does **not**
increment `_recordGen`, and `_processRecording` (`:378-457`) never re-checks generation after
its `await`s. So:

- User taps mic during processing → `toggleMic` → `_friendlyReset('Process cancel kiya gaya.')`
  (`:152`) → snackbar says cancelled, UI goes idle.
- The `await _ask.ask(...)` is still running. When it returns, execution continues to
  `_setPhase(HomeVoiceQaPhase.speaking)` (`:424`) and **plays the answer out loud**.

The user cancels, gets told it's cancelled, then Aivy starts talking anyway.

**(b) Same for the 28-second processing timeout** (`:99-107`): the client resets and shows
"Sochne me thoda waqt lag raha hai", but the function keeps running (its own timeout is
**120 s**, `aivyVoiceAsk.ts:409`), still pays for Gemini + TTS, and the late response still
triggers playback.

**(c) The client callable timeout is 120 s** (`aivy_voice_ask_service.dart:65`) — over four
times the UI's patience. These three numbers (28 s / 120 s / 120 s) should be one coherent
budget.

**Fix:** capture `final gen = _recordGen` at the top of `_processRecording` and bail out after
every `await` if `gen != _recordGen`; make `_friendlyReset` bump `_recordGen`.

---

## 10. 🔒 Security: any user can transcribe another user's audio (IDOR)

`aivyVoiceAsk.ts:431` takes `audioUrl` **straight from the client** and passes it to
`transcribeFromFirebaseStorageUrlWithFallback`. That resolves to:

```ts
// googleSpeechCloud.ts:59-65
function decodeStoragePathFromDownloadUrl(audioUrl: string): string {
  const pathRaw = audioUrl.split("/o/")[1]?.split("?")[0];
  ...
}
// :67-75 — downloads with the ADMIN SDK, which bypasses storage.rules
const bucket = getStorage().bucket(storageBucketName());
const [buf] = await bucket.file(filePath).download();
```

**There is no check that the decoded path starts with `users/{request.auth.uid}/`.** Any
authenticated user can pass `.../o/users%2F<someone-elses-uid>%2Fvoice%2Fask_123.wav?...` and
the function will download that user's private voice recording with admin privileges and
return the transcript in the response.

`storage.rules` correctly scopes `users/{userId}/**` to the owner — but the Admin SDK ignores
storage rules entirely, so the rule provides no protection here.

**Fix (one line):**

```ts
const path = decodeStoragePathFromDownloadUrl(audioUrl);
if (!path.startsWith(`users/${uid}/`)) {
  throw new HttpsError("permission-denied", "Audio does not belong to this user");
}
```

**Secondary:** `synthesizeToFirebaseStorage` (`:281-295`) publishes every answer MP3 with a
`firebaseStorageDownloadTokens` public URL and `cacheControl: public,max-age=31536000`.
Anyone holding the link can fetch business answers without authentication, forever.

---

## 11. 🗑️ Storage grows forever — nothing is ever deleted

- Every question uploads `users/{uid}/voice/ask_<timestamp>.wav`. The client deletes its
  *local* temp file (`voice_file_upload_io.dart:30-34`) but the **Storage object stays**.
- Every answer writes `users/{uid}/tts/<uuid>.mp3` with a 1-year cache header. Never deleted.

At ~320 KB per question and ~40 KB per answer, 100 voice turns a day ≈ **13 GB/year** of
write-once-never-read garbage, billed monthly. There is no lifecycle rule, no TTL, no cleanup
function. Add a GCS lifecycle policy (delete `users/*/voice/**` and `users/*/tts/**` after
1–7 days), or drop Storage from the path entirely (§5) so it never accumulates.

---

## 12. ⚡ The UI is repainting ~1300 blurred shapes per frame

This is the *other* half of "bahut slow" — even before the network, the screen itself is heavy.

**`_SpiralGalaxyPainter.paint`** (`aivy_voice_home_screen.dart:439-541`), running every frame:

```dart
for (var arm = 0; arm < 3; arm++) {
  for (var theta = -0.35 * math.pi; theta < 4.6 * math.pi; theta += 0.045) {
```

The loop's `break` condition (`r > maxR * 1.02`) is **never reached** on a phone-sized canvas —
at `theta = 4.6π`, `r = 2.8·e^(0.175·14.45) ≈ 35 px`, while `maxR ≈ 200 px`. So the full
**~345 iterations × 3 arms = ~1035 `drawCircle` calls** run every single frame.

Then 260 more stars, **each with `MaskFilter.blur`** (`:534-539`) — per-shape blur is one of
the most expensive operations in Skia/Impeller because it cannot batch.

On top of that, **two** `_VoiceRingsPainter` layers (`:200-247`), 14 + 12 = 26 stroked circles,
**every one with `MaskFilter.blur`** (`:652-655`), plus echo rings — all repainting every frame
because `tick` is driven by the 90-second controller.

Plus a `BackdropFilter(sigma 16)` on the transcript card (`:703-704`).

**Total: ~1300 draw calls per frame, ~290 of them individually blurred.** On a mid-range
Android this is a guaranteed 15–25 fps, and it runs **continuously**, including while idle.

Practical fixes: pre-render the static galaxy + starfield **once into an offscreen image**
(`ui.PictureRecorder`) and just rotate/blit it; drop `MaskFilter.blur` on individual stars in
favour of a couple of pre-blurred sprite layers; cut ring counts; wrap each painter in its own
`RepaintBoundary`.

**Also:** `HomeShell` puts this screen in an `IndexedStack` (`home_shell.dart:237`), so it stays
mounted on every other tab. All four `AnimationController`s are `..repeat()` forever
(`:47-62`) and their `AnimatedBuilder`s keep rebuilding at 60 fps while the user is in Chat,
WhatsApp, or Dashboard. It should be wrapped in `TickerMode(enabled: isVoiceHome)` or the
controllers stopped when the tab is not selected — right now this screen taxes the whole app.

---

## 13. 🎤 Silence detection uses fixed dB thresholds that will not work on most devices

`home_voice_qa_session.dart:274-303`

```dart
if (amp.current > -28.0) { _hasSpoken = true; _lastSpeechTime = now; }
...
if (amp.current < -38.0) { /* after 2 s → auto-submit */ }
```

`Amplitude.current` from the `record` plugin is raw dBFS and varies enormously by device, mic
gain, and how far the phone is from the mouth. Two failure modes, both of which look like
"the app hangs":

- **Quiet phone / soft speaker:** peaks never exceed −28 dB → `_hasSpoken` stays `false` →
  auto-submit **never fires** → the user waits for the **45-second** safety timeout
  (`:89-96`). This alone would explain "bahut slow chalta hai".
- **Noisy shop floor / office:** ambient noise stays above −38 dB → the silence branch never
  triggers → same 45-second wait.

There is no noise-floor calibration and no adaptive threshold. The standard approach is to
sample the ambient floor for the first ~300 ms and set the thresholds relative to it
(e.g. `floor + 12 dB` for speech, `floor + 5 dB` for silence), or to use server-side VAD /
endpointing — which streaming STT and Gemini Live both give you for free.

The fixed 2000 ms silence window is also long; 700–900 ms is the normal conversational
end-of-turn.

---

## 14. Hands-free loop has ~1.5–2 s of dead air and clips the first word

After speaking finishes (`:444-450`):

```dart
Timer(const Duration(milliseconds: 1200), () { startRecording(); });
```

A hard-coded 1200 ms pause. Then `startRecording` (`:201-258`) does, **serially**, before the
mic is actually open:

1. `Permission.microphone.request()` — a platform-channel round trip, **on every turn**
2. `AivyChatVoiceCoordinator.instance.stop()`
3. `_tts.stop()`
4. `_stopRecorderOnly()` (which itself `await`s `_recorder.isRecording()`)
5. `_prepareRecordSession()` — full `AudioSession.configure()` + `setActive(true)`
6. `HapticFeedback.mediumImpact()`
7. `getTemporaryDirectory()`
8. `_recorder.hasPermission()` — *second* permission check
9. `_recorder.start(...)`

That's easily another 300–800 ms of platform work. Total gap ≈ **1.5–2 s**, and because the
phase only flips to `listening` *after* `start()` returns, **the user's first syllable is
routinely cut off**. Permission should be checked once per session, and the audio session
configured once — not rebuilt per turn.

---

## 15. Smaller issues worth fixing

| # | Issue | Location |
| --- | --- | --- |
| 15.1 | `cancelRecording()` calls `_history.clear()` — cancelling one recording **wipes the whole conversation memory**. Almost certainly unintended. | `home_voice_qa_session.dart:166` |
| 15.2 | TTS error fallback re-synthesizes the **written Hinglish (Latin) text** through the `hi-IN-Neural2-D` voice, which mispronounces Latin script badly — and costs another round trip. | `:431-436` |
| 15.3 | `_TypingText` runs `setState` per character at 22 ms, completely decoupled from actual audio playback — text and speech drift apart. Should be driven by playback position, or dropped. | `:962-978` |
| 15.4 | `handsFreeEnabled` is never persisted. `VoiceFeatureSettings` exists (`lib/core/voice/voice_feature_settings.dart`) and is used by chat, but the voice home screen ignores it — the toggle resets on every app launch. | `:305-310` |
| 15.5 | Two separate `AudioPlayer` instances (`GoogleHomeVoiceService` + `AivyChatVoiceCoordinator`) are both allocated and both stopped defensively everywhere. One shared player would be simpler and avoid focus fights. | — |
| 15.6 | Error copy is inconsistent — "Microphone permission is required." / "Microphone not available." in English, everything else in Hinglish. Also no `openAppSettings()` path when permission is permanently denied. | `:207`, `:231` |
| 15.7 | `_friendlyError` matches on `e.toString().contains('unauthenticated')` instead of reading `FirebaseFunctionsException.code`. Fragile. | `:459-471` |
| 15.8 | Web is unsupported at runtime (`voice_file_upload.dart:13` throws `UnsupportedError`) but the screen renders fully on web with a working-looking mic button. It should degrade visibly. | — |
| 15.9 | Web search runs a Firestore config read + Serper call **serially** before the answer call, and re-reads `app_config/search` every time. Cache the key. | `webSearch.ts:29-37`, `aivyVoiceAsk.ts:547` |
| 15.10 | `aivyVoiceAsk` has no rate limiting. Each call triggers STT + 2 Gemini calls + TTS + optional Serper + an unbounded Firestore scan. | `aivyVoiceAsk.ts:405` |
| 15.11 | No `minInstances` on `aivyVoiceAsk` → every idle-period first question pays a 3–8 s cold start (the function imports `@google-cloud/speech`, `@google-cloud/text-to-speech`, `firebase-admin`, `luxon`). | `aivyVoiceAsk.ts:406-411` |
| 15.12 | `speakAndWait` waits on `playerStateStream.firstWhere(...)` with a **90 s** timeout while the speaking safety timer is 60 s — another mismatched pair. | `google_home_voice_service.dart:85` |
| 15.13 | STT uses `alternativeLanguageCodes` + `model: "latest_short"` + `useEnhanced: false`, with **no `speechContexts` phrase hints** — the actual cause of the name mishearing that §6 tries to paper over. | `googleSpeechCloud.ts:110-117` |

---

## 16. Recommended plan

### Phase A — quick wins, no architecture change (target: ~7 s → ~3 s)

1. **Fix the security hole** — validate `audioUrl` path against `users/{uid}/` (§10). *Do this first.*
2. **Delete the romanize call** — have the answer prompt return the romanized transcript in its existing JSON (§3).
3. **Return TTS audio inline as base64** — remove the Storage write + client re-download (§5).
4. **Switch the recorder to Opus** (§2).
5. **`minInstances: 1`** on `aivyVoiceAsk` (§15.11).
6. **Cache the data snapshot** per uid for 30–60 s and bound `fetchAllPayments` (§4).
7. **Fix the cancellation races** — generation check after every `await` (§9).
8. **Wire `isWhoToCallAnalyticsQuestionText` into the voice path** so questions about reminders stop being refused (§8).
9. **Delete the `अभी` / `रवि` / `Ravi` regex replacements** and add STT phrase hints instead (§6, §15.13).
10. **Fix the UI paint cost** — pre-render the galaxy to an image, drop per-star blur, add `TickerMode` gating (§12).
11. **Adaptive silence threshold** calibrated from the ambient noise floor (§13).
12. **Storage lifecycle rule** to stop unbounded growth (§11).

### Phase B — the actual Gemini Live migration (target: <1 s, with barge-in)

The Live API cannot be driven from Cloud Functions callables — it needs a persistent
bidirectional connection. Two viable shapes:

- **Ephemeral-token + direct client connection (recommended):** a small callable mints a
  short-lived Live API token; the Flutter app opens the WebSocket directly to Google. Lowest
  latency (no relay hop), and the API key still never ships in the APK. Needs
  `web_socket_channel` on the client and raw PCM mic streaming (`record` supports
  `startStream`).
- **Cloud Run relay:** Flutter ⇄ your Cloud Run WebSocket ⇄ Gemini Live. More control (you can
  inject the Firestore snapshot server-side and keep tool-calling private), one extra hop of
  latency, and it must be Cloud Run — Cloud Functions cannot hold long-lived sockets.

Either way the following are then handled *by the protocol* and can be deleted:
separate STT, separate TTS, silence/VAD detection, the hands-free loop timer, the phase state
machine's speaking/listening handoff, and the "stop speaking" plumbing (Live has native
interruption).

The Firestore snapshot should move from "paste the whole database into every prompt" to
**Live tool/function declarations** (`get_todays_reminders`, `get_pending_payments`,
`get_client_dues`) that the model calls only when it actually needs data. That fixes §4
permanently and cuts input tokens by an order of magnitude.

---

## 17. Summary table

| Severity | Count | Items |
| --- | --- | --- |
| 🔴 Security | 1 | §10 cross-user audio transcription (IDOR) |
| 🔴 Correctness | 4 | §6 transcript corruption, §7 dead correction pass, §8 legitimate questions refused, §9 cancel/timeout races |
| 🟠 Performance | 6 | §1 architecture, §2 WAV, §3 extra Gemini call, §4 unbounded Firestore + prompt, §5 TTS round-trip, §12 UI paint cost |
| 🟠 UX | 2 | §13 silence detection, §14 hands-free dead air + clipped first word |
| 🟡 Cost / hygiene | 13 | §11 storage growth, §15.1–15.13 |
| ⚫ Not built | 1 | Gemini Live — 0 lines of it exist |
