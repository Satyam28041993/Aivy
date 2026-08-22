/**

 * Auto-create a `contacts` row when an inbound WhatsApp arrives from a number

 * that is not yet in the user's contact book.

 *

 * Owner resolution order:

 *   1. Explicit ownerUid / phoneNumberId lookup on coexistence connection

 *   2. app_config/meta_whatsapp.defaultContactsOwnerUid

 *   3. Environment variable CONTACTS_AUTO_OWNER_UID

 *   4. Legacy app_config/whatsapp.contactsOwnerUid (migration fallback only)

 */



import { FieldValue, getFirestore } from "firebase-admin/firestore";

import { logger } from "firebase-functions";

import { resolveContactsOwnerUid } from "../whatsapp/credentials/ownerProvider";

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



export async function ensureContactFromWhatsAppInbound(opts: {

  from: string;

  profileName: string | null;

  phoneNumberId?: string | null;

}): Promise<void> {

  const ownerUid = await resolveContactsOwnerUid({

    phoneNumberId: opts.phoneNumberId ?? null,

    allowLegacyFallback: true,

  });

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


