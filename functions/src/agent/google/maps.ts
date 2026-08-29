/**
 * Google Maps Platform — places and routes.
 *
 * Unlike Calendar/Gmail/Sheets, these are not the *user's* data, so they use a
 * project API key rather than a per-user OAuth token. The key lives in
 * Firestore (`app_config/maps`, field `mapsApiKey`) exactly like the search key,
 * for the same reason: it never reaches the client, it is readable only by the
 * Admin SDK, and changing it does not need a redeploy.
 *
 * These are the current APIs, not the legacy ones:
 *   - Places API (New) → places:searchText
 *   - Routes API       → directions/v2:computeRoutes
 * Both want the key in a header and an explicit field mask, which is also why
 * responses here are small — we ask for the six fields we actually show.
 */

import { getFirestore } from "firebase-admin/firestore";

export class MapsApiError extends Error {
  constructor(
    readonly api: string,
    readonly status: number,
    readonly detail: string,
  ) {
    super(`${api} ${status}: ${detail}`);
    this.name = "MapsApiError";
  }

  get hindiMessage(): string {
    if (this.status === 0) {
      return (
        "Maps abhi set nahi hai — Firebase Console me app_config/maps → mapsApiKey " +
        "daalna hoga."
      );
    }
    if (this.status === 403 || this.status === 401) {
      return "Maps key kaam nahi kar rahi — Cloud Console me Places (New) aur Routes API enable hain kya?";
    }
    return "Maps se jawaab nahi mila, thodi der baad try kijiye.";
  }
}

// The key changes about never, and a Firestore read per tool call is a waste of
// a hundred milliseconds on a screen where latency is the whole feel.
let cachedKey: { value: string; atMs: number } | null = null;
const KEY_TTL_MS = 5 * 60 * 1000;

export function resetMapsKeyCache(): void {
  cachedKey = null;
}

async function mapsKey(): Promise<string> {
  const now = Date.now();
  if (cachedKey && now - cachedKey.atMs < KEY_TTL_MS) {
    return cachedKey.value;
  }
  let fromDb = "";
  try {
    const snap = await getFirestore().collection("app_config").doc("maps").get();
    fromDb = `${snap.data()?.mapsApiKey ?? ""}`.trim();
  } catch {
    fromDb = "";
  }
  const key = fromDb || `${process.env.MAPS_API_KEY ?? ""}`.trim();
  if (!key) {
    throw new MapsApiError("Maps", 0, "mapsApiKey not configured");
  }
  cachedKey = { value: key, atMs: now };
  return key;
}

async function callMaps<T>(
  api: string,
  url: string,
  fieldMask: string,
  body: unknown,
): Promise<T> {
  const key = await mapsKey();
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Goog-Api-Key": key,
      "X-Goog-FieldMask": fieldMask,
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new MapsApiError(api, res.status, text.slice(0, 280));
  }
  return (await res.json()) as T;
}

// ---------------------------------------------------------------------------
// Places
// ---------------------------------------------------------------------------

export interface PlaceRow {
  name: string;
  address: string;
  rating: number | null;
  ratingCount: number;
  openNow: boolean | null;
  phone: string;
  mapsUri: string;
}

const PLACES_FIELDS = [
  "places.displayName",
  "places.formattedAddress",
  "places.rating",
  "places.userRatingCount",
  "places.currentOpeningHours.openNow",
  "places.nationalPhoneNumber",
  "places.googleMapsUri",
].join(",");

/**
 * Text search — "paas me printing press", "Rohan Traders Kanpur".
 * `near` only biases the results; it does not filter them, so a good match far
 * away still comes back rather than the query silently returning nothing.
 */
export async function placesTextSearch(opts: {
  query: string;
  near?: string | null;
  openNow?: boolean;
  limit?: number;
}): Promise<PlaceRow[]> {
  const q = opts.query.trim();
  if (!q) {
    return [];
  }
  const textQuery = opts.near && opts.near.trim() ? `${q} near ${opts.near.trim()}` : q;
  const body: Record<string, unknown> = {
    textQuery,
    maxResultCount: Math.min(10, Math.max(1, opts.limit ?? 5)),
    languageCode: "en",
    regionCode: "IN",
  };
  if (opts.openNow) {
    body.openNow = true;
  }

  const res = await callMaps<{ places?: Array<Record<string, unknown>> }>(
    "Places",
    "https://places.googleapis.com/v1/places:searchText",
    PLACES_FIELDS,
    body,
  );

  return (res.places ?? []).map((p) => {
    const display = (p.displayName ?? {}) as Record<string, unknown>;
    const hours = (p.currentOpeningHours ?? {}) as Record<string, unknown>;
    const rating = Number(p.rating);
    return {
      name: `${display.text ?? "(bina naam)"}`,
      address: `${p.formattedAddress ?? ""}`,
      rating: Number.isFinite(rating) && rating > 0 ? rating : null,
      ratingCount: Number(p.userRatingCount ?? 0) || 0,
      openNow: typeof hours.openNow === "boolean" ? hours.openNow : null,
      phone: `${p.nationalPhoneNumber ?? ""}`,
      mapsUri: `${p.googleMapsUri ?? ""}`,
    };
  });
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

export type TravelMode = "DRIVE" | "TWO_WHEELER" | "WALK" | "BICYCLE" | "TRANSIT";

export interface RouteResult {
  distanceKm: number;
  durationMinutes: number;
  mode: TravelMode;
  mapsUri: string;
}

const ROUTE_FIELDS = "routes.duration,routes.distanceMeters";

/** Google's duration comes back as a protobuf duration string: "1234s". */
function secondsFrom(raw: unknown): number {
  const n = Number(`${raw ?? ""}`.replace(/s$/, ""));
  return Number.isFinite(n) ? n : 0;
}

function mapsDirectionsLink(origin: string, destination: string, mode: TravelMode): string {
  const travel =
    mode === "WALK"
      ? "walking"
      : mode === "BICYCLE"
        ? "bicycling"
        : mode === "TRANSIT"
          ? "transit"
          : "driving";
  return (
    "https://www.google.com/maps/dir/?api=1" +
    `&origin=${encodeURIComponent(origin)}` +
    `&destination=${encodeURIComponent(destination)}` +
    `&travelmode=${travel}`
  );
}

/**
 * Distance and time between two places named in plain words — Routes geocodes
 * the addresses itself, so nothing needs resolving first.
 *
 * TRAFFIC_AWARE means the ETA is the one Maps would show right now, which is
 * the whole point of asking "kitna time lagega".
 */
export async function computeRoute(opts: {
  origin: string;
  destination: string;
  mode?: TravelMode;
}): Promise<RouteResult | null> {
  const origin = opts.origin.trim();
  const destination = opts.destination.trim();
  if (!origin || !destination) {
    return null;
  }
  const mode: TravelMode = opts.mode ?? "DRIVE";

  const body: Record<string, unknown> = {
    origin: { address: origin },
    destination: { address: destination },
    travelMode: mode,
    languageCode: "en",
    units: "METRIC",
  };
  // Traffic only applies to road vehicles; asking for it on WALK is rejected.
  if (mode === "DRIVE" || mode === "TWO_WHEELER") {
    body.routingPreference = "TRAFFIC_AWARE";
  }

  const res = await callMaps<{
    routes?: Array<{ duration?: string; distanceMeters?: number }>;
  }>("Routes", "https://routes.googleapis.com/directions/v2:computeRoutes", ROUTE_FIELDS, body);

  const route = res.routes?.[0];
  if (!route) {
    return null;
  }
  return {
    distanceKm: Math.round(((route.distanceMeters ?? 0) / 1000) * 10) / 10,
    durationMinutes: Math.round(secondsFrom(route.duration) / 60),
    mode,
    mapsUri: mapsDirectionsLink(origin, destination, mode),
  };
}
