# Aivy Agent Screen — build plan

Teen review docs ka nateeja, ab implementation plan. Ye doc build ke saath update hota rahega.

Peeche ke docs: `CHAT_PAGE_REVIEW.md` · `CHAT_COMMAND_LAYER_REVIEW.md` ·
`AIVY_AGENT_SCREEN_ANALYSIS.md` · `AIVY_INTENT_AND_DATE_ANALYSIS.md`

---

## Goal

Ek nayi screen jo **insaan jaisi personal assistant** ho:

1. **Kaam** — "kal 11 baje rohan ke saath meeting new labels ke regarding" → meeting + reminder
2. **Report** — "kisko aaj call karna hai", "koi important cheez hai kya"
3. **Aam baat** — "aivy yaar main bore ho raha hu" → normal baat-cheet, ChatGPT/Gemini jaisi
4. **General sawaal** — kuch bhi poochho → search + research karke jawaab
5. **Yaad rakhe** — baat karte-karte smart bane
6. Koi command nahi, koi menu nahi, koi `1`/`2` nahi

Purani chat screen baad me hategi — isliye naya screen **standalone** hai, purane
`ControlledChatFlow` par bilkul depend nahi karta.

---

## Architecture

```
AivyAgentScreen (Flutter)
      │  text / voice
      ▼
aivyAgent  (ek Cloud Function — saara dimaag yahin)
      │
      ├── system prompt + user profile + memory + pichhle 10 turn + last saved refs
      │
      ├── AGENT LOOP (Gemini 2.5 Flash, function calling, max 5 hops)
      │     ├── WRITE tools  → draft banate hain (turant save NAHI)
      │     ├── READ tools   → turant jawaab
      │     └── GENERAL tools → web search, yaad rakho
      │
      └── reply + draft cards
      ▼
Confirm card → user "Sahi hai" → aivyAgentCommit → asli Firestore write
```

### Kyun server-side

- Writes ek hi jagah, Admin SDK se — client patla rehta hai
- Gemini key APK me nahi jaati
- Voice aur text dono ek hi dimaag use karte hain
- `checkReminders` (scheduled, `collectionGroup("reminders")`) server-likhe reminders ko
  bhi utha lega — **verified**, notification mil jaayega

### Do-phase write — yahi sabse zaroori safety hai

Write tool **turant save nahi karta**. Wo `users/{uid}/agent_drafts/{id}` me ek draft likhta
hai aur card wapas bhejta hai. User "Sahi hai" dabaye → `aivyAgentCommit` chalta hai →
asli record banta hai.

Isse teen fayde: galat samajh **dikh** jaati hai, "Badlo" normal bhasha me hota hai
(koi field picker nahi), aur model kabhi chup-chaap data kharab nahi kar sakta.

Read tools ko confirm ki zaroorat nahi — wo turant chalte hain.

---

## Tools

### Write (draft banate hain)

| Tool | Firestore | Shape kahan se |
| --- | --- | --- |
| `create_meeting` | `reminders` (type `meeting`) + auto reminder | `reminder_repository.dart:24-61` |
| `create_reminder` | `reminders` | wahi |
| `record_quotation` | `quotations` + follow-up reminder | `chat_repository.dart:150-185` |
| `record_order` | `orders` | `chat_repository.dart:121-148` |
| `record_payment_due` | `payments` (v2 shape) | `payment_repository.dart:295-335` |
| `record_payment_received` | `payments` settle + linked reminders | `payment_settlement.ts` |
| `remember_fact` | user memory | `aivyProcess.ts:502` |

Shapes **bilkul wahi** rakhne hain jo aaj hain — warna purane 21 analytics reads naye
data ko nahi dekh paayenge. `clientNameLower` ke liye Dart ka `normalizeName` server par
**exactly** port karna hai (server ka `normalizeClientNameKey` alag hai — punctuation strip
nahi karta).

### Read (turant)

| Tool | Kya deta hai |
| --- | --- |
| `get_agenda` | `window`: today / tomorrow / this_week / last_week / overdue |
| `get_important` | Overdue + aaj ke kaam + risky clients — "koi important cheez hai kya" |
| `find_records` | `type` (quotation/order/payment/meeting/reminder) + `client?` + `window?` |
| `get_client_summary` | Ek client ka poora hisaab |
| `get_pending_payments` | `window?`, `client?` |
| `search_clients` | Fuzzy naam se |

### General

| Tool | Kya |
| --- | --- |
| `web_search` | `runWebSearch` (Serper) — research ke liye |

Aam baat-cheet ke liye koi tool nahi — model seedha baat karta hai.

---

## Dates — hybrid (model samjhe, code hisaab kare)

Model se ISO date **nahi** maangte. Model deta hai:

```
when_phrase: "kal 11 baje"     ← jaisa bola
when_tense:  "future" | "past" ← tense se (D5 fix: "kal payment aaya tha" = past)
day_period:  "morning" | "afternoon" | "evening" | "night" | null   ← D3 fix
```

Server ka resolver hisaab karta hai. Naye resolver me teen bug **theek** honge jo aaj
`reminder_time_parser.dart` me hain:

| Bug | Aaj | Naya |
| --- | --- | --- |
| `kal 11 baje` | 23:00 (blanket `+12`, `:571`) | 11:00 — 9/10/11 subah, 1–7 shaam |
| `kal 10` vs `kal 10 baje` | 10:00 vs 22:00 | dono same |
| `kal` hamesha future | past record galat din par | tense se decide |

Aur jo aaj missing hai wo add hoga: Hindi weekday (`somvar`…), `is hafte`, `agle hafte`,
`agle mahine`, `15 tarikh`.

Confirm card poori date shabdon me dikhata hai ("Somvar, 24 August, 11:00 AM") — galti
turant pakdi jaayegi.

---

## Client naam

Model naam **guess nahi karega**. Tool ke andar resolve hoga:
ek match → aage · kai match → `needs_disambiguation` wapas, agent khud poochhega ·
koi match nahi → naya client banane ka option.

---

## Chat features

| Feature | Kaise |
| --- | --- |
| **History** | `users/{uid}/agent_chats/{chatId}` + `/messages` — sidebar me list, rename, delete |
| **Naya chat** | Ek tap; purana history me chala jaata hai |
| **Streaming feel** | Reply aane par typing effect |
| **Action cards** | Har draft ke liye ek card, inline confirm |
| **Copy / retry** | Har bubble par |
| **Voice** | Phase 3 |
| **Smart hota jaana** | `remember_fact` tool + memory har turn ke system prompt me |

---

## Build order

| # | Kaam | Status |
| --- | --- | --- |
| 1 | Plan doc | ✅ |
| 2 | Backend: name normalize (exact Dart port) + date resolver | ⬜ |
| 3 | Backend: write tools + drafts | ⬜ |
| 4 | Backend: read tools | ⬜ |
| 5 | Backend: agent loop + `aivyAgent` + `aivyAgentCommit` callables | ⬜ |
| 6 | Client: models + repository (sessions/messages/drafts) | ⬜ |
| 7 | Client: agent service | ⬜ |
| 8 | Client: screen + bubbles + action card + history drawer | ⬜ |
| 9 | HomeShell me naya tab | ⬜ |
| 10 | Tests + `flutter analyze` + `npm run build` | ⬜ |

Purani chat screen **chhui nahi jaayegi** — jab naya screen theek chalne lage, tab hatayenge.
