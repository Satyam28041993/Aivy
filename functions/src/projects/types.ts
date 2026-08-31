/** Flexible project thread — no fixed pipeline. */

export const PROJECT_STATUSES = ["active", "paused", "done"] as const;
export type ProjectStatus = (typeof PROJECT_STATUSES)[number];

export const ITEM_STATUSES = [
  "pending",
  "waiting_on_them",
  "done",
  "cancelled",
] as const;
export type ProjectItemStatus = (typeof ITEM_STATUSES)[number];

export const ITEM_KINDS = [
  "sample",
  "approval",
  "rate",
  "meeting",
  "followup",
  "general",
] as const;
export type ProjectItemKind = (typeof ITEM_KINDS)[number];

export type ProjectClock = {
  timezone: string;
  nowIso: string;
};

export type ProjectRecord = {
  id: string;
  name: string;
  nameKey: string;
  client: string;
  clientKey: string;
  status: ProjectStatus;
  notes: string;
  createdAtMs: number;
  updatedAtMs: number;
};

export type ProjectItemRecord = {
  id: string;
  projectId: string;
  projectName: string;
  title: string;
  description: string;
  kind: ProjectItemKind;
  status: ProjectItemStatus;
  dueAtIso: string | null;
  dueAtMs: number | null;
  waitingOn: string;
  notes: string;
  reminderId: string | null;
  createdAtMs: number;
  updatedAtMs: number;
};

/** Confirmable extract — client must tap Confirm before Firestore write. */
export type ProjectDraftItem = {
  title: string;
  description: string;
  kind: ProjectItemKind;
  status: ProjectItemStatus;
  dueAtIso: string | null;
  dueAtMs: number | null;
  dueLabel: string;
  waitingOn: string;
  notes: string;
};

export type ProjectDraftPayload = {
  flowCategoryId: "project_items";
  type: "project";
  subType: "items";
  projectId: string | null;
  projectName: string;
  client: string;
  sourceText: string;
  items: ProjectDraftItem[];
};

export type ProjectSummaryBuckets = {
  pending: ProjectItemRecord[];
  waitingOnThem: ProjectItemRecord[];
  done: ProjectItemRecord[];
  cancelled: ProjectItemRecord[];
};

export type ProjectTurnMode = "extract" | "query" | "update" | "today";

export type ProjectTurnResult = {
  mode: ProjectTurnMode;
  userReply: string;
  projectDraft?: ProjectDraftPayload;
  data?: Record<string, unknown>;
};
