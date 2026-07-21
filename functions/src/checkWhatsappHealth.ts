import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions";
import { HttpsError, onCall } from "firebase-functions/v2/https";

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

    const snap = await getFirestore().collection("app_config").doc("whatsapp").get();
    const cfg = snap.data() ?? {};
    const token = String(cfg.token ?? process.env.WHATSAPP_TOKEN ?? "").trim();
    const phoneId = String(cfg.phoneId ?? process.env.WHATSAPP_PHONE_ID ?? "").trim();
    if (!token || !phoneId) {
      throw new HttpsError(
        "failed-precondition",
        "WhatsApp token/phoneId missing in settings",
      );
    }

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
      });
      return {
        ok: false,
        severity: isTokenIssue ? "warning" : "error",
        statusCode: res.status,
        message: isTokenIssue
            ? "Access token invalid or expired. Update token in settings."
            : rawMessage,
      };
    }

    return {
      ok: true,
      severity: "ok",
      statusCode: res.status,
      message: "WhatsApp token is healthy.",
      phoneId,
      displayPhoneNumber: String(data.display_phone_number ?? ""),
    };
  },
);
