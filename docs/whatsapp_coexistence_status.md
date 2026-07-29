# WhatsApp Coexistence Setup Status

## What we did today (2026-07-29)

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

## What you need to do next

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
