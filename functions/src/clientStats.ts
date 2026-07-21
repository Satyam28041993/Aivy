import {
  getFirestore,
  FieldValue,
  FieldPath,
  type CollectionReference,
  type DocumentData,
  type QueryDocumentSnapshot,
} from "firebase-admin/firestore";
import { DateTime } from "luxon";
import { logger } from "firebase-functions";
import {
  isOpenDueStatus,
  isOpenPaymentDueDoc,
  openDueRollupAmount,
} from "./paymentSettlement";

const pendingRebuild = new Map<string, ReturnType<typeof setTimeout>>();

/**
 * Coalesces rapid writes (e.g. batch imports) to a single recompute.
 */
export function scheduleRebuildClientStats(uid: string, timeZone = "Asia/Kolkata"): void {
  const prev = pendingRebuild.get(uid);
  if (prev) {
    clearTimeout(prev);
  }
  pendingRebuild.set(
    uid,
    setTimeout(() => {
      pendingRebuild.delete(uid);
      void rebuildClientStatsForUser(uid, timeZone).catch((err) => {
        logger.error("scheduleRebuildClientStats failed", {
          uid,
          err: err instanceof Error ? err.message : String(err),
        });
      });
    }, 2000),
  );
}

const SC_LIMIT = 3000;
const MS_PER_DAY = 86400000;

/**
 * Reads an entire subcollection in stable document-id order (batched),
 * avoiding the silent truncation of a single `.limit(n)` query.
 */
async function fetchAllDocsOrderedById(
  col: CollectionReference<DocumentData>,
): Promise<QueryDocumentSnapshot<DocumentData>[]> {
  const out: QueryDocumentSnapshot<DocumentData>[] = [];
  let q = col.orderBy(FieldPath.documentId()).limit(SC_LIMIT);
  for (;;) {
    const snap = await q.get();
    out.push(...snap.docs);
    if (snap.size < SC_LIMIT) {
      break;
    }
    const last = snap.docs[snap.docs.length - 1]!;
    q = col.orderBy(FieldPath.documentId()).startAfter(last).limit(SC_LIMIT);
  }
  return out;
}

export type RiskTag = "good" | "average" | "risky";

export type ClientStatDoc = {
  clientKey: string;
  clientName: string;
  totalBusiness: number;
  totalPending: number;
  lastOrderDateMs: number;
  lastPaymentDateMs: number;
  paymentDelayAvg: number;
  riskTag: RiskTag;
  updatedAtMs: number;
};

export type DailySummaryResult = {
  totalDue: number;
  overdueAmount: number;
  todayDueCount: number;
  riskyClientsCount: number;
  asOfMs: number;
  oneLiner: string;
  fullText: string;
};

function normalizeKey(name: string): string {
  return name.trim().toLowerCase().replace(/\s+/g, " ");
}

function orderAmount(d: DocumentData): number {
  const inv = Number((d as { invoiceAmount?: number }).invoiceAmount);
  if (Number.isFinite(inv) && inv > 0) {
    return inv;
  }
  const a = Number((d as { amount?: number }).amount);
  return Number.isFinite(a) ? a : 0;
}

function orderCancelled(d: DocumentData): boolean {
  const s = String((d as { status?: string }).status ?? "")
    .trim()
    .toLowerCase();
  return s === "cancelled" || s === "canceled";
}

function orderClientName(d: DocumentData): string {
  const t = String(
    (d as { clientName?: string }).clientName ??
      (d as { client?: string }).client ??
      "",
  ).trim();
  return t || "Unknown";
}

function paymentDueMs(d: DocumentData): number {
  const n = readEpochMs((d as { dueDateMs?: unknown }).dueDateMs);
  if (n > 0) {
    return n;
  }
  const pdm = readEpochMs((d as { paymentDueDateMs?: unknown }).paymentDueDateMs);
  if (pdm > 0) {
    return pdm;
  }
  const pd = (d as { paymentDueDate?: unknown }).paymentDueDate;
  if (pd && typeof (pd as { toMillis?: () => number }).toMillis === "function") {
    const m = (pd as { toMillis: () => number }).toMillis();
    if (m > 0) {
      return m;
    }
  }
  const iso = (d as { dueDateIso?: string }).dueDateIso;
  if (typeof iso === "string" && iso.trim().length > 0) {
    const dt = DateTime.fromISO(iso.trim(), { setZone: true });
    if (dt.isValid) {
      return dt.toMillis();
    }
  }
  return 0;
}

function readEpochMs(v: unknown): number {
  if (typeof v === "number" && Number.isFinite(v) && v > 0) {
    return v;
  }
  return 0;
}

function paymentAmount(d: DocumentData): number {
  const raw = (d as { amount?: unknown }).amount;
  if (typeof raw === "number" && Number.isFinite(raw) && raw > 0) {
    return raw;
  }
  if (typeof raw === "string") {
    const n = Number(String(raw).replace(/[,₹\s]/g, ""));
    return Number.isFinite(n) && n > 0 ? n : 0;
  }
  return 0;
}

function isPendingPay(d: DocumentData): boolean {
  return isOpenDueStatus((d as { status?: unknown }).status);
}

function isPaidPay(d: DocumentData): boolean {
  const s = String((d as { status?: string }).status ?? "")
    .trim()
    .toLowerCase();
  return s === "paid" || s === "completed";
}

function isStructuredOpenPaymentDue(d: DocumentData): boolean {
  if ((d as { legacyMigrated?: unknown }).legacyMigrated === true) {
    return false;
  }
  const typ = String((d as { type?: string }).type ?? "").trim().toLowerCase();
  if (typ !== "payment") {
    return false;
  }
  const st = String((d as { status?: string }).status ?? "pending")
    .trim()
    .toLowerCase();
  if (st === "completed" || st === "reverted") {
    return false;
  }
  const stp = String((d as { subType?: string }).subType ?? "").trim().toLowerCase();
  if (stp === "payment_received") {
    return false;
  }
  return true;
}

function rollupKeyForPaymentLikeDoc(
  d: DocumentData,
  displayName: string,
): string {
  const cid = String((d as { clientId?: string }).clientId ?? "").trim();
  if (cid.length > 0) {
    return `cid:${cid}`;
  }
  const ckRaw = String((d as { clientKey?: string }).clientKey ?? "").trim();
  return (
    normalizeKey(String(ckRaw || displayName || "unknown").trim()) || "unknown"
  );
}

function bumpPendingMap(
  byKey: Map<string, { name: string; total: number }>,
  key: string,
  displayName: string,
  amount: number,
): void {
  const prev = byKey.get(key);
  if (prev != null) {
    prev.total += amount;
    if (displayName.length > prev.name.length) {
      prev.name = displayName;
    }
  } else {
    byKey.set(key, { name: displayName, total: amount });
  }
}

async function mergeStructuredOpenPaymentDues(
  uid: string,
  byKey: Map<string, { name: string; total: number }>,
): Promise<void> {
  const col = getFirestore()
    .collection("users")
    .doc(uid)
    .collection("structured_actions");
  const allDocs = await fetchAllDocsOrderedById(col);
  for (const doc of allDocs) {
    const d = doc.data() as DocumentData;
    const typ = String((d as { type?: string }).type ?? "").trim().toLowerCase();
    if (typ !== "payment") {
      continue;
    }
    if (!isStructuredOpenPaymentDue(d)) {
      continue;
    }
    const amount = paymentAmount(d);
    const name = String((d as { name?: string }).name ?? "").trim() || "Unknown";
    const k = rollupKeyForPaymentLikeDoc(d, name);
    bumpPendingMap(byKey, k, name, amount);
  }
}

export type PendingByClientAgg = {
  clientKey: string;
  clientName: string;
  totalPending: number;
};

/**
 * Live rollup: `payments` open dues + legacy `structured_actions` type payment
 * (matches Flutter [_collectAllOpenDueRows] idea; groups by clientId when set).
 */
export async function computeTopClientsByOpenDues(
  uid: string,
  limit: number,
): Promise<PendingByClientAgg[]> {
  const docs = await fetchAllPayments(uid);
  const byKey = new Map<string, { name: string; total: number }>();
  for (const d of docs) {
    if (!isOpenPaymentDueDoc(d)) {
      continue;
    }
    const amount = openDueRollupAmount(d);
    const name = String(
      (d as { clientName?: string }).clientName ??
        (d as { client?: string }).client ??
        "",
    )
      .trim() || "Unknown";
    const k = rollupKeyForPaymentLikeDoc(d, name);
    bumpPendingMap(byKey, k, name, amount);
  }
  await mergeStructuredOpenPaymentDues(uid, byKey);
  const out: PendingByClientAgg[] = [...byKey.entries()].map(([key, v]) => ({
    clientKey: key,
    clientName: v.name,
    totalPending: v.total,
  }));
  out.sort((a, b) => b.totalPending - a.totalPending);
  const n = Math.max(0, Math.floor(limit));
  return out.slice(0, n);
}

type Agg = {
  clientKey: string;
  displayName: string;
  totalBusiness: number;
  totalPending: number;
  lastOrderDateMs: number;
  lastPaymentDateMs: number;
  /** Sum of per-payment delay in days (non-negative) for averaging */
  paidDelayDaySum: number;
  paidDelayCount: number;
};

function emptyAgg(k: string, name: string): Agg {
  return {
    clientKey: k,
    displayName: name,
    totalBusiness: 0,
    totalPending: 0,
    lastOrderDateMs: 0,
    lastPaymentDateMs: 0,
    paidDelayDaySum: 0,
    paidDelayCount: 0,
  };
}

export function riskFromAvgDelayDay(avg: number, paidCount: number): RiskTag {
  if (paidCount === 0) {
    return "average";
  }
  if (avg <= 0) {
    return "good";
  }
  if (avg > 5) {
    return "risky";
  }
  if (avg >= 1) {
    return "average";
  }
  return "good";
}

/**
 * Recomputes per-client aggregates from all orders + payments, writes
 * `users/{uid}/client_stats/{clientKey}` and `users/{uid}/meta/client_insights`.
 */
/**
 * Public alias: returns the same roll-up as [rebuildClientStatsForUser]
 * (totals + one-liner for AI / UI).
 */
export async function generateDailySummary(
  uid: string,
  timeZone = "Asia/Kolkata",
): Promise<DailySummaryResult> {
  return rebuildClientStatsForUser(uid, timeZone);
}

export async function rebuildClientStatsForUser(
  uid: string,
  timeZone = "Asia/Kolkata",
): Promise<DailySummaryResult> {
  const db = getFirestore();
  const nowMs = Date.now();
  const [orderDocs, payDocs] = await Promise.all([
    fetchAllDocsOrderedById(
      db.collection("users").doc(uid).collection("orders"),
    ),
    fetchAllDocsOrderedById(
      db.collection("users").doc(uid).collection("payments"),
    ),
  ]);
  const byKey = new Map<string, Agg>();

  for (const doc of orderDocs) {
    const d = doc.data() as DocumentData;
    if (orderCancelled(d)) {
      continue;
    }
    const name = orderClientName(d);
    const k = normalizeKey(
      String((d as { clientKey?: string }).clientKey ?? name) || name,
    ) || "unknown";
    if (!byKey.has(k)) {
      byKey.set(k, emptyAgg(k, name));
    }
    const a = byKey.get(k)!;
    a.totalBusiness += orderAmount(d);
    const cMs = readEpochMs(
      (d as { createdAtMs?: number }).createdAtMs,
    );
    if (cMs > a.lastOrderDateMs) {
      a.lastOrderDateMs = cMs;
    }
  }

  for (const doc of payDocs) {
    const d = doc.data() as DocumentData;
    const name = String(
      (d as { clientName?: string }).clientName ??
        (d as { client?: string }).client ??
        "Unknown",
    ).trim() || "Unknown";
    const k = normalizeKey(
      String((d as { clientKey?: string }).clientKey ?? name) || name,
    ) || "unknown";
    if (!byKey.has(k)) {
      byKey.set(k, emptyAgg(k, name));
    }
    const a = byKey.get(k)!;
    const amount = paymentAmount(d);
    if (isPendingPay(d)) {
      a.totalPending += amount;
    }
    if (isPaidPay(d)) {
      const paidAt = readEpochMs(
        (d as { paidAtMs?: number }).paidAtMs,
      );
      if (paidAt > a.lastPaymentDateMs) {
        a.lastPaymentDateMs = paidAt;
      }
      const due = paymentDueMs(d);
      if (due > 0 && paidAt > 0) {
        const daysLate = Math.max(0, (paidAt - due) / MS_PER_DAY);
        a.paidDelayDaySum += daysLate;
        a.paidDelayCount += 1;
      }
    }
  }

  const batchSize = 400;
  const entries = [...byKey.entries()];
  for (let i = 0; i < entries.length; i += batchSize) {
    const b = db.batch();
    for (const [k, v] of entries.slice(i, i + batchSize)) {
      const avg =
        v.paidDelayCount > 0
          ? v.paidDelayDaySum / v.paidDelayCount
          : 0;
      const risk = riskFromAvgDelayDay(avg, v.paidDelayCount);
      const ref = db
        .collection("users")
        .doc(uid)
        .collection("client_stats")
        .doc(encodeKeyForDocId(k));
      b.set(ref, {
        clientKey: k,
        clientName: v.displayName,
        totalBusiness: v.totalBusiness,
        totalPending: v.totalPending,
        lastOrderDateMs: v.lastOrderDateMs,
        lastPaymentDateMs: v.lastPaymentDateMs,
        paymentDelayAvg: Math.round(avg * 100) / 100,
        riskTag: risk,
        updatedAtMs: nowMs,
        updatedAt: FieldValue.serverTimestamp(),
      } satisfies Record<string, unknown>);
    }
    await b.commit();
  }

  const summary = buildDailySnapshotFromLivePayments(
    payDocs.map((d) => d.data() as DocumentData),
    byKey,
    timeZone,
    nowMs,
  );

  await db
    .collection("users")
    .doc(uid)
    .collection("meta")
    .doc("client_insights")
    .set(
      {
        totalDue: summary.totalDue,
        overdueAmount: summary.overdueAmount,
        todayDueCount: summary.todayDueCount,
        riskyClientsCount: summary.riskyClientsCount,
        oneLiner: summary.oneLiner,
        fullText: summary.fullText,
        asOfMs: summary.asOfMs,
        timeZone,
        updatedAtMs: nowMs,
        updatedAt: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

  logger.info("rebuildClientStatsForUser done", {
    uid,
    clients: byKey.size,
  });
  return summary;
}

function encodeKeyForDocId(k: string): string {
  const t = k.trim() || "unknown";
  if (/^[a-z0-9 _.-]{1,200}$/i.test(t) && t.length < 150) {
    return t;
  }
  return Buffer.from(t, "utf8").toString("base64url").slice(0, 200);
}

function isCalendarToday(ms: number, zone: string, nowMs: number): boolean {
  const d = DateTime.fromMillis(ms, { zone: "UTC" }).setZone(zone);
  const n = DateTime.fromMillis(nowMs, { zone: "UTC" }).setZone(zone);
  if (!d.isValid || !n.isValid) {
    return false;
  }
  return d.year === n.year && d.month === n.month && d.day === n.day;
}

/**
 * Server dashboard slice for the notification engine and `getDashboardStats` callable.
 * - `overdueCount`: due before the start of the local calendar day, still open.
 * - `todayDueCount`: due on the local calendar day (inclusive of same-day past times), still open.
 * - `followUpsToday`: open items that are either overdue in time or due calendar-today (action list).
 */
export type DashboardEngineStats = {
  todayDueCount: number;
  overdueCount: number;
  followUpsToday: number;
  totalPendingAmount: number;
};

export function computeDashboardEngineStats(
  payDocs: DocumentData[],
  timeZone: string,
  nowMs: number,
): DashboardEngineStats {
  const zone = (timeZone && timeZone.trim()) || "Asia/Kolkata";
  const nowZ = DateTime.fromMillis(nowMs, { zone: "UTC" }).setZone(zone);
  if (!nowZ.isValid) {
    return {
      todayDueCount: 0,
      overdueCount: 0,
      followUpsToday: 0,
      totalPendingAmount: 0,
    };
  }
  const startOfToday = nowZ.startOf("day");
  const endOfToday = nowZ.endOf("day");
  const startOfTodayMs = startOfToday.toMillis();
  const endOfTodayMs = endOfToday.toMillis();

  let todayDueCount = 0;
  let overdueCount = 0;
  let totalPendingAmount = 0;
  for (const d of payDocs) {
    if (!isOpenPaymentDueDoc(d)) {
      continue;
    }
    const due = paymentDueMs(d);
    if (due <= 0) {
      continue;
    }
    const amt = openDueRollupAmount(d);
    totalPendingAmount += amt;
    if (due < startOfTodayMs) {
      overdueCount += 1;
    } else if (due <= endOfTodayMs) {
      todayDueCount += 1;
    }
  }
  const followUpRows = computeFollowupRows(payDocs, zone, nowMs);
  return {
    todayDueCount,
    overdueCount,
    followUpsToday: followUpRows.length,
    totalPendingAmount,
  };
}

export async function getDashboardEngineStats(
  uid: string,
  timeZone: string,
): Promise<DashboardEngineStats> {
  const payDocs = await fetchAllPayments(uid);
  return computeDashboardEngineStats(payDocs, timeZone, Date.now());
}

function buildDailySnapshotFromLivePayments(
  payDocs: DocumentData[],
  byKey: Map<string, Agg>,
  timeZone: string,
  nowMs: number,
): DailySummaryResult {
  let totalDue = 0;
  let overdueAmount = 0;
  for (const d of payDocs) {
    if (!isOpenPaymentDueDoc(d)) {
      continue;
    }
    const amt = openDueRollupAmount(d);
    totalDue += amt;
    const due = paymentDueMs(d);
    if (due > 0 && due < nowMs) {
      overdueAmount += amt;
    }
  }
  const followUps = computeFollowupRows(payDocs, timeZone, nowMs);
  const todayDueCount = followUps.length;

  let riskyClientsCount = 0;
  for (const v of byKey.values()) {
    const avg =
      v.paidDelayCount > 0
        ? v.paidDelayDaySum / v.paidDelayCount
        : 0;
    if (riskFromAvgDelayDay(avg, v.paidDelayCount) === "risky") {
      riskyClientsCount += 1;
    }
  }

  const oneLiner = `Pending ₹${rupees(totalDue)} · overdue ₹${rupees(overdueAmount)} · aaj follow-up: ${todayDueCount} · risky: ${riskyClientsCount}.`;

  const fullText = [
    `• Total due (pending): ₹${rupees(totalDue)}`,
    `• Overdue amount: ₹${rupees(overdueAmount)}`,
    `• Aaj / overdue follow-up items: ${todayDueCount}`,
    `• Risky clients (avg delay >5d): ${riskyClientsCount}`,
  ].join("\n");

  return {
    totalDue,
    overdueAmount,
    todayDueCount,
    riskyClientsCount,
    asOfMs: nowMs,
    oneLiner,
    fullText,
  };
}

function rupees(n: number): string {
  return new Intl.NumberFormat("en-IN", {
    maximumFractionDigits: 0,
  }).format(Math.round(n));
}

/**
 * Fetches top client stats documents by field (server sorts in memory after read).
 */
export async function readClientStatsSorted(
  uid: string,
  by: "totalBusiness" | "totalPending",
  limit: number,
): Promise<ClientStatDoc[]> {
  const db = getFirestore();
  const snap = await db
    .collection("users")
    .doc(uid)
    .collection("client_stats")
    .limit(500)
    .get();
  const rows: ClientStatDoc[] = snap.docs
    .map((doc) => {
      const d = doc.data() as DocumentData;
      return {
        clientKey: String(d.clientKey ?? doc.id).trim(),
        clientName: String(d.clientName ?? "").trim() || "Unknown",
        totalBusiness: Number(d.totalBusiness) || 0,
        totalPending: Number(d.totalPending) || 0,
        lastOrderDateMs: Number(d.lastOrderDateMs) || 0,
        lastPaymentDateMs: Number(d.lastPaymentDateMs) || 0,
        paymentDelayAvg: Number(d.paymentDelayAvg) || 0,
        riskTag: (d.riskTag as RiskTag) || "average",
        updatedAtMs: Number(d.updatedAtMs) || 0,
      };
    })
    .filter((r) => r.clientName.length > 0);
  const field = by === "totalBusiness" ? "totalBusiness" : "totalPending";
  rows.sort((a, b) => (b[field] as number) - (a[field] as number));
  return rows.slice(0, limit);
}

/**
 * Risk-tagged clients with the highest outstanding pending, for assistant lists.
 */
export async function readRiskyClientsTop(
  uid: string,
  limit: number,
): Promise<ClientStatDoc[]> {
  const all = await readClientStatsSorted(uid, "totalPending", 500);
  const risky = all.filter((r) => r.riskTag === "risky");
  return risky.slice(0, Math.max(0, limit));
}

export type OverdueRow = {
  client: string;
  amount: number;
  daysLate: number;
  dueMs: number;
  dueDateLabel: string;
};

/**
 * All pending payments where due &lt; now, with day counts.
 */
export function computeOverdueRows(
  payDocs: DocumentData[],
  timeZone: string,
  nowMs: number,
): OverdueRow[] {
  const zone = timeZone || "Asia/Kolkata";
  const out: OverdueRow[] = [];
  for (const d of payDocs) {
    if (!isOpenPaymentDueDoc(d)) {
      continue;
    }
    const due = paymentDueMs(d);
    if (due <= 0 || due >= nowMs) {
      continue;
    }
    const name = String(
      (d as { clientName?: string }).clientName ?? d.client ?? "Unknown",
    ).trim() || "Unknown";
    const amount = openDueRollupAmount(d);
    const daysLate = Math.max(1, Math.floor((nowMs - due) / MS_PER_DAY));
    const label = DateTime.fromMillis(due, { zone: "UTC" })
      .setZone(zone)
      .toFormat("d LLL yyyy");
    out.push({
      client: name,
      amount,
      daysLate,
      dueMs: due,
      dueDateLabel: label,
    });
  }
  out.sort((a, b) => b.dueMs - a.dueMs);
  return out;
}

/**
 * Overdue (due &lt; now) union due calendar-today, pending.
 */
export function computeFollowupRows(
  payDocs: DocumentData[],
  timeZone: string,
  nowMs: number,
): OverdueRow[] {
  const seen = new Set<string>();
  const out: OverdueRow[] = [];
  for (const d of payDocs) {
    if (!isOpenPaymentDueDoc(d)) {
      continue;
    }
    const due = paymentDueMs(d);
    if (due <= 0) {
      continue;
    }
    const isLate = due < nowMs;
    const isToday = isCalendarToday(due, timeZone, nowMs);
    if (!isLate && !isToday) {
      continue;
    }
    const name = String(
      (d as { clientName?: string }).clientName ?? d.client ?? "Unknown",
    ).trim() || "Unknown";
    const amount = openDueRollupAmount(d);
    const id = `${name}\0${String(due)}\0${String(amount)}`;
    if (seen.has(id)) {
      continue;
    }
    seen.add(id);
    const daysLate = isLate
      ? Math.max(1, Math.floor((nowMs - due) / MS_PER_DAY))
      : 0;
    const label = DateTime.fromMillis(due, { zone: "UTC" })
      .setZone(timeZone)
      .toFormat("d LLL yyyy");
    out.push({
      client: name,
      amount,
      daysLate,
      dueMs: due,
      dueDateLabel: label,
    });
  }
  out.sort((a, b) => a.dueMs - b.dueMs);
  return out;
}

/**
 * Open dues to chase **this calendar week**: anything already overdue plus any
 * still-open payment due up to Sunday night of the ISO week starting Monday
 * (user timezone). When you mark receipt in chat, [isOpenPaymentDueDoc]
 * drops rows automatically.
 */
export function computeWeekPaymentFollowupRows(
  payDocs: DocumentData[],
  timeZone: string,
  nowMs: number,
): OverdueRow[] {
  const zone = timeZone || "Asia/Kolkata";
  const day = DateTime.fromMillis(nowMs, { zone }).startOf("day");
  const weekStart = day.minus({ days: day.weekday - 1 }).startOf("day");
  const weekEndExcl = weekStart.plus({ days: 7 }).startOf("day");
  const weekStartMs = weekStart.toMillis();
  const weekEndMs = weekEndExcl.toMillis();
  const seen = new Set<string>();
  const out: OverdueRow[] = [];

  for (const d of payDocs) {
    if (!isOpenPaymentDueDoc(d)) {
      continue;
    }
    const due = paymentDueMs(d);
    if (due <= 0) {
      continue;
    }
    const overdue = due < nowMs;
    const inCalendarWeek =
      due >= weekStartMs && due < weekEndMs;
    if (!overdue && !inCalendarWeek) {
      continue;
    }

    const name = String(
      (d as { clientName?: string }).clientName ?? d.client ?? "Unknown",
    ).trim() || "Unknown";
    const amount = openDueRollupAmount(d);
    const id = `${name}\0${String(due)}\0${String(amount)}`;
    if (seen.has(id)) {
      continue;
    }
    seen.add(id);

    const daysLate = overdue
      ? Math.max(1, Math.floor((nowMs - due) / MS_PER_DAY))
      : 0;

    const datePart = DateTime.fromMillis(due, { zone: "UTC" })
      .setZone(zone)
      .toFormat("d LLL yyyy");

    let dueDateLabel = datePart;
    if (overdue) {
      dueDateLabel = `${datePart} · ${daysLate} day${daysLate === 1 ? "" : "s"} delay`;
    } else {
      const daysUntil = Math.max(
        0,
        Math.ceil((due - nowMs) / MS_PER_DAY),
      );
      if (daysUntil === 0) {
        dueDateLabel = `${datePart} · due later today`;
      } else {
        dueDateLabel =
          `${datePart} · due in ${daysUntil} day${daysUntil === 1 ? "" : "s"}`;
      }
    }

    out.push({
      client: name,
      amount,
      daysLate,
      dueMs: due,
      dueDateLabel,
    });
  }

  out.sort((a, b) => {
    const aOver = a.daysLate > 0;
    const bOver = b.daysLate > 0;
    if (aOver !== bOver) {
      return aOver ? -1 : 1;
    }
    if (aOver && bOver && a.daysLate !== b.daysLate) {
      return b.daysLate - a.daysLate;
    }
    return a.dueMs - b.dueMs;
  });

  return out;
}

export async function fetchAllPayments(uid: string): Promise<DocumentData[]> {
  const db = getFirestore();
  const docs = await fetchAllDocsOrderedById(
    db.collection("users").doc(uid).collection("payments"),
  );
  return docs.map((d) => d.data() as DocumentData);
}

export function buildDailyStatusUserReply(summary: DailySummaryResult): {
  userReply: string;
  summary: string;
} {
  const block = [
    summary.oneLiner,
    "",
    summary.fullText,
  ].join("\n");
  return { userReply: block, summary: block };
}
