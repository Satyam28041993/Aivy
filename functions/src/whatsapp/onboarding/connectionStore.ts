import { FieldValue, getFirestore } from "firebase-admin/firestore";
import type { WhatsappConnectionMetadata } from "./types";
import { parseOutboundTemplateFields } from "../credentials/templateConfig";

export async function writeWhatsappConnectionMetadata(opts: {
  ownerUid: string;
  wabaId: string;
  phoneNumberId: string;
  displayPhoneNumber: string;
  tokenSecretRef: string;
  connectionStatus?: string;
  historySyncStatus?: string;
  outboundTemplateName?: string;
  outboundTemplateLanguage?: string;
  outboundTemplateBodyParamCount?: number;
  contactsOwnerUid?: string;
}): Promise<WhatsappConnectionMetadata> {
  const ownerUid = String(opts.ownerUid ?? "").trim();
  const wabaId = String(opts.wabaId ?? "").trim();
  const phoneNumberId = String(opts.phoneNumberId ?? "").trim();
  const displayPhoneNumber = String(opts.displayPhoneNumber ?? "").trim();
  const tokenSecretRef = String(opts.tokenSecretRef ?? "").trim();

  if (!ownerUid) {
    throw new Error("ownerUid is required");
  }
  if (!wabaId) {
    throw new Error("wabaId is required");
  }
  if (!phoneNumberId) {
    throw new Error("phoneNumberId is required");
  }
  if (!tokenSecretRef) {
    throw new Error("tokenSecretRef is required");
  }

  const nowMs = Date.now();
  const templates = parseOutboundTemplateFields({
    outboundTemplateName: opts.outboundTemplateName,
    outboundTemplateLanguage: opts.outboundTemplateLanguage,
    outboundTemplateBodyParamCount: opts.outboundTemplateBodyParamCount,
  });
  const contactsOwnerUid =
    String(opts.contactsOwnerUid ?? ownerUid).trim() || ownerUid;
  const metadata: WhatsappConnectionMetadata = {
    ownerUid,
    wabaId,
    phoneNumberId,
    displayPhoneNumber,
    connectionStatus: opts.connectionStatus ?? "connected",
    historySyncStatus: opts.historySyncStatus ?? "pending",
    coexistenceEnabled: true,
    tokenSecretRef,
    onboardedAtMs: nowMs,
    outboundTemplateName: templates.outboundTemplateName,
    outboundTemplateLanguage: templates.outboundTemplateLanguage,
    outboundTemplateBodyParamCount: templates.outboundTemplateBodyParamCount,
    contactsOwnerUid,
  };

  await getFirestore()
    .collection("users")
    .doc(ownerUid)
    .collection("meta")
    .doc("whatsapp_connection")
    .set(
      {
        ...metadata,
        onboardedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
        updatedAtMs: nowMs,
      },
      { merge: true },
    );

  return metadata;
}

export async function readWhatsappConnectionMetadata(
  ownerUid: string,
): Promise<WhatsappConnectionMetadata | null> {
  const uid = String(ownerUid ?? "").trim();
  if (!uid) {
    return null;
  }
  const snap = await getFirestore()
    .collection("users")
    .doc(uid)
    .collection("meta")
    .doc("whatsapp_connection")
    .get();
  if (!snap.exists) {
    return null;
  }
  const data = (snap.data() ?? {}) as Record<string, unknown>;
  const templates = parseOutboundTemplateFields(data);
  return {
    ownerUid: uid,
    wabaId: String(data.wabaId ?? "").trim(),
    phoneNumberId: String(data.phoneNumberId ?? "").trim(),
    displayPhoneNumber: String(data.displayPhoneNumber ?? "").trim(),
    connectionStatus: String(data.connectionStatus ?? "").trim(),
    historySyncStatus: String(data.historySyncStatus ?? "").trim(),
    coexistenceEnabled: data.coexistenceEnabled === true,
    tokenSecretRef: String(data.tokenSecretRef ?? "").trim(),
    onboardedAtMs:
      typeof data.onboardedAtMs === "number"
        ? data.onboardedAtMs
        : Number(data.onboardedAtMs ?? 0) || 0,
    outboundTemplateName: templates.outboundTemplateName,
    outboundTemplateLanguage: templates.outboundTemplateLanguage,
    outboundTemplateBodyParamCount: templates.outboundTemplateBodyParamCount,
    contactsOwnerUid:
      String(data.contactsOwnerUid ?? uid).trim() || uid,
  };
}
