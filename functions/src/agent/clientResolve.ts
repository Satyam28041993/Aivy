/**
 * Server-side client name resolution for agent tools.
 *
 * The model is never allowed to guess which client a name refers to. It passes
 * the raw token it heard; this module matches it against `users/{uid}/clients`
 * and reports back one of three outcomes, so the agent can ask when it is
 * genuinely ambiguous instead of writing to the wrong ledger.
 *
 * Matching mirrors `ClientRepository.resolveForPaymentName` in the app:
 * case-insensitive exact match first, then prefix, and only the display name is
 * compared (`normalizeForMatch` is trim + lowercase, not the particle-stripping
 * `normalizeName` used for `nameLower` keys).
 */

import { getFirestore } from "firebase-admin/firestore";

import { capitalizeWords, normalizeName } from "./nameNormalize";

export interface AgentClient {
  id: string;
  name: string;
  nameLower: string;
  outstandingBalance: number;
}

export type ClientResolution =
  | { status: "single"; client: AgentClient }
  | { status: "ambiguous"; candidates: AgentClient[] }
  | { status: "not_found"; query: string };

/** Trim + lowercase only — matches `ClientRepository.normalizeForMatch`. */
export function normalizeForMatch(name: string): string {
  return name.trim().toLowerCase();
}

/**
 * Names that are chat noise rather than real clients. Ported from
 * `ClientRepository.looksLikeChatNoiseClientName` so the agent does not offer
 * to "create" a client called "cancel".
 */
const SINGLE_TOKEN_NOISE: ReadonlySet<string> = new Set([
  "cancel",
  "band",
  "stop",
  "skip",
  "yes",
  "no",
  "haan",
  "nahi",
  "ok",
  "confirm",
  "edit",
  "undo",
  "aivy",
  "hi",
  "hello",
  "hey",
]);

export function looksLikeNoiseClientName(raw: string): boolean {
  const t = raw.trim();
  if (t.length < 2) {
    return true;
  }
  const low = normalizeForMatch(t);
  if (SINGLE_TOKEN_NOISE.has(low)) {
    return true;
  }
  // Pure numbers are menu picks, never client names.
  if (/^\d+$/.test(low)) {
    return true;
  }
  return false;
}

function clientsRef(uid: string) {
  return getFirestore().collection("users").doc(uid).collection("clients");
}

function toClient(id: string, d: Record<string, unknown>): AgentClient {
  const name = String(d.name ?? "").trim();
  const nlRaw = String(d.nameLower ?? "").trim();
  const balance = d.outstandingBalance;
  return {
    id,
    name,
    nameLower: nlRaw || (name ? normalizeName(name) : ""),
    outstandingBalance: typeof balance === "number" ? balance : 0,
  };
}

export async function listClients(uid: string): Promise<AgentClient[]> {
  const snap = await clientsRef(uid).get();
  const out = snap.docs.map((d) => toClient(d.id, d.data() as Record<string, unknown>));
  out.sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()));
  return out;
}

/**
 * Resolves a spoken client token. Exact match wins; a single prefix match is
 * accepted; anything else is reported so the agent can ask.
 */
export async function resolveClient(
  uid: string,
  input: string,
): Promise<ClientResolution> {
  const q = (input ?? "").trim();
  if (!q) {
    return { status: "not_found", query: "" };
  }
  const qn = normalizeForMatch(q);
  const all = await listClients(uid);

  const exact = all.filter((c) => normalizeForMatch(c.name) === qn);
  if (exact.length === 1) {
    return { status: "single", client: exact[0]! };
  }
  if (exact.length > 1) {
    return { status: "ambiguous", candidates: exact };
  }

  const prefix = all.filter((c) => normalizeForMatch(c.name).startsWith(qn));
  if (prefix.length === 1) {
    return { status: "single", client: prefix[0]! };
  }
  if (prefix.length > 1) {
    return { status: "ambiguous", candidates: prefix };
  }

  // Last resort: the particle-stripped key, so "Rohan ka" finds "Rohan".
  const keyed = normalizeName(q);
  if (keyed && keyed !== qn) {
    const byKey = all.filter((c) => c.nameLower === keyed);
    if (byKey.length === 1) {
      return { status: "single", client: byKey[0]! };
    }
    if (byKey.length > 1) {
      return { status: "ambiguous", candidates: byKey };
    }
  }

  return { status: "not_found", query: q };
}

/** Creates a client the same way the app's `ClientRepository.createClient` does. */
export async function createClient(
  uid: string,
  name: string,
): Promise<AgentClient> {
  const trimmed = capitalizeWords(name.trim());
  const nl = normalizeName(trimmed);
  const ref = clientsRef(uid).doc();
  const nowMs = Date.now();
  await ref.set({
    name: trimmed,
    nameLower: nl,
    outstandingBalance: 0,
    createdAtMs: nowMs,
  });
  return { id: ref.id, name: trimmed, nameLower: nl, outstandingBalance: 0 };
}

/** Prefix search used by the `search_clients` tool. */
export async function searchClients(
  uid: string,
  input: string,
  limit = 10,
): Promise<AgentClient[]> {
  const q = (input ?? "").trim().toLowerCase();
  const all = await listClients(uid);
  if (!q) {
    return all.slice(0, limit);
  }
  const starts = all.filter((c) => c.name.toLowerCase().startsWith(q));
  if (starts.length > 0) {
    return starts.slice(0, limit);
  }
  return all.filter((c) => c.name.toLowerCase().includes(q)).slice(0, limit);
}
