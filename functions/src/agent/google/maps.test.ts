import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const configMock = vi.fn();

vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({
    collection: () => ({ doc: () => ({ get: () => Promise.resolve({ data: () => configMock() }) }) }),
  }),
}));

const { computeRoute, MapsApiError, placesTextSearch, resetMapsKeyCache } = await import("./maps");

interface Captured {
  url: string;
  headers: Record<string, string>;
  body: Record<string, unknown>;
}

function stubFetch(responses: Array<{ status?: number; json?: unknown; text?: string }>) {
  const calls: Captured[] = [];
  let i = 0;
  vi.stubGlobal("fetch", (url: string, init: Record<string, unknown> = {}) => {
    calls.push({
      url,
      headers: (init.headers ?? {}) as Record<string, string>,
      body: JSON.parse(`${init.body}`),
    });
    const r = responses[Math.min(i++, responses.length - 1)]!;
    const status = r.status ?? 200;
    return Promise.resolve({
      ok: status >= 200 && status < 300,
      status,
      text: () => Promise.resolve(r.text ?? ""),
      json: () => Promise.resolve(r.json ?? {}),
    });
  });
  return calls;
}

beforeEach(() => {
  resetMapsKeyCache();
  delete process.env.MAPS_API_KEY;
  configMock.mockReset().mockReturnValue({ mapsApiKey: "KEY" });
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("configuration", () => {
  it("says what to do when no key is set, instead of calling Google", async () => {
    configMock.mockReturnValue({});
    const calls = stubFetch([{ json: {} }]);
    const err = await placesTextSearch({ query: "printing press" }).catch((e) => e);
    expect(err).toBeInstanceOf(MapsApiError);
    expect((err as MapsApiError).hindiMessage).toContain("app_config/maps");
    expect(calls).toHaveLength(0);
  });

  it("reads the key once and reuses it", async () => {
    stubFetch([{ json: { places: [] } }]);
    await placesTextSearch({ query: "a" });
    await placesTextSearch({ query: "b" });
    expect(configMock).toHaveBeenCalledTimes(1);
  });
});

describe("places", () => {
  it("sends the key and field mask as headers, not query params", async () => {
    const calls = stubFetch([{ json: { places: [] } }]);
    await placesTextSearch({ query: "printing press", near: "Kanpur", openNow: true });

    const c = calls[0]!;
    expect(c.url).toBe("https://places.googleapis.com/v1/places:searchText");
    expect(c.headers["X-Goog-Api-Key"]).toBe("KEY");
    expect(c.headers["X-Goog-FieldMask"]).toContain("places.googleMapsUri");
    expect(c.body.textQuery).toBe("printing press near Kanpur");
    expect(c.body.openNow).toBe(true);
    expect(c.body.regionCode).toBe("IN");
  });

  it("flattens a result into the fields the model shows", async () => {
    stubFetch([
      {
        json: {
          places: [
            {
              displayName: { text: "Sharma Printers" },
              formattedAddress: "Mall Road, Kanpur",
              rating: 4.3,
              userRatingCount: 128,
              currentOpeningHours: { openNow: true },
              nationalPhoneNumber: "099999 99999",
              googleMapsUri: "https://maps.google.com/?cid=1",
            },
          ],
        },
      },
    ]);
    const rows = await placesTextSearch({ query: "printers" });
    expect(rows[0]).toEqual({
      name: "Sharma Printers",
      address: "Mall Road, Kanpur",
      rating: 4.3,
      ratingCount: 128,
      openNow: true,
      phone: "099999 99999",
      mapsUri: "https://maps.google.com/?cid=1",
    });
  });

  it("leaves rating and open-now unset rather than guessing zero", async () => {
    stubFetch([{ json: { places: [{ displayName: { text: "X" } }] } }]);
    const rows = await placesTextSearch({ query: "x" });
    expect(rows[0]!.rating).toBeNull();
    expect(rows[0]!.openNow).toBeNull();
  });
});

describe("routes", () => {
  it("asks for traffic on a drive and converts the response", async () => {
    const calls = stubFetch([{ json: { routes: [{ duration: "2730s", distanceMeters: 18450 }] } }]);
    const route = await computeRoute({ origin: "Kanpur", destination: "Lucknow" });

    expect(calls[0]!.url).toBe("https://routes.googleapis.com/directions/v2:computeRoutes");
    expect(calls[0]!.body.routingPreference).toBe("TRAFFIC_AWARE");
    expect(route).toMatchObject({ distanceKm: 18.5, durationMinutes: 46, mode: "DRIVE" });
    expect(route!.mapsUri).toContain("travelmode=driving");
  });

  it("does not ask for traffic when walking — Routes rejects that", async () => {
    const calls = stubFetch([{ json: { routes: [{ duration: "600s", distanceMeters: 800 }] } }]);
    const route = await computeRoute({ origin: "a", destination: "b", mode: "WALK" });
    expect(calls[0]!.body.routingPreference).toBeUndefined();
    expect(route!.mapsUri).toContain("travelmode=walking");
  });

  it("returns null when there is no route rather than inventing one", async () => {
    stubFetch([{ json: { routes: [] } }]);
    expect(await computeRoute({ origin: "a", destination: "b" })).toBeNull();
  });

  it("names a key problem apart from a broken call", async () => {
    stubFetch([{ status: 403, text: "API not enabled" }]);
    const err = await computeRoute({ origin: "a", destination: "b" }).catch((e) => e);
    expect((err as MapsApiError).hindiMessage).toContain("Routes API");
  });
});
