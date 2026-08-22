import { getFirestore } from "firebase-admin/firestore";
import { readWhatsappConnectionMetadata } from "../onboarding/connectionStore";
import { readLegacyWhatsAppConfig } from "./legacyProvider";
import { parseOutboundTemplateFields } from "./templateConfig";

export async function migrateLegacyOutboundTemplatesToConnection(
  ownerUid: string,
): Promise<{
  migrated: boolean;
  ownerUid: string;
  templates: ReturnType<typeof parseOutboundTemplateFields>;
}> {
  const uid = String(ownerUid ?? "").trim();
  if (!uid) {
    throw new Error("ownerUid is required");
  }

  const connection = await readWhatsappConnectionMetadata(uid);
  if (!connection) {
    throw new Error(`No coexistence connection for ownerUid ${uid}`);
  }

  const existing = parseOutboundTemplateFields(connection as unknown as Record<string, unknown>);
  if (existing.outboundTemplateName) {
    return { migrated: false, ownerUid: uid, templates: existing };
  }

  const legacy = await readLegacyWhatsAppConfig();
  if (!legacy?.outboundTemplateName) {
    return { migrated: false, ownerUid: uid, templates: existing };
  }

  const templates = parseOutboundTemplateFields(legacy.raw);
  await getFirestore()
    .collection("users")
    .doc(uid)
    .collection("meta")
    .doc("whatsapp_connection")
    .set(
      {
        outboundTemplateName: templates.outboundTemplateName,
        outboundTemplateLanguage: templates.outboundTemplateLanguage,
        outboundTemplateBodyParamCount: templates.outboundTemplateBodyParamCount,
        templatesMigratedFromLegacyAtMs: Date.now(),
      },
      { merge: true },
    );

  return { migrated: true, ownerUid: uid, templates };
}
