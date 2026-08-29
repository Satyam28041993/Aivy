/**
 * One-button wipe of everything the business has recorded.
 *
 * `clearUserData`'s wipe mode already deletes the whole user subtree, which is
 * why this exists separately: it deletes *almost* everything. Keeping memory
 * out of a full recursive delete is not a flag you can pass that function, and
 * WhatsApp history lives outside the user subtree it walks.
 *
 * Deliberately not clever: no filters, no date range, no "archive instead".
 * The user asked for a clean slate, and a half-clean slate is worse than either
 * end — stale rows in reports are exactly what made them ask.
 *
 * Two things survive on purpose:
 *
 *   - `memory/*` — the personal details Aivy has learned. The user asked to
 *     keep these, and they are not business records.
 *   - `meta/google_prefs` — a setting (which Sheet to write to), not data.
 *     Wiping it would silently break Sheets afterwards.
 *
 * WhatsApp *credentials* live in `app_config`, which this never touches, so the
 * connection survives the wipe of its messages.
 */

import { HttpsError, onCall } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions";

const REGION = "us-central1";

/**
 * Typed by the user, so a mis-tap cannot reach this. Same phrase the older
 * `clearUserData` wipe uses — one phrase to remember, not two.
 */
const CONFIRM_PHRASE = "DELETE ALL MY DATA";

/**
 * Per-user subcollections that hold recorded work.
 *
 * `recursiveDelete` follows subcollections, so `agent_chats` takes its messages
 * with it.
 */
const USER_COLLECTIONS = [
  "clients",
  "client_stats",
  "quotations",
  "orders",
  "payments",
  "reminders",
  "tasks",
  "followups",
  "records",
  "entries",
  "jobs",
  "sessions",
  "chats",
  "agent_chats",
  "agent_drafts",
  "structured_actions",
  "notifications",
  "daily_summary",
  "contacts",
  "places",
  "memory_logs",
] as const;

/** Docs under `users/{uid}/meta` that are state, not settings. */
const USER_META_DOCS = ["chat_state", "dashboard_stats"] as const;

/**
 * WhatsApp message stores. These sit at the top level rather than under the
 * user, because they are keyed by the business phone number — this app serves
 * one business, so the whole collection is that business's history.
 *
 * Config (`app_config/whatsapp*`) is not in this list and is never touched.
 */
const WHATSAPP_COLLECTIONS = [
  "whatsapp_messages",
  "whatsapp_conversations",
  "whatsapp_message_index",
  "whatsapp_ai_inbox",
  "whatsapp_pending_status",
  "whatsapp_coexistence_history",
  "whatsapp_coexistence_message_echoes",
  "whatsapp_coexistence_app_state_sync",
] as const;

export interface ResetSummary {
  /** Collection name → docs removed. */
  removed: Record<string, number>;
  total: number;
}

async function countDocs(path: FirebaseFirestore.Query): Promise<number> {
  try {
    const snap = await path.count().get();
    return snap.data().count;
  } catch {
    return 0;
  }
}

export const aivyResetData = onCall(
  { region: REGION, timeoutSeconds: 540, memory: "512MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in required");
    }
    const payload = (request.data ?? {}) as Record<string, unknown>;
    if (`${payload.confirmPhrase ?? payload.confirm ?? ""}`.trim().toUpperCase() !== CONFIRM_PHRASE) {
      throw new HttpsError(
        "failed-precondition",
        `Type ${CONFIRM_PHRASE} to confirm.`,
      );
    }
    const includeWhatsApp = payload.includeWhatsApp !== false;

    const db = getFirestore();
    const userRef = db.collection("users").doc(uid);
    const removed: Record<string, number> = {};

    for (const name of USER_COLLECTIONS) {
      const ref = userRef.collection(name);
      const n = await countDocs(ref);
      if (n > 0) {
        await db.recursiveDelete(ref);
        removed[name] = n;
      }
    }

    for (const doc of USER_META_DOCS) {
      const ref = userRef.collection("meta").doc(doc);
      const snap = await ref.get();
      if (snap.exists) {
        await ref.delete();
        removed[`meta/${doc}`] = 1;
      }
    }

    if (includeWhatsApp) {
      for (const name of WHATSAPP_COLLECTIONS) {
        const ref = db.collection(name);
        const n = await countDocs(ref);
        if (n > 0) {
          await db.recursiveDelete(ref);
          removed[name] = n;
        }
      }
    }

    const total = Object.values(removed).reduce((a, b) => a + b, 0);
    logger.warn("aivyResetData: wiped business data", { uid, total, removed });

    return { ok: true, total, removed } satisfies ResetSummary & { ok: boolean };
  },
);
