/**
 * Decide whether a chat turn is a project dump, status query, or item update.
 * Intentionally conservative so payment / single-reminder lines stay on those flows.
 */

const PAYMENT_CUE =
  /\b(payment|pay|invoice|inr|₹|rs\.?|rupees?|lena hai|dena hai paisa|collect|received|due amount)\b/i;

const ORDER_CUE =
  /\b(quotation|quote|dispatch|dispatched|bhej diya|bhej dena|naya order|new order)\b/i;

const PROJECT_WORD =
  /\b(project|proj|saite|site|kaam|job card|plywood site|glass site)\b/i;

const ITEM_KIND_CUE =
  /\b(sample|samples|label|labels|approval|approve|rate|rates|qc|q\.c\.|po\b|p\.o\.|purchase order|follow[\s-]?up|meeting|mulakat|mulaqat|visit|dikha(?:ya|ye|o)?|pasand)\b/i;

const WAITING_CUE =
  /\b(waiting|wait|unpe|un par|unka|unse|unki|unke|client se|approval pending|rate pending|po pending|atka|atki|atke|pending unpe)\b/i;

const QUERY_CUE =
  /\b(kya haal|kya hal|kya atka|kya atki|status|haal hai|kitna pending|kya pending|waiting on|aaj ke (item|kaam)|project mein kya|project ka kya)\b/i;

const TODAY_CUE =
  /\b(aaj (ke )?(project|items?|kaam)|today'?s? (project|items?)|aaj kya (pending|atka)|aaj waiting)\b/i;

const UPDATE_DONE =
  /\b(done|ho gaya|ho gya|complete|completed|mark (as )?done|finish|finished|khatam)\b/i;

const UPDATE_WAITING =
  /\b(waiting( on them)?|unpe atka|un par atka|unse lena|client pe)\b/i;

const UPDATE_CANCEL =
  /\b(cancel|cancelled|mat karo|chhod do|drop (it|karo))\b/i;

const SIMPLE_REMINDER =
  /^(?:[\w.]+ ){0,6}(ko )?(aaj|kal|parso|tomorrow|today).{0,40}\b(call|phone|milna|yaad|remind)/i;

function cueCount(text: string, re: RegExp): number {
  const flags = re.flags.includes("g") ? re.flags : `${re.flags}g`;
  const global = new RegExp(re.source, flags);
  return (text.match(global) ?? []).length;
}

export function looksLikePaymentOrOrderLine(text: string): boolean {
  const t = text.trim();
  if (!t) {
    return false;
  }
  if (PAYMENT_CUE.test(t) && /\d/.test(t)) {
    return true;
  }
  if (ORDER_CUE.test(t) && !ITEM_KIND_CUE.test(t)) {
    return true;
  }
  return false;
}

export function looksLikeSimpleReminder(text: string): boolean {
  const t = text.trim();
  if (t.length > 90) {
    return false;
  }
  if (ITEM_KIND_CUE.test(t) && cueCount(t, ITEM_KIND_CUE) >= 2) {
    return false;
  }
  if (PROJECT_WORD.test(t)) {
    return false;
  }
  return SIMPLE_REMINDER.test(t);
}

export function looksLikeProjectDump(text: string): boolean {
  const t = text.trim();
  if (t.length < 18) {
    return false;
  }
  if (looksLikePaymentOrOrderLine(t)) {
    return false;
  }
  if (looksLikeSimpleReminder(t)) {
    return false;
  }
  if (QUERY_CUE.test(t) || TODAY_CUE.test(t)) {
    return false;
  }
  const kinds = cueCount(t, ITEM_KIND_CUE);
  if (PROJECT_WORD.test(t) && (kinds >= 1 || WAITING_CUE.test(t) || t.length > 40)) {
    return true;
  }
  if (kinds >= 2) {
    return true;
  }
  if (kinds >= 1 && WAITING_CUE.test(t) && t.length >= 28) {
    return true;
  }
  // Multi-clause field note: two+ commas / "aur" with a kind cue.
  const clauses = t.split(/\s*(?:,| aur | and )\s*/i).filter((c) => c.trim().length > 8);
  if (kinds >= 1 && clauses.length >= 3) {
    return true;
  }
  return false;
}

export function looksLikeProjectQuery(text: string): boolean {
  const t = text.trim();
  if (!t) {
    return false;
  }
  if (looksLikePaymentOrOrderLine(t)) {
    return false;
  }
  if (TODAY_CUE.test(t)) {
    return true;
  }
  if (QUERY_CUE.test(t)) {
    return true;
  }
  if (PROJECT_WORD.test(t) && /\b(kya|haal|status|pending|atka|batao|dikhao)\b/i.test(t)) {
    return true;
  }
  return false;
}

export function looksLikeProjectToday(text: string): boolean {
  return TODAY_CUE.test(text.trim());
}

export function looksLikeProjectItemUpdate(text: string): boolean {
  const t = text.trim();
  if (t.length < 8 || t.length > 160) {
    return false;
  }
  if (looksLikeProjectDump(t) || looksLikePaymentOrOrderLine(t)) {
    return false;
  }
  const hasTarget =
    PROJECT_WORD.test(t) || ITEM_KIND_CUE.test(t) || /\b(item|wale|wala|wali)\b/i.test(t);
  const hasStatus = UPDATE_DONE.test(t) || UPDATE_WAITING.test(t) || UPDATE_CANCEL.test(t);
  return hasTarget && hasStatus;
}

export type DetectedProjectTurn =
  | "dump"
  | "query"
  | "today"
  | "update"
  | null;

export function detectProjectTurn(text: string): DetectedProjectTurn {
  const t = text.trim();
  if (!t) {
    return null;
  }
  if (looksLikeProjectToday(t)) {
    return "today";
  }
  if (looksLikeProjectQuery(t)) {
    return "query";
  }
  if (looksLikeProjectItemUpdate(t)) {
    return "update";
  }
  if (looksLikeProjectDump(t)) {
    return "dump";
  }
  return null;
}

/** Pull a likely project/client name from "Pune project ka kya haal hai". */
export function extractProjectNameHint(text: string): string {
  const t = text.trim();
  const named = t.match(
    /\b([A-Za-z][A-Za-z0-9.&'\-]*(?:\s+[A-Za-z][A-Za-z0-9.&'\-]*){0,3})\s+project\b/i,
  );
  if (named?.[1]) {
    return named[1].trim();
  }
  const wale = t.match(
    /\b([A-Za-z][A-Za-z0-9.&'\-]*)\s+(?:wale|wala|wali)\b/i,
  );
  if (wale?.[1] && !/^(yeh|woh|is|us|the|a|an)$/i.test(wale[1])) {
    return wale[1].trim();
  }
  return "";
}
