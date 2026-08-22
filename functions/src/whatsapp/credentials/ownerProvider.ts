import { getFirestore } from "firebase-admin/firestore";
import { readMetaWhatsappClientConfig } from "../onboarding/clientConfig";
import { readWhatsappConnectionMetadata } from "../onboarding/connectionStore";
import { readLegacyContactsOwnerUid } from "./legacyProvider";

export type ResolveOwnerOptions = {
  ownerUid?: string | null;
  phoneNumberId?: string | null;
  allowLegacyFallback?: boolean;
};

function normalizeUid(raw: unknown): string | null {
  const uid = String(raw ?? "").trim();
  return uid.length > 8 ? uid : null;
}

async function findOwnerUidByPhoneNumberId(
  phoneNumberId: string,
): Promise<string | null> {
  const id = String(phoneNumberId ?? "").trim();
  if (!id) {
    return null;
  }
  const snap = await getFirestore()
    .collectionGroup("meta")
    .where("phoneNumberId", "==", id)
    .limit(1)
    .get();
  if (snap.empty) {
    return null;
  }
  const data = snap.docs[0].data() as Record<string, unknown>;
  return (
    normalizeUid(data.contactsOwnerUid) ??
    normalizeUid(data.ownerUid) ??
    normalizeUid(snap.docs[0].ref.parent.parent?.id)
  );
}

export async function resolveContactsOwnerUid(
  options: ResolveOwnerOptions = {},
): Promise<string | null> {
  const explicit = normalizeUid(options.ownerUid);
  if (explicit) {
    return explicit;
  }

  const phoneNumberId = String(options.phoneNumberId ?? "").trim();
  if (phoneNumberId) {
    const fromPhone = await findOwnerUidByPhoneNumberId(phoneNumberId);
    if (fromPhone) {
      return fromPhone;
    }
  }

  const envUid = normalizeUid(process.env.CONTACTS_AUTO_OWNER_UID);
  if (envUid) {
    return envUid;
  }

  const meta = await readMetaWhatsappClientConfig();
  const fromMeta = normalizeUid(meta.defaultContactsOwnerUid);
  if (fromMeta) {
    return fromMeta;
  }

  if (options.allowLegacyFallback !== false) {
    return readLegacyContactsOwnerUid();
  }

  return null;
}

export async function resolveDefaultOwnerUid(
  options: ResolveOwnerOptions = {},
): Promise<string | null> {
  const explicit = normalizeUid(options.ownerUid);
  if (explicit) {
    const connection = await readWhatsappConnectionMetadata(explicit);
    if (connection) {
      return normalizeUid(connection.contactsOwnerUid) ?? explicit;
    }
    return explicit;
  }

  return resolveContactsOwnerUid(options);
}
