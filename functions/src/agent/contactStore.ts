/**
 * CRM contacts — the visiting-card book.
 *
 * Lives at the root `contacts` collection with `ownerUid`, same shape the
 * Flutter `ContactService` writes. A second collection under the user would
 * have meant a second contacts screen and a second search, so the agent
 * writes here and Records already shows them.
 *
 * Lookup is the same rule the app uses: prefix for short tokens, contains
 * once the query is three letters. Phone digits are matched too, because
 * "98765 wala" is how a number comes back in conversation.
 */

import { FieldValue, getFirestore } from "firebase-admin/firestore";

export interface CrmContact {
  id: string;
  ownerUid: string;
  name: string;
  nameLower: string;
  phone: string;
  company: string;
  email: string;
  tags: string[];
  notes: string;
  source: string;
  /** Storage paths of the card's photos — the front, and the back when there is one. */
  cardImages: string[];
  createdAtMs: number;
  updatedAtMs: number;
}

export interface SaveContactInput {
  name: string;
  phone?: string | null;
  company?: string | null;
  email?: string | null;
  notes?: string | null;
  source?: string;
  /** Photos of the card on this save; added to any it already has. */
  cardImages?: string[];
  /** When set, update this row rather than creating one. */
  existingId?: string | null;
}

/** The most card photos kept — front and back, plus a retake of each. */
export const MAX_CARD_IMAGES = 4;

function contactsRef() {
  return getFirestore().collection("contacts");
}

/**
 * Same rules as `ContactService.normalizeIndiaPhone`. A visiting card that
 * printed 10 digits is stored as 91 + those digits, so a later search for
 * either form finds it.
 */
export function normalizeIndiaPhone(raw: string | null | undefined): string | null {
  const d = `${raw ?? ""}`.replace(/\D/g, "");
  if (!d) {
    return null;
  }
  if (d.length === 12 && d.startsWith("91")) {
    return d;
  }
  if (d.length === 10) {
    return `91${d}`;
  }
  if (d.length >= 10 && d.length <= 15) {
    return d;
  }
  return null;
}

export function nameMatchesContactQuery(nameLower: string, queryLower: string): boolean {
  const q = queryLower.trim();
  if (!q) {
    return false;
  }
  if (nameLower.startsWith(q)) {
    return true;
  }
  if (q.length < 3) {
    return false;
  }
  return nameLower.includes(q);
}

function contactFrom(id: string, data: FirebaseFirestore.DocumentData): CrmContact {
  const tagsRaw = data.tags;
  const tags: string[] = [];
  if (Array.isArray(tagsRaw)) {
    for (const e of tagsRaw) {
      if (typeof e === "string" && e.trim()) {
        tags.push(e.trim());
      }
    }
  }
  return {
    id,
    ownerUid: `${data.ownerUid ?? ""}`.trim(),
    name: `${data.name ?? ""}`.trim(),
    nameLower: `${data.nameLower ?? data.name ?? ""}`.trim().toLowerCase(),
    phone: `${data.phone ?? ""}`.trim(),
    company: `${data.company ?? ""}`.trim(),
    email: `${data.email ?? ""}`.trim(),
    tags,
    notes: `${data.notes ?? ""}`.trim(),
    source: `${data.source ?? "manual"}`.trim() || "manual",
    cardImages: Array.isArray(data.cardImages)
      ? (data.cardImages as unknown[]).filter((p): p is string => typeof p === "string" && p.length > 0)
      : [],
    createdAtMs: Number(data.createdAtMs ?? 0) || 0,
    updatedAtMs: Number(data.updatedAtMs ?? 0) || 0,
  };
}

/** Existing row with this phone, if any — so a second snap of the same card updates. */
export async function findContactByPhone(
  uid: string,
  phone: string,
): Promise<CrmContact | null> {
  const p = normalizeIndiaPhone(phone);
  if (!p) {
    return null;
  }
  const snap = await contactsRef()
    .where("ownerUid", "==", uid)
    .where("phone", "==", p)
    .limit(1)
    .get();
  if (snap.empty) {
    return null;
  }
  const d = snap.docs[0]!;
  return contactFrom(d.id, d.data());
}

/** Text that is new, added under what was there; a repeat is not added twice. */
export function mergeNotes(oldNotes: string, newNotes: string): string {
  const a = oldNotes.trim();
  const b = newNotes.trim();
  if (!b || a.toLowerCase().includes(b.toLowerCase())) return a;
  if (!a || b.toLowerCase().includes(a.toLowerCase())) return b;
  return `${a}\n${b}`;
}

/**
 * Creates a contact, or updates one — by id, or by the same phone number.
 *
 * An update only adds: a field left empty this time keeps what was saved, and
 * notes and card photos are added to. That is what makes the back of a card,
 * sent after the front, fill the contact in rather than wipe its number.
 */
export async function saveContact(uid: string, input: SaveContactInput): Promise<CrmContact> {
  const nowMs = Date.now();
  let ref = contactsRef().doc();
  let old: CrmContact | null = null;
  if (input.existingId) {
    const snap = await contactsRef().doc(input.existingId).get();
    // Someone else's id is not an update target; it becomes a new contact.
    if (snap.exists && `${snap.data()?.ownerUid ?? ""}` === uid) {
      ref = contactsRef().doc(input.existingId);
      old = contactFrom(snap.id, snap.data() ?? {});
    }
  }
  const phoneIn = normalizeIndiaPhone(input.phone) ?? "";
  if (!old && phoneIn) {
    const existing = await findContactByPhone(uid, phoneIn);
    if (existing) {
      ref = contactsRef().doc(existing.id);
      old = existing;
    }
  }

  const pick = (fresh: string | null | undefined, kept: string | undefined) =>
    (fresh ?? "").trim() || (kept ?? "");
  const name = pick(input.name, old?.name);
  const phone = phoneIn || old?.phone || "";
  const company = pick(input.company, old?.company);
  const email = pick(input.email, old?.email);
  const notes = mergeNotes(old?.notes ?? "", input.notes ?? "");
  const cardImages = [...new Set([...(old?.cardImages ?? []), ...(input.cardImages ?? [])])].slice(
    -MAX_CARD_IMAGES,
  );
  const source = old?.source || (input.source ?? "agent").trim() || "agent";

  const payload: Record<string, unknown> = {
    ownerUid: uid,
    name,
    nameLower: name.toLowerCase(),
    phone,
    company,
    email,
    notes,
    cardImages,
    updatedAt: FieldValue.serverTimestamp(),
    updatedAtMs: nowMs,
  };
  if (!old) {
    payload.tags = [];
    payload.source = source;
    payload.createdAt = FieldValue.serverTimestamp();
    payload.createdAtMs = nowMs;
  }

  await ref.set(payload, { merge: true });
  return {
    id: ref.id,
    ownerUid: uid,
    name,
    nameLower: name.toLowerCase(),
    phone,
    company,
    email,
    tags: old?.tags ?? [],
    notes,
    source,
    cardImages,
    createdAtMs: old?.createdAtMs ?? nowMs,
    updatedAtMs: nowMs,
  };
}

/** One contact of this user's, by id. */
export async function getContact(uid: string, id: string): Promise<CrmContact | null> {
  const snap = await contactsRef().doc(id).get();
  if (!snap.exists || `${snap.data()?.ownerUid ?? ""}` !== uid) return null;
  return contactFrom(snap.id, snap.data() ?? {});
}

export async function searchCrmContacts(
  uid: string,
  query: string,
  limit = 8,
): Promise<CrmContact[]> {
  const q = query.trim().toLowerCase();
  if (!q) {
    return [];
  }
  const digits = q.replace(/\D/g, "");
  const snap = await contactsRef().where("ownerUid", "==", uid).limit(500).get();
  const rows = snap.docs
    .map((d) => contactFrom(d.id, d.data()))
    .filter((c) => {
      if (nameMatchesContactQuery(c.nameLower, q)) {
        return true;
      }
      if (c.company && q.length >= 3 && c.company.toLowerCase().includes(q)) {
        return true;
      }
      if (digits.length >= 4 && c.phone.includes(digits)) {
        return true;
      }
      return false;
    });
  rows.sort((a, b) => a.nameLower.localeCompare(b.nameLower));
  return rows.slice(0, limit);
}
