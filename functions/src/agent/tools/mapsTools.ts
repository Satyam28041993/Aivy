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
  crowDistanceKm,
  MapsApiError,
  mapsDirectionsToLink,
  mapsPinLink,
  nearestPlaceLabel,
  placesTextSearch,
  resolvePlacePoint,
  reverseGeocode,
  type Coords,
  type TravelMode,
} from "../google/maps";
import { createDraft } from "../draftStore";
import {
  deleteSavedPlace,
  findSavedPlace,
  listSavedPlaces,
  mapsPointLink,
} from "../placesStore";
import { draftResult, dataResult, fail, type ToolContext, type ToolResult } from "../toolTypes";

function str(raw: unknown): string {
  return typeof raw === "string" ? raw.trim() : "";
}

function mapsFailure(e: unknown): ToolResult {
  if (e instanceof MapsApiError) {
    return fail("failed", e.userMessage);
  }
  return fail("failed", "No answer from Maps.");
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
    return fail("needs_detail", "What should I look for?");
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
        `Which area should I search around? (tell me the city or area — I will remember it)`,
      );
    }
    return fail("nothing_found", `Nothing found for "${query}" around ${near}.`);
  }

  // Near to far, which is the order anyone reads a list of nearby places in.
  const withDistance = rows.map((r) => ({
    row: r,
    km: coords && r.coords ? crowDistanceKm(coords, r.coords) : null,
  }));
  if (coords) {
    withDistance.sort((a, b) => (a.km ?? 1e9) - (b.km ?? 1e9));
  }

  return dataResult({
    query,
    ...(coords ? { near: "your current location" } : near ? { near } : {}),
    count: withDistance.length,
    places: withDistance.map(({ row: r, km }) => ({
      name: r.name,
      address: r.address,
      ...(km != null ? { distance_km_straight_line: km } : {}),
      ...(r.rating != null ? { rating: r.rating, ratings: r.ratingCount } : {}),
      ...(r.openNow != null ? { open_now: r.openNow } : {}),
      ...(r.phone ? { phone: r.phone } : {}),
      ...(r.mapsUri
        ? { maps_link: r.mapsUri }
        : r.coords
          ? { maps_link: mapsPinLink(r.coords) }
          : {}),
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
  const rawDestination = str(args.destination);
  if (!rawDestination) {
    return fail("needs_detail", "Where are you going?");
  }

  // A saved name beats free text: "Rohan Office" is a point the user pinned,
  // not something for Google to guess at.
  const savedTo = await findSavedPlace(ctx.uid, rawDestination);

  const namedOrigin = str(args.origin);
  const savedFrom = namedOrigin ? await findSavedPlace(ctx.uid, namedOrigin) : null;
  const coords = namedOrigin ? null : coordsOf(ctx);

  const origin: string | Coords = savedFrom
    ? { lat: savedFrom.lat, lng: savedFrom.lng }
    : namedOrigin || coords || str(ctx.userCity);
  if (!origin) {
    return fail("needs_detail", "Starting from where? (a city or place)");
  }

  // Free text is resolved against Places near the user before it is routed.
  // Handed "Saphale station" on its own, Routes picks whichever one it likes
  // and the distance is quietly wrong; biased to the device fix it picks the
  // one they meant, and we get a name and a place id to show for it.
  const resolved =
    savedTo == null
      ? await resolvePlacePoint({
          query: rawDestination,
          coords,
          near: coords ? null : str(ctx.userCity) || null,
        })
      : null;

  const destination: string | Coords = savedTo
    ? { lat: savedTo.lat, lng: savedTo.lng }
    : (resolved?.coords ?? rawDestination);
  const destinationLabel = savedTo ? savedTo.name : (resolved?.name ?? rawDestination);

  const originLabel = savedFrom
    ? savedFrom.name
    : namedOrigin || (coords ? "your current location" : str(ctx.userCity));
  const mode = modeOf(args.travel_mode);

  let route;
  try {
    route = await computeRoute({
      origin,
      destination,
      mode,
      ...(resolved?.id ? { destinationPlaceId: resolved.id } : {}),
      destinationLabel,
    });
  } catch (e) {
    return mapsFailure(e);
  }
  if (!route) {
    return fail("nothing_found", `No route found to ${destinationLabel}.`);
  }

  return dataResult({
    from: originLabel,
    to: destinationLabel,
    // The address makes it checkable: if Maps picked the wrong branch of a
    // common name, the user can see that instead of just doubting the number.
    ...(resolved?.address ? { to_address: resolved.address } : {}),
    mode: route.mode,
    // Along the road, not across the map — the two differ a lot in a town, and
    // a user who measured it in a straight line will think this is wrong.
    distance_km_by_road: route.distanceKm,
    // Live traffic is baked in, which is what makes this worth asking for.
    duration_minutes: route.durationMinutes,
    directions_link: route.mapsUri,
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
      "Cannot get your location right now — is location switched on, and has the app " +
        "been given permission? (Settings → Apps → Aivy → Permissions → Location)",
    );
  }
  // Geocoding gives a street address; the nearest known place stands in when it
  // is unavailable. Coordinates are deliberately NOT returned — handed a pair
  // of numbers the model reads them out, and "19.5699515, 72.8027339" is not an
  // answer to "where am I".
  const address = (await reverseGeocode(coords)) ?? (await nearestPlaceLabel(coords));
  return dataResult({
    ...(address ? { address } : { address_unavailable: true }),
    map_link: mapsPinLink(coords),
    directions_link: mapsDirectionsToLink(coords),
  });
}

// ---------------------------------------------------------------------------
// save_place / get_saved_place / list_saved_places / forget_place
// ---------------------------------------------------------------------------

/**
 * "Yahan ka location Rohan Office ke naam se save karlo."
 *
 * A draft, like every other write — the card shows the address the coordinates
 * resolved to, which is the only way to catch a bad GPS fix before it becomes
 * the place you navigate to for the next year.
 */
export async function savePlaceTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const name = str(args.name);
  if (!name) {
    return fail("needs_detail", "What name should I save this place under?");
  }

  const coords = coordsOf(ctx);
  if (!coords) {
    return fail(
      "needs_detail",
      "Cannot get your location right now — switch location on, allow the app, then " +
        "say it again.",
    );
  }

  // Best-effort: a place with no address is still a usable place.
  // A card showing raw coordinates is one the user cannot check, so the nearest
  // known place stands in when Geocoding is unavailable.
  let address = "";
  try {
    address = (await reverseGeocode(coords)) ?? (await nearestPlaceLabel(coords)) ?? "";
  } catch {
    address = "";
  }

  const existing = await findSavedPlace(ctx.uid, name);
  const replacing = existing != null;

  const lines = [
    { label: "Name", value: name },
    { label: "Place", value: address || `${coords.lat.toFixed(5)}, ${coords.lng.toFixed(5)}` },
  ];
  if (replacing) {
    lines.push({ label: "Note", value: "This will replace the place saved under this name" });
  }

  const draft = await createDraft({
    uid: ctx.uid,
    kind: "saved_place",
    title: "Save place",
    icon: "📍",
    lines,
    chatId: ctx.chatId,
    data: {
      kind: "saved_place",
      name,
      lat: coords.lat,
      lng: coords.lng,
      address,
      replacing,
    },
  });

  return draftResult(
    draft,
    "Place drafted — it saves once confirmed.",
  );
}

export async function getSavedPlaceTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const name = str(args.name);
  if (!name) {
    return fail("needs_detail", "Which place do you want the link for?");
  }
  const place = await findSavedPlace(ctx.uid, name);
  if (!place) {
    const all = await listSavedPlaces(ctx.uid, 20);
    return fail(
      "nothing_found",
      all.length === 0
        ? `No place saved as "${name}". Tell me when you are there and I will save it.`
        : `No place called "${name}". Saved places: ${all.map((p) => p.name).join(", ")}.`,
    );
  }

  const out: Record<string, unknown> = {
    name: place.name,
    map_link: place.mapsLink || mapsPointLink(place.lat, place.lng),
    directions_link: mapsDirectionsToLink({ lat: place.lat, lng: place.lng }),
  };
  if (place.address) {
    out.address = place.address;
  }

  // Distance from here is what they usually want next, so save them the ask.
  const here = coordsOf(ctx);
  if (here) {
    try {
      const route = await computeRoute({
        origin: here,
        destination: { lat: place.lat, lng: place.lng },
      });
      if (route) {
        out.distance_km = route.distanceKm;
        out.duration_minutes = route.durationMinutes;
      }
    } catch {
      // The link is the answer; the ETA was a bonus.
    }
  }
  return dataResult(out);
}

export async function listSavedPlacesTool(ctx: ToolContext): Promise<ToolResult> {
  const rows = await listSavedPlaces(ctx.uid);
  if (rows.length === 0) {
    return fail("nothing_found", "No places saved yet.");
  }
  return dataResult({
    count: rows.length,
    places: rows.map((p) => ({
      name: p.name,
      ...(p.address ? { address: p.address } : {}),
      map_link: p.mapsLink || mapsPointLink(p.lat, p.lng),
    })),
  });
}

export async function forgetPlaceTool(
  ctx: ToolContext,
  args: Record<string, unknown>,
): Promise<ToolResult> {
  const name = str(args.name);
  if (!name) {
    return fail("needs_detail", "Which place should I remove?");
  }
  const removed = await deleteSavedPlace(ctx.uid, name);
  if (!removed) {
    return fail("nothing_found", `No place saved as "${name}".`);
  }
  return dataResult({ removed: name });
}
