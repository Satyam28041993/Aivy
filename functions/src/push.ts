/**
 * Push notifications — the part that reaches the phone when Aivy is closed.
 *
 * Everything else here writes a row into `users/{uid}/notifications`, which the
 * app renders when it is open. That is not a notification: a reminder set for
 * seven o'clock has to arrive at seven whether or not the app is running, the
 * way a message does.
 *
 * The device registers its FCM token in `users/{uid}/devices/{tokenId}` and
 * this sends to every token registered there. Messages carry a `notification`
 * block rather than data alone, deliberately: Android's system tray displays
 * those itself, with no code of ours running, which is what makes a killed app
 * still ring. `channel_id` points at the app's own reminder channel so it keeps
 * the reminder sound and high-importance treatment.
 */

import { getFirestore } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { logger } from "firebase-functions";
import { HttpsError, onCall } from "firebase-functions/v2/https";

const USERS = "users";
const DEVICES = "devices";

/** The high-importance channel the app creates at startup. */
const REMINDER_CHANNEL = "aivy_reminders_v3";

export interface PushMessage {
  title: string;
  body: string;
  /** Small payload the app reads when the notification is tapped. */
  data?: Record<string, string>;
}

/**
 * Sends to every device the user has registered.
 *
 * Never throws: a push that fails must not roll back the reminder that caused
 * it. The in-app row is the record; this is delivery.
 */
export async function pushToUser(userId: string, msg: PushMessage): Promise<number> {
  if (!userId) {
    return 0;
  }
  const db = getFirestore();

  let tokens: string[] = [];
  try {
    const snap = await db.collection(USERS).doc(userId).collection(DEVICES).get();
    tokens = snap.docs
      .map((d) => `${(d.data() as { token?: unknown }).token ?? ""}`.trim())
      .filter((t) => t.length > 0);
  } catch (e) {
    logger.warn("pushToUser: could not read devices", {
      userId,
      err: e instanceof Error ? e.message : String(e),
    });
    return 0;
  }

  if (tokens.length === 0) {
    // Nothing registered yet — an older build, or notifications declined.
    logger.info("pushToUser: no devices registered", { userId });
    return 0;
  }

  const title = msg.title.trim() || "Aivy";
  const body = msg.body.trim();

  let res;
  try {
    res = await getMessaging().sendEachForMulticast({
      tokens: tokens.slice(0, 25),
      notification: { title, body },
      data: msg.data ?? {},
      android: {
        priority: "high",
        notification: {
          // The channel decides the sound on Android 8 and up, and it already
          // carries the reminder tone. Naming a raw resource here as well adds
          // nothing and risks the system failing to build the notification at
          // all when it cannot resolve the name — which shows up as FCM
          // reporting success and the phone showing nothing.
          channelId: REMINDER_CHANNEL,
          priority: "high",
        },
      },
      apns: {
        payload: { aps: { sound: "default", badge: 1 } },
      },
    });
  } catch (e) {
    logger.error("pushToUser: send failed", {
      userId,
      err: e instanceof Error ? e.message : String(e),
    });
    return 0;
  }

  // A token dies when the app is uninstalled or its data cleared. Left in
  // place they are retried on every future push, forever.
  const dead: string[] = [];
  res.responses.forEach((r, i) => {
    if (r.success) {
      return;
    }
    const code = r.error?.code ?? "";
    if (
      code === "messaging/registration-token-not-registered" ||
      code === "messaging/invalid-registration-token" ||
      code === "messaging/invalid-argument"
    ) {
      dead.push(tokens[i]!);
    }
  });
  if (dead.length > 0) {
    await Promise.all(
      dead.map((t) =>
        db
          .collection(USERS)
          .doc(userId)
          .collection(DEVICES)
          .doc(tokenDocId(t))
          .delete()
          .catch(() => undefined),
      ),
    );
  }

  logger.info("pushToUser: sent", {
    userId,
    sent: res.successCount,
    failed: res.failureCount,
    pruned: dead.length,
  });
  return res.successCount;
}

/**
 * A token is far longer than a Firestore document id allows and contains
 * slashes, so the id is a bounded, path-safe slice of it. The full token is
 * kept in the document.
 */
export function tokenDocId(token: string): string {
  return token.replace(/[^A-Za-z0-9_-]/g, "").slice(-120) || "device";
}

/**
 * Callable: sends a push to the caller's own devices, right now.
 *
 * A reminder that does not arrive has a long chain behind it — permission,
 * token registration, the scheduler, FCM, the phone's battery policy — and
 * waiting five minutes for the next scheduled run tells you nothing about
 * which link broke. This exercises the whole delivery path on demand and
 * reports how many devices it reached, which separates "nothing is
 * registered" from "sent, but the phone did not show it".
 */
export const aivyTestPush = onCall(
  { region: "us-central1", timeoutSeconds: 30, memory: "256MiB" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in first.");
    }

    const db = getFirestore();
    const snap = await db.collection("users").doc(uid).collection("devices").get();
    const devices = snap.size;

    const sent = await pushToUser(uid, {
      title: "Aivy test",
      body: "If you can see this, reminders will arrive the same way.",
      data: { type: "test" },
    });

    return { devices, sent };
  },
);
