import { getFirestore } from "firebase-admin/firestore";

import { HttpsError } from "firebase-functions/v2/https";

import { readLegacyWebhookSecrets } from "./credentials/legacyProvider";

import { readMetaWhatsappWebhookConfig } from "./onboarding/clientConfig";

import type { WhatsAppRuntimeConfig } from "./types";



export async function readWhatsAppRuntimeConfig(): Promise<WhatsAppRuntimeConfig> {

  const meta = await readMetaWhatsappWebhookConfig();

  let webhookVerifyToken = meta.webhookVerifyToken;

  let appSecret = meta.appSecret;



  if (!webhookVerifyToken || !appSecret) {

    const legacy = await readLegacyWebhookSecrets();

    webhookVerifyToken = webhookVerifyToken || legacy.webhookVerifyToken;

    appSecret = appSecret || legacy.appSecret;

  }



  if (!webhookVerifyToken) {

    throw new HttpsError(

      "failed-precondition",

      "webhookVerifyToken missing in app_config/meta_whatsapp",

    );

  }

  if (!appSecret) {

    throw new HttpsError(

      "failed-precondition",

      "appSecret missing in app_config/meta_whatsapp",

    );

  }

  return { webhookVerifyToken, appSecret };

}



export async function readWhatsAppVerifyTokenOnly(): Promise<string> {

  const meta = await readMetaWhatsappWebhookConfig();

  let token = meta.webhookVerifyToken;

  if (!token) {

    const legacy = await readLegacyWebhookSecrets();

    token = legacy.webhookVerifyToken;

  }

  if (!token) {

    throw new HttpsError(

      "failed-precondition",

      "webhookVerifyToken missing in app_config/meta_whatsapp",

    );

  }

  return token;

}


