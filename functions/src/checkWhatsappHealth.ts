import { logger } from "firebase-functions";
import { HttpsError, onCall } from "firebase-functions/v2/https";
import { resolveWhatsAppCredentials } from "./whatsapp/credentials/resolver";

const GRAPH_VERSION = "v18.0";

export const checkWhatsappHealth = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Authentication required");
    }
    if (request.auth.token.admin !== true) {
      throw new HttpsError("permission-denied", "Admin access required");
    }

    const body =
      typeof request.data === "object" && request.data !== null
        ? (request.data as { ownerUid?: unknown })
        : {};
    const explicitOwnerUid = String(body.ownerUid ?? "").trim();
    const ownerUid =
      explicitOwnerUid.length > 8 ? explicitOwnerUid : request.auth.uid;

    let resolved;
    try {
      resolved = await resolveWhatsAppCredentials({
        ownerUid,
        operation: "health_check",
      });
    } catch {
      throw new HttpsError(
        "failed-precondition",
        "WhatsApp credentials unavailable",
      );
    }

    const token = resolved.token;
    const phoneId = resolved.phoneNumberId;
    if (!token || !phoneId) {
      throw new HttpsError(
        "failed-precondition",
        "WhatsApp token/phoneNumberId missing after credential resolution",
      );
    }

    logger.info("[checkWhatsappHealth] using credentials", {
      credentialSource: resolved.credentialSource,
      connectionStatus: resolved.connectionStatus,
      phoneNumberId: resolved.phoneNumberId,
      wabaId: resolved.wabaId,
      fallbackReason: resolved.fallbackReason,
      templateSource: resolved.templateSource,
    });

    const url = `https://graph.facebook.com/${GRAPH_VERSION}/${phoneId}?fields=id,display_phone_number`;
    const res = await fetch(url, {
      method: "GET",
      headers: { Authorization: `Bearer ${token}` },
    });
    const text = await res.text();
    let data: Record<string, unknown> = {};
    try {
      data = JSON.parse(text) as Record<string, unknown>;
    } catch {
      data = { raw: text };
    }

    if (!res.ok) {
      const rawMessage = String((data.error as { message?: string } | undefined)?.message ?? text);
      const msg = rawMessage.toLowerCase();
      const isTokenIssue =
        res.status === 401 ||
        msg.includes("invalid oauth") ||
        msg.includes("error validating access token") ||
        msg.includes("session has been invalidated");
      logger.warn("[checkWhatsappHealth] health check failed", {
        status: res.status,
        message: rawMessage,
        credentialSource: resolved.credentialSource,
      });
      return {
        ok: false,
        severity: isTokenIssue ? "warning" : "error",
        statusCode: res.status,
        message: isTokenIssue
            ? "Access token invalid or expired."
            : rawMessage,
        credentialSource: resolved.credentialSource,
        connectionStatus: resolved.connectionStatus,
        fallbackReason: resolved.fallbackReason,
        phoneId,
        wabaId: resolved.wabaId,
      };
    }

    return {
      ok: true,
      severity: "ok",
      statusCode: res.status,
      message: "WhatsApp token is healthy.",
      phoneId,
      displayPhoneNumber: String(data.display_phone_number ?? ""),
      credentialSource: resolved.credentialSource,
      connectionStatus: resolved.connectionStatus,
      fallbackReason: resolved.fallbackReason,
      wabaId: resolved.wabaId,
      templateSource: resolved.templateSource,
    };
  },
);
