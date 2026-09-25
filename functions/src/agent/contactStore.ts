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
  /** When set, update this row rather than creating one. */
  existingId?: string | null;
}

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

export async function saveContact(uid: string, input: SaveContactInput): Promise<CrmContact> {
  const name = input.name.trim();
  const phone = normalizeIndiaPhone(input.phone) ?? "";
  const company = (input.company ?? "").trim();
  const email = (input.email ?? "").trim();
  const notes = (input.notes ?? "").trim();
  const source = (input.source ?? "agent").trim() || "agent";
  const nowMs = Date.now();

  let ref = input.existingId ? contactsRef().doc(input.existingId) : contactsRef().doc();
  if (!input.existingId && phone) {
    const existing = await findContactByPhone(uid, phone);
    if (existing) {
      ref = contactsRef().doc(existing.id);
    }
  }

  const isUpdate = (await ref.get()).exists;
  const payload: Record<string, unknown> = {
    ownerUid: uid,
    name,
    nameLower: name.toLowerCase(),
    phone,
    company,
    email,
    notes,
    updatedAt: FieldValue.serverTimestamp(),
    updatedAtMs: nowMs,
  };
  if (!isUpdate) {
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
    tags: [],
    notes,
    source,
    createdAtMs: nowMs,
    updatedAtMs: nowMs,
  };
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
