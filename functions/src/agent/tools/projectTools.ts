/**
 * Project tools.
 *
 * The shape of the work is decided by the conversation, not by this file. What
 * these do is hold it: create the thread, take a page of notes and turn it into
 * items, move an item along, and answer "where is this project".
 *
 * Adding items goes through a confirm card, because a trip's worth of notes
 * becomes eight items at once and a misread line is far cheaper to fix on a
 * card than after it has become a reminder. Marking one done does not: it is
 * one small, reversible change, and asking twice for it would make the tracker
 * tiresome, which is how trackers die.
 *
 * `create_task` is the one that does not follow that shape. A small job is said
 * in a single sentence, so it is confirmed in a single card — name, who it is
 * for, deadline and steps together — and everything after that reuses the
 * project tools unchanged.
 */

import { DateTime } from "luxon";

import { createDraft } from "../draftStore";
import { resolveWhen, type DayPeriod, type WhenTense } from "../dateResolve";
import {
  addItems,
  createProject,
  dueOf,
  findItem,
  findProject,
  findProjectCandidates,
  isLive,
  kindOf as projectKindOf,
  listItems,
  listProjects,
  setProjectStatus,
  summarise,
  updateItem,
  type ItemKind,
  type ItemStatus,
  type ProjectItem,
  type ProjectKind,
  type ProjectStatus,
} from "../projectStore";
import { normalizeName } from "../nameNormalize";
import { logProjectEvent } from "../projectEvents";
import { cancelReminders } from "../reminderCancel";
import { draftResult, dataResult, fail, type ToolContext, type ToolResult } from "../toolTypes";
import type { DraftCardLine } from "../draftTypes";

function str(raw: unknown): string {
  return typeof raw === "string" ? raw.trim() : "";
}

const KINDS: ReadonlySet<string> = new Set([
  "sample",
  "approval",
  "rate",
  "quotation",
  "meeting",
  "followup",
  "delivery",
  "payment",
  "task",
]);

const ITEM_STATUSES: ReadonlySet<string> = new Set([
  "open",
  "waiting_on_them",
  "done",
  "dropped",
]);

function kindOf(raw: unknown): ItemKind {
  const k = str(raw).toLowerCase();
  return (KINDS.has(k) ? k : "task") as ItemKind;
}

function statusOf(raw: unknown): ItemStatus | null {
  const s = str(raw).toLowerCase();
  return ITEM_STATUSES.has(s) ? (s as ItemStatus) : null;
}

/** Human wording for a state, used on cards and in answers. */
export function statusLabel(s: ItemStatus): string {
  switch (s) {
    case "waiting_on_them":
      return "Waiting on them";
    case "done":
      return "Done";
    case "dropped":
      return "Dropped";
    default:
      return "Open";
  }
}

function whenLabel(ms: number, timezone: string): string {
  if (ms <= 0) {
    return "";
  }
  return new Date(ms).toLocaleDateString("en-IN", {
    day: "numeric",
    month: "short",
    timeZone: timezone || "Asia/Kolkata",
  });
}

function dueLabel(item: ProjectItem, timezone: string): string {
  return whenLabel(item.dueMs, timezone);
}

/**
 * When to ask "how far have you got" on the way to a deadline.
 *
 * Halfway, moved into waking hours. A reminder only on the day something is
 * due is a reminder that arrives too late to change the outcome, which is the
 * whole complaint about deadlines. But two alarms for something due tomorrow
 * morning is nagging, so anything under about a day and a quarter gets one
 * alarm and nothing else, and the nudge is dropped rather than squeezed in if
 * moving it to a civil hour leaves it crowding either end.
 */
export function nudgeFor(nowMs: number, dueMs: number, timezone: string): number {
  const zone = timezone || "Asia/Kolkata";
  const span = dueMs - nowMs;
  if (dueMs <= 0 || span < 30 * 60 * 60 * 1000) {
    return 0;
  }

  let t = DateTime.fromMillis(nowMs + Math.floor(span / 2), { zone });
  if (t.hour < 9) {
    t = t.set({ hour: 9, minute: 0, second: 0, millisecond: 0 });
  } else if (t.hour >= 21) {
    t = t.plus({ days: 1 }).set({ hour: 9, minute: 0, second: 0, millisecond: 0 });
  }

  const ms = t.toMillis();
  const tooSoon = ms <= nowMs + 60 * 60 * 1000;
  const tooLate = ms >= dueMs - 2 * 60 * 60 * 1000;
  return tooSoon || tooLate ? 0 : ms;
}

/** Finds the project, or fails in a way the model can put to the user. */
type Resolved =
  | { project: Awaited<ReturnType<typeof findProject>> & object }
  | { failure: ToolResult };

async function resolveProject(ctx: ToolContext, name: string): Promise<Resolved> {
  const found = await findProject(ctx.uid, name);
  if (found) {
    return { project: found } as const;
  }
  const candidates = await findProjectCandidates(ctx.uid, name);
  if (candidates.length > 1) {
    return {
      failure: fail(
        "needs_detail",
        `Which one — ${candidates.map((p) => p.name).join(", ")}?`,
      ),
    } as const;
  }
  // Tasks live in the same place, so the list offered back has to name both —
  // otherwise "no project called X" is the answer to a question about a task
  // that does exist.
  const all = await listProjects(ctx.uid, { limit: 30 });
  const live = all.filter(isLive);
  return {
    failure: fail(
      "nothing_found",
      live.length === 0
        ? `Nothing called "${name}" — say "start a project for ..." or "task hai ..." and I will open one.`
        : `Nothing called "${name}". Open: ${live.map((p) => p.name).join(", ")}.`,
    ),
  } as const;
}

// ---------------------------------------------------------------------------
// create_project
// ---------------------------------------------------------------------------

export async function createProjectTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const name = str(args.name);
  if (!name) {
    return fail("needs_detail", "What should I call this project?");
  }
  const existing = await findProject(ctx.uid, name);
  if (existing) {
    return dataResult({
      already_exists: true,
      project: existing.name,
      note: "Adding to the one that is already open rather than starting a second.",
    });
  }
  const project = await createProject(ctx.uid, {
    name,
    clientName: str(args.client_name) || null,
    note: str(args.note) || null,
  });
  await logProjectEvent(
    ctx.uid,
    project.id,
    "created",
    project.clientName ? `Project opened for ${project.clientName}` : "Project opened",
  );
  return dataResult({
    created: project.name,
    ...(project.clientName ? { client: project.clientName } : {}),
  });
}

// ---------------------------------------------------------------------------
// create_task
// ---------------------------------------------------------------------------

/** Steps arrive as bare strings or as objects with a title; models send both. */
function stepTitles(raw: unknown): string[] {
  if (!Array.isArray(raw)) {
    return [];
  }
  const out: string[] = [];
  for (const entry of raw) {
    const title =
      typeof entry === "string"
        ? entry.trim()
        : entry != null && typeof entry === "object"
          ? str((entry as Record<string, unknown>).title)
          : "";
    if (title) {
      out.push(title);
    }
  }
  return out;
}

export async function createTaskTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const name = str(args.name);
  if (!name) {
    return fail("needs_detail", "What is the task?");
  }

  // A second task with the same name is nearly always the same task said
  // twice. A closed one is not: "PPT banana" next month is new work.
  const existing = await findProject(ctx.uid, name);
  if (existing && isLive(existing)) {
    return dataResult({
      already_exists: true,
      name: existing.name,
      is_task: projectKindOf(existing) === "task",
      note: "This is already open — add to it or update it rather than starting a second.",
    });
  }

  const phrase = str(args.when_phrase);
  const when = phrase
    ? resolveWhen({
        phrase,
        timezone: ctx.timezone,
        nowIso: ctx.nowIso,
        tense: (str(args.when_tense) || "future") as WhenTense,
        period: (str(args.day_period) || undefined) as DayPeriod | undefined,
      })
    : null;
  // A phrase that could not be read must not become "no deadline". The card
  // would say one thing while the reply said another — which is exactly what
  // happened with "2 din me": the model announced a deadline, the card showed
  // none, and the task saved without the reminder that was the whole point.
  if (phrase && when?.epochMs == null) {
    return fail(
      "needs_detail",
      `I could not work out when "${phrase}" is — give me a date or a number of days.`,
    );
  }
  const dueMs = when?.epochMs ?? 0;

  const nowMs = Date.parse(ctx.nowIso) || Date.now();
  const nudgeMs = nudgeFor(nowMs, dueMs, ctx.timezone);
  const area = str(args.area).toLowerCase() === "personal" ? "personal" : "work";
  const forWhom = str(args.for_whom);
  const note = str(args.note);
  const steps = stepTitles(args.steps);

  const lines: DraftCardLine[] = [];
  if (forWhom) {
    lines.push({ label: "For", value: forWhom });
  }
  lines.push({
    label: "By",
    // A task with no date is allowed, but it then only exists in a list, and
    // saying so on the card is the difference between a choice and a surprise.
    value: dueMs > 0 ? when?.label || whenLabel(dueMs, ctx.timezone) : "No deadline — it will sit in your list",
  });
  steps.forEach((title, i) => {
    lines.push({ label: `Step ${i + 1}`, value: title });
  });
  if (nudgeMs > 0) {
    lines.push({ label: "Check-in", value: whenLabel(nudgeMs, ctx.timezone) });
  }
  if (note) {
    lines.push({ label: "Note", value: note });
  }

  const draft = await createDraft({
    uid: ctx.uid,
    kind: "task",
    title: name,
    icon: area === "personal" ? "🏡" : "📌",
    lines,
    chatId: ctx.chatId,
    data: {
      kind: "task",
      name,
      forWhom,
      area,
      dueMs,
      dueLabel: when?.label ?? "",
      nudgeMs,
      note,
      steps: steps.map((title) => ({
        title,
        kind: "task" as const,
        status: "open" as const,
        dueMs: 0,
        whenLabel: "",
        note: "",
      })),
    },
  });

  return draftResult(
    draft,
    dueMs > 0
      ? "Task drafted — confirming it sets the reminders."
      : "Task drafted. It has no date, so nothing will ring; say when it is due and I will add one.",
  );
}

// ---------------------------------------------------------------------------
// add_project_items
// ---------------------------------------------------------------------------

export async function addProjectItemsTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const projectName = str(args.project);
  if (!projectName) {
    return fail("needs_detail", "Which project is this for?");
  }
  const resolved = await resolveProject(ctx, projectName);
  if ("failure" in resolved) {
    return resolved.failure;
  }
  const project = resolved.project;

  const raw = Array.isArray(args.items) ? args.items : [];
  if (raw.length === 0) {
    return fail("needs_detail", "What needs doing on this project?");
  }

  const parsed = raw
    .filter((r): r is Record<string, unknown> => r != null && typeof r === "object")
    .map((r) => {
      const title = str(r.title);
      const phrase = str(r.when_phrase);
      // Every date goes through the same resolver the rest of the app uses, so
      // "Monday tak" means here what it means everywhere else.
      const when = phrase
        ? resolveWhen({
            phrase,
            timezone: ctx.timezone,
            nowIso: ctx.nowIso,
            tense: (str(r.when_tense) || "future") as WhenTense,
            period: (str(r.day_period) || undefined) as DayPeriod | undefined,
          })
        : null;
      return {
        title,
        kind: kindOf(r.kind),
        status: statusOf(r.status) ?? "open",
        dueMs: when?.epochMs ?? 0,
        whenLabel: when?.label ?? "",
        note: str(r.note),
        /** They gave a date for this one, whether or not it could be read. */
        gaveDate: phrase.length > 0,
      };
    })
    .filter((r) => r.title.length > 0);

  if (parsed.length === 0) {
    return fail("needs_detail", "None of those had anything to do — say them again?");
  }

  // Same rule as create_task: a date that could not be read is said out loud,
  // not quietly dropped. An item silently losing its date loses its reminder,
  // and nothing on the card shows that it happened.
  const unreadable = parsed.filter((p) => p.gaveDate && p.dueMs === 0).map((p) => p.title);
  if (unreadable.length > 0) {
    return fail(
      "needs_detail",
      `I could not work out the date for: ${unreadable.join(", ")}. When are those due?`,
    );
  }

  const lines: DraftCardLine[] = parsed.map((p) => ({
    label: p.whenLabel || statusLabel(p.status),
    value: p.title,
  }));

  const draft = await createDraft({
    uid: ctx.uid,
    kind: "project_items",
    title: `${project.name} — ${parsed.length} item${parsed.length === 1 ? "" : "s"}`,
    icon: "📋",
    lines,
    chatId: ctx.chatId,
    data: {
      kind: "project_items",
      projectId: project.id,
      projectName: project.name,
      items: parsed.map((p) => ({
        title: p.title,
        kind: p.kind,
        status: p.status,
        dueMs: p.dueMs,
        whenLabel: p.whenLabel,
        note: p.note,
      })),
    },
  });

  return draftResult(
    draft,
    "Items drafted — they save once confirmed, and the dated ones become reminders.",
  );
}

// ---------------------------------------------------------------------------
// update_project_item
// ---------------------------------------------------------------------------

export async function updateProjectItemTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const projectName = str(args.project);
  const itemText = str(args.item);
  if (!projectName || !itemText) {
    return fail("needs_detail", "Which project, and which item?");
  }
  const resolved = await resolveProject(ctx, projectName);
  if ("failure" in resolved) {
    return resolved.failure;
  }
  const project = resolved.project;

  const item = await findItem(ctx.uid, project.id, itemText);
  if (!item) {
    const all = await listItems(ctx.uid, project.id);
    const live = all.filter((i) => i.status === "open" || i.status === "waiting_on_them");
    return fail(
      "nothing_found",
      live.length === 0
        ? `Nothing open on ${project.name} matching "${itemText}".`
        : `No item like "${itemText}". Open: ${live.map((i) => i.title).join(", ")}.`,
    );
  }

  const patch: Parameters<typeof updateItem>[3] = {};
  const status = statusOf(args.status);
  if (status) {
    patch.status = status;
  }
  const phrase = str(args.when_phrase);
  if (phrase) {
    const when = resolveWhen({
      phrase,
      timezone: ctx.timezone,
      nowIso: ctx.nowIso,
      tense: (str(args.when_tense) || "future") as WhenTense,
    });
    if (when.epochMs != null) {
      patch.dueMs = when.epochMs;
    }
  }
  const note = str(args.note);
  if (note) {
    patch.note = item.note ? `${item.note}\n${note}` : note;
  }

  if (Object.keys(patch).length === 0) {
    return fail("needs_detail", "What changed about it?");
  }

  await updateItem(ctx.uid, project.id, item.id, patch);

  // Done means done — including the alarm. A reminder that still rings for
  // something finished early is exactly what makes a person stop trusting the
  // reminders that matter.
  let alarmOff = false;
  if ((patch.status === "done" || patch.status === "dropped") && item.reminderId) {
    alarmOff = (await cancelReminders(ctx.uid, [item.reminderId])) > 0;
  }

  const changes: string[] = [];
  if (patch.status) {
    changes.push(statusLabel(patch.status).toLowerCase());
  }
  if (patch.dueMs) {
    changes.push(`due ${whenLabel(patch.dueMs, ctx.timezone)}`);
  }
  if (note && !patch.status && !patch.dueMs) {
    changes.push(note);
  }
  await logProjectEvent(
    ctx.uid,
    project.id,
    patch.status ? "status" : patch.dueMs ? "due" : "note",
    `${item.title} — ${changes.join(", ")}`,
  );

  return dataResult({
    project: project.name,
    item: item.title,
    ...(alarmOff ? { reminder_cancelled: true } : {}),
    ...(patch.status ? { now: statusLabel(patch.status) } : {}),
    ...(patch.dueMs ? { due: dueLabel({ ...item, dueMs: patch.dueMs }, ctx.timezone) } : {}),
  });
}

// ---------------------------------------------------------------------------
// project_status
// ---------------------------------------------------------------------------

export async function projectStatusTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const projectName = str(args.project);
  if (!projectName) {
    return fail("needs_detail", "Which project?");
  }
  const resolved = await resolveProject(ctx, projectName);
  if ("failure" in resolved) {
    return resolved.failure;
  }
  const project = resolved.project;
  const items = await listItems(ctx.uid, project.id);
  const s = summarise(project, items);

  const row = (i: ProjectItem) => ({
    what: i.title,
    kind: i.kind,
    ...(i.dueMs > 0 ? { due: dueLabel(i, ctx.timezone) } : {}),
    ...(i.note ? { note: i.note } : {}),
  });

  const own = dueOf(project);
  const nowMs = Date.parse(ctx.nowIso) || Date.now();

  return dataResult({
    project: project.name,
    is_task: projectKindOf(project) === "task",
    ...(project.clientName ? { for: project.clientName } : {}),
    status: project.status,
    // A task's deadline belongs to the whole thing, not to any one step, so it
    // has to be said here or it is never said at all.
    ...(own > 0
      ? { due: whenLabel(own, ctx.timezone), ...(own < nowMs ? { late: true } : {}) }
      : {}),
    counts: {
      done: s.done.length,
      open: s.open.length,
      waiting_on_them: s.waiting.length,
      overdue: s.overdue.length,
    },
    // Late first, then what is on him, then what is on them, then what is done.
    // The order is the order these should be spoken in.
    overdue: s.overdue.map(row),
    open: s.open.filter((i) => !s.overdue.includes(i)).map(row),
    waiting_on_them: s.waiting.filter((i) => !s.overdue.includes(i)).map(row),
    done: s.done.map((i) => i.title),
    ...(s.next ? { next_up: row(s.next) } : {}),
    ...(project.note ? { project_note: project.note } : {}),
  });
}

// ---------------------------------------------------------------------------
// list_projects / close_project
// ---------------------------------------------------------------------------

export async function listProjectsTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const wantedStatus = str(args.status).toLowerCase();
  const wantedKindRaw = str(args.kind).toLowerCase();
  const wantedKind: ProjectKind | undefined =
    wantedKindRaw === "task" ? "task" : wantedKindRaw === "project" ? "project" : undefined;
  const forWhom = normalizeName(str(args.for_whom));

  let rows = await listProjects(ctx.uid, {
    status: wantedStatus ? (wantedStatus as ProjectStatus) : undefined,
    kind: wantedKind,
  });

  // "Mandar sir ka kya pending hai" is the question this answers, and it has to
  // survive being asked with a partial name.
  if (forWhom) {
    rows = rows.filter((p) => {
      const key = normalizeName(p.clientName);
      return key.length > 0 && (key.includes(forWhom) || forWhom.includes(key));
    });
  }

  if (rows.length === 0) {
    return fail(
      "nothing_found",
      forWhom ? "Nothing open for them." : wantedKind === "task" ? "No tasks yet." : "No projects yet.",
    );
  }

  const nowMs = Date.parse(ctx.nowIso) || Date.now();
  const built = await Promise.all(
    rows.slice(0, 20).map(async (p) => {
      const items = await listItems(ctx.uid, p.id, 100);
      const sum = summarise(p, items);
      const isTask = projectKindOf(p) === "task";
      const due = dueOf(p);
      return {
        row: {
          name: p.name,
          is_task: isTask,
          area: p.area ?? "work",
          ...(p.clientName ? { for: p.clientName } : {}),
          status: p.status,
          open: sum.open.length + sum.waiting.length,
          overdue: sum.overdue.length,
          ...(due > 0
            ? {
                due: whenLabel(due, ctx.timezone),
                ...(due < nowMs ? { late: true } : {}),
              }
            : {}),
          // A task is two or three steps, so listing them costs nothing and
          // saves a second question. A project's items can run to twenty, and
          // that is what project_status is for.
          ...(isTask
            ? {
                steps: items.map((i) => ({ what: i.title, state: statusLabel(i.status) })),
              }
            : {}),
          ...(!isTask && sum.next
            ? { next_up: sum.next.title, next_due: dueLabel(sum.next, ctx.timezone) }
            : {}),
        },
        // Late first, then whatever is due soonest, then the undated.
        sortKey: due > 0 ? (due < nowMs ? due - 1e15 : due) : Number.MAX_SAFE_INTEGER,
      };
    }),
  );

  built.sort((a, b) => a.sortKey - b.sortKey);
  const out = built.map((b) => b.row);
  return dataResult({
    count: out.length,
    tasks: out.filter((r) => r.is_task),
    projects: out.filter((r) => !r.is_task),
  });
}

export async function closeProjectTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const projectName = str(args.project);
  if (!projectName) {
    return fail("needs_detail", "Which project?");
  }
  const resolved = await resolveProject(ctx, projectName);
  if ("failure" in resolved) {
    return resolved.failure;
  }
  const raw = str(args.status).toLowerCase();
  const status: ProjectStatus = (
    ["won", "lost", "on_hold", "done", "active"].includes(raw) ? raw : "done"
  ) as ProjectStatus;

  const project = resolved.project;
  await setProjectStatus(ctx.uid, project.id, status);

  // Closing early is the common case for a task — he finishes the deck a day
  // ahead and says so — so the deadline alarm and every open step's alarm have
  // to go with it. Reopening (status back to active) leaves them cancelled;
  // that is the safe direction to be wrong in.
  let cancelled = 0;
  if (status !== "active") {
    const items = await listItems(ctx.uid, project.id, 200);
    cancelled = await cancelReminders(ctx.uid, [
      ...(project.reminderIds ?? []),
      ...items
        .filter((i) => i.status === "open" || i.status === "waiting_on_them")
        .map((i) => i.reminderId),
    ]);
  }

  await logProjectEvent(
    ctx.uid,
    project.id,
    status === "active" ? "status" : "closed",
    status === "active" ? "Reopened" : `Closed as ${status.replace("_", " ")}`,
  );

  return dataResult({
    project: project.name,
    status,
    ...(cancelled > 0 ? { reminders_cancelled: cancelled } : {}),
  });
}
