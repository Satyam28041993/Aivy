/**
 * Copies outbound template fields from legacy app_config/whatsapp into
 * users/{ownerUid}/meta/whatsapp_connection when the connection doc has none.
 *
 * Usage:
 *   node functions/scripts/migrateWhatsappTemplateConfig.js <ownerUid>
 *
 * Does NOT delete or modify legacy app_config/whatsapp.
 */
const admin = require("firebase-admin");

if (!admin.apps.length) {
  admin.initializeApp();
}

async function main() {
  const ownerUid = String(process.argv[2] ?? "").trim();
  if (!ownerUid) {
    console.error("Usage: node functions/scripts/migrateWhatsappTemplateConfig.js <ownerUid>");
    process.exit(1);
  }

  const { migrateLegacyOutboundTemplatesToConnection } = require("../lib/whatsapp/credentials/templateMigration.js");
  const result = await migrateLegacyOutboundTemplatesToConnection(ownerUid);
  console.log(JSON.stringify(result, null, 2));
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
