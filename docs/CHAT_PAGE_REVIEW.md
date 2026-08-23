# Aivy Chat page (tab 1) — end-to-end review

Scope: the **Chat** tab from the screenshot (`HomeShell` → `ChatScreen`) — both voice
processes on its input bar, the "Play Aivy voice" affordance, and the full command path
from a tap/word to a persisted answer.

This is a **different screen** from the one covered by `VOICE_HOME_REVIEW.md`. That review
is about the Voice Home tab and the `aivyVoiceAsk` backend. This screen uses a completely
separate pipeline (`aivyProcess`), and almost none of the fixes made for Voice Home were
applied here.

Files read for this review:

| Layer | File |
| --- | --- |
| Screen | `lib/features/chat/presentation/chat_screen.dart` (1339 lines) |
| Input bar UI | `lib/features/dashboard/presentation/widgets/ai_input_bar.dart` |
| Bubbles / autoplay | `lib/features/chat/presentation/widgets/chat_bubble.dart`, `chat_conversation_view.dart` |
| Dictation | `lib/core/speech/local_speech_to_text.dart`, `lib/core/speech/dictation_text.dart` |
| Upload | `lib/features/chat/data/voice_file_upload_io.dart` |
| Callable client | `lib/features/chat/data/aivy_process_service.dart`, `lib/core/voice/google_voice_service.dart` |
| Playback | `lib/core/voice/aivy_chat_voice_coordinator.dart`, `lib/core/voice/voice_feature_settings.dart` |
| Text routing | `lib/features/chat/application/user_text_pipeline.dart`, `controlled_chat_flow.dart` (5052 lines) |
| Persistence | `lib/features/chat/data/chat_repository.dart` |
| Backend | `functions/src/aivyProcess.ts` (7580 lines), `googleSpeechCloud.ts`, `romanHinglish.ts`, `intentDetection.ts`, `webSearch.ts` |

---

## 0. Pehle: purana plan kahan tak pahuncha

Aapke repo me teen plan/handoff docs hain. Unki actual sthiti:

| Doc | Kya kehta hai | Aaj ki sachchai |
| --- | --- | --- |
| `docs/VOICE_HOME_REVIEW.md` | 510-line review of the **Voice Home** tab. Headline: "Gemini Live was planned, but nothing of it was built." | **Outdated.** `lib/core/voice/gemini_live/` ab maujood hai (commit `e3f95e8`), 7 files, `gemini_live_voice_session.dart` 670 lines. Doc ka §0 ab galat hai. |
| `docs/VOICE_HOME_NEXT_STEPS.md` | Phase A ka 12-item ordered queue + Phase B (Gemini Live migration). | Phase A ke items **sirf `aivyVoiceAsk` par** lage. Phase B ka "ephemeral token + direct client socket" wala option chun liya gaya. |
| `docs/VOICE_HOME_STATUS.md` | Is branch ne kya laaya: Gemini Live, 16 kHz mic, no-cache hosting, legacy speed fixes. | Sahi hai — par sab kuch **Voice Home** ke liye. |

**Phase A checklist — kis path par laga:**

| # | Phase A item | Voice Home (`aivyVoiceAsk`) | **Chat page (`aivyProcess`)** |
| --- | --- | --- | --- |
| 1 | `audioUrl` ownership check | ✅ `aivyVoiceAsk.ts:33-45` | ❌ **nahi** — IDOR abhi bhi khula (§7.1) |
| 2 | Reminder-question refusal fix | ✅ | n/a (chat me alag guard) |
| 3 | Destructive name regex hataana | ✅ hataaye | ❌ **dono pass abhi bhi zinda** — `aivyProcess.ts:2507-2560` (§7.2) |
| 3b | STT phrase hints | ✅ `googleSpeechCloud.ts` `SPEECH_CONTEXT` | ✅ shared — chat ko bhi milta hai |
| 4 | Romanize round-trip hataana | ✅ parallel kiya | ❌ **serial hi hai** — `aivyProcess.ts:2536` |
| 5 | Cancel/timeout race fix | ✅ | ❌ chat me cancel hai hi nahi (§7.5) |
| 6 | TTS inline base64 | ❌ | ❌ **chat me to aur bura** — alag second callable (§4) |
| 7 | Opus recording | ❌ | ❌ dono chat recorder WAV hi hain |
| 8 | `minInstances` | ❌ | ❌ |
| 9 | Snapshot cache | ✅ | n/a |
| 10 | Adaptive silence threshold | ❌ | ❌ fixed −34 dB (§3) |
| 11 | UI paint cost | ✅ Voice Home | n/a — chat bar halka hai |
| 12 | Storage lifecycle rule | ❌ | ❌ chat bhi WAV + MP3 chhod raha hai |

**Nateeja:** Voice Home theek hua, Chat page ko us kaam ka fayda **nahi** mila. Neeche
sab kuch is page ke liye naye sire se hai.

---

## 1. Poora flow — start to end

Chat page par **teen** input rehte hain, aur ye teenon **alag-alag backend raaste** lete hain.
Yahi is page ki sabse badi samasya hai.

```
                     ┌──────────────── AiInputBar ────────────────┐
                     │  [ text field ]   〰️        🎤        ➡️    │
                     └──────┬────────────┬─────────┬─────────┬────┘
                            │            │         │         │
        typed text ─────────┘            │         │         └── send
                                          │         │
                       hands-free tap ────┘         └──── mic press-and-hold
```

### Raasta A — typed text (aur native dictation ka output)

```
_sendMessage → _sendMessageWithText (chat_screen.dart:829)
  → createEntry + addMessage(user)              [Firestore write ×2]
  → _processUserMessage (:899)
      → ControlledChatFlow.process()            ← stateful wizard, 5052 lines
        ├─ handled=true  → ControlledFlowCoordinator.apply()   (local, no cloud)
        └─ handled=false → UserTextPipeline.processUserMessage()
              ├─ greeting shortcut (≤12 chars, ^hi|hello|hey)  → local reply, no TTS
              ├─ flow-blocking guard → local "flow chal raha hai" reply
              └─ _callAivyProcess()
                    → aivyProcess callable  (60 s timeout)
                    → AssistantGoogleVoiceCompletion.maybeSynthesizeTtsUrl()
                          → googleSpeechSynthesize callable  (120 s timeout)  ← SECOND round trip
                    → completeEntryWithAgentActivation()      [Firestore batch]
```

### Raasta B — mic press-and-hold (🎤)

Ye button ka **do alag vyavhaar** hai, aur user ko pata nahi chalta konsa chal raha hai:

```
_onMicDown (chat_screen.dart:424)
  → web?          → "Voice send is not available on web yet." → return
  → permission
  → fetchChatFlowState → blockGeneric?
      ├─ NO  → AudioRecorder.start(WAV 16 kHz)      ← CLOUD path
      │         release → _onMicUp → _submitCloudVoiceMessage()
      │             upload WAV → aivyProcess(audioUrl) → STT → Gemini → TTS
      │
      └─ YES → LocalSpeechToText (platform recognizer)   ← DICTATION path
                release → _onMicUp → _sendMessageWithText(said)  → Raasta A
```

### Raasta C — hands-free (〰️)

```
_toggleHandsFreeVoice (chat_screen.dart:200)
  → web? → refuse
  → flow active? → "Is flow ke dauran hands-free voice band hai." → refuse
  → AudioRecorder.start(WAV 16 kHz)
  → onAmplitudeChanged(220 ms) → _handsFreeLastLoudAt if dB > -34
  → Timer(320 ms) → _tickHandsFreeSilence()
        silence > 1350 ms  → _finishHandsFreeSubmit()
        no speech at all   → 22 s → "Zyaada shor nahi mila"
  → _submitCloudVoiceMessage()   ← SAME as Raasta B cloud path
```

### Backend — `aivyProcess` (`functions/src/aivyProcess.ts:2420`)

```
auth check
 → audioUrl? → transcribeFromFirebaseStorageUrl()   [Google STT, hi-IN]
                  fallback → transcribeAudioWithGemini()   [inline base64]
 → Name corrections Pass 1  (Devanagari regex ×20)          :2507-2530
 → containsDevanagari? → romanizeUserFacingText()  [Gemini call #1]  :2536
 → Name corrections Pass 2  (Hinglish regex ×7)             :2550-2560
 → search keywords? → runWebSearch()  [Firestore read + Serper]
 → isWhoCreatedYouQuestion? → static identity reply → END
 → Promise.all: fetchRecentMemoryLogTexts + buildRecentMemoryContext + getUserMemory
 → isWhoToCallAnalyticsQuestionText? → tryDataDrivenResponse → END
 → tryManualCollectionReminder → END
 → detectIntent / clientIntent  →  routedUserIntent
 → intent != reminder → tryRuleBasedOrderQuotationFirst → END
 → intent != reminder → strict rule text but no match → OQ_REPHRASE hard stop → END
 → intent != reminder → tryDataDrivenResponse → END
 → processWithGemini()  [Gemini call #2 — the real answer]
 → injectDispatchPaymentFollowUpReminderIfNeeded
 → enrichAgentResponse  (pure, no network)
 → replyEchoesUserInput? → retry data-driven, else plain fallback  [Gemini call #3]
 → finalizeAivyResponse → applyRomanHinglishFields  [up to 4+N MORE Gemini calls, SERIAL]
```

Command routing ka dil ye hai: **rule engine pehle, data engine doosra, Gemini aakhri**.
Har `→ END` ek short-circuit hai. `routedUserIntent === "reminder"` teen bade rule/data
blocks ko **poora skip** kar deta hai — matlab "reminder" shabd wale kisi bhi vaakya par
order/quotation/analytics ka koi jawab nahi milega.

---

## 2. Voice process #1 — mic press-and-hold (🎤)

**Ye ek button hai jiske do bilkul alag dimaag hain**, aur switch chhupa hua hai.

`chat_screen.dart:470-527`:

- Flow **band** hai → cloud recorder (WAV → Storage → `aivyProcess` → STT).
- Flow **chalu** hai → platform dictation (`speech_to_text`), text input field jaisa.

Do raaste, do alag latency, do alag accuracy, do alag failure mode — aur UI dono me
lagbhag same dikhta hai. Sirf dictation strip ka sub-label badalta hai (`:1185-1215`):
"Recording — release to send" vs "Listening…". User ke liye ye samajhna namumkin hai
ki aaj mic ne kya kiya.

**Iske alawa:**

| # | Issue | Location |
| --- | --- | --- |
| 2.1 | `Permission.microphone.request()` **har press par** — platform channel round trip mic khulne se pehle. Pehla akshar routinely kat jaata hai. | `:450` |
| 2.2 | Do permission checks serial: `Permission.microphone` phir `_voiceRecorder.hasPermission()`. | `:450`, `:486` |
| 2.3 | `fetchChatFlowState()` bhi mic start se **pehle** — ek aur Firestore read press aur record ke beech. | `:474` |
| 2.4 | 450 ms / 1400 byte se chhota clip chupchaap discard, sirf snackbar. Recording upload nahi hoti, user ko lagta hai app ne suna hi nahi. | `:653-668` |
| 2.5 | Dictation loop `while (_holdMic && mounted)` `_localSpeech.listen()` ko baar-baar restart karta hai. `pauseFor: 10 s` — 10 s chup rehne par platform session band, phir restart, aur `mergeDictationHypothesis` se text jodta hai. Lambe dictation me duplicate/missing shabd yahin se aate hain. | `:558-572`, `local_speech_to_text.dart:52-62` |
| 2.6 | Web par poora button dead — `kIsWeb` par sirf snackbar, par button dikhta poora enabled hai. | `:425-434` |

---

## 3. Voice process #2 — hands-free (〰️)

`_toggleHandsFreeVoice` (`:200`) + `_tickHandsFreeSilence` (`:319`).

| # | Issue | Detail |
| --- | --- | --- |
| 3.1 | **Fixed −34 dB threshold**, koi noise-floor calibration nahi. Dheeme bolne wale ya shor wale kamre me `_handsFreeLastLoudAt` kabhi set hi nahi hota → 22 s wait → "Zyaada shor nahi mila". Ye wahi bug hai jo Voice Home me §13 me tha (`-28/-38`), bas number alag. | `:302-304` |
| 3.2 | Silence window 1350 ms — baat-cheet ka natural end-of-turn 700–900 ms hai. Har turn me ~0.5 s extra. | `:341` |
| 3.3 | `setState(() {})` **har 220 ms** amplitude callback par, poori `ChatScreen` rebuild — jisme `ChatConversationView`, bubbles, flow chips sab hain. Sirf 40×28 px ka spike strip chahiye tha. `RepaintBoundary` + `ValueNotifier<double>` se ye poora rebuild hat sakta hai. | `:298-306` |
| 3.4 | Flow state sirf **start** par check hota hai. Bolte waqt agar flow shuru ho jaaye, `_submitCloudVoiceMessage` bina dobara check kiye cloud ko bhej dega — flow guard bypass. | `:250-262` vs `:685` |
| 3.5 | Cloud voice sabmit **`ControlledChatFlow` ko poora bypass** karta hai (§7.3 — headline bug). | `:685-786` |
| 3.6 | Ek hi `AudioRecorder` instance dono processes share karte hain, guard sirf boolean flags se. `_holdMic` aur `_handsFreeListening` ke beech koi lock nahi — sirf early-return checks. | `:78`, `:212-228`, `:437` |
| 3.7 | WAV, 16 kHz mono = **32 KB/second**. 10 s ka sawaal = 320 KB upload. Opus me ~80 KB hota. Backend `.opus`/`.ogg` pehle se handle karta hai (`googleSpeechCloud.ts:86-88`). | `:274-280`, `:489-495` |

---

## 4. "Play Aivy voice" aur assistant TTS

Screenshot me jo button dikh raha hai, uske peeche ye hai:

```
aivyProcess returns
  → maybeSynthesizeTtsUrl()                     ← alag callable, SERIAL
      → googleSpeechSynthesize (120 s timeout)
          → Google TTS synthesize (hi-IN-Neural2-D)
          → Storage write users/{uid}/tts/{uuid}.mp3  (cache 1 saal, public token)
          → download URL return
  → completeEntryWithAgentActivation(assistantTtsUrl: url)   ← BUBBLE AB LIKHTA HAI
  → Firestore stream → ChatConversationView._onMessages
      → autoplay (VoiceFeatureSettings.autoPlayAssistantVoice, default TRUE)
      → AivyChatVoiceCoordinator.playUrl → MP3 dobara download → just_audio
```

| # | Issue | Impact |
| --- | --- | --- |
| 4.1 | **Assistant ka jawaab tab tak screen par aata hi nahi jab tak TTS poora ban na jaaye.** `completeEntryWithAgentActivation` TTS ke *baad* call hota hai (`user_text_pipeline.dart:125-135`, `chat_screen.dart:755-762`). Text 1 s me taiyaar tha, par user 2–4 s aur intezaar karta hai — sirf audio ke liye jise wo shayad chalayega bhi nahi. **Yahi chat page ka sabse bada perceived-latency source hai.** | 🔴 |
| 4.2 | TTS ek **doosra callable** hai — apna auth, apna cold start, apna Storage write, apna client download. Voice Home ke §5 wala masla, par yahan double. | 🟠 |
| 4.3 | Voice `hi-IN-Neural2-D` par Latin-script Hinglish bola jaata hai. Poora pipeline text ko Devanagari se Roman me convert karta hai (`applyRomanHinglishFields`), phir usi Roman text ko Hindi voice se padhwata hai — uchcharan kharab aata hai. | 🟠 |
| 4.4 | Autoplay **default ON**, aur button bhi hai. Bubble aate hi apne aap bajta hai, phir "Play Aivy voice" dobara bajane ke liye. UI me is toggle ka koi switch nahi — `VoiceFeatureSettings` sirf SharedPreferences me hai, koi screen ise set nahi karta. | 🟠 |
| 4.5 | TTS **sirf cloud jawaabon par**. Greeting shortcut, controlled-flow ke sawaal, aur error bubbles bina awaaz ke aate hain. Screenshot me yahi dikh raha hai: "Good Afternoon Satyam Sir" par button nahi, agla jawaab par hai. Voice behaviour random lagta hai. | 🟠 |
| 4.6 | `synthesizeToFirebaseStorage` har MP3 ko `firebaseStorageDownloadTokens` public URL + `cacheControl: public,max-age=31536000` ke saath likhta hai. Link jiske paas ho, wo bina auth business jawaab sun sakta hai, hamesha ke liye. | 🔴 |
| 4.7 | Koi cleanup nahi — na `users/*/voice/*.wav`, na `users/*/tts/*.mp3`. Chat page ka apna storage leak, Voice Home wale ke upar. | 🟡 |
| 4.8 | `AivyChatVoiceCoordinator` sirf `stop()`/`playUrl()` deta hai — pause, seek, ya "abhi baj raha hai" state nahi. Button dabane par kuch dikhta nahi jab tak awaaz shuru na ho. | 🟡 |

---

## 5. Command kaise leta hai — text ka raasta

Do layer client par, phir teen layer server par.

**Client layer 1 — `ControlledChatFlow` (5052 lines).** Ye ek stateful wizard hai jo
Firestore me `pendingAction` rakhta hai. `isCategoryTrigger` (`:348-370`) — `+` se shuru,
`aivy`, ya `hi/hello/hey aivy` — category menu khol deta hai aur `getGreeting()` bhejta hai
("Good Afternoon Satyam Sir, aap kya karna chahte hai?" — screenshot wala exact line,
`flow_formatters.dart:19`). Us waqt se poori chat generic AI se **block** ho jaati hai
(`isControlledFlowBlockingGenericAi`, `:374-380`).

**Client layer 2 — `UserTextPipeline`.** Greeting shortcut (≤12 chars), flow guard, phir
`detectIntent()` + `expandSmartCommandInput()` → `aivyProcess`.

**Server — §1 ka routing.**

| # | Issue | Location |
| --- | --- | --- |
| 5.1 | **Flow state ki koi expiry nahi.** Ek baar `pendingAction` set ho gaya to Firestore me pada rehta hai — app restart ke baad bhi. Category menu to agle message par khud clear ho jaata hai (`:647-656`), par gehre steps (`actionAwaitingChatConfirm`, `actionEditingConfirm`, `actionAwaitingPaymentSettlementDate`) nahi. User raat ko flow adhoora chhod de, agle din har message "Abhi flow chal raha hai" se takraayega. | `controlled_chat_flow.dart:374-380`, `user_text_pipeline.dart:52-73` |
| 5.2 | Do jagah greeting handle hoti hai, alag jawaab ke saath: `isCategoryTrigger` → "Good Afternoon Satyam Sir…" (Hinglish, flow kholta hai), aur `_tryGreetingIntent` → "Hello. How can I assist you today?" (English, kuch nahi kholta). "hello aivy" pehle wale me, "hello" akela doosre me. Do alag personalities. | `controlled_chat_flow.dart:360-365`, `user_text_pipeline.dart:97-118`, `aivy_response_formatter.dart:26` |
| 5.3 | `fetchChatFlowState` ek hi turn me **do baar** Firestore se padha jaata hai — `ControlledChatFlow.process()` ke andar, aur phir `UserTextPipeline` me. | `user_text_pipeline.dart:52` |
| 5.4 | `routedUserIntent === "reminder"` order/quotation rule engine, rule hard-stop, **aur** data-driven analytics — teenon skip kar deta hai (`:2709`, `:2741`, `:2774`). "Ravi ka reminder aur uska pending payment batao" jaisa mixed sawaal seedha Gemini par chala jaata hai, bina kisi business data ke. | `aivyProcess.ts:2702-2790` |
| 5.5 | Web search detection substring match hai: `"google se"` kisi bhi vaakya me ho to Serper call chalta hai. "Ravi ne google se contact kiya tha" → bekaar search + latency. | `aivyProcess.ts:2572-2576` |
| 5.6 | `OQ_REPHRASE` hard stop: agar text strict order/dispatch/quotation jaisa lage par rule engine kuch na nikaale, to Gemini ko bhi nahi poochha jaata — seedha "rephrase karo". Ek rule miss = poora dead end. | `aivyProcess.ts:2741-2771` |
| 5.7 | Client aur server dono `detectIntent()` chalate hain (`intent_detection.dart` aur `intentDetection.ts`) — do alag implementation, jo drift kar sakti hain. Client apna label `clientIntent` me bhejta hai aur server usko prefer karta hai. | `user_text_pipeline.dart:75`, `aivyProcess.ts:2683-2700` |

---

## 6. Latency budget — ek chat voice turn

10-second sawaal, 4G, India → us-central1:

| Step | Typical | Worst |
| --- | --- | --- |
| Permission + flow read + recorder start (press se mic tak) | 300 ms | 800 ms |
| Recording finalize + WAV flush | 100 ms | 300 ms |
| **WAV upload** (320 KB, uncompressed) | 800 ms | 2500 ms |
| `aivyProcess` cold start (no `minInstances`) | 150 ms warm | **3000–8000 ms** |
| Admin SDK WAV wapas download | 200 ms | 500 ms |
| Google STT sync recognize | 600 ms | 1500 ms |
| **Gemini #1 — romanize** (hi-IN STT hai to hamesha chalta hai) | 800 ms | 2000 ms |
| Memory + profile Firestore reads | 200 ms | 800 ms |
| Rule / data-driven engine (Firestore scans) | 300 ms | 2000 ms |
| **Gemini #2 — asli jawaab** | 1200 ms | 3500 ms |
| `applyRomanHinglishFields` (0–5 **serial** Gemini calls) | 0 ms | 4000 ms |
| **`googleSpeechSynthesize` callable** (cold start + TTS + Storage write) | 900 ms | 3000 ms |
| Firestore batch write → stream → bubble dikha | 200 ms | 600 ms |
| MP3 dobara download + player prepare | 400 ms | 1200 ms |
| **Total, pehle bole gaye shabd tak** | **~6.2 s** | **~20+ s** |
| **Total, bubble dikhne tak** (TTS iske andar hai — §4.1) | **~5.8 s** | **~19 s** |

Typed text ka turn: upload/STT/romanize hat jaate hain, ~2.5–3 s, jisme se ~1 s sirf TTS
ka hai jo bubble ko rok kar rakhta hai.

**Sabse bade single wins:**

1. TTS ko bubble write ke baad background me le jaao — user ko **~1–3 s** turant milta hai (§4.1).
2. `applyRomanHinglishFields` ke serial calls ko `Promise.all` karo, ya prompt hi Roman Hinglish maango (already maangte hain — ye layer zyadatar bekaar chalti hai).
3. `minInstances: 1` `aivyProcess` par — 3–8 s ka cold-start cliff khatam.
4. Romanize call parallel/hataao (jaise `aivyVoiceAsk` me hua).
5. Opus recording — upload 4× chhota.

---

## 7. Bugs — severity ke hisaab se

### 7.1 🔴 Security: koi bhi user kisi aur ka audio transcribe kar sakta hai (IDOR)

`aivyProcess.ts:2471` client se aaya `audioUrl` seedha `transcribeFromFirebaseStorageUrl()`
ko deta hai. Wo `decodeStoragePathFromDownloadUrl` se path nikaal kar **Admin SDK** se
download karta hai (`googleSpeechCloud.ts:59-75`) — Admin SDK `storage.rules` ko poora
bypass karta hai.

`aivyVoiceAsk` me ye **theek ho chuka hai** (`assertCallerOwnsVoiceAudioUrl`, `:33-45`),
par `aivyProcess` me wahi check **kabhi nahi laga**. Grep confirm karta hai: `aivyProcess.ts`
me `users/${uid}/` prefix check ka ek bhi instance nahi.

Gemini fallback bhi wahi karta hai — `fetchAudioInlinePart` (`:4242-4269`) same decode,
same admin download, koi check nahi.

**Fix — wahi 12 lines jo `aivyVoiceAsk.ts:33` me pehle se likhi hain**, `aivyProcess` me
`audioUrl` use karne se pehle call kar do.

### 7.2 🔴 Transcripts abhi bhi corrupt ho rahe hain

`aivyProcess.ts:2507-2530` (Pass 1) aur `:2550-2560` (Pass 2) me wahi khatarnak global
regex zinda hain jo `aivyVoiceAsk` se hataaye gaye the:

```ts
{ pattern: /अभी/g,  replacement: "Aivy" },   // :2518  — "अभी" ka matlab "now"
{ pattern: /रवि/g,  replacement: "Aivy" },   // :2517  — Ravi, aam client naam
{ pattern: /रावी/g, replacement: "Aivy" },   // :2516
{ pattern: /\b(ravi|Ravi|rawi|Rawi|raavi|Raavi)\b/gi, replacement: "Aivy" },  // :2551
{ pattern: /\bbaby\b/gi,  replacement: "Aivy" },   // :2523
{ pattern: /\bheavy\b/gi, replacement: "Aivy" },   // :2524
```

- "अभी कॉल करना है" → "Aivy कॉल करना है". Har wo vaakya jisme "abhi" hai, kharab.
- "Ravi ko payment reminder lagao" → "Aivy ko payment reminder lagao". Client ka naam
  gayab, reminder galat jagah.

`SPEECH_CONTEXT` phrase hints (`googleSpeechCloud.ts:107-120`) pehle se lagi hain aur chat
path ko bhi milti hain — matlab in regexes ka **maqsad pehle hi poora ho chuka hai**. Ab ye
sirf nuksaan kar rahe hain.

### 7.3 🔴 Cloud voice `ControlledChatFlow` ko poora bypass karta hai

`_submitCloudVoiceMessage` (`chat_screen.dart:685`) `_aivyProcessService.analyzeVoice(url)`
ko seedha call karta hai aur phir `completeEntryWithAgentActivation`. **`_controlledFlow.process()`
kabhi nahi chalta.**

Iska matlab:

| Flow me sawaal | Type karo | Mic hold karo (dictation) | Hands-free bolo |
| --- | --- | --- | --- |
| "Confirm / Edit / Cancel?" | ✅ kaam karta hai | ✅ kaam karta hai | ❌ cloud AI ko jaata hai |
| "Payment receive date?" | ✅ | ✅ | ❌ |
| "1 · Name / 2 · Amount?" | ✅ | ✅ | ❌ |

Hands-free flow shuru hone par refuse karta hai (`:250-262`), par ye check **sirf start par**
hota hai. Aur mic-hold cloud path (jab flow band tha jab press hua) bhi turant baad flow
shuru hone par bypass kar dega. Ek hi app me ek hi sawaal ka jawaab teen alag tareeke se
behave karta hai.

**Fix:** `_submitCloudVoiceMessage` transcript milne ke baad `_processUserMessage(transcript, entryId)`
se guzre — bilkul waise jaise dictation path `_sendMessageWithText` se guzarta hai. Isse
`analyzeVoice` ko sirf transcription ke liye use karna padega, ya transcript ko `analyzeInput`
me dobara bhejna padega.

### 7.4 🟠 Assistant bubble TTS ke intezaar me rukta hai

§4.1 dekho. Ye correctness bug nahi hai par sabse zyada mehsoos hone wala.

### 7.5 🟠 Bheja hua message cancel nahi ho sakta

`_sendGeneration` (`:845`, `:697`) sirf `setState` ko guard karta hai — `await` ke baad koi
generation check nahi. Na koi "Stop" button hai. Agar user galat sawaal bhej de, use
`aivyProcess` (60 s) + `googleSpeechSynthesize` (120 s) ka poora chakkar jhelna hai, aur
jawaab aakhir me aa hi jaayega aur **apne aap baj bhi jaayega**.

Voice Home me ye §9 me fix hua tha. Chat me abhi bhi hai.

### 7.6 🟠 Error handling transcript kho deta hai

`_submitCloudVoiceMessage` ke `catch` (`:763-782`) me: entry fail hoti hai, generic error
bubble likhta hai. User ka **bola hua transcript kahin nahi bachta** — agar `aivyProcess`
STT ke baad Gemini par fail hua, to jo sahi transcribe ho chuka tha wo bhi gaya. User ko
poora dobara bolna padta hai.

### 7.7 🟡 Chhoti par asli baatein

| # | Issue | Location |
| --- | --- | --- |
| 7.7.1 | Error copy mila-jula: "Microphone permission is required for voice." (English) vs "Pehle mic hold band karein." (Hinglish) vs "Thoda aur der boliye — phir bhejenge." | `:241`, `:222`, `:390` |
| 7.7.2 | `AivyProcessService._analyzeRequestInternal` **har call par** `getIdToken(true)` — force refresh, network round trip, har message par. Cache karna chahiye. | `aivy_process_service.dart:259` |
| 7.7.3 | Web par teenon voice affordances render hote hain (mic + hands-free), par teenon `kIsWeb` par sirf snackbar dete hain. Button disabled dikhna chahiye. | `:201`, `:425` |
| 7.7.4 | `_voiceRecorder` `dispose()` me dispose hota hai par hands-free timer/subscription cancel `dispose` me hain — recorder stop async hai (`_stopVoiceRecorderForDispose`), race possible agar screen recording ke beech close ho. | `:153-187` |
| 7.7.5 | `VoiceFeatureSettings` ke dono toggles ka UI me koi switch nahi. Dono default `true`. User autoplay band nahi kar sakta. | `voice_feature_settings.dart`, koi caller nahi |
| 7.7.6 | Hands-free ka 22 s "too quiet" timeout aur mic-hold ka koi max duration nahi — user 5 minute hold kar sakta hai, 9.6 MB WAV ban jaayega. | `:337-341`, `:424` |
| 7.7.7 | `aivyProcess` par koi rate limiting nahi. Har call: STT + 1–7 Gemini calls + Firestore scans + optional Serper. | `aivyProcess.ts:2420` |
| 7.7.8 | `console.log("USER PROFILE:", userProfile)` `finalizeAivyResponse` me — user ka poora profile Cloud Logging me plain. | `aivyProcess.ts:3571` |

---

## 8. Summary

| Severity | Count | Items |
| --- | --- | --- |
| 🔴 Security | 2 | §7.1 cross-user audio (IDOR, chat path), §4.6 public forever TTS URLs |
| 🔴 Correctness | 2 | §7.2 transcript corruption (`अभी`/`रवि`/`Ravi`), §7.3 cloud voice flow bypass |
| 🟠 Performance | 5 | §4.1 TTS bubble ko rokta hai, §4.2 alag TTS callable, §6 romanize + serial roman fields, §3.3 220 ms full rebuild, §3.7 WAV upload |
| 🟠 UX | 4 | §2 mic ke do chhupe dimaag, §3.1 fixed dB threshold, §4.4 autoplay bina toggle, §7.5 cancel nahi hai |
| 🟡 Hygiene | 9 | §4.7 storage leak, §5.1 flow expiry, §5.2 do greetings, §7.6 transcript loss, §7.7.1–7.7.8 |

---

## 9. Aage ka plan

### Phase A — jo `aivyVoiceAsk` me ho chuka, wahi chat par lagao (~1 din)

Order isi tarah rakho; 1 aur 2 sabse zyada value per line.

| # | Kaam | Kahan | Effort |
| --- | --- | --- | --- |
| 1 | `assertCallerOwnsVoiceAudioUrl` ko `aivyProcess` me wire karo — `transcribeFromFirebaseStorageUrl` aur `fetchAudioInlinePart` dono se pehle. | `aivyProcess.ts:2471`, `:4242` | ~10 lines |
| 2 | Dono name-correction pass **delete** karo. Phrase hints pehle se lagi hain. | `aivyProcess.ts:2507-2560` | −60 lines |
| 3 | TTS ko bubble ke **baad** background me le jaao — pehle `completeEntryWithAgentActivation` (bina `ttsAudioUrl`), phir synthesize, phir message doc par `ttsAudioUrl` patch karo. Bubble ~1–3 s pehle dikhega. | `user_text_pipeline.dart:125-135`, `chat_screen.dart:755-762`, `chat_repository.dart:1200` | ~40 lines |
| 4 | `_submitCloudVoiceMessage` ko `_processUserMessage` se guzaaro taaki voice bhi controlled flow me kaam kare. | `chat_screen.dart:685-786` | ~30 lines |
| 5 | Romanize call ko parallel karo ya hataao (jaise `aivyVoiceAsk` me hua); `applyRomanHinglishFields` ke scalar fields `Promise.all` karo. | `aivyProcess.ts:2536`, `romanHinglish.ts:117-122` | ~20 lines |
| 6 | `minInstances: 1` `aivyProcess` par. | `aivyProcess.ts:2421-2425` | 1 line |
| 7 | Recorder `AudioEncoder.opus` (dono jagah), `voice_file_upload_io.dart` me `.opus` ext + content type. | `chat_screen.dart:274`, `:489`, `voice_file_upload_io.dart:20-25` | ~15 lines |
| 8 | Adaptive silence threshold — pehle 300 ms se noise floor lo, `floor + 12 dB` speech, `floor + 5 dB` silence; window 1350 → 850 ms. | `chat_screen.dart:298-341` | ~40 lines |
| 9 | Cancel: `_sendGeneration` ko har `await` ke baad check karo, input bar par "Stop" do. | `chat_screen.dart:685-786`, `:829-892` | ~30 lines |
| 10 | Amplitude ko `ValueNotifier<double>` + `RepaintBoundary` me daalo, `setState` hataao. | `chat_screen.dart:298-306`, `:1256` | ~20 lines |
| 11 | Failure par transcript bachao — error path me user bubble ka transcript rakho aur retry do. | `chat_screen.dart:763-782` | ~20 lines |
| 12 | Storage lifecycle rule — `users/*/voice/**` + `users/*/tts/**` 7 din baad delete. | GCS console / `gsutil lifecycle` | config |
| 13 | `console.log("USER PROFILE:", ...)` hataao. | `aivyProcess.ts:3571` | 1 line |

**Expected:** typed turn ~2.5 s → ~1.2 s. Voice turn ~6.2 s → ~3 s. Transcripts kharab
hona band. Voice flow me kaam karne lagega.

### Phase B — do voice processes ko ek karo

Abhi teen input paths hain jo teen alag tarah behave karte hain. Target: **ek** voice
affordance jo har jagah same kaam kare.

- Mic ke do chhupe dimaag (§2) khatam — hamesha cloud STT, aur flow ka jawaab dena ho to
  transcript `ControlledChatFlow` ko do (Phase A #4 isi ki neev hai).
- Hands-free ko mic hold ka hi ek mode banao (tap = hands-free, hold = push-to-talk), ek
  hi recorder + ek hi state machine ke saath.
- `VoiceFeatureSettings` ke toggles `more_screen.dart` me expose karo.

### Phase C — Voice Home ka Gemini Live chat par laana

`lib/core/voice/gemini_live/` pehle se maujood hai (session, PCM in/out, business tools,
snapshot service). Chat page abhi bhi purana batch pipeline chala raha hai.

Sochne wali baat: chat ek **transactional** surface hai (order banao, payment settle karo,
reminder lagao) — uske liye `ControlledChatFlow` ka confirm-step design sahi hai. Live
conversational hai. Sabse behtar shape:

- Chat me Live **sirf transcription** ke liye (streaming STT, ~300 ms partials), aur asli
  command routing wahi `aivyProcess` + flow rahe.
- Ya `aivy_business_tools.dart` ke tool declarations ko `aivyProcess` me bhi laao taaki
  Gemini poora database prompt me paste karne ke bajaye zaroorat par data maange.

Ye decision Phase A ke baad lena chahiye — Phase A ke saare kaam Phase C me bhi bache
rahenge.
