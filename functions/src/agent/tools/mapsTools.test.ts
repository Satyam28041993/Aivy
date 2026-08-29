import { beforeEach, describe, expect, it, vi } from "vitest";

import type { ToolContext } from "../toolTypes";

const placesMock = vi.fn();
const routeMock = vi.fn();
const geocodeMock = vi.fn();

vi.mock("../google/maps", async () => {
  const actual = await vi.importActual<typeof import("../google/maps")>("../google/maps");
  return {
    ...actual,
    placesTextSearch: (...a: unknown[]) => placesMock(...a),
    computeRoute: (...a: unknown[]) => routeMock(...a),
    reverseGeocode: (...a: unknown[]) => geocodeMock(...a),
  };
});

const { findPlacesTool, getDirectionsTool, whereAmITool } = await import("./mapsTools");
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
