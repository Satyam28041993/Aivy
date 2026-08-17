# WhatsApp Coexistence Setup Status

## Blocked on Meta, not on this repo (2026-08-17, evening)

Everything on our side is deployed and provably correct. Embedded Signup still
cannot complete because Meta refuses to let this business onboard customers.

**Symptom.** The Embedded Signup popup renders a barrier page reading
*"Prakruti Graphic Pvt Ltd can't onboard customers at the moment"*, then spins
forever. It never returns a WABA, a phone number, or an OAuth code, so the
backend is never even reached.

**What we ruled out, in order:**

| Hypothesis | Verdict |
| --- | --- |
| App Review not approved | ❌ Approved 2026-08-13 (3 permissions, table below) |
| App not in Live mode | ❌ Switched to Live; "Aivy switched to live mode" alert confirms |
| Business not a Tech Provider | ❌ "Verified as a Tech Provider" alert, 2026-07-22 |
| Frontend sending wrong launch options | ❌ `[aivy-es]` logs the exact expected payload |
| Coexistence `featureType` rejected | ❌ `?es=plain` drops it and hits the **same** wall |
| Backend / functions not deployed | ❌ All 25 functions deployed 2026-08-17 18:19 UTC |

The `?es=plain` result is the decisive one: with `featureType` removed the
launch options are plain Embedded Signup, and Meta blocks it identically. The
refusal is therefore business-level, not flavour-level.

**Prime suspects, in the Meta dashboard:**

1. **Tech Provider onboarding is not provisioned.** Under
   App → Use cases → *Connect on WhatsApp* → Customize, the left nav has a
   **Tech Provider onboarding** section that renders completely blank. Being
   verified as a Tech Provider and having Tech Provider onboarding provisioned
   are different things; the blank panel suggests the latter never happened.
2. **Permissions are approved but not published.** In the same Customize view
   `whatsapp_business_management`, `whatsapp_business_messaging` and
   `public_profile` all show status **"Ready to publish"** rather than live.
   `manage_app_solution` sits at "Ready for testing" — it was never granted
   Advanced Access, and Tech Provider flows often require it.

**For a Meta support ticket, quote:** App ID `1138403541782773`, Business ID
`285078384657633`, Embedded Signup config `1353972743598527`. App is Live,
`whatsapp_business_management` + `whatsapp_business_messaging` approved,
business verified as Tech Provider, yet Embedded Signup returns "can't onboard
customers at the moment" for both the coexistence and plain flows, and the
Tech Provider onboarding tab is blank.

**Deployment note.** All of the above is live from branch
`claude/git-pull-aro-fxj5gh`, not from `main` — `main` has none of the WhatsApp
coexistence work. A deploy run from `main` would remove it from production.

## App Review state (2026-08-17)

**App Review is approved.** Meta approved the submission of 2026-08-13 10:28 IST:

| Permission | Status |
| --- | --- |
| `whatsapp_business_management` | ✅ Approved |
| `whatsapp_business_messaging` | ✅ Approved |
| `public_profile` | ✅ Approved |

That clears the blocker recorded in commit `b52a1c1` and in
`docs/whatsapp-embedded-signup-go-live.md` Part B. Approval alone is **not**
enough to fix `36008` — the app must also be switched to **Live** mode
(Part C), which is still pending.

### Remaining steps, in order

1. **Meta dashboard → App Mode → flip to Live.** Approval does not flip it for
   you. While the app is Unpublished, Meta keeps ignoring
   `override_default_response_type` and the code exchange keeps failing 36008.
2. **Confirm `app_config/meta_whatsapp` is seeded** in Firestore —
   `appId`, `embeddedSignupConfigId`, `graphApiVersion`, and the server-side
   `appSecret`. Client config can be seeded with
   `node functions/scripts/seedMetaWhatsappClientConfig.js`
   (needs `META_EMBEDDED_SIGNUP_CONFIG_ID`).
3. **Deploy** functions + hosting so the fixes from `b52a1c1` are live
   (token-derived WABA/phone ids, all three FINISH events, `[aivy-es]` logging).
4. **Test** Connect WhatsApp Business at `https://aivy-5c031.web.app/`.
   Keep the browser console open — the flow logs launch options, every raw
   `postMessage`, and the `FB.login` response under `[aivy-es]`.

### If it still fails after going Live

- `firebase functions:log --only completeWhatsappEmbeddedSignup -n 20` — the
  function surfaces the real Meta message and subcode, not a bare `INTERNAL`.
- Still 36008 → A/B against plain Embedded Signup by opening the app with
  `?es=plain`, which drops the coexistence `featureType`. If plain succeeds and
  coexistence does not, the gap is Tech Provider provisioning, not this code.

## What we did on 2026-07-29

1. **Investigated Error 36008**
   - The app experienced an issue during the final stage of the Meta Embedded Signup flow: `Error validating verification code (subcode 36008)`.
   - We verified that this error strictly requires the Meta App to be in **Live mode** with **Advanced Access** for the `whatsapp_business_management` and `whatsapp_business_messaging` permissions.

2. **Frontend Adjustments & Bug Fixes**
   - Fixed lint issues in `lib/features/home/presentation/aivy_voice_home_screen.dart` (removed unused `BackdropFilter` import and captured `ScaffoldMessenger` before async gaps).
   - Added a bugfix in `lib/features/whatsapp/onboarding/meta_embedded_signup_service_web.dart` to ensure that the Flutter app properly waits for the Embedded Signup window to send the `FINISH_WHATSAPP_BUSINESS_APP_ONBOARDING` event before completing the flow. This guarantees the `wabaId` is captured and passed to the backend, fixing the `wabaId is required after Embedded Signup` error.
   - (Temporarily tried switching to the Implicit Token flow to bypass Advanced Access, but this breaks the Embedded Signup UI, so we successfully reverted it back to the proper OAuth Code flow).
   - Deployed the latest fixes to Firebase Hosting.

3. **Meta App Dashboard Setup**
   - Initiated an App Review submission on the Meta Developer Dashboard for the required Advanced Access permissions.
   - Completed the "Allowed usage" sections for `whatsapp_business_messaging`, `manage_app_solution`, `public_profile`, and `whatsapp_business_management`.
   - Completed the "Data handling" section.
   - Added "Reviewer instructions" explaining how to test the app and documenting the current `36008` blockage.

## Plan as it stood on 2026-07-29 (historical — steps 1 and 2 are now done)

1. **Submit the App Review**
   - If you haven't clicked it already, make sure to click the blue **Submit for review** button at the bottom of the Meta App Review submissions page.

2. **Wait for Meta's Approval**
   - Meta will take anywhere from a few hours to a few days to review your request.
   - Check your Meta Developer Alert Inbox and email for updates.

3. **Switch to Live Mode**
   - Once Meta approves the permissions, go to the top bar of your Meta App Dashboard and toggle the App Mode from **Development** to **Live**.

4. **Test the Connection**
   - Open your deployed app at `https://aivy-5c031.web.app/`.
   - Click **Connect WhatsApp Business**.
   - Complete the Meta popup flow.
   - The connection should now succeed and save without throwing the `36008` error.

Once the WhatsApp account is successfully linked, you can proceed with testing incoming/outgoing messages alongside your CRM logic!
