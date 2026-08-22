/**
 * Seeds public Meta WhatsApp client config for Embedded Signup.
 *
 * Run:
 *   node functions/scripts/seedMetaWhatsappClientConfig.js
 *
 * Does NOT touch legacy app_config/whatsapp.
 */

const { initializeApp, getApps } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

const CONFIG = {
  appId: process.env.META_APP_ID ?? "1138403541782773",
  embeddedSignupConfigId: process.env.META_EMBEDDED_SIGNUP_CONFIG_ID ?? "",
  graphApiVersion: process.env.META_GRAPH_API_VERSION ?? "v21.0",
};

if (getApps().length === 0) {
  initializeApp({ projectId: "aivy-5c031" });
}

async function main() {
  if (!CONFIG.embeddedSignupConfigId) {
    console.error(
      "Set META_EMBEDDED_SIGNUP_CONFIG_ID before running this script.",
    );
    process.exit(1);
  }

  const db = getFirestore();
  await db.collection("app_config").doc("meta_whatsapp").set(
    {
      ...CONFIG,
      updatedAt: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
  console.log("✅  app_config/meta_whatsapp updated (public client config only).");
  process.exit(0);
}

main().catch((err) => {
  console.error("❌  Failed:", err);
  process.exit(1);
});
