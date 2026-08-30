/**
 * Write tools. Each one resolves what the user said into a concrete draft and
 * stops there — nothing reaches the business collections until the user
 * confirms and `commit.ts` replays the draft.
 *
 * Two rules hold across every tool here:
 *   - the client is resolved by `clientResolve`, never guessed by the model;
 *   - the date is resolved by `dateResolve` from a phrase plus the tense and
 *     day period the model read off the sentence, never computed by the model.
 */

import { getFirestore } from "firebase-admin/firestore";

import {
  effectiveRemainingAmount,
  isOpenPaymentDueDoc,
} from "../../paymentSettlement";
import { capitalizeWords } from "../nameNormalize";
import {
  createDraft,
  listPendingDrafts,
  markDraftStatus,
} from "../draftStore";
import { formatWhenLabel, resolveWhen, type DayPeriod, type WhenTense } from "../dateResolve";
import {
  looksLikeNoiseClientName,
  resolveClient,
  type AgentClient,
} from "../clientResolve";
import type { DraftCardLine, DraftClientRef, RememberedFact } from "../draftTypes";
import { draftResult, fail, type ToolContext, type ToolResult } from "../toolTypes";
import { DateTime } from "luxon";

/** Formats ₹ the way the rest of the app does. */
export function formatInr(amount: number): string {
  return `₹${new Intl.NumberFormat("en-IN", { maximumFractionDigits: 0 }).format(amount)}`;
}

function coerceAmount(raw: unknown): number | null {
  if (typeof raw === "number" && Number.isFinite(raw) && raw > 0) {
    return raw;
  }
  if (typeof raw === "string") {
    const cleaned = raw.replace(/[₹,\s]/g, "");
    const n = Number(cleaned);
    if (Number.isFinite(n) && n > 0) {
      return n;
    }
  }
  return null;
}

function str(raw: unknown): string {
  return typeof raw === "string" ? raw.trim() : "";
}

function tenseOf(raw: unknown): WhenTense {
  return raw === "past" ? "past" : "future";
}

function periodOf(raw: unknown): DayPeriod | null {
  const v = str(raw).toLowerCase();
  if (v === "morning" || v === "afternoon" || v === "evening" || v === "night") {
    return v;
  }
  return null;
}

/**
 * Turns a client token into a draft reference, or a failure the agent can ask
 * about. `allowCreate` is false for lookups where inventing a client makes no
 * sense (settling a payment against someone with no dues, say).
 */
async function referenceClient(
  ctx: ToolContext,
  rawName: string,
  allowCreate: boolean,
): Promise<{ ref: DraftClientRef } | { failure: ToolResult }> {
  const name = rawName.trim();
  if (!name) {
    return {
      failure: fail("needs_detail", "Which client is this for?"),
    };
  }
  if (looksLikeNoiseClientName(name)) {
    return {
      failure: fail(
        "needs_detail",
        `"${name}" does not look like a client name — what is the correct name?`,
      ),
    };
  }

  const res = await resolveClient(ctx.uid, name);
  if (res.status === "single") {
    return { ref: { id: res.client.id, name: res.client.name, createNew: false } };
  }
  if (res.status === "ambiguous") {
    return {
      failure: fail(
        "needs_client_choice",
        `"${name}" matches more than one client — which one?`,
        res.candidates.map((c: AgentClient) => ({ id: c.id, label: c.name })),
      ),
    };
  }
  if (!allowCreate) {
    return {
      failure: fail(
        "client_not_found",
        `No client named "${name}" was found.`,
      ),
    };
  }
  // New client — commit will create it, so the card can say so.
  return { ref: { id: null, name: capitalizeWords(name), createNew: true } };
}

function clientLine(ref: DraftClientRef | null): DraftCardLine[] {
  if (!ref) {
    return [];
  }
  return [
    {
      label: "Client",
      value: ref.createNew ? `${ref.name} (new client)` : ref.name,
    },
  ];
}

// ---------------------------------------------------------------------------
// create_meeting
// ---------------------------------------------------------------------------

export async function createMeetingTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const whenPhrase = str(args.when_phrase);
  if (!whenPhrase) {
    return fail("needs_date", "When is the meeting? (e.g. tomorrow 11 am)");
  }
  const when = resolveWhen({
    phrase: whenPhrase,
    timezone: ctx.timezone,
    nowIso: ctx.nowIso,
    tense: tenseOf(args.when_tense),
    period: periodOf(args.day_period),
  });
  if (!when.iso || when.epochMs == null) {
    return fail("needs_date", `Could not read a date from "${whenPhrase}" — say it again?`);
  }

  let clientRef: DraftClientRef | null = null;
  const rawClient = str(args.client_name);
  if (rawClient) {
    const resolved = await referenceClient(ctx, rawClient, true);
    if ("failure" in resolved) {
      return resolved.failure;
    }
    clientRef = resolved.ref;
  }

  const agenda = str(args.agenda);
  const note = str(args.note) || null;
  const lead = typeof args.reminder_lead_minutes === "number"
    ? Math.max(0, Math.min(24 * 60, args.reminder_lead_minutes))
    : 15;

  const reminderAt = DateTime.fromMillis(when.epochMs, { zone: ctx.timezone })
    .minus({ minutes: lead });

  const lines: DraftCardLine[] = [
    ...clientLine(clientRef),
    { label: "When", value: when.label ?? whenPhrase },
  ];
  if (agenda) {
    lines.push({ label: "Regarding", value: agenda });
  }
  lines.push({
    label: "Reminder",
    value: `${lead} min before — ${reminderAt.toFormat("h:mm a")}`,
  });

  // Only promise the calendar when this turn actually carries a Google token —
  // a card that says "Calendar par bhi jaayega" and then does not is worse than
  // one that never mentioned it.
  const hasGoogle = typeof ctx.googleToken === "string" && ctx.googleToken.trim().length > 0;
  const addToCalendar = hasGoogle && args.add_to_calendar !== false;
  const durationMinutes = typeof args.duration_minutes === "number"
    ? Math.max(15, Math.min(12 * 60, args.duration_minutes))
    : 60;
  if (addToCalendar) {
    lines.push({ label: "Calendar", value: `Also on Google Calendar (${durationMinutes} min)` });
  }

  if (note) {
    lines.push({ label: "Note", value: note });
  }

  const draft = await createDraft({
    uid: ctx.uid,
    kind: "meeting",
    title: "Meeting",
    icon: "📅",
    lines,
    chatId: ctx.chatId,
    data: {
      kind: "meeting",
      client: clientRef,
      agenda,
      whenIso: when.iso,
      whenMs: when.epochMs,
      whenLabel: when.label ?? whenPhrase,
      reminderLeadMinutes: lead,
      note,
      addToCalendar,
      durationMinutes,
    },
  });

  return draftResult(
    draft,
    "Meeting draft ready, with its reminder. Ask the user to confirm — nothing is saved yet.",
  );
}

// ---------------------------------------------------------------------------
// create_reminder
// ---------------------------------------------------------------------------

const REMINDER_TYPES = new Set(["call", "followup", "task", "meeting", "personal"]);

export async function createReminderTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const title = str(args.title);
  if (!title) {
    return fail("needs_detail", "What is the reminder for?");
  }
  const whenPhrase = str(args.when_phrase);
  if (!whenPhrase) {
    return fail("needs_date", "When should I remind you?");
  }
  const when = resolveWhen({
    phrase: whenPhrase,
    timezone: ctx.timezone,
    nowIso: ctx.nowIso,
    tense: tenseOf(args.when_tense),
    period: periodOf(args.day_period),
  });
  if (!when.iso || when.epochMs == null) {
    return fail("needs_date", `Could not read a time from "${whenPhrase}" — say it again?`);
  }

  let clientRef: DraftClientRef | null = null;
  const rawClient = str(args.client_name);
  if (rawClient) {
    const resolved = await referenceClient(ctx, rawClient, true);
    if ("failure" in resolved) {
      return resolved.failure;
    }
    clientRef = resolved.ref;
  }

  const rawType = str(args.reminder_type).toLowerCase();
  const reminderType = REMINDER_TYPES.has(rawType) ? rawType : "task";
  const priorityRaw = str(args.priority).toLowerCase();
  const priority = ["high", "medium", "low"].includes(priorityRaw) ? priorityRaw : "medium";
  const note = str(args.note) || null;

  // "every month on the 5th" sets one reminder, not a series. Saying so on the
  // card beats a cheerful "set for every month" that quietly is not true.
  const repeats =
    /\b(har|every|each)\s+(mahine|month|hafte|week|din|day|saal|year)\b|\b(daily|weekly|monthly|roz|rozana)\b/i
      .test(`${whenPhrase} ${title}`);

  const lines: DraftCardLine[] = [
    { label: "Task", value: title },
    ...clientLine(clientRef),
    { label: "When", value: when.label ?? whenPhrase },
  ];
  if (priority !== "medium") {
    lines.push({ label: "Priority", value: capitalizeWords(priority) });
  }
  if (repeats) {
    lines.push({
      label: "Heads up",
      value: "One-time only — repeating reminders are not supported yet",
    });
  }
  if (note) {
    lines.push({ label: "Note", value: note });
  }

  const icon = reminderType === "call" ? "📞" : reminderType === "followup" ? "🔁" : "⏰";
  const titleLabel =
    reminderType === "call"
      ? "Call reminder"
      : reminderType === "followup"
        ? "Follow-up"
        : reminderType === "personal"
          ? "Personal reminder"
          : "Reminder";

  const draft = await createDraft({
    uid: ctx.uid,
    kind: "reminder",
    title: titleLabel,
    icon,
    lines,
    chatId: ctx.chatId,
    data: {
      kind: "reminder",
      title,
      client: clientRef,
      whenIso: when.iso,
      whenMs: when.epochMs,
      whenLabel: when.label ?? whenPhrase,
      reminderType,
      priority,
      note,
    },
  });

  return draftResult(
    draft,
    repeats
        ? "Reminder drafted. It is ONE reminder, not a repeating one — say that " +
            "plainly before they confirm."
        : "Reminder drafted — ask them to confirm. Nothing is saved yet.",
  );
}

// ---------------------------------------------------------------------------
// record_quotation
// ---------------------------------------------------------------------------

export async function recordQuotationTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const amount = coerceAmount(args.amount);
  if (amount == null) {
    return fail("needs_amount", "What was the quotation amount?");
  }
  const resolved = await referenceClient(ctx, str(args.client_name), true);
  if ("failure" in resolved) {
    return resolved.failure;
  }

  // Follow-up defaults to a week out when the user did not say.
  const followPhrase = str(args.followup_phrase) || "7 din baad";
  const follow = resolveWhen({
    phrase: followPhrase,
    timezone: ctx.timezone,
    nowIso: ctx.nowIso,
    tense: "future",
    period: periodOf(args.day_period),
  });
  const followMs = follow.epochMs
    ?? DateTime.fromISO(ctx.nowIso, { zone: ctx.timezone }).plus({ days: 7 }).toMillis();
  const followIso = follow.iso
    ?? DateTime.fromMillis(followMs, { zone: ctx.timezone }).toISO()!;
  const followLabel = follow.label
    ?? formatWhenLabel(DateTime.fromMillis(followMs, { zone: ctx.timezone }), true);

  const note = str(args.note) || null;
  const lines: DraftCardLine[] = [
    ...clientLine(resolved.ref),
    { label: "Amount", value: formatInr(amount) },
    { label: "Follow-up", value: followLabel },
  ];
  if (note) {
    lines.push({ label: "Note", value: note });
  }

  const draft = await createDraft({
    uid: ctx.uid,
    kind: "quotation",
    title: "Quotation",
    icon: "📄",
    lines,
    chatId: ctx.chatId,
    data: {
      kind: "quotation",
      client: resolved.ref,
      amount,
      followUpIso: followIso,
      followUpMs: followMs,
      followUpLabel: followLabel,
      note,
    },
  });

  return draftResult(
    draft,
    "Quotation drafted, with its follow-up reminder. Ask them to confirm — nothing is saved yet.",
  );
}

// ---------------------------------------------------------------------------
// record_order
// ---------------------------------------------------------------------------

export async function recordOrderTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const amount = coerceAmount(args.amount);
  if (amount == null) {
    return fail("needs_amount", "What is the order amount?");
  }
  const resolved = await referenceClient(ctx, str(args.client_name), true);
  if ("failure" in resolved) {
    return resolved.failure;
  }
  const note = str(args.note) || null;

  const lines: DraftCardLine[] = [
    ...clientLine(resolved.ref),
    { label: "Amount", value: formatInr(amount) },
  ];
  if (note) {
    lines.push({ label: "Note", value: note });
  }

  const draft = await createDraft({
    uid: ctx.uid,
    kind: "order",
    title: "Order",
    icon: "📦",
    lines,
    chatId: ctx.chatId,
    data: { kind: "order", client: resolved.ref, amount, note },
  });

  return draftResult(draft, "Order drafted — ask them to confirm.");
}

// ---------------------------------------------------------------------------
// record_payment_due
// ---------------------------------------------------------------------------

export async function recordPaymentDueTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const amount = coerceAmount(args.amount);
  if (amount == null) {
    return fail("needs_amount", "How much is due?");
  }
  const resolved = await referenceClient(ctx, str(args.client_name), true);
  if ("failure" in resolved) {
    return resolved.failure;
  }

  const duePhrase = str(args.due_phrase) || "30 din baad";
  const due = resolveWhen({
    phrase: duePhrase,
    timezone: ctx.timezone,
    nowIso: ctx.nowIso,
    tense: "future",
  });
  const dueMs = due.epochMs
    ?? DateTime.fromISO(ctx.nowIso, { zone: ctx.timezone }).plus({ days: 30 }).toMillis();
  const dueIso = due.iso ?? DateTime.fromMillis(dueMs, { zone: ctx.timezone }).toISO()!;
  const dueLabel = due.label
    ?? formatWhenLabel(DateTime.fromMillis(dueMs, { zone: ctx.timezone }), false);

  const note = str(args.note) || null;
  const lines: DraftCardLine[] = [
    ...clientLine(resolved.ref),
    { label: "Amount", value: formatInr(amount) },
    { label: "Due date", value: dueLabel },
  ];
  if (note) {
    lines.push({ label: "Note", value: note });
  }

  const draft = await createDraft({
    uid: ctx.uid,
    kind: "payment_due",
    title: "Payment due",
    icon: "💰",
    lines,
    chatId: ctx.chatId,
    data: {
      kind: "payment_due",
      client: resolved.ref,
      amount,
      dueIso,
      dueMs,
      dueLabel,
      note,
    },
  });

  return draftResult(draft, "Payment due drafted — ask them to confirm.");
}

// ---------------------------------------------------------------------------
// record_payment_received
// ---------------------------------------------------------------------------

/** Open dues for a client, largest-match-first so settlement picks sensibly. */
async function openDuesForClient(
  uid: string,
  clientId: string | null,
  clientName: string,
): Promise<Array<{ paymentId: string; remaining: number; dueMs: number | null; label: string }>> {
  const db = getFirestore();
  const snap = await db.collection("users").doc(uid).collection("payments").get();
  const out: Array<{ paymentId: string; remaining: number; dueMs: number | null; label: string }> = [];
  const wantLower = clientName.trim().toLowerCase();

  for (const doc of snap.docs) {
    const d = doc.data();
    if (!isOpenPaymentDueDoc(d)) {
      continue;
    }
    const docClientId = String(d.clientId ?? "").trim();
    const docName = String(d.clientName ?? "").trim();
    const matches = clientId
      ? docClientId === clientId
      : docName.toLowerCase() === wantLower;
    if (!matches) {
      continue;
    }
    const remaining = effectiveRemainingAmount(d);
    if (remaining <= 0) {
      continue;
    }
    const dueRaw = d.dueDateMs;
    const dueMs = typeof dueRaw === "number" ? dueRaw : null;
    out.push({
      paymentId: doc.id,
      remaining,
      dueMs,
      label: `${formatInr(remaining)}${dueMs ? ` · due ${DateTime.fromMillis(dueMs).toFormat("d MMM")}` : ""}`,
    });
  }
  out.sort((a, b) => (a.dueMs ?? Number.MAX_SAFE_INTEGER) - (b.dueMs ?? Number.MAX_SAFE_INTEGER));
  return out;
}

export async function recordPaymentReceivedTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const amount = coerceAmount(args.amount);
  if (amount == null) {
    return fail("needs_amount", "How much was received?");
  }
  // Settling against a client with no record at all makes no sense, so this one
  // does not offer to create.
  const resolved = await referenceClient(ctx, str(args.client_name), false);
  if ("failure" in resolved) {
    return resolved.failure;
  }

  const whenPhrase = str(args.when_phrase) || "aaj";
  const when = resolveWhen({
    phrase: whenPhrase,
    timezone: ctx.timezone,
    nowIso: ctx.nowIso,
    // Money that "aaya" already happened.
    tense: tenseOf(args.when_tense ?? "past"),
  });
  const receivedMs = when.epochMs ?? DateTime.fromISO(ctx.nowIso, { zone: ctx.timezone }).toMillis();
  const receivedIso = when.iso ?? DateTime.fromMillis(receivedMs, { zone: ctx.timezone }).toISO()!;
  const receivedLabel = when.label
    ?? formatWhenLabel(DateTime.fromMillis(receivedMs, { zone: ctx.timezone }), false);

  // No open due is not a dead end. The money did arrive; recording it as a
  // standalone receipt is right, and refusing would lose the fact entirely.
  const dues = await openDuesForClient(ctx.uid, resolved.ref.id, resolved.ref.name);

  // Prefer an exact-amount match, else settle oldest-first.
  const exact = dues.filter((d) => Math.abs(d.remaining - amount) < 0.01);
  const targets = exact.length === 1 ? exact : dues;

  const note = str(args.note) || null;
  const lines: DraftCardLine[] = [
    ...clientLine(resolved.ref),
    { label: "Receive", value: formatInr(amount) },
    { label: "When", value: receivedLabel },
    {
      label: "Applied to",
      value: targets.length === 0
          ? "No open due — recorded on its own"
          : targets.length === 1
              ? targets[0]!.label
              : `${targets.length} open dues — oldest first`,
    },
  ];
  if (note) {
    lines.push({ label: "Note", value: note });
  }

  const draft = await createDraft({
    uid: ctx.uid,
    kind: "payment_received",
    title: "Payment received",
    icon: "✅",
    lines,
    chatId: ctx.chatId,
    data: {
      kind: "payment_received",
      client: resolved.ref,
      amount,
      receivedIso,
      receivedMs,
      receivedLabel,
      targets,
      note,
    },
  });

  return draftResult(draft, "Receipt drafted — ask them to confirm.");
}

// ---------------------------------------------------------------------------
// remember_fact
// ---------------------------------------------------------------------------

/**
 * A key per subject, not per category.
 *
 * Memory is one flat document, so whatever a fact is filed under is what it
 * overwrites. Filing by category meant the second "family" fact erased the
 * first — tell it about your wife and then your daughter, and your wife was
 * gone. The key is the subject itself, so facts accumulate.
 */
function factKey(raw: string, fallback: string): string {
  const key = raw
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 40);
  return key || fallback;
}

/** Both shapes of the argument: one fact, or a batch of them. */
function factsFrom(args: Record<string, unknown>): RememberedFact[] {
  const out: RememberedFact[] = [];
  const seen = new Set<string>();

  const push = (rawKey: string, rawValue: string, fallbackKey: string) => {
    const value = rawValue.trim();
    if (!value) {
      return;
    }
    const key = factKey(rawKey, fallbackKey);
    if (seen.has(key)) {
      return;
    }
    seen.add(key);
    out.push({ key, value });
  };

  const batch = Array.isArray(args.facts) ? args.facts : [];
  batch.forEach((raw, i) => {
    if (raw == null || typeof raw !== "object") {
      return;
    }
    const row = raw as Record<string, unknown>;
    push(str(row.key) || str(row.category), str(row.value) || str(row.fact), `fact_${i + 1}`);
  });

  // The single-fact form still works, and is what a passing remark uses.
  push(str(args.key) || str(args.category), str(args.fact) || str(args.value), "note");

  return out;
}

export async function rememberFactTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const facts = factsFrom(args);
  if (facts.length === 0) {
    return fail("needs_detail", "What should I remember?");
  }

  const draft = await createDraft({
    uid: ctx.uid,
    kind: "remember_fact",
    title: facts.length === 1 ? "Remember this" : `Remember ${facts.length} things`,
    icon: "🧠",
    lines: facts.map((f) => ({
      label: capitalizeWords(f.key.replace(/_/g, " ")),
      value: f.value,
    })),
    chatId: ctx.chatId,
    data: {
      kind: "remember_fact",
      // Kept so a draft written by this build still reads on the old path.
      category: facts[0]!.key,
      fact: facts[0]!.value,
      facts,
    },
  });

  return draftResult(draft, "Ready to remember this — ask them to confirm.");
}

// ---------------------------------------------------------------------------
// cancel_draft — the user changed their mind mid-sentence
// ---------------------------------------------------------------------------

export async function cancelDraftTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const draftId = str(args.draft_id);
  if (draftId) {
    await markDraftStatus(ctx.uid, draftId, "cancelled");
    return draftResultless("Draft cancel kar diya.");
  }
  const pending = await listPendingDrafts(ctx.uid, ctx.chatId, 1);
  if (pending.length === 0) {
    return fail("nothing_found", "There is no pending card to cancel.");
  }
  await markDraftStatus(ctx.uid, pending[0]!.id, "cancelled");
  return draftResultless("Draft cancel kar diya.");
}

function draftResultless(message: string): ToolResult {
  return { ok: true, kind: "data", data: { cancelled: true, message } };
}
