import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import * as logger from "firebase-functions/logger";

const CONFIRM_WIPE = "DELETE ALL MY DATA";

function readTimestampMs(
  data: Record<string, unknown> | undefined,
): number | null {
  if (!data) {
    return null;
  }
  const tryNum = (k: string): number | null => {
    const v = data[k];
    if (typeof v === "number" && Number.isFinite(v)) {
      return v;
    }
    return null;
  };
  for (const k of [
    "updatedAtMs",
    "createdAtMs",
    "dispatchedAtMs",
    "paymentDueDateMs",
    "scheduledTime",
    "remindAt",
    "startAtMs",
  ]) {
    const n = tryNum(k);
    if (n != null && n > 0) {
      return n;
    }
  }
  for (const k of ["updatedAt", "createdAt", "lastLoginAt", "serverTime"]) {
    const v = data[k];
    if (v instanceof Timestamp) {
      return v.toMillis();
    }
  }
  return null;
}

function inDateFilter(
  ms: number | null,
  op: "before" | "after" | "between",
  beforeMs: number | undefined,
  afterMs: number | undefined,
  startMs: number | undefined,
  endMs: number | undefined,
): boolean {
  if (ms == null || !Number.isFinite(ms)) {
    return false;
  }
  if (op === "before") {
    if (beforeMs == null || !Number.isFinite(beforeMs)) {
      return false;
    }
    return ms < beforeMs;
  }
  if (op === "after") {
    if (afterMs == null || !Number.isFinite(afterMs)) {
      return false;
    }
    return ms > afterMs;
  }
  if (op === "between") {
    if (startMs == null || endMs == null || !Number.isFinite(startMs) || !Number.isFinite(endMs)) {
      return false;
    }
    return ms >= startMs && ms <= endMs;
  }
  return false;
}

/** `daily_summary` doc id: yyyy-MM-dd at UTC start for comparison */
function dailySummaryMsFromId(id: string): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(id.trim());
  if (!m) {
    return null;
  }
  const y = Number(m[1]);
  const mo = Number(m[2]) - 1;
  const d = Number(m[3]);
  if (!Number.isFinite(y) || !Number.isFinite(mo) || !Number.isFinite(d)) {
    return null;
  }
  return Date.UTC(y, mo, d, 0, 0, 0, 0);
}

async function deleteFlatCollectionByFilter(
  uid: string,
  name: string,
  filter: (data: Record<string, unknown>, id: string) => boolean,
): Promise<number> {
  const db = getFirestore();
  const col = db.collection("users").doc(uid).collection(name);
  const snap = await col.get();
  let n = 0;
  for (const doc of snap.docs) {
    const data = doc.data() as Record<string, unknown>;
    if (filter(data, doc.id)) {
      await doc.ref.delete();
      n += 1;
    }
  }
  return n;
}

async function deleteChatsByFilter(
  uid: string,
  filter: (ms: number | null, id: string) => boolean,
): Promise<number> {
  const db = getFirestore();
  const col = db.collection("users").doc(uid).collection("chats");
  const snap = await col.get();
  let n = 0;
  for (const doc of snap.docs) {
    const data = doc.data() as Record<string, unknown>;
    const ms = readTimestampMs(data);
    if (filter(ms, doc.id)) {
      await db.recursiveDelete(doc.ref);
      n += 1;
    }
  }
  return n;
}

/**
 * Remove Firestore data under the signed-in user. `wipe` = full recursive delete
 * of `users/{uid}`; `dateFilter` = only documents whose best-known timestamp
 * matches the op (docs without a readable timestamp are left as-is).
 */
export const clearUserData = onCall(
  { region: "us-central1", timeoutSeconds: 300, memory: "512MiB" },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError("unauthenticated", "Sign in required.");
    }
    const uid = request.auth.uid;
    const raw = (request.data || {}) as Record<string, unknown>;
    const mode = raw.mode;
    const db = getFirestore();
    const userRef = db.collection("users").doc(uid);

    if (mode === "wipe") {
      const confirmPhrase = String(raw.confirmPhrase ?? "").trim();
      if (confirmPhrase !== CONFIRM_WIPE) {
        throw new HttpsError(
          "invalid-argument",
          `Type the exact confirmation phrase: ${CONFIRM_WIPE}`,
        );
      }
      const snap = await userRef.get();
      logger.info("clearUserData: wipe", { uid, exists: snap.exists });
      if (snap.exists) {
        await db.recursiveDelete(userRef);
      } else {
        const top = await userRef.listCollections();
        for (const c of top) {
          const docs = await c.get();
          for (const d of docs.docs) {
            await db.recursiveDelete(d.ref);
          }
        }
      }
      return { ok: true, mode: "wipe", removed: "all" };
    }

    if (mode === "dateFilter") {
      const op = raw.op;
      if (op !== "before" && op !== "after" && op !== "between") {
        throw new HttpsError(
          "invalid-argument",
          "op must be before, after, or between",
        );
      }
      const beforeMs = typeof raw.beforeMs === "number" ? raw.beforeMs : undefined;
      const afterMs = typeof raw.afterMs === "number" ? raw.afterMs : undefined;
      const startMs = typeof raw.startMs === "number" ? raw.startMs : undefined;
      const endMs = typeof raw.endMs === "number" ? raw.endMs : undefined;

      if (op === "before" && beforeMs == null) {
        throw new HttpsError("invalid-argument", "beforeMs required for op=before");
      }
      if (op === "after" && afterMs == null) {
        throw new HttpsError("invalid-argument", "afterMs required for op=after");
      }
      if (op === "between" && (startMs == null || endMs == null)) {
        throw new HttpsError(
          "invalid-argument",
          "startMs and endMs required for op=between",
        );
      }
      if (op === "between" && startMs != null && endMs != null && endMs < startMs) {
        throw new HttpsError("invalid-argument", "endMs must be >= startMs");
      }

      const match = (data: Record<string, unknown>, docId: string) => {
        let ms = readTimestampMs(data);
        if (ms == null && docId.length > 0) {
          const d = dailySummaryMsFromId(docId);
          if (d != null) {
            ms = d;
          }
        }
        return inDateFilter(
          ms,
          op,
          beforeMs,
          afterMs,
          startMs,
          endMs,
        );
      };

      const matchChat = (ms: number | null) =>
        inDateFilter(ms, op, beforeMs, afterMs, startMs, endMs);

      const names = [
        "entries",
        "tasks",
        "reminders",
        "notifications",
        "quotations",
        "goals",
        "memory",
        "sessions",
        "orders",
        "jobs",
        "profile",
      ];
      const counts: Record<string, number> = {};
      let total = 0;

      for (const name of names) {
        const n = await deleteFlatCollectionByFilter(uid, name, match);
        counts[name] = n;
        total += n;
      }

      const nDaily = await deleteFlatCollectionByFilter(
        uid,
        "daily_summary",
        match,
      );
      counts.daily_summary = nDaily;
      total += nDaily;

      const nMeta = await deleteFlatCollectionByFilter(uid, "meta", match);
      counts.meta = nMeta;
      total += nMeta;

      const nChats = await deleteChatsByFilter(uid, matchChat);
      counts.chats = nChats;
      total += nChats;

      // Clear activeChatId if it points at a removed chat
      const chatStateRef = userRef.collection("meta").doc("chat_state");
      const chatStateSnap = await chatStateRef.get();
      const activeId = (chatStateSnap.data()?.activeChatId as string | undefined)
        ?.trim();
      if (activeId) {
        const still = await userRef
          .collection("chats")
          .doc(activeId)
          .get();
        if (!still.exists) {
          await chatStateRef.set(
            { activeChatId: null },
            { merge: true },
          );
        }
      }

      logger.info("clearUserData: dateFilter", { uid, op, total, counts });
      return { ok: true, mode: "dateFilter", op, totalDeleted: total, counts };
    }

    throw new HttpsError("invalid-argument", "mode must be wipe or dateFilter");
  },
);
