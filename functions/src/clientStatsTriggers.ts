import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { scheduleRebuildClientStats } from "./clientStats";

/**
 * Recomputes `client_stats` + `meta/client_insights` when order rows change.
 */
export const onOrderWriteForClientStats = onDocumentWritten(
  { region: "us-central1", document: "users/{userId}/orders/{orderId}" },
  (event) => {
    const uid = event.params["userId"] as string;
    if (uid) {
      scheduleRebuildClientStats(uid);
    }
  },
);

/**
 * Recomputes aggregates when payment rows change.
 */
export const onPaymentWriteForClientStats = onDocumentWritten(
  { region: "us-central1", document: "users/{userId}/payments/{paymentId}" },
  (event) => {
    const uid = event.params["userId"] as string;
    if (uid) {
      scheduleRebuildClientStats(uid);
    }
  },
);
