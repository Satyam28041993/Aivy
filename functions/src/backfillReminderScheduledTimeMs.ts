import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import * as logger from "firebase-functions/logger";

/**
 * One-time / ops backfill: copies millis from canonical `scheduledAt` into
 * `scheduledTimeMs` when the latter is missing (legacy rows).
 *
 * Call with `{ secret: "<REMINDER_BACKFILL_SECRET>" }`.
 * Configure `REMINDER_BACKFILL_SECRET` for the Functions runtime.
 */
export const backfillReminderScheduledTimeMs = onCall(
  { region: "us-central1", timeoutSeconds: 540, memory: "512MiB" },
  async (request) => {
    const secret = process.env.REMINDER_BACKFILL_SECRET ?? "";
    const provided = String(
      (request.data as { secret?: string })?.secret ?? "",
    ).trim();
    if (!secret || provided !== secret) {
      throw new HttpsError("permission-denied", "Invalid or missing secret.");
    }

    const db = getFirestore();
    const usersSnap = await db.collection("users").get();

    let scanned = 0;
    let updated = 0;

    let batch = db.batch();
    let batchOps = 0;

    const commitBatch = async () => {
      if (batchOps > 0) {
        await batch.commit();
        batch = db.batch();
        batchOps = 0;
      }
    };

    for (const userDoc of usersSnap.docs) {
      const remindersSnap = await userDoc.ref.collection("reminders").get();

      for (const doc of remindersSnap.docs) {
        scanned++;
        const data = doc.data() as Record<string, unknown>;
        const schedAt = data.scheduledAt;
        const stm = data.scheduledTimeMs;

        const missingDerived =
          stm === undefined ||
          stm === null ||
          (typeof stm === "number" && stm === 0);

        if (missingDerived && schedAt instanceof Timestamp) {
          batch.update(doc.ref, { scheduledTimeMs: schedAt.toMillis() });
          batchOps++;
          updated++;
          if (batchOps >= 400) {
            await commitBatch();
          }
        }
      }
    }

    await commitBatch();

    logger.info("backfillReminderScheduledTimeMs done", { scanned, updated });
    return { ok: true, scanned, updated };
  },
);
