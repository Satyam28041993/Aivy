/**
 * Maps tools — finding a place, and how far / how long it is.
 *
 * Both are reads, so they answer straight away: no card, nothing saved. The
 * useful part is that they return rows rather than prose, so "paas me koi
 * printing press hai?" and "Rohan ke office tak kitna time lagega?" both work
 * without a phrasing template for either.
 */

import {
  computeRoute,
  MapsApiError,
  placesTextSearch,
  reverseGeocode,
  type Coords,
  type TravelMode,
} from "../google/maps";
import { dataResult, fail, type ToolContext, type ToolResult } from "../toolTypes";

function str(raw: unknown): string {
  return typeof raw === "string" ? raw.trim() : "";
}

function mapsFailure(e: unknown): ToolResult {
  if (e instanceof MapsApiError) {
    return fail("failed", e.hindiMessage);
  }
  return fail("failed", "Maps se jawaab nahi mila.");
}

const MODES: Record<string, TravelMode> = {
  drive: "DRIVE",
  car: "DRIVE",
  bike: "TWO_WHEELER",
  two_wheeler: "TWO_WHEELER",
  scooter: "TWO_WHEELER",
  walk: "WALK",
  bicycle: "BICYCLE",
  cycle: "BICYCLE",
  transit: "TRANSIT",
  bus: "TRANSIT",
  train: "TRANSIT",
};

function modeOf(raw: unknown): TravelMode {
  return MODES[str(raw).toLowerCase()] ?? "DRIVE";
}

/** Device fix for this turn, if the app sent one. */
function coordsOf(ctx: ToolContext): Coords | null {
  const c = ctx.coords;
  if (!c || !Number.isFinite(c.lat) || !Number.isFinite(c.lng)) {
    return null;
  }
  if (c.lat === 0 && c.lng === 0) {
    return null;
  }
  return { lat: c.lat, lng: c.lng };
}

// ---------------------------------------------------------------------------
// find_places
// ---------------------------------------------------------------------------

export async function findPlacesTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const query = str(args.query);
  if (!query) {
    return fail("needs_detail", "Kya dhoondhna hai?");
  }
  // "paas me" only means something relative to somewhere. Best is the live fix
  // from the phone; then an area they named; then the city we remember.
  const named = str(args.near);
  const coords = named ? null : coordsOf(ctx);
  const near = named || str(ctx.userCity) || "";

  let rows;
  try {
    rows = await placesTextSearch({
      query,
      near: near || null,
      coords,
      openNow: args.open_now === true,
      limit: typeof args.limit === "number" ? args.limit : 5,
    });
  } catch (e) {
    return mapsFailure(e);
  }

  if (rows.length === 0) {
    // Without a location this was a search of the whole country, so "kuch nahi
    // mila" would be misleading — the honest answer is that we do not know
    // where to look. Asking once is also what makes the next search work, since
    // the answer can then be remembered.
    if (!near && !coords) {
      return fail(
        "needs_detail",
        `Kahan ke aas-paas dhoondhun? (shehar ya area bata dijiye — main yaad rakh lungi)`,
      );
    }
    return fail("nothing_found", `"${query}" ke liye ${near} ke aas-paas kuch nahi mila.`);
  }

  return dataResult({
    query,
    ...(coords ? { near: "aapki current location" } : near ? { near } : {}),
    count: rows.length,
    places: rows.map((r) => ({
      name: r.name,
      address: r.address,
      ...(r.rating != null ? { rating: r.rating, ratings: r.ratingCount } : {}),
      ...(r.openNow != null ? { open_now: r.openNow } : {}),
      ...(r.phone ? { phone: r.phone } : {}),
      ...(r.mapsUri ? { maps_link: r.mapsUri } : {}),
    })),
  });
}

// ---------------------------------------------------------------------------
// get_directions
// ---------------------------------------------------------------------------

export async function getDirectionsTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const destination = str(args.destination);
  if (!destination) {
    return fail("needs_detail", "Jaana kahan hai?");
  }
  const namedOrigin = str(args.origin);
  const coords = namedOrigin ? null : coordsOf(ctx);
  const origin: string | Coords = namedOrigin || coords || str(ctx.userCity);
  if (!origin) {
    return fail("needs_detail", "Kahan se chalna hai? (shehar ya jagah bata dijiye)");
  }
  const mode = modeOf(args.travel_mode);

  let route;
  try {
    route = await computeRoute({ origin, destination, mode });
  } catch (e) {
    return mapsFailure(e);
  }
  if (!route) {
    return fail("nothing_found", `${destination} tak ka raasta nahi mila.`);
  }

  return dataResult({
    from: typeof origin === "string" ? origin : "aapki current location",
    to: destination,
    mode: route.mode,
    distance_km: route.distanceKm,
    // Live traffic is baked in, which is what makes this worth asking for.
    duration_minutes: route.durationMinutes,
    maps_link: route.mapsUri,
  });
}

// ---------------------------------------------------------------------------
// where_am_i
// ---------------------------------------------------------------------------

/**
 * Answers "main abhi kahan hoon". The address needs the Geocoding API; without
 * it the coordinates still come back, because knowing the fix exists is more
 * useful than a flat "pata nahi".
 */
export async function whereAmITool(ctx: ToolContext): Promise<ToolResult> {
  const coords = coordsOf(ctx);
  if (!coords) {
    return fail(
      "needs_detail",
      "Abhi location nahi mil rahi — phone me location on hai? App ko permission " +
        "di hai kya? (Android settings → Apps → Aivy → Permissions → Location)",
    );
  }
  const address = await reverseGeocode(coords);
  return dataResult({
    ...(address ? { address } : {}),
    lat: coords.lat,
    lng: coords.lng,
    maps_link: `https://www.google.com/maps/search/?api=1&query=${coords.lat},${coords.lng}`,
    ...(address ? {} : { note: "Address nahi nikal paaya (Geocoding API enable nahi hai)." }),
  });
}
