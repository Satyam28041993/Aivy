import { resolveDueHint } from "./dates";
import type {
  ProjectClock,
  ProjectDraftItem,
  ProjectDraftPayload,
  ProjectItemKind,
  ProjectItemStatus,
} from "./types";
import { ITEM_KINDS, ITEM_STATUSES } from "./types";

const KIND_HINTS: Array<{ kind: ProjectItemKind; re: RegExp }> = [
  { kind: "sample", re: /\b(sample|samples|label|labels|dikha(?:ya|ye|o)?|swatch)\b/i },
  { kind: "approval", re: /\b(approval|approve|approved|pass karo|ok karwana)\b/i },
  { kind: "rate", re: /\b(rate|rates|price|pricing|quote rate)\b/i },
  { kind: "meeting", re: /\b(meeting|mulakat|mulaqat|visit|aayega|aayegi|aa raha)\b/i },
  { kind: "followup", re: /\b(follow[\s-]?up|followup|peecha)\b/i },
];

export function normalizeNameKey(raw: string): string {
  return raw
    .toLowerCase()
    .replace(/\b(project|proj|ji|sir|wale|wala|wali)\b/g, " ")
    .replace(/[^\p{L}\p{N}\s.&'-]/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

export function normalizeItemKind(raw: string | undefined): ProjectItemKind {
  const v = (raw ?? "").trim().toLowerCase();
  if ((ITEM_KINDS as readonly string[]).includes(v)) {
    return v as ProjectItemKind;
  }
  for (const h of KIND_HINTS) {
    if (h.re.test(v)) {
      return h.kind;
    }
  }
  return "general";
}

export function normalizeItemStatus(raw: string | undefined): ProjectItemStatus {
  const v = (raw ?? "").trim().toLowerCase().replace(/\s+/g, "_");
  if (v === "waiting" || v === "waiting_on_client" || v === "their_side") {
    return "waiting_on_them";
  }
  if ((ITEM_STATUSES as readonly string[]).includes(v)) {
    return v as ProjectItemStatus;
  }
  return "pending";
}

export function inferKindFromText(text: string): ProjectItemKind {
  for (const h of KIND_HINTS) {
    if (h.re.test(text)) {
      return h.kind;
    }
  }
  return "general";
}

export function inferStatusFromText(text: string): ProjectItemStatus {
  const t = text.toLowerCase();
  if (/\b(cancel|cancelled|chhod|drop)\b/.test(t)) {
    return "cancelled";
  }
  if (/\b(done|ho gaya|ho gya|complete|completed|khatam|pasand aa(?:ya|yega)?)\b/.test(t) &&
      !/\b(rate|approval|po|pending|dena hai|aayega)\b/.test(t)) {
    return "done";
  }
  if (
    /\b(unka|unse|unki|unke|unpe|client se|waiting|approval pending|rate pending|po pending|dena hai)\b/.test(
      t,
    )
  ) {
    // "rate Monday tak dena hai" / client-side work → waiting_on_them
    if (/\b(unka|unse|unki|unke|unpe|client|approval|rate|po|qc)\b/.test(t)) {
      return "waiting_on_them";
    }
  }
  return "pending";
}

export function inferWaitingOn(text: string): string {
  const t = text.trim();
  const unka = t.match(
    /\b(?:unka|unki|unke|unse)\s+([A-Za-z][A-Za-z0-9.&'\-]*(?:\s+[A-Za-z][A-Za-z0-9.&'\-]*){0,3})/i,
  );
  if (unka?.[1]) {
    return unka[1].replace(/\b(ko|se|ka|ke|ki)\b/gi, " ").replace(/\s+/g, " ").trim();
  }
  const waiting = t.match(
    /\bwaiting(?:\s+on)?\s+([A-Za-z][A-Za-z0-9.&'\-]*(?:\s+[A-Za-z][A-Za-z0-9.&'\-]*){0,3})/i,
  );
  if (waiting?.[1] && !/^(them|client|us)$/i.test(waiting[1])) {
    return waiting[1].trim();
  }
  return "";
}

function splitClauses(text: string): string[] {
  return text
    .split(/\s*(?:,+|\/|;|\n| aur |\band\b)\s*/i)
    .map((c) => c.trim())
    .filter((c) => c.length >= 6);
}

function guessProjectName(text: string): string {
  const named = text.match(
    /\b([A-Za-z][A-Za-z0-9.&'\-]*(?:\s+[A-Za-z][A-Za-z0-9.&'\-]*){0,2})\s+project\b/i,
  );
  if (named?.[1]) {
    return titled(named[1]);
  }
  const person = text.match(/^([A-Za-z][A-Za-z0-9.&'\-]*)\s+ko\b/i);
  if (person?.[1]) {
    return titled(person[1]);
  }
  return "General";
}

function guessClient(text: string, projectName: string): string {
  const ko = text.match(/\b([A-Za-z][A-Za-z0-9.&'\-]*)\s+ko\b/i);
  if (ko?.[1]) {
    return titled(ko[1]);
  }
  if (projectName && projectName !== "General") {
    return projectName;
  }
  return "";
}

function titled(raw: string): string {
  return raw
    .trim()
    .split(/\s+/)
    .map((w) => (w ? w[0].toUpperCase() + w.slice(1) : w))
    .join(" ");
}

export function draftItemFromClause(
  clause: string,
  clock: ProjectClock,
): ProjectDraftItem {
  const kind = inferKindFromText(clause);
  const status = inferStatusFromText(clause);
  const due = resolveDueHint(clause, clock);
  const waitingOn = inferWaitingOn(clause);
  const title = clause.replace(/\s+/g, " ").trim().slice(0, 140);
  return {
    title,
    description: clause.trim(),
    kind,
    status,
    dueAtIso: due?.iso ?? null,
    dueAtMs: due?.ms ?? null,
    dueLabel: due?.label ?? "",
    waitingOn,
    notes: "",
  };
}

export function heuristicExtractDraft(
  text: string,
  clock: ProjectClock,
): ProjectDraftPayload {
  const clauses = splitClauses(text);
  const items = (clauses.length >= 2 ? clauses : [text.trim()])
    .map((c) => draftItemFromClause(c, clock))
    .filter((i) => i.title.length > 0);
  const projectName = guessProjectName(text);
  const client = guessClient(text, projectName);
  return {
    flowCategoryId: "project_items",
    type: "project",
    subType: "items",
    projectId: null,
    projectName,
    client,
    sourceText: text.trim(),
    items: items.length > 0 ? items : [draftItemFromClause(text, clock)],
  };
}

export function normalizeDraftItem(
  raw: Partial<ProjectDraftItem> & { title?: string },
  clock: ProjectClock,
): ProjectDraftItem | null {
  const title = (raw.title ?? "").trim();
  if (!title) {
    return null;
  }
  const description = (raw.description ?? title).trim();
  const dueFromFields =
    raw.dueAtIso || raw.dueLabel
      ? resolveDueHint(raw.dueAtIso || raw.dueLabel || "", clock)
      : null;
  const due = dueFromFields ?? (raw.dueAtMs && raw.dueAtIso
    ? { iso: raw.dueAtIso, ms: raw.dueAtMs, label: raw.dueLabel || "" }
    : resolveDueHint(description, clock));
  return {
    title: title.slice(0, 180),
    description: description.slice(0, 500),
    kind: normalizeItemKind(raw.kind),
    status: normalizeItemStatus(raw.status) || inferStatusFromText(description),
    dueAtIso: due?.iso ?? (typeof raw.dueAtIso === "string" ? raw.dueAtIso : null),
    dueAtMs: due?.ms ?? (typeof raw.dueAtMs === "number" ? raw.dueAtMs : null),
    dueLabel: due?.label ?? (raw.dueLabel ?? ""),
    waitingOn: (raw.waitingOn ?? inferWaitingOn(description)).trim(),
    notes: (raw.notes ?? "").trim(),
  };
}

export function mergeDraft(
  base: ProjectDraftPayload,
  items: ProjectDraftItem[],
  projectName?: string,
  client?: string,
  projectId?: string | null,
): ProjectDraftPayload {
  return {
    ...base,
    projectId: projectId === undefined ? base.projectId : projectId,
    projectName: (projectName ?? base.projectName).trim() || base.projectName,
    client: (client ?? base.client).trim(),
    items,
  };
}
