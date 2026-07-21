/**
 * Auto-create a `contacts` row when an inbound WhatsApp arrives from a number
 * that is not yet in the user's contact book.
 *
 * The target owner is read in order:
 *   1. Firestore `app_config/whatsapp.contactsOwnerUid`
 *   2. Environment variable `CONTACTS_AUTO_OWNER_UID`
 *
 * When neither is set, this is a no-op (avoids writing orphan docs).
 */

import { FieldValue, getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions";
import { withRetry } from "../whatsapp/retry";

function normalizeWaPhone(raw: string): string | null {
  const d = String(raw ?? "").replace(/\D/g, "");
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

async function resolveContactsOwnerUid(): Promise<string | null> {
  try {
    const snap = await getFirestore().collection("app_config").doc("whatsapp").get();
    const u = String(snap.data()?.contactsOwnerUid ?? "").trim();
    if (u.length > 8) {
      return u;
    }
  } catch {
    // ignore
  }
  const env = String(process.env.CONTACTS_AUTO_OWNER_UID ?? "").trim();
  return env.length > 8 ? env : null;
}

export async function ensureContactFromWhatsAppInbound(opts: {
  from: string;
  profileName: string | null;
}): Promise<void> {
  const ownerUid = await resolveContactsOwnerUid();
  if (!ownerUid) {
    return;
  }
  const phone = normalizeWaPhone(opts.from);
  if (!phone) {
    return;
  }
  const db = getFirestore();
  const dup = await withRetry("contactDupCheck", () =>
    db
      .collection("contacts")
      .where("ownerUid", "==", ownerUid)
      .where("phone", "==", phone)
      .limit(1)
      .get(),
  );
  if (!dup.empty) {
    return;
  }
  const name =
    (opts.profileName ?? "").trim() ||
    phone;
  const nameLower = name.trim().toLowerCase();
  const nowMs = Date.now();
  await withRetry("contactCreate", () =>
    db.collection("contacts").add({
      ownerUid,
      name,
      nameLower,
      phone,
      company: "",
      email: "",
      tags: ["whatsapp"],
      notes: "Auto-created from WhatsApp inbound",
      source: "whatsapp_auto",
      createdAt: FieldValue.serverTimestamp(),
      createdAtMs: nowMs,
      updatedAt: FieldValue.serverTimestamp(),
      updatedAtMs: nowMs,
    }),
  );
  logger.info("[contacts] auto-created from WhatsApp", { phone, ownerUid });
}
