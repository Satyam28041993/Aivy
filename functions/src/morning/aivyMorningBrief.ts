/**
 * The callable behind the Today screen's brief.
 *
 * It is built on demand rather than by a schedule for one hard reason: the
 * server has no Google refresh token, only the access token the app hands over
 * with a request, so it cannot read Gmail unless the app is open. Once a day
 * is enough — the second call before midnight returns the first one's work.
 */

import { HttpsError, onCall } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import { logger } from "firebase-functions";

import { buildBrief, cachedBrief, dateKeyFor } from "./brief";

const geminiApiKey = defineSecret("GEMINI_API_KEY");

function str(raw: unknown): string {
  return typeof raw === "string" ? raw.trim() : "";
}

export const aivyMorningBrief = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 120,
    memory: "512MiB",
    secrets: [geminiApiKey],
  },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in first.");
    }

    const payload = (request.data ?? {}) as Record<string, unknown>;
    const timezone = str(payload.timezone) || "Asia/Kolkata";
    // Used for the length of the call and never written down, exactly like the
    // token the agent turns forward.
    const googleToken = str(payload.googleAccessToken) || null;
    const force = payload.force === true;

    const dateKey = dateKeyFor(timezone);
    if (!force) {
      const cached = await cachedBrief(uid, dateKey);
      if (cached) {
        return { brief: cached, cached: true };
      }
    }

    const key = geminiApiKey.value() || process.env.GEMINI_API_KEY || "";
    if (!key) {
      throw new HttpsError("failed-precondition", "The model key is not configured.");
    }

    try {
      const brief = await buildBrief({ uid, timezone, googleToken, geminiKey: key });
      return { brief, cached: false };
    } catch (e) {
      logger.error("aivyMorningBrief failed", {
        uid,
        err: e instanceof Error ? e.message : String(e),
      });
      throw new HttpsError("internal", "Could not build the brief.");
    }
  },
);
