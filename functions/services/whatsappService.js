"use strict";

const GRAPH_VERSION = "v18.0";
const RETRY_DELAY_MS = 2000;

function getCredentialResolver() {
  return require("../lib/whatsapp/credentials/resolver.js");
}

/**
 * @param {string | null | undefined} ownerUid
 */
async function loadSendConfig(ownerUid) {
  const { resolveWhatsAppCredentials } = getCredentialResolver();
  const resolved = await resolveWhatsAppCredentials({
    ownerUid: ownerUid ?? null,
    operation: "send",
  });
  return {
    token: resolved.token,
    phoneId: resolved.phoneNumberId,
    outboundTemplateName: resolved.outboundTemplateName,
    outboundTemplateLanguage: resolved.outboundTemplateLanguage,
    outboundTemplateBodyParamCount: resolved.outboundTemplateBodyParamCount,
    _credentialMeta: {
      credentialSource: resolved.credentialSource,
      connectionStatus: resolved.connectionStatus,
      wabaId: resolved.wabaId,
      ownerUid: resolved.ownerUid,
    },
    templateSource: resolved.templateSource,
  };
}

/**
 * @param {Record<string, unknown>} config
 * @param {string | null | undefined} messageId
 */
async function recordSendSuccess(config, messageId) {
  const meta = config._credentialMeta;
  if (!meta || !messageId) {
    return;
  }
  const { recordSuccessfulWhatsAppSend } = getCredentialResolver();
  try {
    await recordSuccessfulWhatsAppSend({
      credentialSource: meta.credentialSource,
      phoneNumberId: String(config.phoneId ?? ""),
      wabaId: meta.wabaId,
      connectionStatus: meta.connectionStatus,
      ownerUid: meta.ownerUid,
      messageId,
    });
  } catch (e) {
    console.warn("[WhatsApp] migration dashboard update failed", e);
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * India format: 91 + 10 digits, no + prefix.
 * @param {string} to
 */
function validatePhone(to) {
  const s = String(to ?? "").trim().replace(/^\+/, "");
  if (!/^91\d{10}$/.test(s)) {
    throw new Error(
      "Phone must be in format 91XXXXXXXXXX (no + prefix, 12 digits)",
    );
  }
  return s;
}

/**
 * @param {string} message
 */
function validateMessage(message) {
  const s = String(message ?? "").trim();
  if (!s) {
    throw new Error("Message must not be empty");
  }
  return s;
}

function truncateText(s, max) {
  const t = String(s ?? "");
  if (t.length <= max) {
    return t;
  }
  return t.slice(0, max);
}

/**
 * Meta rejects free-form text outside the 24h customer-care window → use template.
 * @param {unknown} err
 */
function needsTemplateFallback(err) {
  const code = err?.details?.error?.code;
  const sub = err?.details?.error?.error_subcode;
  const msg = String(err?.message ?? "").toLowerCase();
  const es = String(err?.details?.error?.error_user_title ?? "").toLowerCase();
  const combined = `${msg} ${es}`;
  if (code === 131047 || sub === 131047) {
    return true;
  }
  if (combined.includes("131047")) {
    return true;
  }
  if (combined.includes("re-engagement")) {
    return true;
  }
  if (combined.includes("template") && combined.includes("required")) {
    return true;
  }
  if (combined.includes("outside the customer")) {
    return true;
  }
  if (combined.includes("customer service window")) {
    return true;
  }
  return false;
}

/**
 * @param {string | null | undefined} [ownerUid]
 * @returns {Promise<Record<string, unknown>>}
 */
async function getWhatsAppConfig(ownerUid) {
  const config = await loadSendConfig(ownerUid ?? null);
  return {
    token: config.token,
    phoneId: config.phoneId,
    outboundTemplateName: config.outboundTemplateName,
    outboundTemplateLanguage: config.outboundTemplateLanguage,
    outboundTemplateBodyParamCount: config.outboundTemplateBodyParamCount,
    credentialSource: config._credentialMeta?.credentialSource ?? "LEGACY",
    templateSource: config.templateSource ?? "LEGACY",
  };
}

/**
 * @param {string} to
 * @param {string} message
 * @param {string | null | undefined} [ownerUid]
 */
async function sendOnce(to, message, ownerUid) {
  const config = await loadSendConfig(ownerUid);
  const token = config.token;
  const phoneId = config.phoneId;

  if (!token || !phoneId) {
    const err = new Error("WhatsApp config missing");
    err.status = 400;
    throw err;
  }

  console.log("WA CONFIG LOADED:", {
    hasToken: !!token,
    phoneId,
    credentialSource: config._credentialMeta?.credentialSource ?? "LEGACY",
  });
  console.log("TO:", to);

  const url = `https://graph.facebook.com/${GRAPH_VERSION}/${phoneId}/messages`;
  const body = {
    messaging_product: "whatsapp",
    to,
    type: "text",
    text: { body: message },
  };

  console.log("[WhatsApp] Meta API request", {
    url,
    to,
    messageLength: message.length,
  });

  const res = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  const text = await res.text();
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    data = { raw: text };
  }

  console.log("[WhatsApp] Meta API response", {
    status: res.status,
    ok: res.ok,
    body: data,
  });

  if (!res.ok) {
    const msg =
      data?.error?.message ||
      (typeof text === "string" && text) ||
      `HTTP ${res.status}`;
    const err = new Error(msg);
    err.status = res.status;
    err.details = data;
    throw err;
  }

  const messageId = data?.messages?.[0]?.id;
  await recordSendSuccess(config, messageId);
  return { messageId: messageId ?? null, raw: data };
}

/**
 * Approved template (business-initiated / outside 24h window).
 * Firestore `app_config/whatsapp`:
 *   outboundTemplateName (string, required for fallback)
 *   outboundTemplateLanguage (string, default "en")
 *   outboundTemplateBodyParamCount (number 0–3): body {{n}} placeholders, in order:
 *        1 → message text (truncated), 2 → contactName, 3 → literal "-"
 * @param {string} to
 * @param {Record<string, unknown>} config
 * @param {{ message: string, contactName: string }} ctx
 */
async function sendTemplateOnce(to, config, ctx) {
  const token = config.token;
  const phoneId = config.phoneId;
  if (!token || !phoneId) {
    const err = new Error("WhatsApp config missing");
    err.status = 400;
    throw err;
  }

  const name = String(config.outboundTemplateName ?? "").trim();
  if (!name) {
    const err = new Error(
      "outboundTemplateName missing in WhatsApp outbound template settings.",
    );
    err.status = 400;
    throw err;
  }

  const lang = String(config.outboundTemplateLanguage ?? "en").trim() || "en";
  let paramCount = Number(config.outboundTemplateBodyParamCount);
  if (!Number.isFinite(paramCount)) {
    paramCount = 0;
  }
  paramCount = Math.min(3, Math.max(0, Math.floor(paramCount)));

  const components = [];
  if (paramCount > 0) {
    const parameters = [];
    for (let i = 0; i < paramCount; i++) {
      if (i === 0) {
        parameters.push({
          type: "text",
          text: truncateText(ctx.message, 1024),
        });
      } else if (i === 1) {
        parameters.push({
          type: "text",
          text: truncateText(ctx.contactName || "Customer", 256),
        });
      } else {
        parameters.push({ type: "text", text: "-" });
      }
    }
    components.push({ type: "body", parameters });
  }

  const url = `https://graph.facebook.com/${GRAPH_VERSION}/${phoneId}/messages`;
  const body = {
    messaging_product: "whatsapp",
    to,
    type: "template",
    template: {
      name,
      language: { code: lang },
      ...(components.length ? { components } : {}),
    },
  };

  console.log("[WhatsApp] Meta template request", {
    url,
    to,
    template: name,
    language: lang,
    paramCount,
  });

  const res = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  const text = await res.text();
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    data = { raw: text };
  }

  console.log("[WhatsApp] Meta template response", {
    status: res.status,
    ok: res.ok,
    body: data,
  });

  if (!res.ok) {
    const msg =
      data?.error?.message ||
      (typeof text === "string" && text) ||
      `HTTP ${res.status}`;
    const err = new Error(msg);
    err.status = res.status;
    err.details = data;
    throw err;
  }

  const messageId = data?.messages?.[0]?.id;
  await recordSendSuccess(config, messageId);
  return { messageId: messageId ?? null, raw: data };
}

/**
 * Try session text first; on Meta “template / re-engagement” errors, send approved template if configured.
 * @param {string} to
 * @param {string} message
 * @param {{ contactName?: string, ownerUid?: string | null }} [opts]
 */
async function sendWhatsAppMessageOrTemplate(to, message, opts = {}) {
  const cleanTo = validatePhone(to);
  const cleanMsg = validateMessage(message);
  const contactName = String(opts.contactName || "").trim() || "Customer";
  const ownerUid = opts.ownerUid ?? null;

  let lastErr;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      if (attempt > 0) {
        console.log(
          `[WhatsApp] Retrying text after ${RETRY_DELAY_MS}ms (attempt ${attempt + 1})`,
        );
        await sleep(RETRY_DELAY_MS);
      }
      const result = await sendOnce(cleanTo, cleanMsg, ownerUid);
      if (!result.messageId) {
        console.error(
          "[WhatsApp] Meta response missing messages[0].id",
          result.raw,
        );
        throw new Error("Meta API response did not include a message id");
      }
      return { messageId: result.messageId, raw: result.raw, usedTemplate: false };
    } catch (e) {
      lastErr = e;
      console.error("[WhatsApp] Text send failed", {
        attempt: attempt + 1,
        message: e?.message || String(e),
        status: e?.status,
        details: e?.details,
      });
    }
  }

  if (needsTemplateFallback(lastErr)) {
    const config = await loadSendConfig(ownerUid);
    const tn = String(config.outboundTemplateName ?? "").trim();
    if (tn) {
      try {
        const result = await sendTemplateOnce(cleanTo, config, {
          message: cleanMsg,
          contactName,
        });
        if (!result.messageId) {
          throw new Error("Meta template response did not include a message id");
        }
        console.log("[WhatsApp] Fallback template sent OK", { template: tn });
        return {
          messageId: result.messageId,
          raw: result.raw,
          usedTemplate: true,
        };
      } catch (e2) {
        lastErr = e2;
        console.error("[WhatsApp] Template fallback failed", {
          message: e2?.message || String(e2),
          status: e2?.status,
          details: e2?.details,
        });
      }
    } else {
      console.warn(
        "[WhatsApp] Template fallback needed but outboundTemplateName not configured",
      );
    }
  }

  throw lastErr;
}

/**
 * Send a WhatsApp text via Cloud API. Validates phone (91XXXXXXXXXX) and non-empty message.
 * Retries once after 2s on failure.
 * @param {string} to
 * @param {string} message
 * @param {{ ownerUid?: string | null }} [opts]
 * @returns {Promise<{ messageId: string, raw: object }>}
 */
async function sendWhatsAppMessage(to, message, opts = {}) {
  const cleanTo = validatePhone(to);
  const cleanMsg = validateMessage(message);
  const ownerUid = opts.ownerUid ?? null;

  let lastErr;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      if (attempt > 0) {
        console.log(
          `[WhatsApp] Retrying after ${RETRY_DELAY_MS}ms (attempt ${attempt + 1})`,
        );
        await sleep(RETRY_DELAY_MS);
      }
      const result = await sendOnce(cleanTo, cleanMsg, ownerUid);
      if (!result.messageId) {
        console.error(
          "[WhatsApp] Meta response missing messages[0].id",
          result.raw,
        );
        throw new Error("Meta API response did not include a message id");
      }
      return { messageId: result.messageId, raw: result.raw };
    } catch (e) {
      lastErr = e;
      console.error("[WhatsApp] Send failed", {
        attempt: attempt + 1,
        message: e?.message || String(e),
        status: e?.status,
        details: e?.details,
      });
    }
  }
  throw lastErr;
}

/**
 * Phase 2 — ready for automation; not wired to triggers yet.
 * @param {string} clientName
 * @param {string|number} amount
 * @param {string} dueDate
 * @param {string} phone
 */
async function sendPaymentReminder(clientName, amount, dueDate, phone) {
  const message = `Dear ${clientName}, ₹${amount} payment due on ${dueDate}. Kindly clear it. - Aivy`;
  return sendWhatsAppMessage(phone, message);
}

/**
 * Phase 2 — ready for automation; not wired to triggers yet.
 * @param {string} clientName
 * @param {string|number} amount
 * @param {string} phone
 */
async function sendDispatchAlert(clientName, amount, phone) {
  const message = `Your order of ₹${amount} has been dispatched. Thank you!`;
  return sendWhatsAppMessage(phone, message);
}

module.exports = {
  getWhatsAppConfig,
  sendWhatsAppMessage,
  sendWhatsAppMessageOrTemplate,
  sendPaymentReminder,
  sendDispatchAlert,
};
