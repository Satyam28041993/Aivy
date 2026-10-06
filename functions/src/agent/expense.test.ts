/**
 * Travel expense: start → the day's visits in order → back, one priced leg per
 * row, the day's total on its last leg only.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";

const created: Array<Record<string, unknown>> = [];
vi.mock("./draftStore", () => ({
  createDraft: async (input: Record<string, unknown>) => {
    created.push(input);
    return { id: "d1", status: "pending", ...input };
  },
}));
vi.mock("firebase-admin/firestore", () => ({ getFirestore: vi.fn(), FieldValue: {} }));
vi.mock("firebase-functions", () => ({ logger: { warn: vi.fn() } }));

const visits = { current: [] as Array<Record<string, unknown>> };
vi.mock("./visitStore", async () => {
  const actual = await vi.importActual<typeof import("./visitStore")>("./visitStore");
  return { ...actual, listVisits: async () => visits.current };
});

const existing = { current: null as Record<string, unknown> | null };
vi.mock("./expenseStore", async () => {
  const actual = await vi.importActual<typeof import("./expenseStore")>("./expenseStore");
  return {
    ...actual,
    getExpense: async () => existing.current,
    expenseSettings: async () => ({ ratePerKm: 4, vehicle: "Bike" }),
    expenseSheetLink: async () => null,
    listExpenses: async () => [],
  };
});

const HOME = { lat: 19.88, lng: 75.36 };
vi.mock("./placesStore", () => ({
  findSavedPlace: async (_uid: string, name: string) =>
    name.toLowerCase() === "ghar" ? { name: "Ghar", lat: HOME.lat, lng: HOME.lng } : null,
}));

const routes: Array<{ origin: unknown; destination: unknown; mode: string }> = [];
vi.mock("./google/maps", async () => {
  const actual = await vi.importActual<typeof import("./google/maps")>("./google/maps");
  return {
    ...actual,
    resolvePlacePoint: async () => null,
    computeRoute: async (o: { origin: unknown; destination: unknown; mode: string }) => {
      routes.push(o);
      return { distanceKm: 10.25 + routes.length, durationMinutes: 20, mode: o.mode, mapsUri: "" };
    },
  };
});

const { recordTravelExpenseTool } = await import("./tools/expenseTools");
const { priceLegs, expenseToRows, EXPENSE_HEADER } = await import("./expenseStore");

const CTX = {
  uid: "u",
  timezone: "Asia/Kolkata",
  nowIso: "2026-10-06T20:05:00+05:30",
  chatId: "c",
  googleToken: "tok",
  coords: HOME,
};

function visit(id: string, client: string, ms: number, pin: { lat: number; lng: number } | null, location = "") {
  return {
    id,
    clientName: client,
    location,
    lat: pin?.lat ?? null,
    lng: pin?.lng ?? null,
    visitDateMs: ms,
    createdAtMs: ms,
  };
}

beforeEach(() => {
  created.length = 0;
  routes.length = 0;
  existing.current = null;
  visits.current = [];
});

describe("pricing", () => {
  it("prices each leg and totals them so the column sums to the claim", () => {
    const p = priceLegs(
      [
        { from: "A", to: "B", purpose: "B", km: 12.3 },
        { from: "B", to: "A", purpose: "Return", km: 12.4 },
      ],
      4,
    );
    expect(p.legs.map((l) => l.amount)).toEqual([49.2, 49.6]);
    expect(p.totalKm).toBe(24.7);
    expect(p.totalAmount).toBe(98.8);
  });

  it("writes one row per leg with the day total on the last only", () => {
    const rows = expenseToRows(
      {
        id: "2026-10-06",
        dateMs: 0,
        dateLabel: "06-Oct-2026",
        startPoint: "Ghar",
        endPoint: "Ghar",
        vehicle: "Bike",
        ratePerKm: 4,
        legs: [
          { from: "Ghar", to: "Bajaj", purpose: "Bajaj", km: 10, amount: 40 },
          { from: "Bajaj", to: "Ghar", purpose: "Return", km: 10, amount: 40 },
        ],
        totalKm: 20,
        totalAmount: 80,
        createdAtMs: Date.parse("2026-10-06T15:00:00Z"),
        sheetRow: null,
      },
      "Asia/Kolkata",
    );
    expect(rows).toHaveLength(2);
    expect(rows[0]).toHaveLength(EXPENSE_HEADER.length);
    expect(rows[0]![8]).toBe("");
    expect(rows[1]![8]).toBe("20");
    expect(rows[1]![9]).toBe("80");
  });
});

describe("record_travel_expense", () => {
  it("asks for the start point first", async () => {
    const r = await recordTravelExpenseTool(CTX, {});
    expect(r.ok).toBe(false);
  });

  it("routes start → visits in the order made → back, by two-wheeler", async () => {
    const t = Date.parse("2026-10-06T06:00:00Z");
    visits.current = [
      visit("v2", "Exide", t + 3_600_000, null, "Chikalthana"),
      visit("v1", "Bajaj Auto", t, { lat: 19.85, lng: 75.3 }),
    ];
    const r = await recordTravelExpenseTool(CTX, { start_point: "ghar" });
    expect(r.ok).toBe(true);
    expect(routes).toHaveLength(3);
    expect(routes[0]).toMatchObject({ origin: HOME, destination: { lat: 19.85, lng: 75.3 }, mode: "TWO_WHEELER" });
    expect(routes[1]!.destination).toBe("Exide, Chikalthana");
    expect(routes[2]!.destination).toEqual(HOME);
    const data = created[0]!.data as { legs: Array<{ purpose: string }>; ratePerKm: number; day: string };
    expect(data.legs.map((l) => l.purpose)).toEqual(["Bajaj Auto", "Exide", "Return"]);
    expect(data.ratePerKm).toBe(4);
    expect(data.day).toBe("2026-10-06");
  });

  it("says so when the day has no visits", async () => {
    const r = await recordTravelExpenseTool(CTX, { start_point: "ghar" });
    expect(r.ok).toBe(false);
    expect(created).toHaveLength(0);
  });

  it("does not record the same day twice", async () => {
    existing.current = { totalKm: 20, totalAmount: 80 };
    visits.current = [visit("v1", "Bajaj Auto", Date.parse("2026-10-06T06:00:00Z"), null, "Waluj")];
    const r = await recordTravelExpenseTool(CTX, { start_point: "ghar" });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(/already recorded/);
  });
});
