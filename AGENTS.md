# Aivy — working agreement

One file, read by every assistant that touches this repo: Claude Code reads it
through `CLAUDE.md`, Cursor reads it directly. **Whoever finishes a piece of work
updates the "Where things stand" section below before pushing.** That is the
whole mechanism — it only works if it is done every time.

## Rule zero: branch from the live branch

Active branch: **`claude/page-voice-process-review-enhkhh`**

Start every task from that branch's head. Not from `main`, not from an older
branch, not from whatever a tool opened last week.

This has already cost us once. A project feature was built on a base 55 commits
behind; it was wired into a chat pipeline that had been deleted, and merging it
would have brought the retired Chat screen back. The work was sound and had to
be thrown away. That copy lived at commit `ae5e88e` on
`cursor/chat-projects-no-voice-5a06` and `apk/chat-projects-no-voice` — both
deleted, not merged.

## The traps in this repo

Each of these cost real time. They are here so they cost it once.

**Deploying without the server.** `Deploy Web` has a `deploy_functions` input.
It now defaults to true, but if you dispatch the workflow by API, pass it
explicitly. A run that skips the functions still reports success, because a
skipped step is not a failed one — so hosting updates, the server does not, and
nothing says so. A push to `deploy/**` is the git trigger when Actions
dispatch is unavailable; that path always deploys functions. An unset input
on a push used to skip them — do not put that back.

**Deleting a function from the source does not undeploy it.** It keeps
answering, so an old callable can still reply to something that was meant to
reach the new one. `Deploy Web` has a **Delete retired functions** step with a
named list — add a name there when you retire a callable. It is deliberately
not `firebase deploy --force`, which deletes anything missing from source: one
forgotten export would take a live function with it, silently.

**A new callable is created private.** The Firebase CLI sets a callable's
invoker policy only when it *creates* the function. Add every new callable to
the `for svc in ...` list in `.github/workflows/deploy-web.yml`, or it will be
unreachable and the browser will report it as a CORS error.

**Notification channels are immutable.** Android fixes a channel's settings at
creation. The live channel is `aivy_reminders_v3` and it deliberately has **no
custom sound** — `v2` named a raw resource, and a channel whose sound will not
resolve accepts notifications and shows nothing. If a channel must change,
change its id.

**Android needs one keystore.** `android/app/aivy-debug.keystore` is committed
on purpose and is what every build signs with. Google sign-in is registered
against its fingerprint. Do not regenerate it.

**A refusal about the user's own data is a bug.** Asked for "mandar sir ka
location" — an address he had saved himself — Aivy refused three times as
somebody else's private information. Nothing had told the model that everything
these tools reach is one person's own notebook, so it applied a generic privacy
rule to the user's own note. The rule is now in `systemPrompt.ts` under **Their
own records are theirs**, with a test pinning it. It applies to places,
contacts, occasions, remembered facts and the document library alike, and
stops short of hunting for something never recorded.

**Firestore rejects `undefined`.** Not "ignores" — rejects, and the write throws.
Omit the key instead. `stripUndefined` in `chatStore.ts` guards the chat path;
nothing guards the others.

**Callables cannot carry a PDF.** The request ceiling is about 10 MB, so a file
goes to Storage first (`users/{uid}/agent_files/...`) and the turn only sends
the path. The server downloads that prefix and no other — including `..`
tricks. Bytes go to Gemini on *this* turn as `inlineData` and are never written
into chat history; a conversation that replayed base64 would grow until the
next turn failed.

**Gmail is Android-only.** The server holds no Google refresh token — only the
access token the app forwards with a request. So nothing on a schedule can read
Gmail, and the web build cannot read it at all. The morning brief is built when
the app opens for this reason, not because a cron would have been harder.

**Non-interactive function deploy aborts on orphans.** If source no longer
exports a function that is still deployed, `firebase deploy --only functions
--non-interactive` stops the whole job. Delete those names *first*. Do not pass
`--force` on deploy — that would also delete a forgotten live export. This
cost one Deploy Web run: hosting updated, the named-delete step never ran.
The consequence to remember: **add the name to that list in the same commit
that removes the callable.** Leave it for later and the next deploy — anyone's
— is blocked, with an error that says nothing about a workflow step existing
to fix it.

**`continue-on-error` on Functions deploy is trap 1 in a different coat.**
A leftover branch tried that. The run stays green while the server did not
update. Do not put it back.

**Do not bring in a second keystore.** A leftover branch carried
`aivy-qa.keystore`. Live signs with `aivy-debug.keystore`. A different
fingerprint would break Google sign-in.

## How the app is put together

- **`aivyAgent`** is the live pipeline: Gemini function-calling over the tools in
  `functions/src/agent/toolRegistry.ts`. Writes create a draft; nothing is saved
  until the user confirms the card. `aivyProcess` is the older chat pipeline,
  still deployed, not where new work goes.
- **Tabs**: Aivy · Today · Records · More. The voice home, the old Chat screen
  and the WhatsApp screens were removed; WhatsApp's *backend* still runs.
- **Design**: `lib/core/design/aivy_ui.dart`. Use `AivyCard`, `AivySectionHeader`,
  `AivyPill`. Colour carries meaning — red late, amber a decision, green settled,
  violet Aivy. A screen that reaches for `Theme.of(context)` defaults will look
  like a different app.
- **Tasks and projects are one collection**, told apart by `kind`. A task is a
  name with a deadline and a few steps — a project with fewer parts, not a
  different animal — so every reader, reminder and status answer written for
  projects works on it unchanged. Docs written before tasks existed carry no
  `kind`, so read through `kindOf(p)`, never `p.kind`. `create_task` saves the
  whole thing from one sentence on one card: splitting it into create-then-add
  is how a feature stops being used. A deadline sets its own reminder plus a
  halfway check-in, and marking a step done — or closing a task early — cancels
  what is still scheduled (`agent/reminderCancel.ts`). A task that keeps ringing
  after it is finished teaches him to ignore the ones that matter.
- **The brief is ordered the way a morning is used**: tasks, projects, today,
  mail, news, alerts, under one counted line. It ran mail-first once, which put
  what he owes his director below twenty lines of alert digest. Sections fold
  and the choice is remembered, but not all folded by default — a brief that
  opens shut costs six taps to read one morning. Folded headers carry their
  count, because folded and broken look identical without it. The tasks and
  projects sections are read straight from Firestore and appended *after* the
  model writes the rest: they are counts and dates that are already right, and
  two sections have been lost before to model output arriving in an unexpected
  shape.
- **Reminders** are the one delivery path. Anything with a date should become a
  reminder rather than growing a second mechanism: the phone alarm and the
  server push both already work off them.
- **Language**: the app and Aivy's replies are English. The user writes Hinglish.
  The morning brief's news and Google Alerts sections are Hindi, deliberately.

## Where things stand

_Last updated: after the first live E2E smoke run and its fixes._travel_expense`) and the visit location question._

The leftover remotes are gone and `main` has been fast-forwarded to the live
branch, so the working agreement and the old short environment file are no
longer two different documents.

**12,228 lines of retired code deleted.** `aivyProcess.ts` (7,580) was the whole
pre-agent chat pipeline; the only thing still reaching into it was
`getUserMemory`, now `agent/userMemory.ts`. The voice callables
(`aivyVoiceAsk`, `googleSpeechCloud`, `elevenLabsTts`) and the WhatsApp
screens' send callables went with their screens — the WhatsApp *webhook*
backend is untouched. `ChatRepository` went from 1,611 lines to 375: sixteen of
its eighty members had a caller. Each deletion was decided by counting callers
and following the call graph, not by reading names — `paymentSettlement`,
`webSearch` and `readNudgeState` all looked equally orphaned and are all live.

**Nothing voice-related is left in the app.** `audio_service.dart` plays the
reminder sound and is not speech. `firebase_storage` and `storage.rules` are
now used by the Aivy paperclip — a photo or PDF uploads to
`users/{uid}/agent_files/` before the turn.

**Working and tested in the live app**

- Reminders — created by talking, alarm on the phone, push with the app closed
- Morning brief on Today — mail, news (Hindi), Google Alerts by term (Hindi),
  today's commitments; built once a day on open, pull-to-refresh rebuilds
- Occasions — birthdays and anniversaries, warned 15/10/5/1 days ahead and on
  the day, every year
- Saved places, Maps search and directions, live location
- Google: Calendar, Gmail, Sheets, Contacts — Android only
- Dashboard and Records, dark throughout
- Tasks — created from one sentence, deadline plus a halfway check-in, steps
  marked done from chat, reminders cancelled when a task closes early
- The Work list in Records and the detail sheet with its history
- The brief's new order, its counted summary line, and folding sections
- **The app after 12,228 lines were deleted** — build31 exercised on the phone:
  notifications, push, exact alarms, a real reminder firing, Today and Records
  all intact

**Just built, not yet exercised by the user**

- **Where they work** (`functions/src/agent/workContext.ts`). Since 21 Sep 2026
  they are a BDM at **Great Eastern IDTech (GEIPL)** and no longer at Prakruti
  Graphic (PGPL). The prompt now says business is either Great Eastern or their
  own **PrintSahaj**, and that a remembered "works at Prakruti" line is out of
  date. It is in the prompt, not only in memory, because memory saved earlier
  may still say Prakruti and a fact cannot overrule itself. Tests in
  `systemPrompt.test.ts`. Not live until `Deploy Web` runs with the functions.
- **Great Eastern training** (`functions/src/agent/geiplKnowledge.ts`), so Aivy
  can answer a client's questions while the user sits with them. Written from
  the training PDFs and docs in their Drive plus geipl.com: company, hardware,
  supplies, WMS, RFID, TTR, label stocks, and the DinoLabelDigital terms and
  process. About 3,000 words, sent on every turn. Where sources disagree the
  file names which to quote (₹10,000 MOV and 7 working days, not the older
  brochure MOQ). Prices are not in this file — see the price book below.
- **Document library** (`functions/src/agent/brochures.ts`, tool
  `find_document`). 34 product brochures (Drive "NEW BROUCHER": Printer,
  Scanner, Mobile Computer, Bartender) and 21 training/company files (Drive
  "01 Training & Company Knowledge", Word/PPT/Excel included) are copied to
  Firebase Storage under `library/` by `functions/scripts/syncBrochures.cjs`,
  run by the **Sync Document Library** workflow; one Firestore row per file in
  `brochures/{driveFileId}` holds a token download link a client can open.
  Re-run the workflow after adding files to Drive; links survive re-runs
  because the token is kept. **The service account can only read folders
  shared with it** — the workflow prints its email first. The catalog in
  `brochures.ts`, written from reading every brochure, also renders the
  product list the prompt recommends from, so the two cannot drift. Internal
  sales docs are flagged `share_with_client: false`.
- **Aivy reads the brochures** (`read_document`). The sync also extracts the
  full text of every PDF/Word/PPT/Excel into `brochureText/{driveFileId}`
  (pdf-parse, mammoth, jszip — devDependencies, used only by the script).
  Spec questions are answered from that text, one document per call, not from
  the catalogue's one-liners. Brochures that are pictures or whose fonts
  extract as noise are stored as `readable: false`, and Aivy says it cannot
  read them rather than guessing — DS3678 and BHT-1700/1800 were like that
  when read by hand. Retrieval is keyword ranking over the catalogue, not
  embeddings: with ~55 files and model numbers as the main query, that is
  enough; revisit if the library grows into the hundreds.
- **The price book** (`functions/src/agent/priceBook.ts`, tool `get_price`).
  Transcribed from photos of the printed 2026 price book into the user's
  Google Sheet "GEIPL Price Book 2026 - Aivy" (in the price-book photo folder
  in Drive): terms, systems, then supplies — labels per roll, then the Indian
  Chrome rate per 1000, then one column per material as a live formula of
  chrome x the multiplier in its heading — then products with no brochure and
  points to confirm. **The prices are never in this repo, which is public.**
  `scripts/syncPriceBook.cjs` (a step of the Sync Document Library workflow)
  exports the sheet and writes Firestore `priceBook/current`; it re-checks
  every material rate against chrome x multiplier and refuses to write if one
  is off. The sheet is shared (Viewer) with the service account. Firestore
  rules give clients no access to it; only the functions read it. The prompt
  says prices are for the user's eyes, not to be put into anything sent to a
  client unasked, and always "GST extra". Edit the sheet, re-run the workflow.
- **BarTender training** (`functions/src/agent/bartenderKnowledge.ts`, rendered
  inside the Great Eastern section). From the BarTender 2022 four-edition
  comparison the user supplied, the three BarTender PDFs in the library and
  what search could read of bartendersoftware.com (the site is blocked from
  this environment). Editions feature by feature, workstation vs printer
  licensing — which is why the price book's "Starter, unlimited printers" and
  the old charts' "up to 3" are both true — the price-book SKU codes decoded,
  support tiers, Cloud plans, the manufacturing pitch and six questions for
  choosing an edition. No website prices, at the user's request: Great
  Eastern's come from `get_price`. The 2022 comparison PDF is also in the
  library (Drive Bartender folder), so it can be sent to a client.
- **Visits — the DSR** (`agent/visitStore.ts`, `agent/tools/visitTools.ts`;
  tools `record_visit`, `set_visit_followup`, `list_visits`). The user's
  Great Eastern daily sales report. "Visit record karo" → the tool refuses to
  draw the card until contact person, discussion and status are given or the
  user says that is all (`details_complete`), so the cross-question is
  enforced in code → one card → confirm writes `users/{uid}/visits` **and**
  a row in "Aivy DSR - Great Eastern visits", a Google Sheet created in their
  Drive on the first visit (`meta/dsr` holds its id) → the commit message asks
  whether to set a follow-up → `set_visit_followup` writes a reminder and fills
  that visit's row. The Firestore row is the record, the sheet a copy: a visit
  saved without a Google token (web, or permission missing) waits with
  `sheetRow: null` and is copied on the next save that has one; a deleted
  sheet is replaced rather than breaking every save. Rows are written RAW so
  phone numbers keep their leading zero.
- **Visits report** (`lib/features/visits/`). Records has a **Visits** chip
  and a section at the top: this month's count, follow-ups ahead, the last
  three visits and **Open visits · Excel**, which opens a full screen —
  period chips (today / week / month / last month / all), search, summary
  tiles, a table view shaped like the sheet (scrolls sideways) or cards for
  one hand, and a sheet per visit with a Call button. **Download Excel** is
  Google's own `export?format=xlsx` link for the DSR sheet, opened in the
  user's Google session, so no copy of the data passes through us; it is
  disabled until the first visit has reached the sheet. Read-only, like the
  other record screens: visits are recorded by telling Aivy.
- **Visit location is asked, not assumed.** When the phone has a fix,
  `record_visit` will not draw the card until the user has said whether they
  are at the client's place right now (`at_client_location`), in the same
  message as any missing details. Yes keeps the pin on the visit and saves the
  client as a saved place (so "Bajaj ka location" and directions work); no
  captures nothing.
- **Travel expense** (`agent/expenseStore.ts`, `agent/tools/expenseTools.ts`;
  tools `record_travel_expense`, `list_travel_expenses`). Bike, ₹4/km for now
  (`DEFAULT_RATE_PER_KM`; `users/{uid}/meta/expenseSettings {ratePerKm,
  vehicle}` overrides it without a deploy) — the rest of the policy is not
  known yet. The first visit of a day sets one 8 PM reminder (fixed id
  `expense-prompt-yyyy-MM-dd`, subType `expense_prompt`); a visit saved after
  8 PM asks in the chat instead. The user gives the start point (a saved place
  like "ghar", or an area); Aivy routes start → each visit of the day in the
  order made → back on Google Maps (two-wheeler, car if that fails; a visit's
  pin when it has one, else "client, location"), one card with every leg.
  Confirm writes `users/{uid}/travelExpenses/{yyyy-MM-dd}` — one per day,
  a second entry for the same day is refused — cancels the 8 PM reminder, and
  appends one row per leg to "Aivy Expenses - Great Eastern travel" in their
  Drive, with the day totals on the last leg only so the Amount column sums to
  the claim. Same catch-up rule as the DSR. Records has an **Expenses** chip
  and section; **Open expenses · Excel** shows days as routes or a leg table,
  with Download Excel. Not yet: odometer readings, toll/food/other heads, bill
  photos — waiting on the company policy.
- **Brochure links are file cards** (`message_links.dart`, `_FileCard` in
  `agent_message_bubble.dart`). A Firebase Storage link is named by its file
  ("DS-2208 2D DS2278-BT.pdf", not "firebasestorage.googleapis.com") and gets
  Download, WhatsApp (wa.me), Gmail (mailto on the phone, Gmail compose on the
  web) and Copy link. They share the link, not the bytes. File links are
  always lifted out of the text, even in a list, since each card names itself.
- **Enter sends** in the composer, Shift+Enter is a new line, and the phone
  keyboard shows a send key. The field is read-only rather than disabled while
  a reply is coming, so it keeps focus between messages. An Enter that
  finishes an IME composition is left alone.
- **`**bold**` renders as bold** (`message_format.dart`); the bubble used to
  print the asterisks. Only bold — the replies use nothing else.
- **Files on Aivy** — paperclip on the composer (camera, photo, PDF). The app
  uploads to Storage; `aivyAgent` downloads only `users/{uid}/agent_files/`,
  shows the bytes to Gemini on this turn, and stores `📎 filename` in history.
  A visiting card becomes a `saved_contact` draft (root `contacts`, same as
  Records). A brochure / rate card / training PDF becomes a `library_item`
  draft (`users/{uid}/library`). `search_library` answers later; a job line
  still goes through `remember_fact`. Writes wait for the confirm card. Image
  and PDF only — PPT and Excel are refused with a sentence, not a second
  editor. `find_contact` reads the CRM book first, so a saved card is
  findable on web without Google.
- **Visiting cards, front and back** (merged from the Cursor branch, then
  fixed against what the user asked). Some cards are front only, some front +
  back. Two photos in one message are one contact read from both sides; a
  back sent later passes `contact_id` from the commit summary and adds to
  that contact. `saveContact` only adds on update — an empty field keeps what
  was saved, notes are appended, card photos are unioned (`cardImages`, max
  4) — so a back with no number cannot wipe the front's. Tools get this
  turn's checked uploads as `ctx.attachments`; the model never copies a
  Storage path, which is why library items used to be filed without their
  file. Records has a **Visiting cards** chip and section; the screen shows
  each card's front/back photos, Call, WhatsApp, and builds the Excel on the
  phone (`excel` + `file_saver`).
- **Delete, with a card and a trash copy** (`agent/deleteStore.ts`,
  `tools/deleteTools.ts`; tools `delete_record`, `restore_deleted`,
  `list_deleted`). Reminders, tasks, projects, visits, a day of travel, saved
  places, occasions, one remembered fact, contacts, library items,
  quotations, orders and dues with nothing paid. Several matches → the tool
  returns options and the model must ask. Confirm copies the document (and a
  project's items) to `users/{uid}/trash/{id}` **before** deleting, cancels
  linked reminders (by id, and by `visitId`/`projectId`/`quotationId`/
  `relatedReminderId`), and blanks — not removes — a visit's DSR row or a
  day's expense rows, because later records remember their row numbers.
  Restore puts the document back; a visit rewrites its row on the next sync,
  a day of travel is appended again; cancelled reminders stay cancelled.
  Received money is the ledger and is never offered. Clients themselves are
  not deletable yet — too much hangs off them.
- **AI usage & cost** (`agent/aiUsage.ts`, `lib/features/ai_usage/`). Every
  chat turn and morning brief writes `users/{uid}/aiUsage`: the user's
  message, the reply, the tools called, Gemini's own token counts summed
  across hops, and the cost at Gemini 2.5 Flash's standard paid price ($0.30
  in / $2.50 out per million, thinking billed as output, cached input a
  tenth; ₹88 to the dollar). More → **AI usage & cost**. "In" is the whole
  request — system prompt, history, tool results — which is why it dwarfs
  the message. On the free tier the real bill is nothing; the screen says so.
  Prices live in `PRICES`, pinned by `aiUsage.test.ts`.
- **E2E smoke** (`.github/workflows/e2e-smoke.yml`,
  `functions/scripts/e2e/smoke.mjs`). This environment cannot reach
  `cloudfunctions.net` or Cloud Run, so the live end-to-end run happens on
  GitHub Actions: a throwaway anonymous user talks to the deployed agent in
  Hinglish — visit with the location question and follow-up, a second visit,
  the day's travel, a fictional visiting card's front and back
  (`card_front.png`, `card_back.png`), delete and undo — then reads Firestore
  back. Push a change under `functions/scripts/e2e/` (bump `RUN`) to run it
  against what is deployed. **Read the transcript, not just the ticks**: the
  first run passed 28/28 and still showed five bugs, fixed in the same push —
  - a confirmed card's result was stored as a second assistant line straight
    after the card, so the model learned to write "Saved —" before anyone
    tapped. Commit rows now replay as the user's tap, then the result
    (`confirmedTurns`);
  - an empty answer after a tool asked for details came out as "I did not
    catch that" — the loop now nudges once;
  - a card with a mobile and a landline in one field was refused — the first
    good number is the phone, the rest go in the notes;
  - Google's plus code ("R6VQ+95C, …") led the visit location — stripped;
  - a delete card promised to cancel a follow-up the visit never had.
  The second run (32/32) still showed "I have set a follow-up… confirm?"
  before the tap and internal visit ids in a list; the prompt now words a
  pending card as waiting and keeps ids to itself, and the smoke test checks
  both.
  The third run caught an empty *first* answer — Gemini 2.5 Flash sometimes
  returns nothing before any tool runs (often `MALFORMED_FUNCTION_CALL`);
  the one nudge now covers every empty answer and logs the finish reason.
  The fourth had "I have updated…" and the card's lines pasted into the
  chat; every draft result now carries a `reply_rule`. The fifth run was
  35/35 with a clean transcript, and the APK was built from that head.
- **Projects** (`functions/src/agent/projectStore.ts`, `tools/projectTools.ts`).
  A project holds whatever that job needs — no fixed pipeline, because every job
  is shaped differently. Items carry a kind, a date and a status, and
  `waiting_on_them` is a first-class state: half this trade is waiting on a
  client, and calling that "pending" makes both the feeling and the answer wrong.
  Dated items become reminders. Works entirely through chat.
- **A project's items and its history.** The sheet opens and the Work list
  reads, but no project has been filled from a page of trip notes yet, and no
  history line has been written by a real update — every project that exists
  predates the event log.
- **The detail sheet** (`lib/features/projects/`). Tapping a work line in the
  brief opens the whole thing: steps with their states, and a **history** —
  every change, when it happened. `updatedAtMs` cannot answer "kab kya update
  kiya", because current state is what history was overwritten into, so every
  change now appends a line to `projects/{id}/events`
  (`functions/src/agent/projectEvents.ts`), best-effort — a failed event must
  never cost the change it describes. The sheet is **read-only**; the button at
  the bottom hands you to Aivy, which is the only path that also writes the
  reminders, the draft card and the history line.

**Known gaps — pick these up next**

- **History starts from now.** Projects and tasks created before this have no
  events, and the sheet says so rather than showing an empty box.
- **Repeating reminders are not real.** "Every month on the 5th" sets one
  reminder. The card says so honestly rather than pretending. A task with no
  deadline has the same shape of gap: it saves, but nothing ever rings for it,
  so it only surfaces in the brief's list.
- `functions/src/morning/money.ts` is **parked, not dead**. Bank and UPI parsing
  with tests, removed from the brief at the user's request until the shape is
  settled. Do not delete it; it is coming back.
- **`More` still lists dead ends.** "Meeting sessions" says "record a meeting
  from Home" and there is no Home screen; "Chat sessions" counts threads from a
  screen that no longer exists. They render live data, so they were left alone —
  but they are a product decision waiting to be made, not working features.
- **`aivy_ai_response.dart` is mostly unused.** `ReminderSuggestion` inside it
  is live, which is why the file stayed. The rest of its classes have no
  reader.
- **PPT and Excel are not readable yet.** The paperclip takes a photo or a
  PDF. There is no Documents edit screen — filing and recall are through
  Aivy, same as everything else.

## The machines this runs on

Two assistants work here and their environments differ, which is worth saying
once rather than rediscovering.

**This section was deleted once, by accident.** The file it is restored from
was the Cursor Cloud environment doc that lived at this path before the working
agreement was written over it — and the first Cursor session after that lost
its Flutter SDK path and could not run `flutter analyze` at all. If you rewrite
this file, keep this section.

**Cursor Cloud VM**
- Flutter SDK (stable) is at `~/flutter`, on `PATH` via `~/.bashrc`. A
  non-interactive shell may not see it — then use `~/flutter/bin/flutter`.
- Node 22 (nvm) and Java 21 are preinstalled. The update script runs
  `npm install` in `functions/` and `flutter pub get` at the root.
- Run the web app: `flutter run -d web-server --web-port 8080 --web-hostname
  0.0.0.0` (first page load compiles, so it takes 15–60s). `flutter run -d
  chrome` also works.

**Claude Code environment**
- No Flutter SDK at all. CI is the only Dart compiler available; `Checks` runs
  `flutter analyze` and `flutter test` and fails on errors.
- Node and the functions toolchain work normally.

**True on both**
- The app points at the live Firebase project `aivy-5c031`. There is no
  emulator config in `firebase.json`, so writing Firestore or deploying needs
  real credentials.
- **Sign-in is Google OAuth only.** The README says anonymous auth; the code
  (`lib/core/auth/aivy_auth_controller.dart`) explicitly signs anonymous users
  out. There is no test bypass, so any signed-in flow needs a real account.
- **Secrets are not in the repo.** `GEMINI_API_KEY` and the integration keys
  live in Firebase Secret Manager and `functions/.env` (gitignored). Vitest does
  not need them; deploying does.

To exercise a deployed callable without the OAuth UI, mint an anonymous token
directly — anonymous sign-in is enabled on the project even though the app
signs those users out:

```bash
API_KEY="AIzaSyD9kg-3Q5Etl9GQ_EJqvw2MQvyogCDeCqw"   # public web key, from firebase_options.dart
ID_TOKEN=$(curl -s -X POST \
  "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$API_KEY" \
  -H "Content-Type: application/json" -d '{"returnSecureToken":true}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['idToken'])")

curl -s -X POST "https://us-central1-aivy-5c031.cloudfunctions.net/aivyProcess" \
  -H "Authorization: Bearer $ID_TOKEN" -H "Content-Type: application/json" \
  -d '{"data":{"text":"Remind me to call Sam tomorrow at 5pm","timezone":"UTC","nowIso":"2026-01-01T00:00:00.000Z"}}'
```

The body wraps in `{"data":{...}}` and the reply comes back as
`{"result":{...}}`. It hits live Gemini and Firestore under a throwaway uid, so
it leaves real rows behind.

## Before you push

- `cd functions && npx tsc --noEmit -p tsconfig.json && npx vitest run`
- Flutter has no SDK in the Claude Code environment — CI is the only compiler.
  `Checks` runs `flutter analyze` and `flutter test`; it fails on errors.
- Update **Where things stand** above.
