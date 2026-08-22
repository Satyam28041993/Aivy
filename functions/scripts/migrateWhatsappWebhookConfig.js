/**
 * Copies webhookVerifyToken, appSecret, and defaultContactsOwnerUid from
 * legacy app_config/whatsapp into app_config/meta_whatsapp.
 *
 * Usage:
 *   node functions/scripts/migrateWhatsappWebhookConfig.js
 *
 * Does NOT delete legacy app_config/whatsapp.
 */
const admin = require("firebase-admin");

if (!admin.apps.length) {
  admin.initializeApp();
}

async function main() {
  const db = admin.firestore();
  const legacySnap = await db.collection("app_config").doc("whatsapp").get();
  const legacy = legacySnap.data() ?? {};

  const patch = {
    webhookVerifyToken: String(
      legacy.webhookVerifyToken ?? process.env.WHATSAPP_WEBHOOK_VERIFY_TOKEN ?? "",
    ).trim(),
    appSecret: String(
      legacy.appSecret ?? process.env.WHATSAPP_APP_SECRET ?? "",
    ).trim(),
    defaultContactsOwnerUid: String(
      legacy.contactsOwnerUid ?? process.env.CONTACTS_AUTO_OWNER_UID ?? "",
    ).trim(),
    migratedFromLegacyAt: admin.firestore.FieldValue.serverTimestamp(),
  };

  await db.collection("app_config").doc("meta_whatsapp").set(patch, { merge: true });
  console.log(JSON.stringify({ migrated: true, fields: Object.keys(patch) }, null, 2));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
