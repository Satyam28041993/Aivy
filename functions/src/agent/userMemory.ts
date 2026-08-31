/**
 * What Aivy remembers about the person she works for.
 *
 * One document, `users/{uid}/memory/profile`, whose keys are subjects — wife,
 * daughter, city, trade — and whose values are the line to recall. The agent
 * reads the whole of it into every system prompt, which is why it is a single
 * document rather than a collection: one read, always complete.
 *
 * Writing happens in `commit.ts`, after the user has confirmed the card, and
 * writes one key per fact. This file only reads. That split is deliberate —
 * reading is cheap and happens on every turn, writing needs a yes.
 *
 * This lived inside the 7,500-line `aivyProcess.ts` and was the only thing the
 * agent still needed from it. Pulling it out is what let that file go.
 */

import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions";

const PROFILE_DOC = "profile";

export async function getUserMemory(uid: string): Promise<Record<string, unknown>> {
  try {
    const doc = await getFirestore()
      .collection("users")
      .doc(uid)
      .collection("memory")
      .doc(PROFILE_DOC)
      .get();
    const data = doc.data();
    return data ? ({ ...data } as Record<string, unknown>) : {};
  } catch (e) {
    // A turn without memory is worse than a turn with it and far better than
    // no turn at all, so a failed read is a warning and an empty object.
    logger.warn("getUserMemory failed; using empty", {
      uid,
      err: e instanceof Error ? e.message : String(e),
    });
    return {};
  }
}
