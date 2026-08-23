# Aivy Agent Screen — phase plan aur progress

Har phase alag se banta hai, alag se test hota hai, green hone par hi agla phase.
Ye doc build ke saath update hota rahega — har phase ka status aur test result yahin.

Design ka poora reasoning: `AIVY_AGENT_BUILD_PLAN.md`
Review docs: `CHAT_PAGE_REVIEW.md` · `CHAT_COMMAND_LAYER_REVIEW.md` ·
`AIVY_AGENT_SCREEN_ANALYSIS.md` · `AIVY_INTENT_AND_DATE_ANALYSIS.md`

---

## Test environment ki sachchai

| Toolchain | Is machine par | Kya chala sakte hain |
| --- | --- | --- |
| Node 22 + npm | ✅ | `npm run build` (tsc), `vitest` — **backend poora test hoga** |
| Flutter / Dart SDK | ❌ nahi hai | `flutter analyze` / `flutter test` **nahi** chala sakte |

Isliye: backend ke har phase ke liye asli automated test likhe aur chalaye jaayenge.
Flutter side ke liye pure-Dart logic ko test-able rakha jaayega, par test **aapki machine
par** chalane honge. Ye phase 7–9 me saaf likha rahega — jhooth nahi bolunga ki maine
Flutter code run kiya.

**Baseline (phase 0):** `npm run build` ✅ · `vitest` ✅ 64/64 pass

---

## Phases

| # | Phase | Deliverable | Test | Status |
| --- | --- | --- | --- | --- |
| 1 | Foundations | `nameNormalize.ts`, `dateResolve.ts` | vitest — normalize parity + date cases incl. 3 bug fixes | ✅ 41/41 |
| 2 | Store layer | `draftStore.ts`, `clientResolve.ts`, `draftTypes.ts`, `toolTypes.ts` | vitest | ✅ 5/5 |
| 3 | Write tools | 8 tools → drafts + `commit.ts` | vitest — Firestore mocked | ✅ 23/23 |
| 4 | Read tools | 7 tools + `timeWindow.ts` | vitest | ✅ 12/12 |
| 5 | Agent loop | registry + system prompt + loop | vitest — scripted model | ✅ 13/13 |
| 6 | Callables | `chatStore.ts`, 3 callables, indexes | `npm run build` + vitest | ✅ 162/162 |
| 7 | Flutter data | `agent_models.dart`, `agent_service.dart` | Dart test likha — **aapki machine par chalega** | ✅ code |
| 8 | Flutter UI | screen + 3 widgets | static review (analyzer nahi hai) | ✅ code |
| 9 | Wiring | HomeShell me 'Aivy' tab | screens/destinations count match | ✅ |
| 10 | Final pass | scenario walkthrough | vitest | ✅ 11/11 |

---

## Phase log

### Phase 1 — Foundations ✅

- `functions/src/agent/nameNormalize.ts` — exact port of Dart `normalizeName`
  (particle stripping included; server ka purana `normalizeClientNameKey` ye nahi karta,
  isliye naya port zaroori tha)
- `functions/src/agent/dateResolve.ts` — hybrid resolver
- `functions/src/agent/dateResolve.test.ts` — **41 tests, sab pass**

Teenon date bug test se pinned hain:

| Bug | Test | Result |
| --- | --- | --- |
| `kal 11 baje` → 23:00 | `bug #1` block | ab **11:00**, label "Ravivar, 24 August, 11:00 AM" |
| `kal 10` ≠ `kal 10 baje` | `bug #2` block | ab dono **10:00** |
| `kal` hamesha future | `bug #3` block | tense se — future 24th, past 22nd |

Naya support jo pehle nahi tha: Hindi weekdays (`somvar`…`ravivar`), `is/agle/pichhle hafte`,
`agle/pichhle mahine`, `15 tarikh`, `agle mahine ki 5 tarikh`, `N din pehle`.

`npm run build` ✅ · poora suite ✅ **105/105** (baseline 64 + naye 41)

### Phase 2 — Store layer ✅

- `clientResolve.ts` — exact/prefix/particle-key matching, ported from
  `ClientRepository.resolveForPaymentName`. Teen outcome: `single` / `ambiguous` /
  `not_found` — model **kabhi guess nahi karta**, tool poochhta hai.
- `looksLikeNoiseClientName` — "cancel", "1", "hello" jaise words client naam nahi ban sakte
- `draftTypes.ts` + `draftStore.ts` — two-phase write ki neev
- `toolTypes.ts` — tool ↔ model contract (failure bhi ek jawaab hai, error nahi)

`vitest` ✅ 5/5

### Phase 3 — Write tools ✅

`tools/writeTools.ts` — 8 tools, har ek draft banata hai, **kuch save nahi karta**:
`create_meeting` · `create_reminder` · `record_quotation` · `record_order` ·
`record_payment_due` · `record_payment_received` · `remember_fact` · `cancel_draft`

`commit.ts` — confirm hone par asli Firestore write. Har shape purane repository se
mirror ki hai (reminders / quotations / orders / payments), warna 21 purane analytics
queries naya data dekh hi nahi paate. Payment settlement transaction me hai.

Test (23) me pinned:

| Case | Expect |
| --- | --- |
| "kal 11 baje rohan ke saath meeting, new labels" | `Ravivar, 24 August, **11:00 AM**` + client + agenda + auto-reminder |
| Date na ho | `needs_date` — draft **nahi** banta |
| Do "Rohan" hon | `needs_client_choice` + dono options |
| Naya client | `createNew: true`, commit par banega |
| "kal payment aaya" | past tense → **22 August** |
| Exact-amount due | wahi due target hota hai |
| Kai dues | purane se adjust, oldest-first |
| "cancel" client slot me | reject |

`npm run build` ✅ · poora suite ✅ **133/133**

### Phase 4 — Read tools ✅

`timeWindow.ts` — 10 named windows (`today`…`overdue`/`all`). Test me pinned:
`this_week` **Monday–Sunday** hai (rolling 7 din nahi), month windows calendar month hain.

`tools/readTools.ts` — 7 tools: `get_agenda` · `get_important` · `find_records` ·
`get_pending_payments` · `get_client_summary` · `search_clients` · `web_search`

`get_important` wahi sawaal hai jiska aaj koi jawaab nahi tha ("koi important cheez hai kya") —
overdue tasks + aaj ka kaam + overdue payments + risky clients, ek call me.

`vitest` ✅ 12/12

### Phase 5 — Agent loop ✅

- `toolRegistry.ts` — 15 tool declarations. Description model ke liye instruction ki tarah
  likhi hai ("the words the user actually said, do not convert them") — yahi model ko date
  banane se rokta hai.
- `systemPrompt.ts` — persona. Teen kaam saaf: **baat-cheet**, **sawaal** (web search),
  **kaam** (tools). Isme likha hai ki har message par tool mat chalao, aur bore ho rahe user
  se dhang se baat karo.
- `agentLoop.ts` — model → tool → model loop, bounded hops, transport injectable.

**Koi intent classifier nahi, koi keyword gate nahi, koi routing table nahi.**

13 tests (scripted model se, bina network):

| Case | Expect |
| --- | --- |
| "bore ho raha hu" | koi tool nahi chalta, seedha jawaab |
| "aaj kisko call karna hai" | `get_agenda` → result → reply |
| quotation + meeting ek message me | **do** tool call ek turn me |
| ambiguous client | failure model ko jaati hai, wo poochhta hai |
| unknown tool | dispatch nahi hota |
| write tool | model ko `saved: false` dikhta hai |
| hop budget | maxHops par rukta hai |

**Do asli bug mile aur theek kiye** (test likhne se hi pakde gaye):
1. `contents` array transport ko live reference milta tha aur baad me mutate hota tha —
   ab snapshot jaata hai
2. `hops` off-by-one — budget khatam hone par `maxHops + 1` return karta tha

`npm run build` ✅ · poora suite ✅ **158/158**

### Phase 6 — Callables ✅

- `chatStore.ts` — chats `users/{uid}/agent_chats/{chatId}` + `/messages`.
  History model ke liye `modelParts` se rebuild hoti hai (display text se nahi), warna
  tool calls aur unke responses history me se gayab ho jaate.
- `aivyAgent` — ek turn: memory + history + pending cards → system prompt → loop →
  dono messages Firestore me. Client sirf stream padhta hai.
- `aivyAgentCommit` — "Sahi hai" par asli write; `noteSaved` se agla turn jaanta hai ki
  abhi kya save hua (isse "usko" bind hota hai).
- `aivyAgentChats` — list / new / rename / delete.
- `index.ts` me export, `firestore.indexes.json` me `agent_drafts` ke 2 composite index.

Firestore rules pehle se recursive hain (`users/{userId}/{document=**}`) — naya rule nahi chahiye.

`npm run build` ✅ · poora suite ✅ **162/162**

### Phase 7–9 — Flutter side ✅ (code likha, run nahi kar paya)

- `models/agent_models.dart` — draft, message, chat, turn, commit result.
  Parsing jaan-boojh kar forgiving hai (backend baad me field jode to purani build
  conversation blank na kare).
- `data/agent_service.dart` — callables + Firestore streams. Reply **stream se** aati hai,
  return value se nahi — isliye UI khud update hoti hai.
- `presentation/aivy_agent_screen.dart` — ek input, koi menu nahi, koi number nahi.
- `widgets/agent_action_card.dart` — confirm card. "save nahi hua" badge saaf dikhta hai.
  **"Badlo" me koi field picker nahi** — cursor wapas composer me jaata hai, kyunki
  "12 baje kar do" bol kar theek karna hi is screen ka point hai.
- `widgets/agent_message_bubble.dart` — bubble + typing indicator
- `widgets/agent_history_drawer.dart` — history, rename, delete, nayi baat
- `home_shell.dart` — naya **"Aivy"** tab index 1 par. Purana Chat 2 par shift hua,
  saare index-based conditions (appBar switch, `_openChatTab`, `extendBodyBehindAppBar`)
  update kiye. **Purani chat screen chhui nahi** — jab naya theek chale, tab hategi.

⚠️ **Imandari se:** is machine par Flutter/Dart SDK nahi hai. Maine `flutter analyze` ya
`flutter test` **nahi** chalaya. Jo kiya: bracket-balance check, unused/missing import scan,
aur har cross-file symbol manually verify kiya. `test/agent_models_test.dart` likha hai —
aap `flutter test` chala kar confirm kar lijiye.

### Phase 10 — Scenario walkthrough ✅

`scenarios.test.ts` — scripted model, par neeche sab asli: asli tool registry, asli write
tools, asli date resolver, asli client resolution. Sirf Firestore stub hai.

| Scenario | Result |
| --- | --- |
| "kal mera meeting hai 11 baje rohan ke sath new labels ke regarding" | ✅ **11:00 AM** (11 PM nahi), client + agenda + auto-reminder |
| "rohan ko 50000 ka quotation diya" | ✅ draft, ₹50,000 |
| "kisko quotation diya?" | ✅ jawaab milta hai, **kuch record nahi hota** |
| Dono ek message me | ✅ **do card**, ek turn me |
| "kal karan se 30000 payment aaya tha" | ✅ **22 August** (past tense), sahi due par |
| "aaj kisko call karna hai?" | ✅ sirf aaj ka, kal ka leak nahi hota |
| "koi important cheez hai kya?" | ✅ overdue + aaj + overdue paisa |
| "aivy yaar main bore ho raha hu" | ✅ **koi tool nahi chalta**, baat karti hai |
| "printing pe GST kitna?" | ✅ web search |
| Do "Rohan" | ✅ poochhti hai, **kuch nahi likhti** |
| Amount missing | ✅ poochhti hai, guess nahi karti |

Ek bug is test ne pakda: mera Firestore stub har collection ko same docs de raha tha,
jisse payment row `reminders` me gin raha tha. Stub ko collection-aware kiya.

`npm run build` ✅ · poora backend suite ✅ **173/173**
