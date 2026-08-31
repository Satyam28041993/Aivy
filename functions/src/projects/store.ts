import {
  FieldValue,
  getFirestore,
  type DocumentData,
  type QueryDocumentSnapshot,
} from "firebase-admin/firestore";

import { startOfLocalDayMs, startOfNextLocalDayMs } from "./dates";
import { normalizeNameKey } from "./extract";
import type {
  ProjectClock,
  ProjectDraftItem,
  ProjectItemKind,
  ProjectItemRecord,
  ProjectItemStatus,
  ProjectRecord,
  ProjectStatus,
} from "./types";

function projectsCol(uid: string) {
  return getFirestore().collection("users").doc(uid).collection("projects");
}

function itemsCol(uid: string) {
  return getFirestore().collection("users").doc(uid).collection("project_items");
}

function asString(v: unknown): string {
  return typeof v === "string" ? v.trim() : "";
}

function asNum(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}

function projectFromDoc(
  doc: QueryDocumentSnapshot<DocumentData> | { id: string; data: () => DocumentData },
): ProjectRecord {
  const d = doc.data();
  const statusRaw = asString(d.status);
  const status: ProjectStatus =
    statusRaw === "paused" || statusRaw === "done" ? statusRaw : "active";
  return {
    id: doc.id,
    name: asString(d.name) || "Untitled",
    nameKey: asString(d.nameKey),
    client: asString(d.client),
    clientKey: asString(d.clientKey),
    status,
    notes: asString(d.notes),
    createdAtMs: asNum(d.createdAtMs) ?? 0,
    updatedAtMs: asNum(d.updatedAtMs) ?? 0,
  };
}

function itemFromDoc(
  doc: QueryDocumentSnapshot<DocumentData> | { id: string; data: () => DocumentData },
): ProjectItemRecord {
  const d = doc.data();
  const statusRaw = asString(d.status);
  const status: ProjectItemStatus =
    statusRaw === "waiting_on_them" ||
    statusRaw === "done" ||
    statusRaw === "cancelled"
      ? statusRaw
      : "pending";
  const kindRaw = asString(d.kind) as ProjectItemKind;
  const kind: ProjectItemKind =
    kindRaw === "sample" ||
    kindRaw === "approval" ||
    kindRaw === "rate" ||
    kindRaw === "meeting" ||
    kindRaw === "followup"
      ? kindRaw
      : "general";
  return {
    id: doc.id,
    projectId: asString(d.projectId),
    projectName: asString(d.projectName),
    title: asString(d.title),
    description: asString(d.description),
    kind,
    status,
    dueAtIso: asString(d.dueAtIso) || null,
    dueAtMs: asNum(d.dueAtMs),
    waitingOn: asString(d.waitingOn),
    notes: asString(d.notes),
    reminderId: asString(d.reminderId) || null,
    createdAtMs: asNum(d.createdAtMs) ?? 0,
    updatedAtMs: asNum(d.updatedAtMs) ?? 0,
  };
}

export async function listProjects(uid: string): Promise<ProjectRecord[]> {
  const snap = await projectsCol(uid).orderBy("updatedAtMs", "desc").limit(80).get();
  return snap.docs.map(projectFromDoc);
}

export async function getProject(
  uid: string,
  projectId: string,
): Promise<ProjectRecord | null> {
  const doc = await projectsCol(uid).doc(projectId).get();
  if (!doc.exists) {
    return null;
  }
  return projectFromDoc({ id: doc.id, data: () => doc.data() as DocumentData });
}

export async function findProjectByHint(
  uid: string,
  hint: string,
): Promise<ProjectRecord | null> {
  const key = normalizeNameKey(hint);
  if (!key) {
    return null;
  }
  const all = await listProjects(uid);
  const exact = all.find((p) => p.nameKey === key || p.clientKey === key);
  if (exact) {
    return exact;
  }
  const partial = all.find(
    (p) =>
      p.nameKey.includes(key) ||
      key.includes(p.nameKey) ||
      p.clientKey.includes(key) ||
      (p.clientKey && key.includes(p.clientKey)),
  );
  return partial ?? null;
}

export async function createProject(
  uid: string,
  input: { name: string; client?: string; notes?: string },
): Promise<ProjectRecord> {
  const now = Date.now();
  const name = input.name.trim() || "Untitled";
  const client = (input.client ?? "").trim();
  const ref = projectsCol(uid).doc();
  const data = {
    name,
    nameKey: normalizeNameKey(name),
    client,
    clientKey: normalizeNameKey(client || name),
    status: "active" as const,
    notes: (input.notes ?? "").trim(),
    createdAt: FieldValue.serverTimestamp(),
    createdAtMs: now,
    updatedAt: FieldValue.serverTimestamp(),
    updatedAtMs: now,
  };
  await ref.set(data);
  return {
    id: ref.id,
    name,
    nameKey: data.nameKey,
    client,
    clientKey: data.clientKey,
    status: "active",
    notes: data.notes,
    createdAtMs: now,
    updatedAtMs: now,
  };
}

export async function addItems(
  uid: string,
  project: ProjectRecord,
  drafts: ProjectDraftItem[],
): Promise<ProjectItemRecord[]> {
  const now = Date.now();
  const written: ProjectItemRecord[] = [];
  const batch = getFirestore().batch();
  for (const d of drafts) {
    const ref = itemsCol(uid).doc();
    const row = {
      projectId: project.id,
      projectName: project.name,
      title: d.title,
      description: d.description,
      kind: d.kind,
      status: d.status,
      dueAtIso: d.dueAtIso,
      dueAtMs: d.dueAtMs,
      waitingOn: d.waitingOn,
      notes: d.notes,
      reminderId: null as string | null,
      createdAt: FieldValue.serverTimestamp(),
      createdAtMs: now,
      updatedAt: FieldValue.serverTimestamp(),
      updatedAtMs: now,
    };
    batch.set(ref, row);
    written.push({
      id: ref.id,
      ...row,
    });
  }
  batch.update(projectsCol(uid).doc(project.id), {
    updatedAt: FieldValue.serverTimestamp(),
    updatedAtMs: now,
  });
  await batch.commit();
  return written;
}

export async function listItemsForProject(
  uid: string,
  projectId: string,
): Promise<ProjectItemRecord[]> {
  const snap = await itemsCol(uid)
    .where("projectId", "==", projectId)
    .limit(200)
    .get();
  const items = snap.docs.map(itemFromDoc);
  items.sort((a, b) => (a.createdAtMs || 0) - (b.createdAtMs || 0));
  return items;
}

export async function listOpenItems(uid: string): Promise<ProjectItemRecord[]> {
  const snap = await itemsCol(uid).limit(400).get();
  return snap.docs
    .map(itemFromDoc)
    .filter((i) => i.status === "pending" || i.status === "waiting_on_them");
}

export async function listTodayItems(
  uid: string,
  clock: ProjectClock,
): Promise<ProjectItemRecord[]> {
  const start = startOfLocalDayMs(clock);
  const end = startOfNextLocalDayMs(clock);
  const open = await listOpenItems(uid);
  return open.filter((i) => {
    if (i.dueAtMs != null && i.dueAtMs >= start && i.dueAtMs < end) {
      return true;
    }
    if (i.status === "waiting_on_them" && i.dueAtMs != null && i.dueAtMs < end) {
      return true;
    }
    return false;
  });
}

export async function updateItemStatus(
  uid: string,
  itemId: string,
  status: ProjectItemStatus,
): Promise<ProjectItemRecord | null> {
  const ref = itemsCol(uid).doc(itemId);
  const snap = await ref.get();
  if (!snap.exists) {
    return null;
  }
  const now = Date.now();
  await ref.update({
    status,
    updatedAt: FieldValue.serverTimestamp(),
    updatedAtMs: now,
  });
  const after = await ref.get();
  return itemFromDoc({ id: after.id, data: () => after.data() as DocumentData });
}

export async function setItemReminderId(
  uid: string,
  itemId: string,
  reminderId: string,
): Promise<void> {
  await itemsCol(uid).doc(itemId).update({
    reminderId,
    updatedAt: FieldValue.serverTimestamp(),
    updatedAtMs: Date.now(),
  });
}

export function matchItemByText(
  items: ProjectItemRecord[],
  text: string,
): ProjectItemRecord[] {
  const t = text.toLowerCase();
  return items.filter((i) => {
    const blob = `${i.title} ${i.kind} ${i.waitingOn} ${i.description}`.toLowerCase();
    const tokens = t
      .split(/\s+/)
      .map((w) => w.replace(/[^a-z0-9]/g, ""))
      .filter((w) => w.length >= 3);
    return tokens.some((tok) => blob.includes(tok));
  });
}
