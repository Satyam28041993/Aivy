# Aivy — poori intent list, sharpness review, aur date parsing

Do sawaal ke jawaab:

1. **Kya ye har intent ko sharp-ly pakad legi?** — "quotation diya" (record karo) vs
   "kisko quotation diya" (report do) vs meeting vs reminder vs personal baat.
2. **Kya dates thik se samajh paayegi?**

`AIVY_AGENT_SCREEN_ANALYSIS.md` ka agla hissa. Wo doc "possible hai kya" par tha —
ye doc "kitna sharp" par hai.

---

## Part A — Poori intent inventory (purane chat screen se)

Kul **52 intents** nikle. Teen family me baante:

### A1. WRITE — kuch record karna (17)

| # | Intent | Aaj kaise pakda jaata hai | Save hota hai? |
| --- | --- | --- | --- |
| W1 | Reminder — call | `detectIntent` regex + wizard `reminder:call` | ✅ free text se bhi |
| W2 | Reminder — meeting | wahi + wizard `reminder:meeting` | ✅ free text se bhi |
| W3 | Reminder — task | `tryParseTaskReminderOneLine` + wizard | ✅ free text se bhi |
| W4 | Reminder — follow-up | wizard `reminder:followup` | ✅ free text se bhi |
| W5 | Personal reminder | wizard `personal:task` **only** | ❌ sirf wizard |
| W6 | Birthday tracker | wizard `personal:birthday` **only** | ❌ sirf wizard — server par birthday ka koi code hi nahi |
| W7 | Payment received (due settle) | `tryParsePaymentReceivedDirect`, `detectPaymentReceivedWithNameDetails` | ❌ sirf wizard/flow |
| W8 | Payment due (naya) | `tryParsePaymentDueKo`, `tryParseManualPaymentLine` | ❌ sirf wizard/flow |
| W9 | Payment follow-up | wizard `payment:followup` | ❌ sirf wizard |
| W10 | Order — new | `isRuleOrderCreateText` (server) | ❌ **server likhta hi nahi** |
| W11 | Order — update / note | wizard `order:update` | ❌ sirf wizard |
| W12 | Order dispatch (+ payment terms) | `isRuleDispatchCue`, `isRuleDispatchText`, `isDispatchRecordText` | ❌ **server likhta hi nahi** |
| W13 | Quotation — new | `isRuleQuotationText` (server) | ❌ **server likhta hi nahi** |
| W14 | Quotation — follow-up | wizard `quotation:followup` | ❌ sirf wizard |
| W15 | Client follow-up | wizard `followup:client` | ❌ sirf wizard |
| W16 | Naya client banana | `_ensureClientForPaymentMap` → confirm | ❌ sirf flow ke andar |
| W17 | Memory / profile fact ("mera naam…", family) | `saveUserMemory` (`aivyProcess.ts:502`) | ⚠️ partial |

**Sabse badi baat is table me:** 17 me se sirf **4** (reminders) free text se save hote hain.
Baaki 13 ke liye wizard chahiye — `+` → category → subcategory → step-by-step → Confirm.

### A2. READ — sawaal poochhna (21 analytics kinds)

`aivyProcess.ts:243-264`:

| Group | Kinds |
| --- | --- |
| Quotation | `quotation_count`, `quotation_value`, `quotation_names`, `quotation_line_items` |
| Order / dispatch | `job_incoming_count`, `dispatch_count`, `dispatch_value`, `dispatch_names`, `dispatch_line_items`, `order_month_value`, `pending_orders_list` |
| Payment | `payment_due_list`, `payment_outstanding_total`, `overdue_payments_list`, `week_payment_followup_list` |
| Follow-up / reminder | `reminder_list`, `followup_today_list` |
| Client insight | `client_rank_business`, `client_rank_pending`, `risky_clients_list` |
| Summary | `daily_status_summary` |

Chunne ka tareeka: ek **giant regex gate** (`:5378`) — 60+ keyword ek line me — phir
`classifyAnalyticsRequest` + `classifyClientInsightsRequest`.

### A3. ACTION — kuch bahar bhejna (5)

| # | Intent | Detector |
| --- | --- | --- |
| X1 | WhatsApp message bhejo | `WhatsappContactIntentParser` — `"X ko WhatsApp pe message bhejo ki …"` |
| X2 | Google Calendar event | `GoogleCalendarIntentParser` — keyword **aur** time hint dono chahiye |
| X3 | Gmail bhejo | `GoogleGmailIntentParser` — email address + verb chahiye |
| X4 | Google Sheets row | `GoogleSheetsIntentParser` |
| X5 | Web search | 12 hardcoded keywords (`"google se"`, `"net pe"`…) |

### A4. CONVERSATION (9)

Greeting · "tumhe kisne banaya" · undo · cancel flow · disambiguation reply ·
menu pick · inline edit · personal baat-cheet · general chit-chat

---

## Part B — Aapka asli sawaal: WRITE vs READ ka farq

> "kab main quotation **diya** bol raha hu, kab quotation ka **report** maang raha hu"

### Aaj ye kaise decide hota hai

Koi ek jagah nahi. **Chaar** detectors aapas me race karte hain:

```
"rohan ko 50000 ka quotation diya"
  → _isBusinessStatsOrListQuestion?  quotation ✓ par kitne/list/batao ✗  → false
  → isRuleQuotationText?             ✓  → WRITE samjha
  → …aur phir kuch save nahi karta   ← Cause 1

"kisko quotation diya?"
  → _isBusinessStatsOrListQuestion?  quotation ✓ + kisko ✓  → true → READ
  → classifyAnalyticsRequest → quotation_names  ← sahi!
  → collection khaali                ← Cause 1 ka nateeja
```

**Ye classification aaj sach me sahi hai.** "kisko quotation diya" theek `quotation_names`
par jaata hai. Fail hone ki wajah classification nahi — **data hai hi nahi**.

### Par ye sirf tab tak chalta hai jab tak keyword list me shabd hon

Read ka faisla **question-word list** par tika hai:
`kitne|kitna|kitni|kisko|kisse|list|how many|abhi tak|total|saare|count|batao|bata|report|naam|names|pichhle|mahine|month|aaj|kal|guzre|value`

Jo iske bahar hai, wo **write** maan liya jaata hai:

| Aap poochte ho | Aaj kya samjha jaata hai |
| --- | --- |
| "quotation kiska pending hai" | `pending` list me nahi → **write** samjha |
| "Rohan wala quotation dikhao zara" | `dikhao` list me nahi → **write** samjha |
| "quotation bheja tha na usko?" | koi question word nahi → **write** samjha |
| "kya maine Rohan ko quotation diya?" | `kya` list me nahi → **write** samjha |

Ye chaaron ek insaan ke liye saaf sawaal hain. Regex ke liye statement hain.

### Ek LLM ke liye ye **aasaan** kaam hai

Write vs read ka farq **grammar** ka hai — past-tense statement vs question — aur yahi
cheez language models sabse achhi karte hain. "kya maine Rohan ko quotation diya?" me
`kya … ?` ka structure hi sawaal hai; kisi keyword list ki zaroorat nahi.

**Ye upgrade ka sabse pakka hissa hai.** Aur ek tool-calling agent me ye classification ka
sawaal hi khatam ho jaata hai — `record_quotation` aur `find_records` do alag tools hain,
model jise chahe use kare, aur **write se pehle confirm card** dikhta hai. Galat samjha to
aap card par turant dekh lenge — aaj galti chup-chaap hoti hai.

---

## Part C — Har intent family kitni sharp ho sakti hai

Imandari se, family ke hisaab se:

| Family | Aaj | Agent se | Kyun |
| --- | --- | --- | --- |
| **Write vs read farq** | 🟠 keyword list par tika | 🟢 **bahut sharp** | Grammar ka kaam, LLM ki sabse strong cheez |
| **Meeting vs reminder vs call vs task** | 🟠 `reminder:call`/`meeting` sirf wizard me alag; free text me sab reminder ban jaate hain | 🟢 **sharp** | "meeting hai" vs "call karna hai" vs "yaad dila dena" — saaf lexical farq |
| **Client naam nikalna** | 🟠 regex se token todta hai | 🟢 sharp — par naam **resolve** tool kare, model nahi | Fuzzy match + disambiguation pehle se bana hai |
| **Amount nikalna** | 🟢 achha (`extract_inr_amount`, `number_context_parser`) | 🟢 sharp | Dono achhe |
| **Personal vs business baat** | 🔴 personal ka server par code hi nahi (W5, W6) | 🟢 sharp | Model ko sirf batana hai |
| **Ek message me kai kaam** | 🔴 **namumkin** — ek JSON, ek intent | 🟢 sharp | Kai tool calls ek turn me |
| **Pichhli baat ka reference** ("kisko diya tha?") | 🔴 sirf payment ke liye `lastEntity` | 🟢 sharp — agar saved refs context me daale jaayein | Design ka hissa, model ka nahi |
| **Report ka time window** ("is week", "last week") | 🟠 kuch chalte hain | 🟢 sharp | Tool ka `window` parameter |
| **"koi important cheez hai kya"** | 🔴 kisi kind se match nahi | 🟢 sharp | Ek `get_important` tool |
| **Dates** | 🟠🐞 mila-jula — **Part D dekho** | 🟠 **model akela nahi** — hybrid chahiye | Neeche |

Do jagah jahan agent apne aap sharp **nahi** hoga, aur design se sambhalna padega:

1. **Dates** — Part D.
2. **Client naam** — model ko naam **guess** nahi karne dena. Tool fuzzy match kare aur
   kai match hon to wapas `needs_disambiguation` bheje, taaki agent poochh le.

---

## Part D — Dates: kya aaj theek hai, kya nahi

Date parsing ka saara kaam `reminder_time_parser.dart` (889 lines) aur
`conversational_date_parser.dart` me hai. Ye code **achha aur tested** hai
(`test/reminder_time_parser_extended_test.dart` maujood hai) — par usme kuch pakke gaps
aur do asli bugs hain.

### D1. Aaj kya kaam karta hai ✅

| Cheez | Example |
| --- | --- |
| Relative din | `aaj`, `kal`, `parso`, `today`, `tomorrow`, `yesterday` |
| Relative duration | `2 din baad`, `do din ke baad`, `after 3 days` |
| Numeric date | `02/05/2026`, `5-5-26`, `20.05` |
| Month naam (English) | `5 May`, `May 5`, `jan`, `january` |
| Weekday (English) | `monday` … `sunday` — hamesha **agli** baar |
| Din ka pehar | `subah` (9 AM default), `shaam`, `raat`, `dopahar` |
| Mixed | `kal 5pm`, `10 din baad 4 baje`, `kal subah` |
| Time formats | `3:30pm`, `15:00`, `3.30`, `5 baje` |
| Fullwidth IME text | `ＡＡＪ` → `aaj` |

### D2. Jo aaj **nahi** chalta ❌

| Cheez | Aaj kya hota hai |
| --- | --- |
| **Hindi weekday naam** — `somvar`, `mangalvar`, `shukravar` | Table me sirf English hai (`:270-278`) → date miss |
| **`is hafte` / `agle hafte`** | Koi parser nahi |
| **`agle mahine` / `is mahine ke end me`** | Koi parser nahi |
| **`15 tarikh` / `mahine ki 5 tarikh`** | `tarikh` shabd kahin nahi |
| **`next Monday` vs `this Monday`** | Dono ek hi — hamesha agli baar (`:282-283`) |
| **Hindi month naam** — `mai`, `agast` | Sirf English month naam |
| **Festival / event** — "Diwali ke baad" | Koi support nahi |

### D3. 🐞 Bug 1 — "kal 11 baje" ka matlab **11 PM** nikalta hai

Ye aapke apne example ka bug hai:

> "kal mera meeting hai **11 baje** rohan ke sath"

`_resolveAmbiguous12HourTime` (`:552-598`) ka rule:

```dart
if (!anchorIsToday) {
  if (preferPmForFutureDay) {
    return _TimeOfDayValue(hour: rawHour + 12, minute: rawMinute);   // :571
  }
  ...
}
```

Aaj ka din **nahi** hai + koi `subah`/`shaam` shabd nahi → **blanket `+12`**. Hour dekha
hi nahi jaata:

| Aap bolte ho | Aaj set hota hai | Hona chahiye |
| --- | --- | --- |
| `kal 4 baje` | 16:00 | 16:00 ✅ |
| `kal 6 baje` | 18:00 ✅ (test `:17` isi ko pin karta hai) | 18:00 |
| `kal 9 baje` | 21:00 | 09:00 ❌ |
| `kal 10 baje` | 22:00 | 10:00 ❌ |
| **`kal 11 baje`** | **23:00** | **11:00** ❌ |

Business ke liye 9/10/11 **hamesha subah** hote hain. Blanket `+12` 4–7 ke liye sahi hai,
9–11 ke liye galat.

> Note: main is environment me Dart chala kar prove nahi kar saka (SDK nahi hai). Ye
> code path se nikala hai, aur uske sibling test (`kal 6 baje` → 18) se confirm hota hai
> ki yahi branch chalta hai — us branch me hour-wise koi shart hai hi nahi.

### D4. 🐞 Bug 2 — "kal 10" aur "kal 10 baje" alag jawaab dete hain

Wahi file, doosra branch (`:440-455`):

```dart
// Informal "kal 10" → 10:00 (morning-first), "kal 15" → 15:00.
return _TimeOfDayValue(hour: h, minute: 0);
```

| Input | Result |
| --- | --- |
| `kal 10` | **10:00** (morning-first) |
| `kal 10 baje` | **22:00** (blanket +12) |

Ek hi baat, sirf "baje" lagane se 12 ghante ka farq. Do alag code path, do alag rule.

### D5. 🐞 Bug 3 — "kal" hamesha **aane wala kal** hai, beeta hua kabhi nahi

Hindi me `kal` dono hai — kal (tomorrow) aur kal (yesterday). Tense se pata chalta hai.

Parser hamesha `+1 day` karta hai (`:180`, `:541`). `yesterday` sirf **English** shabd ke
liye handle hai (`:537-539`).

Aapke use case me ye seedha chubhta hai, kyunki aap **beete hue kaam** record karte hain:

| Aap bolte ho | Aaj kya samjha jaata hai |
| --- | --- |
| "kal Rohan se payment aaya tha" | **kal** (aane wala) — future date par record |
| "kal quotation bheja tha" | future date |
| "kal meeting thi Rohan ke saath" | future date |

`parso` ke saath bhi wahi — hamesha `+2` (`:185-192`), "parso" ka "beeta parso" wala
matlab kabhi nahi.

### D6. To kya agent dates **behtar** karega?

Seedha jawaab: **kuch me haan, kuch me nahi — aur akela LLM ispar bharosa layak nahi hai.**

**LLM jahan clearly behtar hai** (kyunki ye samajh ka kaam hai, calculation ka nahi):

| Problem | Kyun LLM behtar |
| --- | --- |
| **D5 — "kal" past ya future** | Tense se pata chalta hai: "kal payment **aaya tha**" (past) vs "kal meeting **hai**" (future). Regex tense nahi dekh sakta. Ye LLM ke liye aasaan hai. |
| **D3 — "11 baje" AM/PM** | "meeting 11 baje" business context me subah hai. Blanket `+12` context nahi dekhta. |
| **D2 — naye phrases** | `somvar`, `is hafte`, `15 tarikh`, `agle mahine` — model ye pehle se jaanta hai, har ek ke liye regex nahi likhna padega |

**LLM jahan kamzor hai:**

| Problem | Kyun |
| --- | --- |
| **Date ka hisaab** — "aaj mangalvar hai to agle somvar ki tarikh kya" | Models arithmetic aur calendar counting me galti karte hain. Ispar bharosa nahi karna chahiye. |
| **Timezone / DST** | Model ko nahi pata user IST me hai |
| **"agle mahine ki 31"** jaisi invalid date | Model bina soche bana dega |

### D7. Isliye: **hybrid** — model samjhe, code hisaab kare

Recommended shape — model se ISO date **mat** maango:

```
User:  "kal mera meeting hai 11 baje rohan ke sath new labels ke regarding"

Model tool call kare:
  create_meeting({
    client: "rohan",
    when_phrase: "kal 11 baje",     ← jaisa bola, waisa
    when_tense:  "future",          ← model ka faisla (D5 ka fix)
    day_period:  "morning",         ← model ka faisla (D3 ka fix)
    agenda:      "new labels"
  })

Tool ke andar:
  ReminderTimeParser (tested, 889 lines) + tense + period se resolve
  → 2026-08-24T11:00:00+05:30

Confirm card:
  📅 Meeting — Rohan Traders
     Somvar, 24 August, 11:00 AM        ← poora likha hua
     Regarding: new labels
     [✓ Sahi hai]  [✎ Badlo]  [✕ Nahi]
```

Teen faayde:
1. **Hisaab tested code karta hai** — model calendar arithmetic nahi karta
2. **Samajh model karti hai** — tense aur pehar, jahan regex haar jaata hai
3. **Card poori date shabdon me dikhata hai** — galat hui to aap turant pakad lenge,
   aur "12 baje kar do" bol kar theek kar denge

Iske saath D2 ke gaps parser me add karne padenge (`somvar`, `is hafte`, `tarikh`,
`agle mahine`) — ~150 lines, straightforward. Model unhe pehchan lega, par resolve karne
wala code hona chahiye.

---

## Part E — Kahan sharp **nahi** hogi (imandari se)

| Cheez | Sach |
| --- | --- |
| 100% accuracy | Nahi milegi. ~90–95% realistic hai. Farq ye hai ki galti **confirm card par dikhegi**, aaj chup-chaap hoti hai. |
| Date arithmetic | Model par bharosa mat karo — D7 wala hybrid hi chalega |
| Client naam | Model guess na kare; tool resolve kare aur zaroorat ho to poochhe |
| Bahut lambi ulti baat | "Rohan ko quotation diya tha par wo cancel ho gaya, ab naya banaya hai 60000 ka" — model shayad ek hi tool call karega. Iske liye confirm card hi bachav hai. |
| Bilkul naye words | Model regex se **bahut** behtar hai, par kabhi-kabhi galat samjhega |
| Latency | Read sawaal ~1.5–2.5 s. Aaj ka chat turn bhi ~2.5 s hai (`CHAT_PAGE_REVIEW.md` §6), to bura nahi. |

**Sabse zaroori guardrail:** har **write** confirm card se guzre, har **read** turant chale.
Isse model ki galti kabhi chup-chaap data me nahi jaayegi.

---

## Part F — Nateeja

**Sawaal 1 — kya har intent sharp-ly pakdegi?**

Haan, aaj se kaafi zyada sharp — par is wajah se nahi ki model jaadoo hai:

- **Write vs read** (aapki main chinta): 🟢 ye LLM ka sabse strong kaam hai. Aur tool-calling
  me ye sawaal hi khatam ho jaata hai — `record_quotation` aur `find_records` alag tools hain.
- **Meeting / reminder / call / task / personal** ka farq: 🟢 sharp
- **Ek message me kai kaam**: 🟢 aaj namumkin hai, agent me normal
- **Pichhli baat ka reference**: 🟢 sharp — par ye **design** se aayega (saved refs context
  me daalne se), model se apne aap nahi

Aur yaad rahe — aaj ki sabse badi dikkat classification nahi hai. `"kisko quotation diya"`
**aaj bhi sahi classify hota hai**. Fail isliye hota hai kyunki 17 me se 13 write intents
free text se **kuch save hi nahi karte**.

**Sawaal 2 — kya dates thik samajh paayegi?**

Sirf model se: **nahi** — model calendar math me galti karta hai.
Hybrid se (model samjhe + tested parser hisaab kare + card par poori date dikhe): **haan**,
aur aaj se saaf behtar, kyunki teen asli bug abhi zinda hain:

- `kal 11 baje` → **11 PM** (aapka apna example)
- `kal 10` = 10 AM par `kal 10 baje` = 10 PM
- `kal`/`parso` kabhi past nahi hote — beete hue kaam galat din par record hote hain

Ye teenon **aaj bhi bugs hain**, agent ka intezaar nahi karte. Chaahein to inhe abhi
theek kar sakte hain — teenon ek hi file me hain, ~40 lines.
