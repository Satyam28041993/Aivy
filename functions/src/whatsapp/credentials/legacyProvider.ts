import { getFirestore } from "firebase-admin/firestore";
import type { LegacyWhatsAppConfig } from "./types";

async function readLegacyWhatsAppDoc(): Promise<Record<string, unknown>> {
  const snap = await getFirestore().collection("app_config").doc("whatsapp").get();
  if (!snap.exists) {
    return {};
  }
  return (snap.data() ?? {}) as Record<string, unknown>;
}

export async function readLegacyWebhookSecrets(): Promise<{
  webhookVerifyToken: string;
  appSecret: string;
}> {
  const data = await readLegacyWhatsAppDoc();
  return {
    webhookVerifyToken: String(
      data.webhookVerifyToken ?? process.env.WHATSAPP_WEBHOOK_VERIFY_TOKEN ?? "",
    ).trim(),
    appSecret: String(
      data.appSecret ?? process.env.WHATSAPP_APP_SECRET ?? "",
    ).trim(),
  };
}

export async function readLegacyContactsOwnerUid(): Promise<string | null> {
  const data = await readLegacyWhatsAppDoc();
  const uid = String(data.contactsOwnerUid ?? "").trim();
  return uid.length > 8 ? uid : null;
}

export async function readLegacyOutboundTemplates(): Promise<{
  outboundTemplateName: string;
  outboundTemplateLanguage: string;
  outboundTemplateBodyParamCount: number;
}> {
  const data = await readLegacyWhatsAppDoc();
  let paramCount = Number(data.outboundTemplateBodyParamCount);
  if (!Number.isFinite(paramCount)) {
    paramCount = 0;
  }
  return {
    outboundTemplateName: String(data.outboundTemplateName ?? "").trim(),
    outboundTemplateLanguage:
      String(data.outboundTemplateLanguage ?? "en").trim() || "en",
    outboundTemplateBodyParamCount: Math.min(3, Math.max(0, Math.floor(paramCount))),
  };
}

export async function readLegacyWhatsAppConfig(): Promise<LegacyWhatsAppConfig | null> {
  const data = await readLegacyWhatsAppDoc();
  if (Object.keys(data).length === 0) {
    const token = String(process.env.WHATSAPP_TOKEN ?? "").trim();
    const phoneId = String(process.env.WHATSAPP_PHONE_ID ?? "").trim();
    if (!token || !phoneId) {
      return null;
    }
    return {
      token,
      phoneId,
      outboundTemplateName: "",
      outboundTemplateLanguage: "en",
      outboundTemplateBodyParamCount: 0,
      contactsOwnerUid: String(process.env.CONTACTS_AUTO_OWNER_UID ?? "").trim() || null,
      raw: {},
    };
  }

  const token = String(data.token ?? process.env.WHATSAPP_TOKEN ?? "").trim();
  const phoneId = String(data.phoneId ?? process.env.WHATSAPP_PHONE_ID ?? "").trim();
  if (!token || !phoneId) {
    return null;
  }

  const templates = await readLegacyOutboundTemplates();

  return {
    token,
    phoneId,
    outboundTemplateName: templates.outboundTemplateName,
    outboundTemplateLanguage: templates.outboundTemplateLanguage,
    outboundTemplateBodyParamCount: templates.outboundTemplateBodyParamCount,
    contactsOwnerUid: String(data.contactsOwnerUid ?? "").trim() || null,
    raw: data,
  };
}
