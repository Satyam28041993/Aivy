# AGENTS.md

## Cursor Cloud specific instructions

Aivy is a **Flutter** app (root: `lib/`, targets Android + Flutter Web) with a
**Firebase Cloud Functions** backend (`functions/`, TypeScript, Node 22). The
client talks to a live Firebase project (`aivy-5c031`); there is no Firebase
emulator config in `firebase.json`.

### Toolchain (already provisioned in the VM snapshot)
- Flutter SDK (stable) is installed at `~/flutter` and added to `PATH` via
  `~/.bashrc`. If `flutter` is not found in a non-interactive shell, use the
  absolute path `~/flutter/bin/flutter`.
- Node 22 (via nvm) and Java 21 are preinstalled. The update script runs
  `npm install` in `functions/` and `flutter pub get` at the root.

### Lint / test / build / run
- Backend (`functions/`): `npm run build` (tsc), `npm test` (Vitest, tests are
  colocated `*.test.ts` in `src/`). See `functions/package.json` for all scripts.
- Flutter app (root): `flutter analyze` (lint — currently reports pre-existing
  info/warning issues but no errors), `flutter test`.
- Run the app in dev mode for web: `flutter run -d web-server --web-port 8080
  --web-hostname 0.0.0.0` (the web-server device compiles on first request, so
  the first page load takes ~15-60s). A Chrome device is also available via
  `flutter run -d chrome`.

### Non-obvious gotchas
- **Auth requires Google OAuth.** The README mentions "anonymous auth", but the
  current code (`lib/core/auth/aivy_auth_controller.dart`) explicitly signs out
  anonymous users. The only sign-in path is "Continue with Google", so
  exercising any signed-in flow (chat, dashboard, reminders, payments) needs a
  real Google account. There is no test/demo bypass.
- **Backend secrets are not in the repo.** `GEMINI_API_KEY` (core AI, note: code
  uses Google Gemini, not OpenAI despite the README) and optional integration
  keys live in Firebase Secret Manager / `functions/.env` (gitignored). Vitest
  tests do not need them, but deploying/running functions live does.
- The app points at the live cloud project (no emulator), so deploying functions
  or writing Firestore requires Firebase credentials that are not present by
  default.

### Exercising the live backend without Google OAuth
Because the UI is Google-OAuth-only, the fastest way to test the deployed
`aivyProcess` (and other callables) end-to-end is to mint an **anonymous**
Firebase ID token directly (anonymous sign-in is enabled on the project even
though the app signs anonymous users out), then call the callable over HTTPS:

```bash
API_KEY="AIzaSyD9kg-3Q5Etl9GQ_EJqvw2MQvyogCDeCqw"   # public web key (firebase_options.dart)
ID_TOKEN=$(curl -s -X POST \
  "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$API_KEY" \
  -H "Content-Type: application/json" -d '{"returnSecureToken":true}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['idToken'])")

curl -s -X POST "https://us-central1-aivy-5c031.cloudfunctions.net/aivyProcess" \
  -H "Authorization: Bearer $ID_TOKEN" -H "Content-Type: application/json" \
  -d '{"data":{"text":"Remind me to call Sam tomorrow at 5pm","timezone":"UTC","nowIso":"2026-01-01T00:00:00.000Z"}}'
```

The callable request body must be wrapped in `{"data":{...}}` and the response
comes back as `{"result":{...}}`. `aivyProcess` only checks that a request is
authenticated (`request.auth`), so an anonymous token is sufficient. This hits
live Gemini + Firestore under a throwaway anonymous uid.
