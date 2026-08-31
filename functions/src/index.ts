import { initializeApp } from "firebase-admin/app";
import { onRequest } from "firebase-functions/v2/https";

initializeApp();

// ---------------------------------------------------------------------------
// GET /health  →  { status: "running", service: "aivy-functions", ... }
// ---------------------------------------------------------------------------
export const health = onRequest(
  { region: "us-central1", cors: true, invoker: "public" },
  (_req, res) => {
    res.status(200).json({
      status: "running",
      service: "aivy-functions",
      version: "1.0.0",
      timestamp: new Date().toISOString(),
      features: {
        whatsapp_webhook: true,
        auto_reply: true,
        ai_reply_placeholder: true,
        status_tracking: true,
        crm_inbox: true,
      },
    });
  },
);

export { clearUserData } from "./clearUserData";
export { backfillReminderScheduledTimeMs } from "./backfillReminderScheduledTimeMs";
export {
  onOrderWriteForClientStats,
  onPaymentWriteForClientStats,
} from "./clientStatsTriggers";
export { syncClientStats } from "./syncClientStats";
export { aivyAgent, aivyAgentChats, aivyAgentCommit } from "./agent/aivyAgent";
export { aivyResetData } from "./agent/resetData";
export { aivyTestPush } from "./push";
export { checkOccasions } from "./occasionReminders";
export { aivyMorningBrief } from "./morning/aivyMorningBrief";
export { checkWhatsappHealth } from "./checkWhatsappHealth";
export {
  getMetaWhatsappClientConfig,
  completeWhatsappEmbeddedSignup,
} from "./whatsapp/onboarding/callables";
export {
  whatsappWebhook,
  onWhatsAppInboundMessageCreated,
  onWhatsAppMessageIndexCreated,
} from "./whatsappWebhook";
export {
  checkReminders,
  markOverdue,
  getDashboardStats,
  markNotificationRead,
  onPaymentWriteCancelReminders,
  createNotification,
} from "./reminderNotificationEngine";
export { getDashboardEngineStats, computeDashboardEngineStats } from "./clientStats";
