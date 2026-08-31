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
be thrown away. Archived at commit `ae5e88e`, branch
`cursor/chat-projects-no-voice-5a06` — delete that branch, do not merge it.

## The traps in this repo

Each of these cost real time. They are here so they cost it once.

**Deploying without the server.** `Deploy Web` has a `deploy_functions` input.
It now defaults to true, but if you dispatch the workflow by API, pass it
explicitly. A run that skips the functions still reports success, because a
skipped step is not a failed one — so hosting updates, the server does not, and
nothing says so.

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

**Firestore rejects `undefined`.** Not "ignores" — rejects, and the write throws.
Omit the key instead. `stripUndefined` in `chatStore.ts` guards the chat path;
nothing guards the others.

**Gmail is Android-only.** The server holds no Google refresh token — only the
access token the app forwards with a request. So nothing on a schedule can read
Gmail, and the web build cannot read it at all. The morning brief is built when
the app opens for this reason, not because a cron would have been harder.

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
- **Reminders** are the one delivery path. Anything with a date should become a
  reminder rather than growing a second mechanism: the phone alarm and the
  server push both already work off them.
- **Language**: the app and Aivy's replies are English. The user writes Hinglish.
  The morning brief's news and Google Alerts sections are Hindi, deliberately.

## Where things stand

_Last updated: after tasks, the detail sheet, and reordering the brief._

**Working and tested in the live app**

- Reminders — created by talking, alarm on the phone, push with the app closed
- Morning brief on Today — mail, news (Hindi), Google Alerts by term (Hindi),
  today's commitments; built once a day on open, pull-to-refresh rebuilds
- Occasions — birthdays and anniversaries, warned 15/10/5/1 days ahead and on
  the day, every year
- Saved places, Maps search and directions, live location
- Google: Calendar, Gmail, Sheets, Contacts — Android only
- Dashboard and Records, dark throughout

**Just built, not yet exercised by the user**

- **Projects** (`functions/src/agent/projectStore.ts`, `tools/projectTools.ts`).
  A project holds whatever that job needs — no fixed pipeline, because every job
  is shaped differently. Items carry a kind, a date and a status, and
  `waiting_on_them` is a first-class state: half this trade is waiting on a
  client, and calling that "pending" makes both the feeling and the answer wrong.
  Dated items become reminders. Works entirely through chat.
- **Tasks** — the small and medium work, business or personal: a deck a director
  wants in two days, a film to book with his wife. Same collection as projects
  under `kind: "task"`, so every reader, reminder and status answer written for
  projects works on them unchanged; a second collection would have meant writing
  all of it twice. `create_task` saves the whole thing from one sentence — name,
  who it is for, deadline, steps — on one card, because splitting that into
  create-then-add is how a feature stops being used. A deadline gets its own
  reminder plus a halfway check-in, and marking a step done or closing a task
  early **cancels its reminders** (`agent/reminderCancel.ts`) — a task that keeps
  ringing after it is finished teaches him to ignore the ones that matter.
- **The brief reads in the order a morning is used**: tasks, projects, today,
  mail, news, alerts. It used to run mail-first, which put what he owes his
  director below twenty lines of Hindi alert digest. Above it all, one counted
  line — "2 late · 1 due today · 12 alert topics" — so it answers before it is
  read. Sections fold, and the choice is remembered (`shared_preferences`), but
  **not all folded by default**: a brief that opens shut costs six taps to read
  one morning. The four that ask something of you open; news and alerts start
  folded with their count on the header, because folded and broken look
  identical without it.
- **Work in the morning brief** — "Your tasks" and "Projects" sections, late
  first, red for late and amber for due. Built straight from Firestore and
  appended *after* the model has written the rest: these are counts and dates
  that are already right, and two sections have been lost before to model output
  arriving in a shape the parser did not expect.
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

- **There is still no browse list.** The detail sheet opens one project or task
  from the brief, so anything not in today's brief — closed work, a project with
  nothing due — cannot be reached at all. Next: one screen in Records with both,
  tasks by deadline on top, projects below, opening the same sheet. Keep it
  browse-only; creating and editing must stay in chat or the same data ends up
  half-written two different ways.
- **History starts from now.** Projects and tasks created before this have no
  events, and the sheet says so rather than showing an empty box.
- **Repeating reminders are not real.** "Every month on the 5th" sets one
  reminder. The card says so honestly rather than pretending. A task with no
  deadline has the same shape of gap: it saves, but nothing ever rings for it,
  so it only surfaces in the brief's list.
- `functions/src/morning/money.ts` is **parked, not dead**. Bank and UPI parsing
  with tests, removed from the brief at the user's request until the shape is
  settled. Do not delete it; it is coming back.
- `claude/git-pull-aro-fxj5gh` diverges from the active branch and will conflict.

## Before you push

- `cd functions && npx tsc --noEmit -p tsconfig.json && npx vitest run`
- Flutter has no SDK in the Claude Code environment — CI is the only compiler.
  `Checks` runs `flutter analyze` and `flutter test`; it fails on errors.
- Update **Where things stand** above.
