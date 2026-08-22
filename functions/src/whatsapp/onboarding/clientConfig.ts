import { getFirestore } from "firebase-admin/firestore";

import type { MetaWhatsappClientConfig } from "./types";



const DEFAULT_GRAPH_VERSION = "v21.0";



export async function readMetaWhatsappClientConfig(): Promise<MetaWhatsappClientConfig> {

  const snap = await getFirestore()

    .collection("app_config")

    .doc("meta_whatsapp")

    .get();

  const data = (snap.data() ?? {}) as Record<string, unknown>;

  return {

    appId: String(data.appId ?? process.env.META_APP_ID ?? "").trim(),

    embeddedSignupConfigId: String(

      data.embeddedSignupConfigId ?? process.env.META_EMBEDDED_SIGNUP_CONFIG_ID ?? "",

    ).trim(),

    graphApiVersion: String(

      data.graphApiVersion ?? process.env.META_GRAPH_API_VERSION ?? DEFAULT_GRAPH_VERSION,

    ).trim() || DEFAULT_GRAPH_VERSION,

    webhookVerifyToken: String(

      data.webhookVerifyToken ?? process.env.WHATSAPP_WEBHOOK_VERIFY_TOKEN ?? "",

    ).trim(),

    appSecret: String(

      data.appSecret ?? process.env.WHATSAPP_APP_SECRET ?? process.env.META_APP_SECRET ?? "",

    ).trim(),

    defaultContactsOwnerUid: String(

      data.defaultContactsOwnerUid ?? process.env.CONTACTS_AUTO_OWNER_UID ?? "",

    ).trim(),

  };

}



export async function readMetaAppId(): Promise<string> {

  const cfg = await readMetaWhatsappClientConfig();

  return cfg.appId;

}



export async function readMetaWhatsappWebhookConfig(): Promise<{

  webhookVerifyToken: string;

  appSecret: string;

}> {

  const cfg = await readMetaWhatsappClientConfig();

  return {

    webhookVerifyToken: cfg.webhookVerifyToken,

    appSecret: cfg.appSecret,

  };

}


