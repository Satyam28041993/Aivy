import { onCall, HttpsError } from "firebase-functions/v2/https";
import { rebuildClientStatsForUser } from "./clientStats";

/**
 * Forces a full recompute and returns the daily summary (for app-open refresh).
 */
export const syncClientStats = onCall(
  { region: "us-central1" },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Auth required");
    }
    const rawTz = (request.data as { timezone?: string } | undefined)?.timezone;
    const tz =
      typeof rawTz === "string" && rawTz.trim().length > 0
        ? rawTz.trim()
        : "Asia/Kolkata";
    const s = await rebuildClientStatsForUser(request.auth.uid, tz);
    return {
      totalDue: s.totalDue,
      overdueAmount: s.overdueAmount,
      todayDueCount: s.todayDueCount,
      riskyClientsCount: s.riskyClientsCount,
      asOfMs: s.asOfMs,
      oneLiner: s.oneLiner,
      fullText: s.fullText,
    };
  },
);
