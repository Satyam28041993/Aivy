# Aivy Agent Screen — feasibility analysis

Sawaal: **ek nayi screen jahan main normal Hindi / English / Hinglish me bolun, Aivy samjhe
aur kaam kar de.** Koi menu nahi, koi `1`/`2` nahi, koi wizard nahi.

Ye doc sirf **analysis** hai — code nahi. Pehle requirement, phir "aaj kyun nahi chalta"
ka asli root cause, phir "possible hai ya nahi", phir architecture.

---

## 1. Requirement — jo maine samjha

Aapke diye examples se 7 saaf capabilities nikalti hain:

| # | Aap kehte ho | Aivy ko kya karna chahiye |
| --- | --- | --- |
| R1 | "kal mera meeting hai 11 baje rohan ke sath **new labels ke regarding**" | Meeting create — **kiske saath** (Rohan), **kab** (kal 11:00), **kyun** (new labels). Aur meeting hai to **reminder apne aap** lag jaaye. |
| R2 | "rohan ko 50000 ka quotation diya" | Quotation record ho — client, amount, date |
| R3 | "**kisko** quotation diya?" | Upar wala record wapas mile |
| R4 | "payment aaya 30000 karan se" | Payment settle ho, pending due update ho |
| R5 | "aaj kisko call karna hai?" / "kal kisko?" / "is week?" / "last week?" | Time window ke hisaab se follow-up list |
| R6 | "koi important cheez hai kya?" | Overdue + aaj ke kaam + risky clients — ek summary |
| R7 | Poora — bina koi command seekhe, bina koi number dabaye | Sirf baat-cheet |

Ek chhupi hui requirement bhi hai, jo sabse important hai:

> **R8 — Conversation ko yaad rahe.** "quotation diya" ke baad "kisko diya?" ka matlab
> **usi** quotation se hai. Aivy ko pichhli baat aur uska save kiya hua record dono
> yaad rehne chahiye.

---

## 2. Aaj kyun nahi samajhti — 4 asli root cause

Ye "prompt kharab hai" wali baat nahi hai. Architecture level par 4 cheezein hain.

### 🔴 Cause 1 — Free text se business data **save hi nahi hota**

Ye sabse bada karan hai, aur R2/R3 ke fail hone ki poori wajah.

Server ke code me **saaf likha hai**:

```ts
// functions/src/aivyProcess.ts:2835
// Phase 2: do not persist jobs/payments from the server; response is chat-only.
const persistMeta: PersistPgplResult = {};
```

`persistPgplDirectFirestore()` ka poora function (`:3050-3210`) code me maujood hai —
quotation, order, dispatch, payment sab likhna jaanta hai — par **wo kabhi call nahi hota**.
Dead code hai.

Aur `tryRuleBasedOrderQuotationFirst()` (`:2224-2420`) — jo "quotation diya" ko pehchanta
hai — usme **0 Firestore writes** hain. Wo sirf ek reply banata hai.

Business data likhne wala **ek hi** raasta hai: `flow_save_router.dart` — jo **sirf wizard**
se chalta hai (`+` → Quotation → New quotation → 3 sawaal → Confirm).

**Ek apwaad (aur yahi confusion ki jad hai):**

| Cheez | Free text se save? | Kaun likhta hai |
| --- | --- | --- |
| **Reminders** | ✅ **haan** | `chat_repository.dart:1319-1330` → `persistAiReminderSuggestions` |
| Quotations | ❌ nahi | sirf `flow_save_router.dart:126` (wizard) |
| Orders | ❌ nahi | sirf wizard |
| Payments | ❌ nahi | sirf wizard |
| Tasks | ❌ nahi | sirf wizard |

Isliye lagta hai ki "kabhi kaam karta hai kabhi nahi" — reminder wali baat sach me save hoti
hai, baaki sab sirf ek achha sa jawaab deke gayab ho jaati hai.

**R2 → R3 ka poora trace:**

```
"rohan ko 50000 ka quotation diya"
  → ControlledChatFlow idle branch: quotation ka koi parser nahi (sab payment ke hain)
  → detectIntent → general → ProcessResult.none()
  → UserTextPipeline → aivyProcess
  → tryRuleBasedOrderQuotationFirst → reply banaya, KUCH SAVE NAHI
  → chat me: "Theek hai, quotation note kar liya"     ← jhooth
  → users/{uid}/quotations me: KUCH NAHI

"kisko quotation diya?"
  → classifyAnalyticsRequest → kind: "quotation_names"   ← ye sahi kaam karta hai!
  → fetchQuotationsInWindow() → users/{uid}/quotations → 0 docs
  → "koi client naam nahi mila"
```

**Read side sahi hai. Write side hai hi nahi.**

### 🔴 Cause 2 — LLM ke paas koi tool nahi, sirf ek fixed JSON form hai

Aaj Gemini ko ek fixed shape bharna hota hai (`summary`, `userReply`, `clientName`,
`reminderSuggestions[]`, `intent`…). Wo **action nahi le sakta** — bas form bhar sakta hai.
Aur us form me se sirf `reminderSuggestions` ko client uthata hai.

Iska seedha nateeja **R1** par:

> "kal mera meeting hai 11 baje rohan ke sath new labels ke regarding"

Ye ek vaakya me **do** kaam maangta hai — ek meeting record, aur uska reminder. Aaj ka
JSON form ek hi cheez express kar sakta hai. Meeting `reminderSuggestion` ban jaayegi
(reminder to lag jaayega), par:
- "new labels ke regarding" — **kyun** — ka koi field nahi jo reliably bhara jaaye
- Rohan ek client hai ya contact — resolve nahi hota
- ek alag "meeting" record nahi banta, sirf ek reminder banta hai

### 🔴 Cause 3 — Sawaal ka jawaab 21 fixed template se aata hai

`AnalyticsKind` (`aivyProcess.ts:243-264`) me theek **21** kinds hain:
`quotation_count`, `quotation_names`, `dispatch_value`, `payment_due_list`,
`followup_today_list`, `risky_clients_list` … bas.

Inhe chunne ka tareeka ek **giant regex gate** hai (`:5378`) — 60+ keywords ek line me.
Jo sawaal in 21 me nahi aata, ya jiske shabd us regex me nahi hain, uska jawaab data se
nahi aata — wo Gemini ke paas chala jaata hai jo **data dekhta hi nahi**, to andaza lagata hai.

**R5** ka "aaj / kal / is week" chalta hai. "**last week** ka koi important cheez" — `pichh`
regex me hai, par `important` ke liye koi kind nahi. **R6** ka "koi important cheez hai kya"
kisi bhi kind se match nahi karta.

### 🔴 Cause 4 — Routing 100+ regex ka jaal hai jo aapas me ladta hai

- Client par ~10 idle-branch parsers, phir `detectIntent` (270 lines regex)
- Server par phir se `detectIntent` (258 lines), phir `classifyAnalyticsRequest`,
  `isRuleOrderDispatchOrQuotationText`, `isWhoToCallAnalyticsQuestionText`,
  `looksLikeReminderSchedulingLine` …
- `routedUserIntent === "reminder"` **teen** engines ko poora skip kar deta hai
  (`:2709`, `:2741`, `:2774`)

Iska matlab: "kal Rohan ko call karna hai aur uska pending payment bhi batao" → intent
`reminder` → order/quotation engine, rule hard-stop, aur analytics — teenon skip → sirf
reminder banega, payment ka jawaab nahi milega.

Aur ek 5th cheez jo directly R8 ko todti hai:

### 🟠 Cause 5 — Conversation memory bahut kamzor hai

`fetchRecentMemoryLogTexts(uid, 10)` sirf 10 purani **text lines** deta hai. Kya save hua,
kis doc id par — wo model ko nahi pata. `flow.lastEntity` sirf **payment** ke liye set hota
hai (`controlled_chat_flow.dart`), quotation/order/meeting ke liye nahi.

To "quotation diya" ke turant baad "kisko diya?" — model ke paas us quotation ka koi
reference hi nahi hota.

---

## 3. Kya ye possible hai?

**Haan. Aur aapka soch se zyada saamaan pehle se bana hua hai.**

Ye koi zero-se-shuru project nahi hai. Jo cheezein sabse mushkil hain — data model,
Firestore reads, client name resolution, date parsing, reminder scheduling — wo sab
maujood aur tested hain. Jo missing hai wo **ek layer** hai: agent ko haath dena.

| Kya chahiye | Aaj hai? | Kahan |
| --- | --- | --- |
| Firestore data model (quotations, orders, payments, reminders, tasks, clients) | ✅ | `firestore.rules`, `firestore.indexes.json` |
| Business data **likhne** ka logic | ✅ **poora likha hai** | `flow_save_router.dart` (1099 lines), `persistPgplDirectFirestore` (`:3050`, dead) |
| Business data **padhne** ka logic | ✅ 21 analytics kinds + `runAnalyticsRequest` | `aivyProcess.ts:5117-6400` |
| Client naam resolve / fuzzy / disambiguation | ✅ | `client_repository.dart:95`, `client_name_resolution.dart`, `fuzzy_payment_query.dart` |
| Hinglish date/time parsing ("kal 11 baje", "2 din baad") | ✅ 889 lines, tested | `reminder_time_parser.dart` |
| Reminder scheduling + notification engine | ✅ | `reminder_scheduling.dart`, `reminderNotificationEngine.ts` |
| **Tool-calling** ka pattern | ✅ **already built** | `gemini_live/aivy_business_tools.dart` + `aivy_business_snapshot_service.dart` (455 lines) |
| Gemini SDK jo function calling karta hai | ✅ | `firebase_ai: 3.11.0` (pubspec:62) |
| **Write tools** (agent kuch save kar sake) | ❌ **yahi missing hai** | — |
| Multi-step agent loop (tool → result → phir sochna) | ❌ | — |
| Generic confirm card (wizard ke bina) | ❌ | — |
| Structured conversation memory (kya save hua, kis id par) | ❌ | — |

**Sabse important line:** `lib/core/voice/gemini_live/aivy_business_tools.dart` me **6 read
tools** pehle se declared hain (`get_calls_today`, `get_followups_today`,
`get_overdue_items`, `get_payment_followups`…) aur `aivy_business_snapshot_service.dart`
me unke implementations hain. Ye bilkul wahi pattern hai jo nayi screen ko chahiye — bas
abhi sirf Voice Home ke Live session se juda hai, aur **sirf padh sakta hai, likh nahi sakta**.

---

## 4. Nayi architecture — "agent", "command system" nahi

Farq ek line me: **aaj LLM ek form bharta hai. Naye system me LLM ke paas haath honge.**

```
┌─ AGENT SCREEN ────────────────────────────────────────────────┐
│                                                               │
│  User bolta/likhta hai (Hindi / English / Hinglish)           │
│         │                                                      │
│         ▼                                                      │
│  ┌──────────────────────────────────────────────┐            │
│  │  aivyAgent  (ek Cloud Function, ek loop)      │            │
│  │                                               │            │
│  │  system prompt + aaj ki date/time + user      │            │
│  │  profile + pichhle 6 turn + last saved refs   │            │
│  │                                               │            │
│  │  ┌────────── AGENT LOOP (max 4 turns) ──────┐│            │
│  │  │  Gemini 2.5 Flash + TOOLS                ││            │
│  │  │    ↓ tool call                            ││            │
│  │  │  tool chalao → result wapas do            ││            │
│  │  │    ↓ (zaroorat ho to phir tool)           ││            │
│  │  │  final Hinglish jawaab                    ││            │
│  │  └───────────────────────────────────────────┘│            │
│  └──────────────────────────────────────────────┘            │
│         │                                                      │
│         ▼                                                      │
│  Reply + jo save hua uska card ("Meeting ✓ Rohan, kal 11am")   │
└───────────────────────────────────────────────────────────────┘
```

### Tools — yahi asli design hai

**Write tools** (naye — inhi ki wajah se R1–R4 chalenge):

| Tool | Parameters | Kya karta hai |
| --- | --- | --- |
| `create_meeting` | `client`, `when`, `agenda`, `duration?` | Meeting record + **apne aap** reminder |
| `create_reminder` | `title`, `when`, `client?`, `note?`, `priority?` | Reminder / call / task |
| `record_quotation` | `client`, `amount`, `date?`, `note?` | `users/{uid}/quotations` |
| `record_order` | `client`, `amount`, `note?` | `users/{uid}/orders` |
| `record_payment_received` | `client`, `amount`, `date?` | Payment settle + linked due update |
| `record_payment_due` | `client`, `amount`, `due_date` | Naya due |
| `mark_dispatched` | `client`, `order_ref?`, `payment_terms?` | Dispatch + follow-up |

**Read tools** (6 pehle se hain, ~6 aur):

| Tool | Kya deta hai |
| --- | --- |
| `get_agenda` | `window`: today/tomorrow/this_week/last_week — calls, meetings, follow-ups |
| `get_important` | Overdue + aaj ke kaam + risky clients — **R6 ka jawaab** |
| `find_records` | `type`: quotation/order/payment, `client?`, `window?` — **R3 ka jawaab** |
| `get_client_summary` | Ek client ka poora hisaab — dues, quotations, history |
| `get_pending_payments` | `window?`, `client?` |
| `search_clients` | Naam se fuzzy match |

### Teen design faisle jo is system ko kaam karne layak banate hain

**(a) Har write ek confirm card se guzre — par wizard nahi.**
Tool call turant save **nahi** karta. Wo ek draft banata hai, aur chat me ek card dikhta hai:

```
📅 Meeting
   Rohan ke saath · kal, 11:00 AM
   Regarding: new labels
   + reminder 10:45 AM par

   [✓ Sahi hai]   [✎ Badlo]   [✕ Nahi]
```

"Badlo" par bhi user **normal bhasha** me bolta hai — "12 baje kar do" — koi field picker
nahi. Ye purane confirm ka accha idea rakhta hai aur `1`/`2`/`3` wala jaal hata deta hai.
Read tools ko confirm ki zaroorat nahi — wo turant jawaab dete hain.

**(b) Client naam ko tool ke andar resolve karo, agent se mat poochho.**
`create_meeting({client: "rohan"})` → `resolveForPaymentName` chalta hai:
- ek match → aage
- kai match → tool `needs_disambiguation` return karta hai, agent **khud** poochta hai
  "Rohan Traders ya Rohan Prints?"
- koi match nahi → tool naya client banane ka option deta hai

Ye logic pehle se likha hai, bas tool ke peeche daalna hai.

**(c) Har save ka reference conversation me wapas daalo — R8 ka fix.**
Tool result me `{id, type, client, amount}` aata hai, aur wo agle turn ke context me jaata hai:

```
turn 1: "rohan ko 50000 ka quotation diya"
        → record_quotation(...) → {id: "q_8f2", client: "Rohan Traders", amount: 50000}
        → context me: last_saved = [{type: quotation, id: q_8f2, client: Rohan Traders}]
turn 2: "kisko diya tha?"
        → agent context se seedha jawaab: "Rohan Traders ko, ₹50,000 ka"
        → koi tool call bhi nahi chahiye
```

---

## 5. Aapke 7 examples — naye system me

| # | Aap bolte ho | Agent kya karega |
| --- | --- | --- |
| R1 | "kal mera meeting hai 11 baje rohan ke sath new labels ke regarding" | `create_meeting(client:"rohan", when:"kal 11:00", agenda:"new labels")` → confirm card (meeting + auto reminder) → "Sahi hai" → dono save |
| R2 | "rohan ko 50000 ka quotation diya" | `record_quotation(client:"rohan", amount:50000)` → card → save |
| R3 | "kisko quotation diya?" | Context me abhi hai → seedha jawaab. Purana ho to `find_records(type:"quotation", window:"this_week")` |
| R4 | "karan se 30000 payment aaya" | `record_payment_received` → open dues dhoondhta hai → "₹30,000 ka due mila, isi me lagayein?" → save |
| R5 | "aaj kisko call karna hai?" | `get_agenda(window:"today")` → list |
| R5b | "aur is week?" | `get_agenda(window:"this_week")` — "aur" ka matlab context se samajhta hai |
| R6 | "koi important cheez hai kya?" | `get_important()` → overdue + aaj ke kaam + risky clients |

Ek aur cheez jo automatically milegi: **ek message me kai kaam.**
"rohan ko quotation diya 50000 ka, aur kal 11 baje meeting bhi hai uske saath" →
agent **do** tool calls karega, ek hi turn me. Aaj ka system ye kar hi nahi sakta.

---

## 6. Kya risk hai — saaf-saaf

| Risk | Kitna bada | Kya karna hoga |
| --- | --- | --- |
| **Galat save** — agent kuch aisa likh de jo user ne nahi kaha | Sabse bada | Har write par confirm card. Read tools free. |
| **Latency** — tool loop = 2–3 Gemini calls | Medium | Read-only sawaal ~1.5–2.5 s. Write + confirm feel fast lagta hai kyunki card turant dikhta hai. Aaj ka chat turn bhi ~2.5 s hai, to bura nahi. |
| **Cost** — har turn me zyada tokens | Medium | Tools ka schema chhota rakho; poora database prompt me mat bhejo (aaj bheja jaata hai — ulta ye **sasta** padega) |
| **Client naam galat match** | Medium | `resolveForPaymentName` pehle se disambiguation deta hai; agent poochh lega |
| **Purana chat screen** | Chhota | Naya screen alag hai. Purana jaisa hai waisa chalta rahega. |
| **Voice** | Chhota | Wahi agent, input STT se. `CHAT_PAGE_REVIEW.md` §7.3 wala flow-bypass problem yahan hai hi nahi, kyunki koi flow state hi nahi. |

**Jo nahi milega:** 100% accuracy. Kabhi-kabhi galat samjhega. Farq ye hai ki galti
**confirm card par dikhegi** aur user turant theek kar dega — aaj galti chup-chaap ho
jaati hai (ya kuch save hi nahi hota aur pata bhi nahi chalta).

---

## 7. Plan

### Phase 1 — Foundation (backend)
1. `aivyAgent` callable — agent loop, max 4 tool turns, 30 s budget
2. Tool registry + JSON schemas
3. **Write tools** — `flow_save_router.dart` ki logic server par le jao (ya `persistPgplDirectFirestore` ko zinda karo — wo already likha hai)
4. **Read tools** — `runAnalyticsRequest` ke 21 kinds ko 6 saaf tools me wrap karo
5. Client resolution tool ke peeche

### Phase 2 — Nayi screen
6. `AivyAgentScreen` — sirf ek input bar, koi chip nahi, koi menu nahi
7. Generic confirm card (har record type ke liye ek hi widget)
8. Structured memory — last saved refs + 6 turn ka history

### Phase 3 — Voice
9. Wahi agent, input STT se (`CHAT_PAGE_REVIEW.md` Phase A ke fixes yahan kaam aayenge)
10. Ya seedha Gemini Live + wahi tools — `gemini_live/` ka saamaan reuse

### Phase 4 — Purana screen
11. Naya screen theek chalne lage to purane chat ko usme merge karo, ya sirf history ke liye rakho

---

## 8. Ek line ka jawaab

**Haan, possible hai.** Aaj ka system isliye nahi samajhta kyunki wo **samajhne ki koshish
hi nahi karta** — wo 100+ regex se guess karta hai aur free text se kuch **save hi nahi
karta** (reminders ke alawa). Data model, write logic, read logic, date parsing, client
resolution — sab pehle se bana hai. Missing sirf ek layer hai: **LLM ko tools dena aur
usse ek loop me chalana.**

Sabse pehla concrete kadam: **write tools**. Kyunki `record_quotation` ke bina R3
("kisko quotation diya") kabhi kaam nahi karega — chahe model kitna bhi achha ho.
