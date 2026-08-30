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

  get userMessage(): string {
    if (this.status === 0) {
      return (
        "Maps is not set up — add app_config/maps → mapsApiKey in the Firebase Console."
      );
    }
    if (this.status === 403 || this.status === 401) {
      return "The Maps key is not working — are Places (New) and Routes API enabled in Cloud Console?";
    }
    return "No answer from Maps — try again shortly.";
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

/** A point from the user's device. */
export interface Coords {
  lat: number;
  lng: number;
}

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
  /** Device coordinates, when the app had them — beats any place name. */
  coords?: Coords | null;
  /** Metres around `coords` to favour. */
  radiusM?: number;
  openNow?: boolean;
  limit?: number;
}): Promise<PlaceRow[]> {
  const q = opts.query.trim();
  if (!q) {
    return [];
  }
  // Real coordinates say "near here" far better than a place name can, so when
  // the device gave them, they replace the "near <area>" text entirely.
  const useCoords = opts.coords != null;
  const textQuery =
    !useCoords && opts.near && opts.near.trim() ? `${q} near ${opts.near.trim()}` : q;
  const body: Record<string, unknown> = {
    textQuery,
    maxResultCount: Math.min(10, Math.max(1, opts.limit ?? 5)),
    languageCode: "en",
    regionCode: "IN",
  };
  if (useCoords) {
    body.locationBias = {
      circle: {
        center: { latitude: opts.coords!.lat, longitude: opts.coords!.lng },
        radius: Math.min(50_000, Math.max(500, opts.radiusM ?? 8_000)),
      },
    };
  }
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
      name: `${display.text ?? "(unnamed)"}`,
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

function mapsDirectionsLink(
  origin: string | Coords,
  destination: string | Coords,
  mode: TravelMode,
): string {
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
    `&origin=${encodeURIComponent(waypointLabel(origin))}` +
    `&destination=${encodeURIComponent(waypointLabel(destination))}` +
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
function waypoint(place: string | Coords): Record<string, unknown> {
  return typeof place === "string"
    ? { address: place }
    : { location: { latLng: { latitude: place.lat, longitude: place.lng } } };
}

function waypointLabel(place: string | Coords): string {
  return typeof place === "string" ? place : `${place.lat},${place.lng}`;
}

export async function computeRoute(opts: {
  origin: string | Coords;
  destination: string | Coords;
  mode?: TravelMode;
}): Promise<RouteResult | null> {
  const origin = typeof opts.origin === "string" ? opts.origin.trim() : opts.origin;
  const destination =
    typeof opts.destination === "string" ? opts.destination.trim() : opts.destination;
  if (!origin || !destination) {
    return null;
  }
  const mode: TravelMode = opts.mode ?? "DRIVE";

  const body: Record<string, unknown> = {
    origin: waypoint(origin),
    destination: waypoint(destination),
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

// ---------------------------------------------------------------------------
// Reverse geocoding — coordinates to a name a person would use
// ---------------------------------------------------------------------------

/**
 * Turns the device's coordinates into an address.
 *
 * This is the one legacy API left in here, because Places (New) and Routes have
 * no reverse-geocode call. It takes the key as a query parameter rather than a
 * header, so it does not go through `callMaps`.
 *
 * It needs the **Geocoding API** enabled separately. Everything else — "paas
 * me", distance, ETA — works on coordinates without it, so a failure here
 * returns null and the caller falls back to the raw position rather than
 * treating it as an error.
 */
export async function reverseGeocode(coords: Coords): Promise<string | null> {
  let key: string;
  try {
    key = await mapsKey();
  } catch {
    return null;
  }
  const url =
    "https://maps.googleapis.com/maps/api/geocode/json" +
    `?latlng=${coords.lat},${coords.lng}&language=en&key=${encodeURIComponent(key)}`;
  try {
    const res = await fetch(url);
    if (!res.ok) {
      return null;
    }
    const body = (await res.json()) as {
      status?: string;
      results?: Array<{ formatted_address?: string }>;
    };
    if (body.status !== "OK") {
      return null;
    }
    const address = `${body.results?.[0]?.formatted_address ?? ""}`.trim();
    return address || null;
  } catch {
    return null;
  }
}
