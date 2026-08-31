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
 */

import { createDraft } from "../draftStore";
import { resolveWhen, type DayPeriod, type WhenTense } from "../dateResolve";
import {
  addItems,
  createProject,
  findItem,
  findProject,
  findProjectCandidates,
  listItems,
  listProjects,
  setProjectStatus,
  summarise,
  updateItem,
  type ItemKind,
  type ItemStatus,
  type ProjectItem,
  type ProjectStatus,
} from "../projectStore";
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

function dueLabel(item: ProjectItem, timezone: string): string {
  if (item.dueMs <= 0) {
    return "";
  }
  const d = new Date(item.dueMs);
  return d.toLocaleDateString("en-IN", {
    day: "numeric",
    month: "short",
    timeZone: timezone || "Asia/Kolkata",
  });
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
        `Which project — ${candidates.map((p) => p.name).join(", ")}?`,
      ),
    } as const;
  }
  const all = await listProjects(ctx.uid, { limit: 20 });
  return {
    failure: fail(
      "nothing_found",
      all.length === 0
        ? `No project called "${name}" — say "start a project for ..." and I will open one.`
        : `No project called "${name}". Open ones: ${all.map((p) => p.name).join(", ")}.`,
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
  return dataResult({
    created: project.name,
    ...(project.clientName ? { client: project.clientName } : {}),
  });
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
      };
    })
    .filter((r) => r.title.length > 0);

  if (parsed.length === 0) {
    return fail("needs_detail", "None of those had anything to do — say them again?");
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
  return dataResult({
    project: project.name,
    item: item.title,
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

  return dataResult({
    project: project.name,
    ...(project.clientName ? { client: project.clientName } : {}),
    status: project.status,
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
  const wanted = str(args.status).toLowerCase();
  const projects = await listProjects(ctx.uid, {
    status: wanted ? (wanted as ProjectStatus) : undefined,
  });
  if (projects.length === 0) {
    return fail("nothing_found", "No projects yet.");
  }

  const rows = await Promise.all(
    projects.slice(0, 15).map(async (p) => {
      const items = await listItems(ctx.uid, p.id, 100);
      const s = summarise(p, items);
      return {
        project: p.name,
        ...(p.clientName ? { client: p.clientName } : {}),
        status: p.status,
        open: s.open.length + s.waiting.length,
        overdue: s.overdue.length,
        ...(s.next
          ? { next_up: s.next.title, next_due: dueLabel(s.next, ctx.timezone) }
          : {}),
      };
    }),
  );

  return dataResult({ count: rows.length, projects: rows });
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

  await setProjectStatus(ctx.uid, resolved.project.id, status);
  return dataResult({ project: resolved.project.name, status });
}
