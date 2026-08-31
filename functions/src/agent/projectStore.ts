/**
 * Projects — a piece of work that runs for weeks and has many moving parts.
 *
 * Deliberately not a template. A label job goes sample → feature approval →
 * rate → PO; a printing job does not, and the third one will do something else
 * again. Fixing the stages would be right twice and wrong forever after, and a
 * tracker that does not match the work is a tracker nobody opens. So a project
 * holds a name and a list of whatever this one actually needs, each item
 * carrying its own kind, date and state.
 *
 * The one piece of structure that earns its place is `waiting_on_them`. Half of
 * this trade is waiting on somebody else — an approval, a rate confirmation, a
 * PO — and folding that into "pending" makes a person feel behind on work that
 * is not theirs to do, and makes "what is stuck" unanswerable.
 *
 * The same store also holds *tasks* — the small work that arrives verbally and
 * is gone in two days: a deck a director asked for, a film to book with your
 * wife. A task is not a different thing underneath; it is a name with a
 * deadline and a short list of steps, which is a project with fewer parts. So
 * it lives here under `kind: "task"` rather than in a second collection, and
 * every reader, reminder and status answer already written works on it
 * unchanged. A second collection would have meant writing all of that twice
 * and keeping the two halves in step forever.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";

import { normalizeName } from "./nameNormalize";

export type ProjectStatus = "active" | "won" | "lost" | "on_hold" | "done";

/**
 * A long piece of work, or a short one.
 *
 * Only presentation and pacing differ: a project is paced by its items' own
 * dates, a task by one deadline on the whole thing.
 */
export type ProjectKind = "project" | "task";

/** Which half of life this belongs to. It decides colour and wording, never behaviour. */
export type ProjectArea = "work" | "personal";

export type ItemStatus = "open" | "waiting_on_them" | "done" | "dropped";

/** What kind of step this is. Free-form in spirit; these are just the common ones. */
export type ItemKind =
  | "sample"
  | "approval"
  | "rate"
  | "quotation"
  | "meeting"
  | "followup"
  | "delivery"
  | "payment"
  | "task";

export interface Project {
  id: string;
  name: string;
  nameKey: string;
  /**
   * Who it is for: the client on a project, and on a task whoever asked for it
   * — a director, a wife, or nobody. One slot rather than two, because a
   * second field meaning nearly the same thing is a field filled in half the
   * time.
   */
  clientName: string;
  status: ProjectStatus;
  /** Anything worth carrying that is not an item — site address, contact, terms. */
  note: string;
  /** Written on every doc from now on; absent on the ones written before tasks existed. */
  kind?: ProjectKind;
  area?: ProjectArea;
  /** Deadline for the whole thing. 0 on a project, which its items pace instead. */
  dueMs?: number;
  /** Reminders belonging to the deadline itself, so closing it can cancel them. */
  reminderIds?: string[];
  createdAtMs: number;
  updatedAtMs: number;
}

/**
 * Docs written before tasks existed carry no `kind`, and every one of them is a
 * project. Reading through these rather than the raw fields is what lets this
 * ship without a migration.
 */
export function kindOf(p: Project): ProjectKind {
  return p.kind === "task" ? "task" : "project";
}

export function areaOf(p: Project): ProjectArea {
  return p.area === "personal" ? "personal" : "work";
}

export function dueOf(p: Project): number {
  const ms = Number(p.dueMs ?? 0);
  return Number.isFinite(ms) && ms > 0 ? ms : 0;
}

/** Still wants attention — as opposed to won, lost or done. */
export function isLive(p: Project): boolean {
  return p.status === "active" || p.status === "on_hold";
}

export interface ProjectItem {
  id: string;
  projectId: string;
  title: string;
  kind: ItemKind;
  status: ItemStatus;
  /** 0 when the item has no date of its own. */
  dueMs: number;
  note: string;
  /** Reminder created for this item, so completing one can cancel the other. */
  reminderId: string;
  createdAtMs: number;
  updatedAtMs: number;
}

function projectsRef(uid: string) {
  return getFirestore().collection("users").doc(uid).collection("projects");
}

function itemsRef(uid: string, projectId: string) {
  return projectsRef(uid).doc(projectId).collection("items");
}

export const OPEN_ITEM_STATUSES: readonly ItemStatus[] = ["open", "waiting_on_them"];

export async function createProject(
  uid: string,
  input: {
    name: string;
    clientName?: string | null;
    note?: string | null;
    kind?: ProjectKind | null;
    area?: ProjectArea | null;
    dueMs?: number | null;
    reminderIds?: string[] | null;
  },
): Promise<Project> {
  const name = input.name.trim();
  const now = Date.now();
  const ref = projectsRef(uid).doc();
  const project: Project = {
    id: ref.id,
    name,
    nameKey: normalizeName(name),
    clientName: (input.clientName ?? "").trim(),
    status: "active",
    note: (input.note ?? "").trim(),
    kind: input.kind === "task" ? "task" : "project",
    area: input.area === "personal" ? "personal" : "work",
    dueMs: input.dueMs && input.dueMs > 0 ? input.dueMs : 0,
    reminderIds: input.reminderIds ?? [],
    createdAtMs: now,
    updatedAtMs: now,
  };
  await ref.set(project);
  return project;
}

export async function listProjects(
  uid: string,
  opts: { status?: ProjectStatus; kind?: ProjectKind; limit?: number } = {},
): Promise<Project[]> {
  let q = projectsRef(uid).limit(opts.limit ?? 50);
  if (opts.status) {
    q = q.where("status", "==", opts.status) as typeof q;
  }
  const snap = await q.get();
  let rows = snap.docs.map((d) => d.data() as Project);
  // Kind is filtered here rather than in the query: the older docs have no
  // `kind` field at all, so a `where` on it would silently drop every project
  // written before tasks existed.
  if (opts.kind) {
    rows = rows.filter((p) => kindOf(p) === opts.kind);
  }
  // Most recently touched first: the project being worked on is the one being
  // asked about.
  return rows.sort((a, b) => b.updatedAtMs - a.updatedAtMs);
}

/**
 * Finds a project by whatever the user called it.
 *
 * Exact key first, then a unique partial — "Pune" should find "Pune label
 * project" while it is the only one, and stop finding it the day a second Pune
 * project exists, because guessing wrong here writes work onto the wrong job.
 */
export async function findProject(uid: string, name: string): Promise<Project | null> {
  const key = normalizeName(name);
  if (!key) {
    return null;
  }
  const exact = await projectsRef(uid).where("nameKey", "==", key).limit(1).get();
  if (!exact.empty) {
    return exact.docs[0]!.data() as Project;
  }
  const all = await listProjects(uid, { limit: 100 });
  const partial = all.filter(
    (p) =>
      p.nameKey.includes(key) ||
      key.includes(p.nameKey) ||
      normalizeName(p.clientName).includes(key),
  );
  return partial.length === 1 ? partial[0]! : null;
}

/** Every project whose name or client could be meant, for asking which. */
export async function findProjectCandidates(uid: string, name: string): Promise<Project[]> {
  const key = normalizeName(name);
  if (!key) {
    return [];
  }
  const all = await listProjects(uid, { limit: 100 });
  return all.filter(
    (p) =>
      p.nameKey.includes(key) ||
      key.includes(p.nameKey) ||
      normalizeName(p.clientName).includes(key),
  );
}

export async function addItems(
  uid: string,
  projectId: string,
  items: Array<{
    title: string;
    kind?: ItemKind | null;
    dueMs?: number | null;
    note?: string | null;
    status?: ItemStatus | null;
    reminderId?: string | null;
  }>,
): Promise<ProjectItem[]> {
  const db = getFirestore();
  const batch = db.batch();
  const now = Date.now();
  const out: ProjectItem[] = [];

  for (const raw of items) {
    const title = raw.title.trim();
    if (!title) {
      continue;
    }
    const ref = itemsRef(uid, projectId).doc();
    const item: ProjectItem = {
      id: ref.id,
      projectId,
      title,
      kind: raw.kind ?? "task",
      status: raw.status ?? "open",
      dueMs: raw.dueMs && raw.dueMs > 0 ? raw.dueMs : 0,
      note: (raw.note ?? "").trim(),
      reminderId: (raw.reminderId ?? "").trim(),
      createdAtMs: now,
      updatedAtMs: now,
    };
    batch.set(ref, item);
    out.push(item);
  }

  if (out.length > 0) {
    batch.update(projectsRef(uid).doc(projectId), { updatedAtMs: now });
    await batch.commit();
  }
  return out;
}

export async function listItems(
  uid: string,
  projectId: string,
  limit = 200,
): Promise<ProjectItem[]> {
  const snap = await itemsRef(uid, projectId).limit(limit).get();
  const rows = snap.docs.map((d) => d.data() as ProjectItem);
  // Dated work first and soonest first, then undated. What is due decides the
  // day; what has no date is a list to pick from.
  return rows.sort((a, b) => {
    if (a.dueMs > 0 && b.dueMs > 0) {
      return a.dueMs - b.dueMs;
    }
    if (a.dueMs > 0) {
      return -1;
    }
    if (b.dueMs > 0) {
      return 1;
    }
    return a.createdAtMs - b.createdAtMs;
  });
}

/** Matches an item within one project by its words, the way a person refers to it. */
export async function findItem(
  uid: string,
  projectId: string,
  text: string,
): Promise<ProjectItem | null> {
  const key = normalizeName(text);
  if (!key) {
    return null;
  }
  const all = await listItems(uid, projectId);
  const exact = all.filter((i) => normalizeName(i.title) === key);
  if (exact.length === 1) {
    return exact[0]!;
  }
  const partial = all.filter(
    (i) => normalizeName(i.title).includes(key) || key.includes(normalizeName(i.title)),
  );
  return partial.length === 1 ? partial[0]! : null;
}

export async function updateItem(
  uid: string,
  projectId: string,
  itemId: string,
  patch: Partial<Pick<ProjectItem, "status" | "dueMs" | "note" | "title" | "kind" | "reminderId">>,
): Promise<void> {
  const now = Date.now();
  await itemsRef(uid, projectId).doc(itemId).update({ ...patch, updatedAtMs: now });
  await projectsRef(uid).doc(projectId).update({ updatedAtMs: now });
}

/** Attaches the deadline's reminders once they exist, so closing can cancel them. */
export async function setProjectReminders(
  uid: string,
  projectId: string,
  reminderIds: string[],
): Promise<void> {
  await projectsRef(uid).doc(projectId).update({
    reminderIds,
    updatedAtMs: Date.now(),
  });
}

export async function setProjectStatus(
  uid: string,
  projectId: string,
  status: ProjectStatus,
): Promise<void> {
  await projectsRef(uid).doc(projectId).update({
    status,
    updatedAtMs: Date.now(),
    closedAt: status === "active" ? FieldValue.delete() : FieldValue.serverTimestamp(),
  });
}

export interface ProjectSummary {
  project: Project;
  done: ProjectItem[];
  open: ProjectItem[];
  waiting: ProjectItem[];
  overdue: ProjectItem[];
  /** The soonest dated open item — what the project is actually waiting for next. */
  next: ProjectItem | null;
}

export function summarise(
  project: Project,
  items: ProjectItem[],
  nowMs = Date.now(),
): ProjectSummary {
  const done = items.filter((i) => i.status === "done");
  const open = items.filter((i) => i.status === "open");
  const waiting = items.filter((i) => i.status === "waiting_on_them");
  const live = [...open, ...waiting];
  return {
    project,
    done,
    open,
    waiting,
    overdue: live.filter((i) => i.dueMs > 0 && i.dueMs < nowMs),
    next: live.filter((i) => i.dueMs > 0).sort((a, b) => a.dueMs - b.dueMs)[0] ?? null,
  };
}
