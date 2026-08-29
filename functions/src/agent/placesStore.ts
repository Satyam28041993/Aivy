/**
 * Places the user has named — "Rohan Office", "godown", "ghar".
 *
 * Stored under `users/{uid}/places/{id}`. Deliberately a plain store rather
 * than anything clever: a name, a point, and whatever address Google could put
 * to it at the time. The point is what matters — an address can go stale, a
 * latitude cannot.
 *
 * Lookup matches on the same normalised key the client resolver uses, so
 * "rohan office", "Rohan's office" and "ROHAN OFFICE" all find the same row.
 */

import { getFirestore } from "firebase-admin/firestore";

import { normalizeName } from "./nameNormalize";

export interface SavedPlace {
  id: string;
  name: string;
  nameKey: string;
  lat: number;
  lng: number;
  /** Best address at the time of saving; may be empty. */
  address: string;
  mapsLink: string;
  createdAtMs: number;
}

function placesRef(uid: string) {
  return getFirestore().collection("users").doc(uid).collection("places");
}

export function mapsPointLink(lat: number, lng: number): string {
  return `https://www.google.com/maps/search/?api=1&query=${lat},${lng}`;
}

export async function savePlace(
  uid: string,
  input: { name: string; lat: number; lng: number; address?: string | null },
): Promise<SavedPlace> {
  const name = input.name.trim();
  const nameKey = normalizeName(name);

  // Saving the same name twice overwrites rather than stacking: "isko Rohan
  // Office naam se save karlo" said again means the place moved, not that
  // there are now two of them.
  const existing = await placesRef(uid).where("nameKey", "==", nameKey).limit(1).get();
  const ref = existing.empty ? placesRef(uid).doc() : existing.docs[0]!.ref;

  const place: SavedPlace = {
    id: ref.id,
    name,
    nameKey,
    lat: input.lat,
    lng: input.lng,
    address: (input.address ?? "").trim(),
    mapsLink: mapsPointLink(input.lat, input.lng),
    createdAtMs: Date.now(),
  };
  await ref.set(place);
  return place;
}

/**
 * Finds a saved place by name.
 *
 * Exact normalised match first, then a contains match, so "rohan" finds
 * "Rohan Office" when nothing is called exactly that.
 */
export async function findSavedPlace(
  uid: string,
  rawName: string,
): Promise<SavedPlace | null> {
  const key = normalizeName(rawName);
  if (!key) {
    return null;
  }
  const exact = await placesRef(uid).where("nameKey", "==", key).limit(1).get();
  if (!exact.empty) {
    return exact.docs[0]!.data() as SavedPlace;
  }

  const all = await placesRef(uid).limit(100).get();
  const rows = all.docs.map((d) => d.data() as SavedPlace);
  const partial = rows.filter(
    (p) => p.nameKey.includes(key) || key.includes(p.nameKey),
  );
  // Ambiguous partials are not a match — better to say "which one" than to
  // silently route someone to the wrong godown.
  return partial.length === 1 ? partial[0]! : null;
}

export async function listSavedPlaces(uid: string, limit = 50): Promise<SavedPlace[]> {
  const snap = await placesRef(uid).orderBy("createdAtMs", "desc").limit(limit).get();
  return snap.docs.map((d) => d.data() as SavedPlace);
}

export async function deleteSavedPlace(uid: string, rawName: string): Promise<boolean> {
  const place = await findSavedPlace(uid, rawName);
  if (!place) {
    return false;
  }
  await placesRef(uid).doc(place.id).delete();
  return true;
}
