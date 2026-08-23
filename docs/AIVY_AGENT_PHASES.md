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
| 2 | Store layer | `draftStore.ts`, `clientResolve.ts` | vitest (pure logic) | ⬜ |
| 3 | Write tools | 7 tools → drafts | vitest — draft shape == existing Firestore shape | ⬜ |
| 4 | Read tools | 6 tools | vitest — window math, row shaping | ⬜ |
| 5 | Agent loop | tool registry + Gemini function-calling loop | vitest — loop with a fake model | ⬜ |
| 6 | Callables | `aivyAgent`, `aivyAgentCommit` + index wiring | `npm run build` + vitest | ⬜ |
| 7 | Flutter data | models, repository, service | analyzer-safe code (run locally) | ⬜ |
| 8 | Flutter UI | screen, bubbles, action card, history drawer | as above | ⬜ |
| 9 | Wiring | HomeShell tab | as above | ⬜ |
| 10 | Final pass | poora build + test + Q&A walkthrough | sab | ⬜ |

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
