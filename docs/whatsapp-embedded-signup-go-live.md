# WhatsApp Embedded Signup — Fixing error_subcode 36008 (Go-Live Guide)

## Symptom
On the app's **Connect WhatsApp Business** screen, clicking **Connect** opens the Meta
Embedded Signup popup, returns an OAuth `code`, but the backend callable
`completeWhatsappEmbeddedSignup` fails. The Flutter UI shows `Exception: INTERNAL`
and the browser console shows a `500` on `.../completeWhatsappEmbeddedSignup`.

## Confirmed root cause
The Graph API code exchange consistently returns:

```
code 100, error_subcode 36008
"Error validating verification code. Please make sure your redirect_uri is
 identical to the one you used in the OAuth dialog request"
```

We verified (live, 2026-07-27) that **none** of these are the problem:
- App Secret is correct for App ID `1138403541782773` (client_credentials probe → valid, app "Aivy").
- Embedded Signup `config_id` `1346057313766028` belongs to the same app.
- The OAuth dialog is textbook-correct: `response_type=code` and
  `override_default_response_type=true` **do** reach Facebook.
- The exchange fails with **every** redirect_uri variant (omit / empty / page URL /
  origin with & without trailing slash) — so redirect_uri matching is NOT the issue.

Because the exchange fails even when `override_default_response_type=true` is sent,
**Meta is not honouring the server-side (redirect-free) code grant** — the code stays
bound to the JS SDK's internal `xd_arbiter` redirect (a per-session URL the server can
never replicate). Meta silently ignores `override_default_response_type` when the app is
**not yet fully provisioned** for the WhatsApp coexistence server-side token flow.

The Meta app "Aivy" is currently **Unpublished (Development mode)** and **"Currently
ineligible for submission"** (missing App icon, Privacy Policy URL, Category). That is the
blocker.

---

## Fix — provision the app, then go Live

> Business Verification is already ✅ done for this Business Manager. The steps below are
> the remaining requirements. Do them in order.

### Part A — Complete Basic Settings (removes "ineligible")
Meta dashboard → **App settings → Basic**
1. **App Icon** — upload a 1024×1024 PNG.
2. **Privacy Policy URL** — a public URL (e.g. `https://aivy-5c031.web.app/privacy`).
   Publish a simple privacy policy page there first if you don't have one.
3. **Category** — pick the closest match (e.g. *Business and Pages* / *Productivity*).
4. **App Domains** — confirm `aivy-5c031.web.app` is present (it already is).
5. Click **Save changes**.

### Part B — Get Advanced Access for the WhatsApp permissions ✅ DONE (approved 2026-08-13)

> Approved: `whatsapp_business_management`, `whatsapp_business_messaging`,
> `public_profile`. Part C (Live mode) is the remaining blocker — see
> `docs/whatsapp_coexistence_status.md`.

Meta dashboard → **App Review → Permissions and Features**
(or **Review → App Review**, then the *Allowed usage* section)
1. Find **`whatsapp_business_management`** → click **Request Advanced Access**.
2. Find **`whatsapp_business_messaging`** → click **Request Advanced Access**.
3. Business Verification shows ✅ (green) — nothing to do there.
4. If a form asks *how you use the permission*, describe: *"Onboard our own WhatsApp
   Business number via Embedded Signup (coexistence) to send/receive messages in our
   CRM."* Add screencast/notes if requested.

> Advanced Access for these two permissions is what lets Meta issue a **server-side
> (redirect-free) code**, which is exactly what fixes the 36008 error.

### Part C — Switch the app to Live
Top bar of the dashboard → the **App Mode** toggle currently shows **"Unpublished"**.
1. Once Part A is complete, the toggle becomes usable.
2. Flip it to **Live**.
3. Confirm any prompts.

### Part D — Verify
1. Reload the app's **Connect WhatsApp Business** page.
2. Click **Connect**, complete the popup (select WABA + phone number).
3. It should now save the connection (no `INTERNAL` / 500).

If it still fails, check the backend logs — the function now surfaces the **real** Meta
error and subcode (instead of a generic `INTERNAL`):

```bash
firebase functions:log --only completeWhatsappEmbeddedSignup -n 20
```

---

## Backend behaviour change (this commit)
`functions/src/whatsapp/onboarding/exchangeCode.ts` now:
- Performs a single, spec-compliant code exchange **without** `redirect_uri`
  (per Meta Embedded Signup with `override_default_response_type`).
- Throws an `HttpsError` carrying the **actual Meta error message + subcode** so the
  Flutter client and console show a useful message instead of `INTERNAL`.
- For subcode `36008`, the error message points here.

## Code-side fallback (only if Part A–C don't resolve it)
If the app is Live with Advanced Access and 36008 still occurs, replace the `FB.login`
popup with an explicit **redirect-based OAuth flow** where we control the `redirect_uri`
(a Valid OAuth Redirect URI, e.g. `https://aivy-5c031.web.app/`), then fetch the shared
WABAs via the Graph API using the returned business token (instead of relying on the
popup's `postMessage`). Relevant files:
- `lib/features/whatsapp/onboarding/meta_embedded_signup_launch_config.dart`
- `lib/features/whatsapp/onboarding/meta_embedded_signup_service_web.dart`
