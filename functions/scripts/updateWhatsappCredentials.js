/**
 * One-time script to update WhatsApp credentials in Firestore app_config/whatsapp.
 *
 * Run:
 *   node functions/scripts/updateWhatsappCredentials.js
 *
 * Requires: GOOGLE_APPLICATION_CREDENTIALS env var pointing to your service
 * account JSON, OR run inside the Firebase project directory with application
 * default credentials already set via `firebase login`.
 */

const { initializeApp, cert, getApps } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

// ── Credentials ──────────────────────────────────────────────────────────────
const CREDENTIALS = {
  token:
    "EAAQLXzq4EPUBRVQZAhyyqtuWeZAtHoyv2TZAWUiuZByZAMePKJQC0fbQwj53RgbVBi601m0wClvYvBOA1GNIdbWiZCGp5AGTVukYZCYepS5dnZA1KJlQG1UFEACcPX2DTU7SjnKZAxUBZCFZA5Npx8n106VsZCFIBAo2qJ9zvEH8s9FYMQRK8iMB13xZC7DdJnrLhu2DnpwZDZD",
  phoneId: "1037088162831263",
  businessAccountId: "2245517982946337",
  appId: "1138403541782773",
  webhookVerifyToken: "aivy_verify_2026",
  // Fill this in from Meta App Dashboard → App Settings → App Secret
  appSecret: "",
};
// ─────────────────────────────────────────────────────────────────────────────

if (getApps().length === 0) {
  initializeApp({ projectId: "aivy-5c031" });
}

async function main() {
  const db = getFirestore();
  const ref = db.collection("app_config").doc("whatsapp");
  await ref.set(
    {
      ...CREDENTIALS,
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
  console.log("✅  app_config/whatsapp updated successfully.");
  process.exit(0);
}

main().catch((err) => {
  console.error("❌  Failed:", err);
  process.exit(1);
});
