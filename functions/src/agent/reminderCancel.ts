/**
 * Calling off reminders that belong to work now finished.
 *
 * A tracker that keeps ringing about something already done trains a person to
 * ignore it, and the whole reason dated items become reminders is that the
 * phone is where this person actually lives. So the moment an item is marked
 * done — or a task is closed early, which is the common case — its alarm goes
 * with it.
 *
 * Setting the status is enough on both ends: the phone's alarm sync watches
 * pending reminders and cancels the ones that leave that set, and the server's
 * push engine skips anything not pending. There is no third place to tell.
 */

import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions";

/**
 * Marks the given reminders cancelled. Ids that are blank, repeated or already
 * gone are skipped rather than treated as failures — this is always called as
 * the tidy-up half of an update the user has already been told succeeded, and
 * it must never be what makes that update fail.
 */
export async function cancelReminders(uid: string, ids: readonly string[]): Promise<number> {
  const wanted = [...new Set(ids.map((id) => `${id ?? ""}`.trim()).filter(Boolean))];
  if (wanted.length === 0) {
    return 0;
  }

  const db = getFirestore();
  const col = db.collection("users").doc(uid).collection("reminders");
  let cancelled = 0;

  await Promise.all(
    wanted.map(async (id) => {
      try {
        const ref = col.doc(id);
        const snap = await ref.get();
        if (!snap.exists || `${snap.get("status") ?? ""}` !== "pending") {
          return;
        }
        await ref.update({ status: "cancelled", cancelledAtMs: Date.now() });
        cancelled += 1;
      } catch (e) {
        logger.warn("cancelReminders: could not cancel", {
          id,
          err: e instanceof Error ? e.message : String(e),
        });
      }
    }),
  );

  return cancelled;
}
