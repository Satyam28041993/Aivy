/**
 * The yearly dates, warned about in good time.
 *
 * Runs once a day and asks one question of every occasion: how many days until
 * the next one. At 15, 10, 5, 1 and 0 it says so. Nothing is scheduled ahead —
 * a birthday reminder written a year in advance is a reminder that survives a
 * reinstall, a new phone and a changed date only by luck. Recomputing daily
 * costs one read per user and is always right.
 */

import { getFirestore } from "firebase-admin/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { logger } from "firebase-functions";

import {
  daysUntil,
  LEAD_DAYS,
  milestoneLabel,
  nextOccurrence,
  type Occasion,
} from "./agent/occasionStore";
import { createNotification } from "./reminderNotificationEngine";

const REGION = "us-central1";

function headline(o: Occasion): string {
  switch (o.kind) {
    case "anniversary":
      return `${o.name} anniversary`;
    case "birthday":
      return `${o.name}'s birthday`;
    default:
      return o.name;
  }
}

/** "in 15 days · Monday, 19 October · turning 31" */
export function occasionBody(o: Occasion, timezone: string, nowMs = Date.now()): string {
  const days = daysUntil(o, timezone, nowMs);
  const when = nextOccurrence(o, timezone, nowMs);
  const lead =
    days === 0 ? "Today" : days === 1 ? "Tomorrow" : `In ${days} days`;
  const parts = [lead, when.toFormat("cccc, d LLLL")];
  const milestone = milestoneLabel(o, timezone, nowMs);
  if (milestone) {
    parts.push(milestone);
  }
  return parts.join(" · ");
}

export const checkOccasions = onSchedule(
  {
    // 09:00 in Asia/Kolkata. Early enough to act on, late enough not to wake
    // anyone — and a birthday warning at three in the morning is worthless.
    schedule: "30 3 * * *",
    region: REGION,
    memory: "512MiB",
  },
  async () => {
    const db = getFirestore();
    const nowMs = Date.now();

    // Collection group, so a user is only visited when they have occasions.
    const snap = await db.collectionGroup("occasions").limit(2000).get();
    let sent = 0;

    for (const doc of snap.docs) {
      const parts = doc.ref.path.split("/");
      const i = parts.indexOf("users");
      const uid = i >= 0 ? parts[i + 1] : null;
      if (!uid) {
        continue;
      }
      const o = doc.data() as Occasion;
      if (!o.day || !o.month) {
        continue;
      }

      // One zone for now; the reminder engine assumes the same.
      const timezone = "Asia/Kolkata";
      const days = daysUntil(o, timezone, nowMs);
      if (!LEAD_DAYS.includes(days as (typeof LEAD_DAYS)[number])) {
        continue;
      }

      const year = nextOccurrence(o, timezone, nowMs).year;
      try {
        await createNotification({
          userId: uid,
          title: headline(o),
          message: occasionBody(o, timezone, nowMs),
          type: "followup",
          // Per occasion, per year, per lead — so a redeploy or a retry on the
          // same day cannot say it twice.
          dedupeKey: `occasion:${doc.id}:${year}:${days}`,
        });
        sent++;
      } catch (e) {
        logger.error("checkOccasions: could not notify", {
          uid,
          occasion: doc.id,
          err: e instanceof Error ? e.message : String(e),
        });
      }
    }

    logger.info("checkOccasions: done", { occasions: snap.size, sent });
  },
);
