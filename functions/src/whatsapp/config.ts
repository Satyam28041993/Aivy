import { getFirestore } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import type { WhatsAppRuntimeConfig } from "./types";

async function readRawConfigDoc(): Promise<Record<string, unknown>> {
  const snap = await getFirestore()
    .collection("app_config")
    .doc("whatsapp")
    .get();
  if (!snap.exists) {
    return {};
  }
  return (snap.data() ?? {}) as Record<string, unknown>;
}

export async function readWhatsAppRuntimeConfig(): Promise<WhatsAppRuntimeConfig> {
  const data = await readRawConfigDoc();
  const webhookVerifyToken = String(
    data.webhookVerifyToken ?? process.env.WHATSAPP_WEBHOOK_VERIFY_TOKEN ?? "",
  ).trim();
  const appSecret = String(
    data.appSecret ?? process.env.WHATSAPP_APP_SECRET ?? "",
  ).trim();
  if (!webhookVerifyToken) {
    throw new HttpsError(
      "failed-precondition",
      "webhookVerifyToken missing in app_config/whatsapp",
    );
  }
  if (!appSecret) {
    throw new HttpsError(
      "failed-precondition",
      "appSecret missing in app_config/whatsapp",
    );
  }
  return { webhookVerifyToken, appSecret };
}

export async function readWhatsAppVerifyTokenOnly(): Promise<string> {
  const data = await readRawConfigDoc();
  const token = String(
    data.webhookVerifyToken ?? process.env.WHATSAPP_WEBHOOK_VERIFY_TOKEN ?? "",
  ).trim();
  if (!token) {
    throw new HttpsError(
      "failed-precondition",
      "webhookVerifyToken missing in app_config/whatsapp",
    );
  }
  return token;
}
