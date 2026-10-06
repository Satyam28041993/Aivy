/**
 * Documents they will ask about later — rate cards, brochures, training notes.
 *
 * Stored under `users/{uid}/library/{id}`. Not a project and not a remembered
 * fact: a project is work with a deadline, and `remember_fact` is one line
 * about them. A 12-page rate card is neither. Search walks title, excerpt and
 * the extracted facts, because "X ka rate kya hai" will not repeat the file
 * name they saved it under.
 *
 * One file is one record. Saving the same title and kind again overwrites,
 * so a revised rate card does not leave the old prices sitting next to it.
 */

import { getFirestore } from "firebase-admin/firestore";

import { normalizeName } from "./nameNormalize";

export const LIBRARY_KINDS = [
  "brochure",
  "rate_card",
  "training",
  "product",
  "other",
] as const;

export type LibraryKind = (typeof LIBRARY_KINDS)[number];

export interface LibraryFact {
  label: string;
  value: string;
}

export interface LibraryItem {
  id: string;
  title: string;
  titleKey: string;
  kind: LibraryKind;
  sourceName: string;
  mimeType: string;
  storagePath: string;
  excerpt: string;
  facts: LibraryFact[];
  /** Lowercased blob of title + excerpt + facts, for in-memory search. */
  searchText: string;
  createdAtMs: number;
  updatedAtMs: number;
}

export interface SaveLibraryInput {
  title: string;
  kind: LibraryKind;
  sourceName?: string | null;
  mimeType?: string | null;
  storagePath?: string | null;
  excerpt?: string | null;
  facts?: LibraryFact[];
  existingId?: string | null;
}

function libraryRef(uid: string) {
  return getFirestore().collection("users").doc(uid).collection("library");
}

export function isLibraryKind(raw: string): raw is LibraryKind {
  return (LIBRARY_KINDS as readonly string[]).includes(raw);
}

function factsOf(raw: LibraryFact[] | undefined): LibraryFact[] {
  if (!Array.isArray(raw)) {
    return [];
  }
  const out: LibraryFact[] = [];
  for (const f of raw) {
    const label = `${f?.label ?? ""}`.trim();
    const value = `${f?.value ?? ""}`.trim();
    if (label && value) {
      out.push({ label, value });
    }
  }
  return out;
}

function searchBlob(title: string, excerpt: string, facts: LibraryFact[]): string {
  return [title, excerpt, ...facts.map((f) => `${f.label} ${f.value}`)]
    .join(" ")
    .toLowerCase();
}

function itemFrom(id: string, data: FirebaseFirestore.DocumentData): LibraryItem {
  const facts = factsOf(data.facts as LibraryFact[] | undefined);
  const title = `${data.title ?? ""}`.trim();
  const excerpt = `${data.excerpt ?? ""}`.trim();
  const kind = isLibraryKind(`${data.kind ?? ""}`) ? (data.kind as LibraryKind) : "other";
  return {
    id,
    title,
    titleKey: `${data.titleKey ?? normalizeName(title)}`,
    kind,
    sourceName: `${data.sourceName ?? ""}`.trim(),
    mimeType: `${data.mimeType ?? ""}`.trim(),
    storagePath: `${data.storagePath ?? ""}`.trim(),
    excerpt,
    facts,
    searchText: `${data.searchText ?? searchBlob(title, excerpt, facts)}`,
    createdAtMs: Number(data.createdAtMs ?? 0) || 0,
    updatedAtMs: Number(data.updatedAtMs ?? 0) || 0,
  };
}

/** Same title + kind is the same document revised, not a second copy. */
export async function findLibraryByTitleKind(
  uid: string,
  title: string,
  kind: LibraryKind,
): Promise<LibraryItem | null> {
  const titleKey = normalizeName(title);
  if (!titleKey) {
    return null;
  }
  const snap = await libraryRef(uid)
    .where("titleKey", "==", titleKey)
    .where("kind", "==", kind)
    .limit(1)
    .get();
  if (snap.empty) {
    return null;
  }
  const d = snap.docs[0]!;
  return itemFrom(d.id, d.data());
}

export async function saveLibraryItem(uid: string, input: SaveLibraryInput): Promise<LibraryItem> {
  const title = input.title.trim();
  const titleKey = normalizeName(title);
  const kind = input.kind;
  const facts = factsOf(input.facts);
  const excerpt = (input.excerpt ?? "").trim();
  const nowMs = Date.now();

  let ref = input.existingId ? libraryRef(uid).doc(input.existingId) : libraryRef(uid).doc();
  if (!input.existingId) {
    const existing = await findLibraryByTitleKind(uid, title, kind);
    if (existing) {
      ref = libraryRef(uid).doc(existing.id);
    }
  }

  const existingSnap = await ref.get();
  const createdAtMs = existingSnap.exists
    ? Number(existingSnap.data()?.createdAtMs ?? nowMs) || nowMs
    : nowMs;

  const item: LibraryItem = {
    id: ref.id,
    title,
    titleKey,
    kind,
    sourceName: (input.sourceName ?? "").trim(),
    mimeType: (input.mimeType ?? "").trim(),
    storagePath: (input.storagePath ?? "").trim(),
    excerpt,
    facts,
    searchText: searchBlob(title, excerpt, facts),
    createdAtMs,
    updatedAtMs: nowMs,
  };
  await ref.set(item);
  return item;
}

/**
 * Token match over the recent library. Firestore has no full-text index here
 * on purpose — a few hundred documents is the size of a real notebook, and a
 * second copy of the truth (a search index) goes wrong the first time a write
 * half-fails.
 */
export async function searchLibrary(
  uid: string,
  query: string,
  limit = 8,
): Promise<LibraryItem[]> {
  const tokens = query
    .toLowerCase()
    .split(/[^a-z0-9\u0900-\u097f]+/i)
    .map((t) => t.trim())
    .filter((t) => t.length >= 2);
  if (tokens.length === 0) {
    return [];
  }

  const snap = await libraryRef(uid).orderBy("updatedAtMs", "desc").limit(200).get();
  const scored = snap.docs
    .map((d) => itemFrom(d.id, d.data()))
    .map((item) => {
      const hay = item.searchText;
      let score = 0;
      for (const t of tokens) {
        if (hay.includes(t)) {
          score += 1;
        }
      }
      return { item, score };
    })
    .filter((r) => r.score > 0)
    .sort((a, b) => b.score - a.score || b.item.updatedAtMs - a.item.updatedAtMs);

  return scored.slice(0, limit).map((r) => r.item);
}
