/**
 * Server-side intent routing — mirrors the Flutter [detectIntent] contract.
 * Priority: reminder > payment > query > general.
 */

import { logger } from "firebase-functions";

export type AivyUserIntent = "reminder" | "payment" | "query" | "general";

/** Hindi script cues (transcription often returns Devanagari). */
const H_REMINDER = /रिमाइंडर|रिमाइन्दर|रेमाइंडर|याद\s*दिल(?:ाओ|ाना|ा\s*दो|वाना)?/u;
const H_REL_DAY = /आज|कल(?!\u093e)|परसों|परसो|अगले\s*हफ्ते|अगले\s*सप्ताह/u;
const H_TIME = /शाम|सुबह|दोपहर|बजे|[\u0966-\u096f]{1,2}\s*बजे/u;
const H_CALL = /कॉल|फ़ोन|फोन|मिलना|मिलने|कॉल\s*कर|फोन\s*कर/u;

function isBusinessStatsOrListQuestion(lower: string): boolean {
  const hasBiz =
    /\b(quotation|quote|qoutation|order|orders|dispatch|po|p\.o\.|purchase order|बुक|booking|कोटेशन)\b/i.test(
      lower,
    );
  if (!hasBiz) {
    return false;
  }
  return /\b(kitne|kitna|kitni|kisko|kisse|list|how many|abhi tak|total|saare|count|batao|bata|report|naam|names|pichhle|pichle|mahine|month|aaj|kal|guzre|value)\b/i.test(
    lower,
  );
}

function hasTimeOrScheduleCue(lower: string, raw: string): boolean {
  return (
    /\b(baje|subah|shaam|sham|evening|morning|noon|am|pm|a\.m\.|p\.m\.|o['']clock|oclock)\b/i.test(
      lower,
    ) ||
    /\b(\d{1,2}:\d{2}|\d{1,2}[:.]\d{2})\b/.test(lower) ||
    /\b\d{1,2}\s*(baje|bje|pm|am)\b/i.test(lower) ||
    H_TIME.test(raw)
  );
}

function hasDateOrRelativeDay(lower: string, raw: string): boolean {
  return (
    /\b(aaj|kal|parso|tomorrow|today|agla|next week|is hafte|is week|after \d+ days?|(\d+|ek|do|teen|char|paanch|one|two)\s*din( ke baad| baad)?|parson|day after tomorrow)\b/i.test(
      lower,
    ) ||
    /\d{1,2}[/.-]\d{1,2}([/.-]\d{2,4})?/.test(lower) ||
    H_REL_DAY.test(raw)
  );
}

function hasScheduleAction(lower: string, raw: string): boolean {
  return (
    /\b(call|phone|milna|milne|mulakat|mulaqat|follow up|followup|bhejna|bhej|check|visit|dekhna|meet|remind|reminder|yaad|dilao|dilana|dila|call karna|karna hai|lagao|laga|lagana|set reminder|lagwa|lagwana|need to call|have to call|got to call|must call|want to call)\b/i.test(
      lower,
    ) || H_CALL.test(raw)
  );
}

/** "Aaj kisko call karna hai" → analytics, not a new reminder to schedule. */
function isWhoToCallAnalyticsQuestion(lower: string, raw: string): boolean {
  if (!hasDateOrRelativeDay(lower, raw)) {
    return false;
  }
  const asksWhom =
    /\b(kise|kis\s*ko|kisko|kaun|kaun\s*sa|kaun\s*si|kya)\b/i.test(lower) ||
    /किस(?:े|को)|कौन/u.test(raw);
  const hasCall =
    /\b(call|phone|milna|milne|follow\s*up|followup)\b/i.test(lower) || H_CALL.test(raw);
  const asksGuidance =
    /\b(batao|bata|bataye|chahiye|hai\s*\?|hai\?|karna\s+hai|karu|karun|list|dikhao|dikha)\b/i.test(
      lower,
    );
  return asksWhom && hasCall && asksGuidance;
}

function hasReminderKeyword(lower: string, raw: string): boolean {
  if (/\b(remind|reminder)\b/i.test(lower)) {
    return true;
  }
  if (
    /\b(remind\s+me(\s+to)?|please\s+remind|set\s+(up\s+)?a\s+reminder|add\s+a\s+reminder|create\s+a\s+reminder)\b/i.test(
      lower,
    )
  ) {
    return true;
  }
  if (H_REMINDER.test(raw)) {
    return true;
  }
  if (
    /\b(reminder\s+lag|lagao\s+reminder|lagwa\s+reminder|reminder\s+set|set\s+reminder|reminder\s+dila|reminder\s+bana|mujhe\s+.+\s+reminder)\b/i.test(
      lower,
    )
  ) {
    return true;
  }
  return false;
}

function isReminderIntent(lower: string, raw: string): boolean {
  if (isWhoToCallAnalyticsQuestion(lower, raw)) {
    return false;
  }
  if (isBusinessStatsOrListQuestion(lower)) {
    return false;
  }
  if (hasReminderKeyword(lower, raw)) {
    if (!/\b(kitne|kitna|kitni)\b.*(quotation|order|quote|dispatch)/i.test(lower)) {
      return true;
    }
  }
  if (
    /yaad\s*(dilao|dilana|dila do|dila dena|dilwa|dilwana|karwa do|karwa dena|karwana)/i.test(
      lower,
    )
  ) {
    return true;
  }
  if (hasTimeOrScheduleCue(lower, raw) && hasScheduleAction(lower, raw)) {
    return true;
  }
  if (
    hasDateOrRelativeDay(lower, raw) &&
    hasTimeOrScheduleCue(lower, raw) &&
    hasScheduleAction(lower, raw)
  ) {
    return true;
  }
  if (
    /\b(baje|subah|shaam|sham|shaam ko)\b/i.test(lower) &&
    /\b(leni|lena|lana|lenaa|khareed|dawai|davai|facewash|face wash|medicine|tablet|syrup)\b/i.test(
      lower,
    )
  ) {
    return true;
  }
  if (
    hasDateOrRelativeDay(lower, raw) &&
    hasScheduleAction(lower, raw) &&
    !/\b(lena|lene|lenaa|dena|vasool|₹|rs\.?|rupees?)\b/i.test(lower)
  ) {
    return true;
  }
  if (
    hasDateOrRelativeDay(lower, raw) &&
    hasTimeOrScheduleCue(lower, raw) &&
    /\b(ko|karna|karni|karne)\b/.test(lower) &&
    /\b(call|phone|mil|bhej|check|follow)\b/i.test(lower)
  ) {
    return true;
  }
  /** "Mujhe kal Rajesh ko call …" without English "reminder" but clear schedule. */
  if (
    /\b(mujhe|mere|meri|mera)\b/i.test(lower) &&
    hasDateOrRelativeDay(lower, raw) &&
    (hasTimeOrScheduleCue(lower, raw) || /\d/.test(lower)) &&
    (hasScheduleAction(lower, raw) || /\b(ko|karna|karni)\b/.test(lower))
  ) {
    return true;
  }
  if (/मुझे|मेरे|मेरी|मेरा/u.test(raw) && H_REL_DAY.test(raw) && (H_TIME.test(raw) || /\d/.test(raw))) {
    return true;
  }
  return false;
}

function isPaymentIntent(lower: string, raw: string): boolean {
  if (isBusinessStatsOrListQuestion(lower)) {
    return false;
  }
  if (
    /\b([A-Za-z][A-Za-z0-9]*)\s+se\s+[\d,₹\sA-Za-z]*\d[\d,₹\s]*(lena|lene|lenaa|leni|dena|deni)\b/i.test(
      raw,
    )
  ) {
    return true;
  }
  const hasMoney = /(₹|rs\.?|rupees?|inr|\b\d{3,7}\b)/i.test(raw);
  const hasCollect = /\b(lena|lene|lenaa|dena|deni|vasool|vasuli|chuk|payment|collect|collection|receive|baki|jamaa?)\b/i.test(
    lower,
  );
  if (hasMoney && hasCollect) {
    return true;
  }
  return false;
}

function isQueryIntent(lower: string): boolean {
  if (isBusinessStatsOrListQuestion(lower)) {
    return true;
  }
  return /\b(kaun|kise|kisko|kisse|kya bata|kitne|kitna|kitni|list|saare|report|dashboard|batao|bata|count|how many|total|names|pichhle|guzre|dues|due|mahine|month|task|birthday|janamdin|pending|follow\s*up)\b/i.test(
    lower,
  );
}

export function isWhoToCallAnalyticsQuestionText(text: string): boolean {
  const t = text.trim();
  if (!t) {
    return false;
  }
  return isWhoToCallAnalyticsQuestion(t.toLowerCase(), t);
}

export function detectIntent(text: string): AivyUserIntent {
  const t = text.trim();
  if (!t) {
    return "general";
  }
  const lower = t.toLowerCase();
  if (isReminderIntent(lower, t)) {
    return "reminder";
  }
  if (isPaymentIntent(lower, t)) {
    return "payment";
  }
  if (isQueryIntent(lower)) {
    return "query";
  }
  return "general";
}

/** When true, [isQuestionIntentText] must not strip reminders (e.g. "kab … reminder lagao"). */
export function looksLikeReminderSchedulingLine(lower: string, raw: string): boolean {
  if (hasReminderKeyword(lower, raw)) {
    return true;
  }
  if (
    /\b(lagao|lagwa|laga do|set reminder|schedule|reminder)\b/i.test(lower) &&
    (hasDateOrRelativeDay(lower, raw) || hasTimeOrScheduleCue(lower, raw) || /\d/.test(lower))
  ) {
    return true;
  }
  if (
    (hasDateOrRelativeDay(lower, raw) || H_REL_DAY.test(raw)) &&
    (hasTimeOrScheduleCue(lower, raw) || /\d\s*(baje|bje|pm|am|:)/i.test(lower)) &&
    (hasScheduleAction(lower, raw) || H_CALL.test(raw))
  ) {
    return true;
  }
  return false;
}

/** Structured debug line for Cloud Logging. */
export function logIntentForDebug(
  text: string,
  intent: AivyUserIntent,
  parsed?: Record<string, string | number | boolean | null | undefined>,
): void {
  // eslint-disable-next-line no-console
  console.log("INPUT:", text);
  // eslint-disable-next-line no-console
  console.log("INTENT:", intent);
  if (parsed) {
    // eslint-disable-next-line no-console
    console.log("PARSED:", JSON.stringify(parsed));
  }
  logger.info("AIVY_INTENT_DEBUG", { INPUT: text, INTENT: intent, parsed });
}
