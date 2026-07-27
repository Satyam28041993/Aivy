import { logger } from "firebase-functions";
import { HttpsError, onCall } from "firebase-functions/v2/https";

// Emitted to lib/testWhatsappApi.js — resolves to functions/services/whatsappService.js
// eslint-disable-next-line @typescript-eslint/no-require-imports
const { sendWhatsAppMessageOrTemplate } = require("../services/whatsappService.js") as {
  sendWhatsAppMessageOrTemplate: (
    to: string,
    message: string,
    opts?: { contactName?: string; ownerUid?: string | null },
  ) => Promise<{ messageId: string; raw: unknown; usedTemplate?: boolean }>;
};

/**
 * Test / integration callable for WhatsApp Cloud API.
 *
 * This is intentionally callable + admin-only so external actors cannot hit
 * a public HTTP endpoint and abuse the WhatsApp token.
 */
export const testWhatsapp = onCall(
  {
    region: "us-central1",
  },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Authentication required");
    }
    if (request.auth.token.admin !== true) {
      throw new HttpsError("permission-denied", "Admin access required");
    }

    const body =
      typeof request.data === "object" && request.data !== null
        ? (request.data as { phone?: unknown; message?: unknown })
        : {};

    const phone = body.phone;
    const message = body.message;

    logger.info("[testWhatsapp] Incoming request", {
      phone:
        typeof phone === "string"
          ? `${phone.slice(0, 4)}…${phone.slice(-2)}`
          : phone,
      messageLength:
        typeof message === "string" ? message.length : "not-a-string",
    });

    if (typeof phone !== "string" || typeof message !== "string") {
      throw new HttpsError(
        "invalid-argument",
        "Body must include string fields: phone, message",
      );
    }

    try {
      const { messageId, usedTemplate } = await sendWhatsAppMessageOrTemplate(
        phone,
        message,
        {
          contactName: "Test",
          ownerUid: request.auth.uid,
        },
      );
      logger.info("[testWhatsapp] Sent OK", { messageId, usedTemplate });
      return {
        success: true,
        messageId,
        status: "sent",
        usedTemplate: usedTemplate === true,
      };
    } catch (e: unknown) {
      const err = e as { message?: string; status?: number };
      logger.error("[testWhatsapp] Failed", {
        message: err.message,
        status: err.status,
      });
      const raw = (err.message || "WhatsApp send failed").toLowerCase();
      let friendly = err.message || "WhatsApp send failed";
      if (
        raw.includes("whatsapp config not found") ||
        raw.includes("whatsapp config missing")
      ) {
        friendly = "Please configure WhatsApp in settings";
      } else if (
        err.status === 401 ||
        raw.includes("invalid oauth") ||
        raw.includes("error validating access token") ||
        raw.includes("session has been invalidated")
      ) {
        friendly = "Invalid WhatsApp token, please update in settings";
      }
      let code:
        | "invalid-argument"
        | "failed-precondition"
        | "permission-denied"
        | "not-found"
        | "internal";
      if (err.message?.includes("format 91") || err.message?.includes("empty")) {
        code = "invalid-argument";
      } else if (err.status === 401) {
        code = "failed-precondition";
      } else if (err.status === 403) {
        code = "failed-precondition";
      } else if (err.status === 404) {
        code = "not-found";
      } else if (err.status && err.status >= 400 && err.status < 500) {
        code = "invalid-argument";
      } else {
        code = "internal";
      }
      throw new HttpsError(code, friendly);
    }
  },
);
