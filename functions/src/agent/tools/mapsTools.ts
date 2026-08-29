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
  // "paas me" only means something relative to somewhere; fall back to the city
  // we remember about them rather than searching the whole country.
  const near = str(args.near) || str(ctx.userCity) || "";

  let rows;
  try {
    rows = await placesTextSearch({
      query,
      near: near || null,
      openNow: args.open_now === true,
      limit: typeof args.limit === "number" ? args.limit : 5,
    });
  } catch (e) {
    return mapsFailure(e);
  }

  if (rows.length === 0) {
    return fail("nothing_found", `"${query}" ke liye kuch nahi mila${near ? ` ${near} ke aas-paas` : ""}.`);
  }

  return dataResult({
    query,
    near: near || undefined,
    count: rows.length,
    places: rows.map((r) => ({
      name: r.name,
      address: r.address,
      rating: r.rating ?? undefined,
      ratings: r.ratingCount || undefined,
      open_now: r.openNow ?? undefined,
      phone: r.phone || undefined,
      maps_link: r.mapsUri || undefined,
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
  const origin = str(args.origin) || str(ctx.userCity);
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
    return fail("nothing_found", `${origin} se ${destination} tak ka raasta nahi mila.`);
  }

  return dataResult({
    from: origin,
    to: destination,
    mode: route.mode,
    distance_km: route.distanceKm,
    // Live traffic is baked in, which is what makes this worth asking for.
    duration_minutes: route.durationMinutes,
    maps_link: route.mapsUri,
  });
}
