import { beforeEach, describe, expect, it, vi } from "vitest";

import type { ToolContext } from "../toolTypes";

const placesMock = vi.fn();
const routeMock = vi.fn();
const geocodeMock = vi.fn();
const findSavedMock = vi.fn();
const listSavedMock = vi.fn();
const deleteSavedMock = vi.fn();
const createDraftMock = vi.fn();

vi.mock("../google/maps", async () => {
  const actual = await vi.importActual<typeof import("../google/maps")>("../google/maps");
  return {
    ...actual,
    placesTextSearch: (...a: unknown[]) => placesMock(...a),
    computeRoute: (...a: unknown[]) => routeMock(...a),
    reverseGeocode: (...a: unknown[]) => geocodeMock(...a),
  };
});

vi.mock("../placesStore", async () => {
  const actual = await vi.importActual<typeof import("../placesStore")>("../placesStore");
  return {
    ...actual,
    findSavedPlace: (...a: unknown[]) => findSavedMock(...a),
    listSavedPlaces: (...a: unknown[]) => listSavedMock(...a),
    deleteSavedPlace: (...a: unknown[]) => deleteSavedMock(...a),
  };
});

vi.mock("../draftStore", () => ({
  createDraft: (input: Record<string, unknown>) => {
    createDraftMock(input);
    return Promise.resolve({ id: "draft_1", status: "pending", ...input });
  },
}));

const {
  findPlacesTool,
  forgetPlaceTool,
  getDirectionsTool,
  getSavedPlaceTool,
  listSavedPlacesTool,
  savePlaceTool,
  whereAmITool,
} = await import("./mapsTools");
const { MapsApiError } = await import("../google/maps");

const CTX: ToolContext = {
  uid: "u1",
  timezone: "Asia/Kolkata",
  nowIso: "2025-08-23T14:30:00+05:30",
  chatId: "c1",
  userCity: "Kanpur",
};

/** Vasai East, roughly. */
const LOCATED: ToolContext = { ...CTX, coords: { lat: 19.3919, lng: 72.8397 } };

beforeEach(() => {
  placesMock.mockReset();
  routeMock.mockReset();
  geocodeMock.mockReset();
  findSavedMock.mockReset().mockResolvedValue(null);
  listSavedMock.mockReset().mockResolvedValue([]);
  deleteSavedMock.mockReset();
  createDraftMock.mockReset();
});

describe("find_places", () => {
  it("searches around their own city when none is named", async () => {
    placesMock.mockResolvedValue([
      { name: "Sharma Printers", address: "Mall Road", rating: 4.3, ratingCount: 12, openNow: true, phone: "", mapsUri: "u" },
    ]);
    const res = await findPlacesTool(CTX, { query: "printing press" });
    expect(res.ok).toBe(true);
    expect(placesMock.mock.calls[0]![0]).toMatchObject({ near: "Kanpur" });
  });

  it("uses the area the user names instead", async () => {
    placesMock.mockResolvedValue([
      { name: "X", address: "Y", rating: null, ratingCount: 0, openNow: null, phone: "", mapsUri: "" },
    ]);
    await findPlacesTool(CTX, { query: "courier", near: "Lucknow" });
    expect(placesMock.mock.calls[0]![0]).toMatchObject({ near: "Lucknow" });
  });

  it("searches without a bias when the city is unknown", async () => {
    placesMock.mockResolvedValue([]);
    await findPlacesTool({ ...CTX, userCity: null }, { query: "x" });
    expect(placesMock.mock.calls[0]![0]).toMatchObject({ near: null });
  });

  it("says nothing was found when it knew where to look", async () => {
    placesMock.mockResolvedValue([]);
    const res = await findPlacesTool(CTX, { query: "unicorn dealer" });
    expect(res.ok === false && res.reason).toBe("nothing_found");
    expect(res.ok === false && res.message).toContain("Kanpur");
  });

  it("asks where to look rather than claiming nothing exists", async () => {
    placesMock.mockResolvedValue([]);
    const res = await findPlacesTool({ ...CTX, userCity: null }, { query: "printing press" });
    expect(res.ok === false && res.reason).toBe("needs_detail");
    expect(res.ok === false && res.message).toContain("Kahan");
  });

  it("passes a configuration problem through in plain words", async () => {
    placesMock.mockRejectedValue(new MapsApiError("Maps", 0, "no key"));
    const res = await findPlacesTool(CTX, { query: "x" });
    expect(res.ok === false && res.message).toContain("app_config/maps");
  });
});

describe("get_directions", () => {
  it("starts from their city when no origin is given", async () => {
    routeMock.mockResolvedValue({ distanceKm: 82, durationMinutes: 95, mode: "DRIVE", mapsUri: "u" });
    const res = await getDirectionsTool(CTX, { destination: "Lucknow" });
    expect(res.ok).toBe(true);
    expect(routeMock.mock.calls[0]![0]).toMatchObject({ origin: "Kanpur", destination: "Lucknow", mode: "DRIVE" });
  });

  it("maps everyday words for how they travel", async () => {
    routeMock.mockResolvedValue({ distanceKm: 3, durationMinutes: 12, mode: "TWO_WHEELER", mapsUri: "u" });
    await getDirectionsTool(CTX, { destination: "Mall Road", travel_mode: "bike" });
    expect(routeMock.mock.calls[0]![0]).toMatchObject({ mode: "TWO_WHEELER" });
  });

  it("asks where to start from when nothing is known", async () => {
    const res = await getDirectionsTool({ ...CTX, userCity: null }, { destination: "Lucknow" });
    expect(res.ok === false && res.reason).toBe("needs_detail");
    expect(routeMock).not.toHaveBeenCalled();
  });

  it("says so when no route exists", async () => {
    routeMock.mockResolvedValue(null);
    const res = await getDirectionsTool(CTX, { destination: "Antarctica" });
    expect(res.ok === false && res.reason).toBe("nothing_found");
  });
});

describe("live location", () => {
  it("prefers the device fix over the remembered city", async () => {
    placesMock.mockResolvedValue([
      { name: "X", address: "Y", rating: null, ratingCount: 0, openNow: null, phone: "", mapsUri: "" },
    ]);
    await findPlacesTool(LOCATED, { query: "printing press" });
    const arg = placesMock.mock.calls[0]![0] as Record<string, unknown>;
    expect(arg.coords).toEqual({ lat: 19.3919, lng: 72.8397 });
  });

  it("steps aside when the user names an area", async () => {
    placesMock.mockResolvedValue([
      { name: "X", address: "Y", rating: null, ratingCount: 0, openNow: null, phone: "", mapsUri: "" },
    ]);
    await findPlacesTool(LOCATED, { query: "courier", near: "Lucknow" });
    const arg = placesMock.mock.calls[0]![0] as Record<string, unknown>;
    expect(arg.coords).toBeNull();
    expect(arg.near).toBe("Lucknow");
  });

  it("routes from where they are standing", async () => {
    routeMock.mockResolvedValue({ distanceKm: 12, durationMinutes: 25, mode: "DRIVE", mapsUri: "u" });
    const res = await getDirectionsTool(LOCATED, { destination: "Saphale railway station" });
    expect(res.ok).toBe(true);
    expect(routeMock.mock.calls[0]![0]).toMatchObject({
      origin: { lat: 19.3919, lng: 72.8397 },
    });
  });

  it("ignores a nonsense fix", async () => {
    placesMock.mockResolvedValue([]);
    const res = await findPlacesTool(
      { ...CTX, userCity: null, coords: { lat: 0, lng: 0 } },
      { query: "x" },
    );
    // No usable location at all, so it must ask rather than search the ocean.
    expect(res.ok === false && res.reason).toBe("needs_detail");
  });
});

describe("where_am_i", () => {
  it("answers with the address when Geocoding is available", async () => {
    geocodeMock.mockResolvedValue("Vasai East, Maharashtra 401208, India");
    const res = await whereAmITool(LOCATED);
    const data = res.ok && res.kind === "data" ? (res.data as Record<string, unknown>) : {};
    expect(data.address).toContain("Vasai East");
    expect(data.maps_link).toContain("19.3919");
  });

  it("still gives the position when Geocoding is not enabled", async () => {
    geocodeMock.mockResolvedValue(null);
    const res = await whereAmITool(LOCATED);
    const data = res.ok && res.kind === "data" ? (res.data as Record<string, unknown>) : {};
    expect(data.address).toBeUndefined();
    expect(data.lat).toBe(19.3919);
    expect(`${data.note}`).toContain("Geocoding");
  });

  it("says what to check when there is no fix", async () => {
    const res = await whereAmITool(CTX);
    expect(res.ok === false && res.message).toContain("permission");
  });
});

describe("saved places", () => {
  const ROHAN = {
    id: "p1",
    name: "Rohan Office",
    nameKey: "rohan office",
    lat: 19.39,
    lng: 72.84,
    address: "Vasai East",
    mapsLink: "https://maps/x",
    createdAtMs: 0,
  };

  it("saves where they are standing, as a card first", async () => {
    geocodeMock.mockResolvedValue("Vasai East, Maharashtra");
    const res = await savePlaceTool(LOCATED, { name: "Rohan Office" });
    expect(res.ok && res.kind).toBe("draft");

    const draft = createDraftMock.mock.calls.at(-1)![0];
    expect(draft.data).toMatchObject({
      kind: "saved_place",
      name: "Rohan Office",
      lat: 19.3919,
      address: "Vasai East, Maharashtra",
      replacing: false,
    });
  });

  it("warns on the card when it will move an existing place", async () => {
    geocodeMock.mockResolvedValue(null);
    findSavedMock.mockResolvedValue(ROHAN);
    await savePlaceTool(LOCATED, { name: "Rohan Office" });
    const draft = createDraftMock.mock.calls.at(-1)![0];
    expect(draft.data.replacing).toBe(true);
    expect(JSON.stringify(draft.lines)).toContain("purani jagah badal jaayegi");
  });

  it("saves without an address rather than failing", async () => {
    geocodeMock.mockRejectedValue(new Error("geocoding off"));
    const res = await savePlaceTool(LOCATED, { name: "Godown" });
    expect(res.ok).toBe(true);
    expect(createDraftMock.mock.calls.at(-1)![0].data.address).toBe("");
  });

  it("asks for a fix instead of saving a place it cannot locate", async () => {
    const res = await savePlaceTool(CTX, { name: "Godown" });
    expect(res.ok === false && res.reason).toBe("needs_detail");
    expect(createDraftMock).not.toHaveBeenCalled();
  });

  it("hands back the link, and the distance from here", async () => {
    findSavedMock.mockResolvedValue(ROHAN);
    routeMock.mockResolvedValue({ distanceKm: 4.2, durationMinutes: 11, mode: "DRIVE", mapsUri: "u" });
    const res = await getSavedPlaceTool(LOCATED, { name: "rohan office" });
    const data = res.ok && res.kind === "data" ? (res.data as Record<string, unknown>) : {};
    expect(data.maps_link).toBe("https://maps/x");
    expect(data.distance_km).toBe(4.2);
  });

  it("still gives the link when the route lookup fails", async () => {
    findSavedMock.mockResolvedValue(ROHAN);
    routeMock.mockRejectedValue(new Error("routes down"));
    const res = await getSavedPlaceTool(LOCATED, { name: "rohan office" });
    const data = res.ok && res.kind === "data" ? (res.data as Record<string, unknown>) : {};
    expect(data.maps_link).toBe("https://maps/x");
    expect(data.distance_km).toBeUndefined();
  });

  it("names what is saved when the name does not match", async () => {
    listSavedMock.mockResolvedValue([ROHAN]);
    const res = await getSavedPlaceTool(LOCATED, { name: "godown" });
    expect(res.ok === false && res.message).toContain("Rohan Office");
  });

  it("routes to a saved place by name instead of asking Google", async () => {
    findSavedMock.mockImplementation((_uid: string, n: string) =>
      Promise.resolve(n.toLowerCase().includes("rohan") ? ROHAN : null),
    );
    routeMock.mockResolvedValue({ distanceKm: 4.2, durationMinutes: 11, mode: "DRIVE", mapsUri: "u" });
    const res = await getDirectionsTool(LOCATED, { destination: "Rohan Office" });

    expect(routeMock.mock.calls[0]![0]).toMatchObject({
      destination: { lat: 19.39, lng: 72.84 },
    });
    const data = res.ok && res.kind === "data" ? (res.data as Record<string, unknown>) : {};
    expect(data.to).toBe("Rohan Office");
    expect(data.from).toBe("aapki current location");
  });

  it("lists and forgets", async () => {
    listSavedMock.mockResolvedValue([ROHAN]);
    const list = await listSavedPlacesTool(CTX);
    expect(list.ok).toBe(true);

    deleteSavedMock.mockResolvedValue(true);
    expect((await forgetPlaceTool(CTX, { name: "Rohan Office" })).ok).toBe(true);

    deleteSavedMock.mockResolvedValue(false);
    const miss = await forgetPlaceTool(CTX, { name: "nope" });
    expect(miss.ok === false && miss.reason).toBe("nothing_found");
  });
});
