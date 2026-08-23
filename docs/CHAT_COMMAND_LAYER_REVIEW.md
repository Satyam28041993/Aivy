# Aivy Chat — command layer review

Ye doc `CHAT_PAGE_REVIEW.md` ka doosra hissa hai. Wo doc **voice pipeline aur latency**
par tha. Ye doc sirf ek sawaal par hai: **user command kaise deta hai, aur wo command
kis raaste jaata hai.**

Files read: `controlled_chat_flow.dart` (5052), `flow_catalog.dart`, `flow_step_engine.dart`,
`smart_command_expand.dart`, `intent_detection.dart`, `aivy_chat_quick_actions.dart`,
`controlled_flow_coordinator.dart`, `user_text_pipeline.dart`, `chat_screen.dart`,
`functions/src/intentDetection.ts`, `functions/src/aivyProcess.ts`.

---

## 1. Command dene ke 6 tareeke

| # | Tareeka | Kaise trigger hota hai | Kahan handle hota hai |
| --- | --- | --- | --- |
| 1 | **Free text** — "Ravi se 50000 lena hai" | Type + send | `ControlledChatFlow.process()` ka idle branch — 10+ rule parsers |
| 2 | **Flow trigger** — `aivy`, `hi aivy`, `+`, ya `+kuch bhi` | `isCategoryTrigger` (`controlled_chat_flow.dart:348-370`) | Category **bottom sheet** khulta hai (typed nahi, tapped) |
| 3 | **Numbered menu reply** — `1`, `2`, `3` | Flow ke sawaal ka jawaab | Har `pendingAction` ka apna handler |
| 4 | **Quick-action chips** — `[1] Top Clients` … `[6] Status` | Chip tap → poora text bhejta hai (`"Top clients by business"`) | `UserTextPipeline` → `aivyProcess` |
| 5 | **Number shortcuts** — `1`–`11`, `/3`, `*3`, `Q3` | `expandSmartCommandInput` (`smart_command_expand.dart:3-24`) | Analytics query me expand hokar cloud |
| 6 | **Command words** — `confirm`, `edit`, `cancel`, `undo`, `skip`, `yes`/`haan` | Har state ka apna vocabulary | Alag-alag handlers, alag-alag lists |

Aur teen input surfaces (typed / mic-hold / hands-free), jinme se **do voice waale
`ControlledChatFlow` ko bypass karte hain** — wo `CHAT_PAGE_REVIEW.md` §7.3 me hai.

---

## 2. Dispatch precedence — command kis order me match hota hai

`ControlledChatFlow.process()` ka poora order (`:600-1210`):

```
1.  categoryMenu / selectingSub state?  → koi bhi non-trigger text state CLEAR kar deta hai
2.  _repairPaymentSettlementRoutingIfNeeded
3.  text khaali?                        → none  (UI se kabhi ho hi nahi sakta — §5.4)
4.  _isUndoCommand         → undo / galti / galat
5.  _isBroadFlowCancel     → cancel / band / exit / quit / stop
       ⚠ 7 states me se EXCLUDED (confirm, continue, categoryMenu, selectingSub, 2× WhatsApp)
6.  ~25 pendingAction handlers, ek-ek karke if-chain me
       (settlementDate → whatsapp × 4 → chatConfirm → createClient → paymentReceived × 3
        → paymentDue × 2 → followup × 4 → order × 6 → continue → pendingSelection
        → editing → disambig → collecting)
7.  IDLE branch — koi flow nahi:
       isCategoryTrigger              → category sheet
       tryParsePaymentReceivedDirect  → due settlement
       tryParsePaymentDueKo           → in-chat confirm
       detectPaymentReceivedWithNameDetails → payment selection list
       _tryGoogleWorkspaceIntents     → Gmail / Calendar / Sheets
       _tryWhatsAppContactIntent      → WhatsApp flow
       hasPaymentReceivedIntentText   → "1 / 2" choice menu
       _isAmbiguousPaymentVsReminder  → disambig menu
       tryParseManualPaymentLine      → in-chat confirm
       detectIntent(t) == query       → cloudRun
8.  flow blocking?  → "Is step par abhi flow chal raha hai"
9.  none            → UserTextPipeline → aivyProcess
```

Do **alag cloud entry points** hain, aur dono ka preprocessing alag hai:

| | `UserTextPipeline._callAivyProcess` | Coordinator `ProcessKind.cloud` |
| --- | --- | --- |
| Greeting shortcut | ✅ | ❌ |
| Flow-blocking guard | ✅ | ❌ |
| `detectIntent` | ✅ | ❌ (flow apna intent bhejta hai) |
| `expandSmartCommandInput` | ✅ | ❌ |
| Kahan se | `_processUserMessage` fallback | `controlled_flow_coordinator.dart:363-391` |

Matlab ek hi text do alag tareeke se process ho sakta hai, is baat par depend karke ki
flow ne use `cloudRun` kiya ya `none` return kiya.

---

## 3. 🔴 Sabse bada bug: app ke apne numbered menu tootey hue hain

`_looksLikeFollowupOrCallListQuestion` (`:384-415`) ki pehli line:

```dart
if (expandSmartCommandInput(raw) != null) {
  return true;
}
```

Aur `expandSmartCommandInput` **har bare number 1–11** ke liye non-null return karta hai.

Ye function do choice-handlers me **sabse pehle** chalta hai — number check se pehle:

### 3.1 Payment received menu

App ye print karta hai (`controlled_chat_flow.dart:1113-1117`, `controlled_flow_coordinator.dart:118-124`):

```
Kaise proceed karna hai?

1. Client ka naam likhunga
2. Pending clients ki list dikhao
```

User `1` type karta hai → `_handlePaymentReceivedChoice` (`:3538`) →
line **3543** `_looksLikeFollowupOrCallListQuestion("1")` → `expandSmartCommandInput("1")`
= `"Top clients by business"` → **true** → `clearState()` + `ProcessResult.none()`.

Flow **mit jaata hai**, text `UserTextPipeline` par gir jaata hai, wahan `"1"` expand hokar
`"Top clients by business"` ban jaata hai, aur Aivy **top clients ki list** de deti hai.

`low == '1'` wala asli handler line **3549** par hai — 5 line neeche, kabhi nahi chalta.
`2` ke saath bhi wahi.

### 3.2 Payment due menu

App ye print karta hai (`:1126-1134`):

```
💰 Kya karna hai?

1. Saari pending payment ki list (amount + due date)
2. Sirf ek client ki list — pehle 2 bhejein, phir client ka naam
```

Menu khud kehta hai **"pehle 2 bhejein"**. User `2` bhejta hai → `_handlePaymentDueChoice`
(`:3165`) → line **3170** wahi hatch → state clear → cloud →
`"This week payment follow-ups pending list"`.

Aur `_matchesFullPendingListUserReply` (`:417-420`) ki **pehli line hi `if (low == '1')`**
hai — matlab code me `1` ko handle karne ka poora iraada tha, par wo line line 3176 par hai,
hatch ke **6 line baad**. Dead code jo bug ko prove karta hai.

### 3.3 Kahan benign hai

Teesri jagah `_handlePaymentReceivedClientName` (`:2265`) hai. Wahan input ek **client naam**
expected hai, to bare number ka break-out theek hai. Sirf upar ke do sites bug hain.

**Fix:** hatch se number-only inputs nikaal do —

```dart
static bool _looksLikeFollowupOrCallListQuestion(String raw) {
  final low = raw.toLowerCase().trim();
  if (RegExp(r'^\d{1,2}$').hasMatch(low)) {
    return false;          // menu pick, analytics shortcut nahi
  }
  if (expandSmartCommandInput(raw) != null) { ... }
```

...ya behtar: choice-handlers me number check **pehle** karo, hatch baad me.

---

## 4. 🔴 Analytics chips flow ke dauran zinda rehte hain

`_flowChipOverride` (`chat_screen.dart:949-987`) sirf **4** states ke liye chips badalta hai:
`actionAwaitingChatConfirm`, `actionEditingConfirm`, `actionAwaitingContinue`,
`actionAwaitingDisambig`.

Baaki **~21 states** me — `actionCollecting`, `actionAwaitingPaymentDueChoice`,
`actionAwaitingOrderClientName`, `actionPendingSelection`, saare WhatsApp states — default
analytics bar dikhta rehta hai, aur `enabled: !_isSending` (`:1063-1065`) hone ki wajah se
**tap bhi hota hai**.

Nateeja:

```
Aivy:  Client name? ( naam )
User:  [1] Top Clients   ← chip tap
       → sends "Top clients by business"
       → _handleCollecting → applyAnswer(fieldKey: clientName)
       → valid name maan liya jaata hai
Aivy:  Amount? (₹)
```

Client ka naam **"Top clients by business"** save ho jaata hai. `_handleCollecting`
(`:3980`) me koi analytics hatch nahi hai — aur `_isUnrelatedInterrupt` sirf tab chalta
hai jab `FlowApplyInvalid` aaye, jo ek name field par kabhi nahi aata.

**Fix:** flow chalne ke dauran (`isControlledFlowBlockingGenericAi`) ya to chips hide
karo, ya `enabled: false` karo, ya har state ke liye sahi `flowChipOverride` do.

---

## 5. State ke hisaab se "1" ka matlab badalta hai — 9 alag meanings

Yahi is page ki asli mental-model problem hai. Ek hi token, koi visual clue nahi:

| State | `1` ka matlab | `2` | `3` |
| --- | --- | --- | --- |
| Koi flow nahi | "Top clients by business" | "This week payment follow-ups" | "Highest pending client amount" |
| `awaitingChatConfirm` | **CONFIRM — save kar do** | Edit | Cancel |
| `editingConfirm` (payment) | Name / client | Amount (₹) | Date |
| `editingConfirm` (reminder task) | Task | Date | Note |
| `awaitingContinue` | Yes, resume | Cancel | — |
| `awaitingDisambig` | Payment due | Reminder | — |
| `awaitingPaymentReceivedChoice` | *(toota — §3.1)* | *(toota)* | — |
| `awaitingPaymentDueChoice` | *(toota — §3.2)* | *(toota)* | — |
| `pendingSelection` | List ka row 1 | Row 2 | Row 3 |
| `collecting` | Field ki raw value (amount = ₹1) | — | — |

Do baatein khaas khatarnaak:

- `awaitingChatConfirm` me `1` ka matlab **seedha save** hai (`_isChatConfirmButton`, `:1403-1416`).
  User ko lagta hai wo "[1] Top Clients" maang raha hai, aur ek payment record save ho jaata hai.
- `3` confirm state me **Cancel** hai, par agle hi state (edit picker) me **Date**.

---

## 6. Baaki command-layer findings

| # | Issue | Location |
| --- | --- | --- |
| 6.1 | **"Khaali chhod dein = aaj" possible hi nahi.** Flow guard user se kehta hai `'(ya khaali chhod dein = aaj)'`, aur `allowEmptyPaymentReceiveDate` (`:684-690`) khaali input ki ijaazat deta hai — par `_sendMessage` (`chat_screen.dart:817-819`) **aur** `_sendMessageWithText` (`:841-843`) dono khaali text block kar dete hain. UI se khaali bheja hi nahi ja sakta. Dead code + jhootha instruction. | `:1204`, `:684`, `chat_screen.dart:817` |
| 6.2 | **Flow me "back" hai hi nahi.** `FlowStepEngine` sirf aage badhta hai (`nextStepIndex = stepIndex + 1`). Step 3 par galti dikhe to sirf `cancel` — poora flow gaya. `skip` bhi sirf `time` field par chalta hai (`flow_step_engine.dart:405`, `:437`). | `flow_step_engine.dart:216-460` |
| 6.3 | **Cancel vocabulary har state me alag.** Broad cancel `cancel/band/exit/quit/stop` (`:486-498`) 7 states me **excluded** hai; un states me har handler ki apni list hai — kahin `cancel/3/band` (`:1392`), kahin `cancel/nahi/no/2` (`:846`), kahin `band/chhod/quit` (`:2258-2262`). Ek hi shabd kabhi chalega kabhi nahi. | multiple |
| 6.4 | **Category sirf sheet se chunte hain, type karke nahi.** `showCategorySelector` ek modal hai (`controlled_flow_coordinator.dart:76`). Isliye "Aivy, reminder lagao" ek hi line me flow start nahi kar sakta — pehle sheet, phir sub-sheet, phir step-by-step sawaal. Voice ke liye ye poora raasta band hai. | `controlled_flow_coordinator.dart:64-140` |
| 6.5 | **Client aur server ka `detectIntent` alag hai, aur client jeetta hai.** `intentDetection.ts` ka header kehta hai "mirrors the Flutter contract", par: server ke `isQueryIntent` me `task\|birthday\|janamdin\|pending\|follow up` extra hain; server ke `hasScheduleAction` me plain `karna hai` hai jabki client me `karna\s+hai.*\bcall` chahiye; server ke `isWhoToCallAnalyticsQuestion` me Devanagari branches (`किसे\|किसको\|कौन`, `H_CALL`) hain, client me nahi. Client apna label `clientIntent` me bhejta hai aur server use **prefer** karta hai (`aivyProcess.ts:2689-2700`) — to server ka behtar classifier chalta hi nahi. | `intent_detection.dart` vs `intentDetection.ts` |
| 6.6 | **Devanagari dictation client classifier ko chakma de sakti hai.** Platform dictation Hindi ke liye Devanagari deti hai. "आज किसे कॉल करना है" par client ka `_isWhoToCallAnalyticsQuestion` ASCII-only `asksWhom` regex fail karta hai → intent `reminder` ban jaata hai → server `clientIntent: reminder` maan leta hai → order/quotation, rule hard-stop aur data-driven, teenon skip. Bach isliye jaata hai kyunki server pehle romanize karta hai aur `isWhoToCallAnalyticsQuestionText` **`clientIntent` padhne se pehle** chalta hai — par `GEMINI_API_KEY` na ho to romanize skip ho jaata hai aur guard toot jaata hai. | `intent_detection.dart:139-158`, `aivyProcess.ts:2534-2542`, `:2624` |
| 6.7 | **Shortcut map 11 entries, chip bar sirf 6.** `kSmartCommandQueries` me 1–11 hain, `kAivyQuickActionBar` me sirf 1–6. 7–11 (`Aaj kitne order aaye`, `Aaj kitna dispatch hua`, `Is mahine total business`, `Kaun risky client`, `Pending orders list`) sirf tab chalte hain jab user ko unke number yaad hon. Kahin document nahi. | `smart_command_expand.dart:26-38`, `:52-71` |
| 6.8 | Client aur server ke shortcut maps **abhi in sync hain** (dono 1–11 identical, `aivyProcess.ts:6435-6447`) — par ye do jagah hardcoded hain, sirf ek comment "keep in sync" se bandhe hue. Ek jagah badla to chup-chaap drift ho jaayega. | `smart_command_expand.dart:1-2`, `aivyProcess.ts:6435` |
| 6.9 | **`reports` category apna sawaal fenk deti hai.** `_handleCollecting` reports ke liye `_reportsShortcutForSub(sub) ?? q` bhejta hai — matlab `reports:status` par user ne jo bhi likha wo **discard** hokar fixed shortcut chala jaata hai. `query` field poochha hi kyun jaata hai? | `:3989-3999`, `:4274` |
| 6.10 | **Category sheet ke dauran poora input bar freeze.** `showCategorySelector` `_processUserMessage` ke andar `await` hota hai, jo `_isSending = true` ke andar hai. Sheet khuli rahe to mic, chips aur text field sab disabled. Sheet dismiss = flow clear, par user ko ye kahin bataya nahi jaata. | `chat_screen.dart:845`, `controlled_flow_coordinator.dart:76-82` |
| 6.11 | **`undo` ki bhasha bahut chaudi hai.** `low.contains('galti ho gayi')`, `low == 'galat'`, aur `low.contains('undo') && low.length < 20`. "galat number lag gaya" jaisa jayaz vaakya bhi undo trigger kar sakta hai — aur undo **step 4 par** chalta hai, kisi bhi flow state se pehle. | `:500-512`, `:692-694` |

---

## 7. Summary

| Severity | # | Item |
| --- | --- | --- |
| 🔴 | §3 | App ke apne numbered menu (`1`/`2`) analytics shortcut se toot rahe hain — 2 sites |
| 🔴 | §4 | Analytics chips flow ke dauran zinda; chip text field ki value ban jaata hai |
| 🟠 | §5 | `1` ke 9 alag matlab, koi visual clue nahi — confirm state me `1` = seedha save |
| 🟠 | §6.5–6.6 | Client/server intent drift, aur client ka faisla server par thopa jaata hai |
| 🟠 | §6.2 | Flow me back nahi — ek galti = poora flow dobara |
| 🟠 | §6.1 | "Khaali chhod dein" bola jaata hai, par khaali bheja hi nahi ja sakta |
| 🟡 | §6.3, §6.11 | Cancel/undo vocabulary har state me alag aur bahut chaudi |
| 🟡 | §6.4, §6.10 | Category sirf modal se; voice se flow start nahi ho sakta |
| 🟡 | §6.7–6.9 | Shortcut 7–11 chhupe hue, do jagah hardcoded, reports ka input discard |

---

## 8. Suggested fix order

Ye `CHAT_PAGE_REVIEW.md` §9 ke Phase A se **alag aur swatantra** hai — dono parallel chal
sakte hain.

| # | Kaam | Kahan | Effort |
| --- | --- | --- | --- |
| 1 | `_looksLikeFollowupOrCallListQuestion` se bare-number ko exempt karo (ya choice-handlers me number check pehle le jao). Menu phir se kaam karne lagenge. | `controlled_chat_flow.dart:384-390`, `:3170`, `:3543` | ~6 lines |
| 2 | Flow chalne par analytics chips disable/hide karo. | `chat_screen.dart:949-987`, `:1063-1065` | ~15 lines |
| 3 | Har choice-menu ke liye `flowChipOverride` do, taaki user tap kare — type na kare. Isse §5 ka ambiguity apne aap khatam. | `chat_screen.dart:949-987` | ~60 lines |
| 4 | Flow me `back` / `peeche` command add karo (`stepIndex - 1`). | `flow_step_engine.dart`, `controlled_chat_flow.dart:3980` | ~30 lines |
| 5 | Cancel/undo vocabulary ek jagah centralize karo, sab states me same. | `:486-512` + har handler | ~40 lines |
| 6 | `detectIntent` ke do implementations me se ek hataao — client sirf raw text bheje, server classify kare (server ka version zyada complete hai). | `user_text_pipeline.dart:75`, `aivyProcess.ts:2689` | ~20 lines |
| 7 | `'(ya khaali chhod dein = aaj)'` copy hatao, ya ek "Aaj" chip do. | `:1204` | ~5 lines |
| 8 | Shortcut map ek hi jagah rakho (shared JSON/const), 7–11 ke liye chips ya help line do. | `smart_command_expand.dart`, `aivyProcess.ts:6435` | ~20 lines |
