import { logger } from "firebase-functions";
import { defineSecret } from "firebase-functions/params";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { readLegacyContactsOwnerUid, readLegacyOutboundTemplates } from "../credentials/legacyProvider";
import { readMetaWhatsappClientConfig } from "./clientConfig";
import { writeWhatsappConnectionMetadata } from "./connectionStore";
import {
  exchangeEmbeddedSignupCode,
  fetchDisplayPhoneNumber,
} from "./exchangeCode";
import { storeBusinessTokenSecret } from "./tokenStorage";

const metaAppSecret = defineSecret("META_APP_SECRET");

export const getMetaWhatsappClientConfig = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Authentication required");
    }
    const cfg = await readMetaWhatsappClientConfig();
    if (!cfg.appId || !cfg.embeddedSignupConfigId) {
      throw new HttpsError(
        "failed-precondition",
        "Meta WhatsApp client config is incomplete. Set app_config/meta_whatsapp.",
      );
    }
    return cfg;
  },
);

export const completeWhatsappEmbeddedSignup = onCall(
  {
    region: "us-central1",
    secrets: [metaAppSecret],
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Authentication required");
    }

    const uid = String(request.auth.uid ?? "").trim();
    const body =
      typeof request.data === "object" && request.data !== null
        ? (request.data as Record<string, unknown>)
        : {};

    const code = String(body.code ?? "").trim();
    const redirectUri = typeof body.redirectUri === "string" ? body.redirectUri.trim() : undefined;
    let wabaId = String(body.wabaId ?? body.waba_id ?? "").trim();
    let phoneNumberId = String(body.phoneNumberId ?? body.phone_number_id ?? "").trim();
    let displayPhoneNumber = String(
      body.displayPhoneNumber ?? body.display_phone_number ?? "",
    ).trim();

    if (!code) {
      throw new HttpsError("invalid-argument", "code is required");
    }

    if (redirectUri) {
      try {
        const parsedUrl = new URL(redirectUri);
        const isLocalhost = parsedUrl.hostname === "localhost" || parsedUrl.hostname === "127.0.0.1";
        if (parsedUrl.protocol !== "https:" && !(parsedUrl.protocol === "http:" && isLocalhost)) {
          throw new Error("Invalid redirect URI protocol");
        }
      } catch (e) {
        throw new HttpsError("invalid-argument", "Invalid redirectUri");
      }
    }

    const clientCfg = await readMetaWhatsappClientConfig();
    const appSecret = clientCfg.appSecret || metaAppSecret.value();
    if (!clientCfg.appId || !appSecret) {
      throw new HttpsError(
        "failed-precondition",
        "Meta app credentials are not configured on the backend",
      );
    }

    const exchanged = await exchangeEmbeddedSignupCode({
      code,
      redirectUri,
      appId: clientCfg.appId,
      appSecret,
      graphApiVersion: clientCfg.graphApiVersion,
    });

    if (!displayPhoneNumber && phoneNumberId) {
      displayPhoneNumber = await fetchDisplayPhoneNumber({
        phoneNumberId,
        accessToken: exchanged.accessToken,
        graphApiVersion: clientCfg.graphApiVersion,
      });
    }

    const tokenSecretRef = await storeBusinessTokenSecret({
      ownerUid: uid,
      accessToken: exchanged.accessToken,
    });

    if (!wabaId || !phoneNumberId) {
      logger.warn("[whatsapp-onboarding] missing waba/phone metadata from client", {
        uid,
        hasWabaId: Boolean(wabaId),
        hasPhoneNumberId: Boolean(phoneNumberId),
      });
    }

    if (!wabaId) {
      throw new HttpsError(
        "failed-precondition",
        "wabaId is required after Embedded Signup",
      );
    }
    if (!phoneNumberId) {
      throw new HttpsError(
        "failed-precondition",
        "phoneNumberId is required after Embedded Signup",
      );
    }

    const legacyTemplates = await readLegacyOutboundTemplates();
    const legacyContactsOwnerUid = await readLegacyContactsOwnerUid();
    const metaConfig = await readMetaWhatsappClientConfig();

    const metadata = await writeWhatsappConnectionMetadata({
      ownerUid: uid,
      wabaId,
      phoneNumberId,
      displayPhoneNumber,
      tokenSecretRef,
      connectionStatus: "connected",
      historySyncStatus: "pending",
      outboundTemplateName: legacyTemplates.outboundTemplateName,
      outboundTemplateLanguage: legacyTemplates.outboundTemplateLanguage,
      outboundTemplateBodyParamCount: legacyTemplates.outboundTemplateBodyParamCount,
      contactsOwnerUid:
        legacyContactsOwnerUid ||
        metaConfig.defaultContactsOwnerUid ||
        uid,
    });

    logger.info("[whatsapp-onboarding] connection stored", {
      uid,
      wabaId: metadata.wabaId,
      phoneNumberId: metadata.phoneNumberId,
    });

    return {
      wabaId: metadata.wabaId,
      phoneNumberId: metadata.phoneNumberId,
      displayPhoneNumber: metadata.displayPhoneNumber,
      connectionStatus: metadata.connectionStatus,
      historySyncStatus: metadata.historySyncStatus,
      coexistenceEnabled: metadata.coexistenceEnabled,
      tokenSecretRef: metadata.tokenSecretRef,
    };
  },
);
