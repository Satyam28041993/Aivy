/**
 * Read tools. These answer immediately — no draft, no confirmation — because
 * reading cannot damage anything.
 *
 * They return plain data, not prose. The model turns the rows into a sentence,
 * which is what lets "aaj kisko call karna hai" and "koi important cheez hai
 * kya" both work without a template for each phrasing.
 */

import { getFirestore } from "firebase-admin/firestore";
import type { DocumentData, QueryDocumentSnapshot } from "firebase-admin/firestore";

import {
  effectiveRemainingAmount,
  isOpenPaymentDueDoc,
} from "../../paymentSettlement";
import { resolveClient, searchClients } from "../clientResolve";
import { isWindowName, resolveWindow, rowTimeLabel, type WindowName } from "../timeWindow";
import { dataResult, fail, type ToolContext, type ToolResult } from "../toolTypes";
import { runWebSearch } from "../../webSearch";

const MAX_ROWS = 40;

function userRef(uid: string) {
  return getFirestore().collection("users").doc(uid);
}

function str(raw: unknown): string {
  return typeof raw === "string" ? raw.trim() : "";
}

function windowOf(raw: unknown, fallback: WindowName = "today"): WindowName {
  return isWindowName(raw) ? raw : fallback;
}

function num(raw: unknown): number {
  const n = Number(raw);
  return Number.isFinite(n) ? n : 0;
}

/** Reminders carry their instant on `scheduledTimeMs`; be tolerant of older rows. */
function reminderMs(d: DocumentData): number {
  const direct = d.scheduledTimeMs;
  if (typeof direct === "number" && direct > 0) {
    return direct;
  }
  const due = d.dueDateMs;
  if (typeof due === "number" && due > 0) {
    return due;
  }
  const at = d.scheduledAt;
  if (at && typeof at === "object" && "toMillis" in at) {
    return (at as { toMillis(): number }).toMillis();
  }
  return 0;
}

function isPendingReminder(d: DocumentData): boolean {
  const s = String(d.status ?? "pending").toLowerCase();
  return s !== "done" && s !== "completed" && s !== "cancelled" && s !== "paid";
}

interface AgendaRow {
  id: string;
  title: string;
  client: string | null;
  kind: string;
  whenMs: number;
  when: string;
  priority: string | null;
}

async function readReminders(
  ctx: ToolContext,
  startMs: number,
  endMs: number,
  kinds?: Set<string>,
): Promise<AgendaRow[]> {
  const snap = await userRef(ctx.uid).collection("reminders").get();
  const rows: AgendaRow[] = [];
  for (const doc of snap.docs) {
    const d = doc.data();
    if (!isPendingReminder(d)) {
      continue;
    }
    const ms = reminderMs(d);
    if (ms <= 0 || ms < startMs || ms > endMs) {
      continue;
    }
    const sub = String(d.subType ?? "").toLowerCase();
    const type = String(d.type ?? "").toLowerCase();
    const kind = sub || type || "reminder";
    if (kinds && !kinds.has(kind) && !kinds.has(type)) {
      continue;
    }
    rows.push({
      id: doc.id,
      title: String(d.title ?? "").trim(),
      client: str(d.clientName) || null,
      kind,
      whenMs: ms,
      when: rowTimeLabel(ms, ctx.timezone, ctx.nowIso),
      priority: str(d.priority) || null,
    });
  }
  rows.sort((a, b) => a.whenMs - b.whenMs);
  return rows.slice(0, MAX_ROWS);
}

// ---------------------------------------------------------------------------
// get_agenda
// ---------------------------------------------------------------------------

export async function getAgendaTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const name = windowOf(args.window, "today");
  const w = resolveWindow(name, ctx.timezone, ctx.nowIso);

  const only = str(args.only).toLowerCase();
  const kinds = only
    ? new Set(
        only === "calls"
          ? ["call"]
          : only === "meetings"
            ? ["meeting", "meeting_reminder"]
            : only === "followups"
              ? ["followup", "quotation_followup", "payment_followup"]
              : [only],
      )
    : undefined;

  const rows = await readReminders(ctx, w.startMs, w.endMs, kinds);
  return dataResult({
    window: w.name,
    windowLabel: w.label,
    count: rows.length,
    items: rows.map(({ whenMs: _whenMs, ...rest }) => rest),
  });
}

// ---------------------------------------------------------------------------
// get_pending_payments
// ---------------------------------------------------------------------------

interface DueRow {
  id: string;
  client: string;
  amount: number;
  dueMs: number | null;
  due: string | null;
  overdue: boolean;
}

async function readOpenDues(ctx: ToolContext, clientId?: string | null): Promise<DueRow[]> {
  const snap = await userRef(ctx.uid).collection("payments").get();
  const todayStart = resolveWindow("today", ctx.timezone, ctx.nowIso).startMs;
  const rows: DueRow[] = [];
  for (const doc of snap.docs) {
    const d = doc.data();
    if (!isOpenPaymentDueDoc(d)) {
      continue;
    }
    if (clientId && String(d.clientId ?? "") !== clientId) {
      continue;
    }
    const remaining = effectiveRemainingAmount(d);
    if (remaining <= 0) {
      continue;
    }
    const dueRaw = d.dueDateMs;
    const dueMs = typeof dueRaw === "number" && dueRaw > 0 ? dueRaw : null;
    rows.push({
      id: doc.id,
      client: String(d.clientName ?? "").trim(),
      amount: remaining,
      dueMs,
      due: dueMs ? rowTimeLabel(dueMs, ctx.timezone, ctx.nowIso) : null,
      overdue: dueMs != null && dueMs < todayStart,
    });
  }
  rows.sort((a, b) => (a.dueMs ?? Number.MAX_SAFE_INTEGER) - (b.dueMs ?? Number.MAX_SAFE_INTEGER));
  return rows;
}

export async function getPendingPaymentsTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  let clientId: string | null = null;
  const clientName = str(args.client_name);
  if (clientName) {
    const res = await resolveClient(ctx.uid, clientName);
    if (res.status === "ambiguous") {
      return fail(
        "needs_client_choice",
        `"${clientName}" se ek se zyada client match hue — kaunsa?`,
        res.candidates.map((c) => ({ id: c.id, label: c.name })),
      );
    }
    if (res.status === "not_found") {
      return fail("client_not_found", `"${clientName}" naam ka client nahi mila.`);
    }
    clientId = res.client.id;
  }

  const all = await readOpenDues(ctx, clientId);
  const onlyOverdue = args.only_overdue === true || windowOf(args.window, "all") === "overdue";
  const rows = onlyOverdue ? all.filter((r) => r.overdue) : all;
  const total = rows.reduce((sum, r) => sum + r.amount, 0);

  return dataResult({
    count: rows.length,
    totalAmount: total,
    overdueCount: rows.filter((r) => r.overdue).length,
    items: rows.slice(0, MAX_ROWS).map(({ dueMs: _dueMs, ...rest }) => rest),
  });
}

// ---------------------------------------------------------------------------
// get_important
// ---------------------------------------------------------------------------

export async function getImportantTool(ctx: ToolContext): Promise<ToolResult> {
  const today = resolveWindow("today", ctx.timezone, ctx.nowIso);

  const [overdueReminders, todays, dues] = await Promise.all([
    readReminders(ctx, 0, today.startMs - 1),
    readReminders(ctx, today.startMs, today.endMs),
    readOpenDues(ctx),
  ]);

  const overdueDues = dues.filter((d) => d.overdue);
  const dueTotal = overdueDues.reduce((s, d) => s + d.amount, 0);

  // A client is "risky" when several dues have already slipped past.
  const byClient = new Map<string, { count: number; amount: number }>();
  for (const d of overdueDues) {
    const prev = byClient.get(d.client) ?? { count: 0, amount: 0 };
    byClient.set(d.client, { count: prev.count + 1, amount: prev.amount + d.amount });
  }
  const risky = [...byClient.entries()]
    .filter(([, v]) => v.count >= 2)
    .sort((a, b) => b[1].amount - a[1].amount)
    .slice(0, 5)
    .map(([client, v]) => ({ client, overdueCount: v.count, amount: v.amount }));

  return dataResult({
    overdueTasks: {
      count: overdueReminders.length,
      items: overdueReminders.slice(0, 10).map(({ whenMs: _w, ...r }) => r),
    },
    today: {
      count: todays.length,
      items: todays.slice(0, 15).map(({ whenMs: _w, ...r }) => r),
    },
    overduePayments: {
      count: overdueDues.length,
      totalAmount: dueTotal,
      items: overdueDues.slice(0, 10).map(({ dueMs: _d, ...r }) => r),
    },
    riskyClients: risky,
  });
}

// ---------------------------------------------------------------------------
// find_records
// ---------------------------------------------------------------------------

const RECORD_COLLECTIONS: Record<string, string> = {
  quotation: "quotations",
  quotations: "quotations",
  order: "orders",
  orders: "orders",
  payment: "payments",
  payments: "payments",
};

function recordRow(doc: QueryDocumentSnapshot<DocumentData>, ctx: ToolContext) {
  const d = doc.data();
  const created = num(d.createdAtMs);
  return {
    id: doc.id,
    client: String(d.clientName ?? "").trim(),
    amount: num(d.amount),
    status: String(d.status ?? "").trim() || null,
    note: str(d.note) || null,
    createdMs: created,
    created: created ? rowTimeLabel(created, ctx.timezone, ctx.nowIso) : null,
  };
}

export async function findRecordsTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const typeRaw = str(args.type).toLowerCase();

  // Reminders and meetings live in the agenda, not the record collections.
  if (typeRaw === "reminder" || typeRaw === "meeting" || typeRaw === "task") {
    const w = resolveWindow(windowOf(args.window, "all"), ctx.timezone, ctx.nowIso);
    const kinds = typeRaw === "meeting" ? new Set(["meeting", "meeting_reminder"]) : undefined;
    const rows = await readReminders(ctx, w.startMs, w.endMs, kinds);
    const wanted = str(args.client_name).toLowerCase();
    const filtered = wanted
      ? rows.filter((r) => (r.client ?? "").toLowerCase().includes(wanted))
      : rows;
    return dataResult({
      type: typeRaw,
      window: w.name,
      windowLabel: w.label,
      count: filtered.length,
      items: filtered.map(({ whenMs: _w, ...r }) => r),
    });
  }

  const collection = RECORD_COLLECTIONS[typeRaw];
  if (!collection) {
    return fail(
      "invalid",
      "type quotation / order / payment / reminder / meeting me se ek hona chahiye.",
    );
  }

  const w = resolveWindow(windowOf(args.window, "all"), ctx.timezone, ctx.nowIso);
  const snap = await userRef(ctx.uid).collection(collection).get();

  let rows = snap.docs
    .map((doc) => recordRow(doc, ctx))
    .filter((r) => r.createdMs >= w.startMs && r.createdMs <= w.endMs);

  const wanted = str(args.client_name);
  if (wanted) {
    const res = await resolveClient(ctx.uid, wanted);
    const name = res.status === "single" ? res.client.name.toLowerCase() : wanted.toLowerCase();
    rows = rows.filter((r) => r.client.toLowerCase().includes(name));
  }

  rows.sort((a, b) => b.createdMs - a.createdMs);
  const total = rows.reduce((s, r) => s + r.amount, 0);

  return dataResult({
    type: typeRaw,
    window: w.name,
    windowLabel: w.label,
    count: rows.length,
    totalAmount: total,
    clients: [...new Set(rows.map((r) => r.client).filter(Boolean))],
    items: rows.slice(0, MAX_ROWS).map(({ createdMs: _c, ...r }) => r),
  });
}

// ---------------------------------------------------------------------------
// get_client_summary
// ---------------------------------------------------------------------------

export async function getClientSummaryTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const name = str(args.client_name);
  if (!name) {
    return fail("needs_detail", "Kis client ka hisaab chahiye?");
  }
  const res = await resolveClient(ctx.uid, name);
  if (res.status === "ambiguous") {
    return fail(
      "needs_client_choice",
      `"${name}" se ek se zyada client match hue — kaunsa?`,
      res.candidates.map((c) => ({ id: c.id, label: c.name })),
    );
  }
  if (res.status === "not_found") {
    return fail("client_not_found", `"${name}" naam ka client nahi mila.`);
  }
  const client = res.client;
  const lower = client.name.toLowerCase();

  const [quotesSnap, ordersSnap, dues, reminders] = await Promise.all([
    userRef(ctx.uid).collection("quotations").get(),
    userRef(ctx.uid).collection("orders").get(),
    readOpenDues(ctx, client.id),
    readReminders(ctx, 0, Number.MAX_SAFE_INTEGER),
  ]);

  const quotes = quotesSnap.docs
    .map((d) => recordRow(d, ctx))
    .filter((r) => r.client.toLowerCase() === lower);
  const orders = ordersSnap.docs
    .map((d) => recordRow(d, ctx))
    .filter((r) => r.client.toLowerCase() === lower);
  const theirs = reminders.filter((r) => (r.client ?? "").toLowerCase() === lower);

  return dataResult({
    client: client.name,
    quotations: {
      count: quotes.length,
      totalAmount: quotes.reduce((s, r) => s + r.amount, 0),
      recent: quotes.sort((a, b) => b.createdMs - a.createdMs).slice(0, 5)
        .map(({ createdMs: _c, ...r }) => r),
    },
    orders: {
      count: orders.length,
      totalAmount: orders.reduce((s, r) => s + r.amount, 0),
      recent: orders.sort((a, b) => b.createdMs - a.createdMs).slice(0, 5)
        .map(({ createdMs: _c, ...r }) => r),
    },
    pendingDues: {
      count: dues.length,
      totalAmount: dues.reduce((s, r) => s + r.amount, 0),
      items: dues.slice(0, 10).map(({ dueMs: _d, ...r }) => r),
    },
    upcoming: theirs.slice(0, 10).map(({ whenMs: _w, ...r }) => r),
  });
}

// ---------------------------------------------------------------------------
// search_clients
// ---------------------------------------------------------------------------

export async function searchClientsTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const q = str(args.query);
  const found = await searchClients(ctx.uid, q, 15);
  return dataResult({
    query: q,
    count: found.length,
    items: found.map((c) => ({
      id: c.id,
      name: c.name,
      outstandingBalance: c.outstandingBalance,
    })),
  });
}

// ---------------------------------------------------------------------------
// web_search
// ---------------------------------------------------------------------------

export async function webSearchTool(
  _ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const q = str(args.query);
  if (!q) {
    return fail("needs_detail", "Kya search karna hai?");
  }
  const res = await runWebSearch(q);
  if (!res.success) {
    return fail("failed", res.error ?? "Search abhi kaam nahi kar raha.");
  }
  return dataResult({
    query: res.query,
    count: res.results.length,
    results: res.results.slice(0, 6).map((r) => ({
      title: r.title,
      link: r.link,
      snippet: r.snippet,
    })),
  });
}
