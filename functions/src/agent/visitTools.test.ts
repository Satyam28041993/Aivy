/**
 * record_visit asks before it saves: the card is not drawn while the contact,
 * the discussion or the status is missing, unless the user said that is all.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";

const created: Array<Record<string, unknown>> = [];
vi.mock("./draftStore", () => ({
  createDraft: async (input: Record<string, unknown>) => {
    created.push(input);
    return { id: "d1", status: "pending", ...input };
  },
}));
vi.mock("./clientResolve", () => ({
  resolveClient: async () => ({ status: "none" }),
  looksLikeNoiseClientName: () => false,
}));
vi.mock("./google/maps", () => ({
  nearestPlaceLabel: async () => "Waluj MIDC, Aurangabad",
  reverseGeocode: async () => null,
}));
const latest = { current: null as Record<string, unknown> | null };
vi.mock("./visitStore", async () => {
  const actual = await vi.importActual<typeof import("./visitStore")>("./visitStore");
  return {
    ...actual,
    latestVisit: async () => latest.current,
    getVisit: async () => latest.current,
  };
});
vi.mock("firebase-admin/firestore", () => ({ getFirestore: vi.fn(), FieldValue: {} }));
vi.mock("firebase-functions", () => ({ logger: { warn: vi.fn() } }));

const { recordVisitTool, setVisitFollowupTool, missingVisitDetails, periodRange } = await import("./tools/visitTools");

const CTX = {
  uid: "u",
  timezone: "Asia/Kolkata",
  nowIso: "2026-10-06T16:00:00+05:30",
  chatId: "c",
  googleToken: "tok",
  coords: { lat: 19.85, lng: 75.3 },
};

beforeEach(() => {
  created.length = 0;
  latest.current = null;
});

describe("record_visit", () => {
  it("asks for what is missing, all in one go, before drawing a card", async () => {
    const r = await recordVisitTool(CTX, { client_name: "Bajaj Auto" });
    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.reason).toBe("needs_detail");
      expect(r.message).toMatch(/contact person/);
      expect(r.message).toMatch(/discussed/);
      expect(r.message).toMatch(/status or next step/);
    }
    expect(created).toHaveLength(0);
  });

  it("asks only for what is still missing", () => {
    expect(missingVisitDetails({ contact_person: "Sharma", products: "BX410T" })).toEqual([
      "where it stands (status or next step)",
    ]);
  });

  it("saves with gaps once the user has said that is all", async () => {
    const r = await recordVisitTool(CTX, {
      client_name: "Bajaj Auto",
      products: "BX410T",
      details_complete: true,
      at_client_location: false,
    });
    expect(r.ok).toBe(true);
    expect(created).toHaveLength(1);
  });

  it("asks whether they are at the client before using the phone's location", async () => {
    const r = await recordVisitTool(CTX, { client_name: "Bajaj Auto", details_complete: true });
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message).toMatch(/at the client's place/);
    expect(created).toHaveLength(0);
  });

  it("does not ask about the location when the phone has no fix", async () => {
    const r = await recordVisitTool({ ...CTX, coords: null }, { client_name: "Bajaj Auto", details_complete: true });
    expect(r.ok).toBe(true);
  });

  it("keeps no pin when they are not at the client", async () => {
    await recordVisitTool(CTX, { client_name: "Exide", details_complete: true, at_client_location: false });
    const data = created[0].data as { lat: number | null; location: string };
    expect(data.lat).toBeNull();
    expect(data.location).toBe("");
  });

  it("draws one card with the date, the client, the phone's location and where it saves", async () => {
    const r = await recordVisitTool(CTX, {
      client_name: "bajaj auto",
      contact_person: "Mr. Sharma",
      products: "BX410T",
      discussion: "Demo done",
      status: "Interested",
      visit_type: "demo",
      at_client_location: true,
    });
    expect(r.ok).toBe(true);
    const d = created[0];
    const lines = d.lines as Array<{ label: string; value: string }>;
    const get = (l: string) => lines.find((x) => x.label === l)?.value;
    expect(get("Date")).toBe("06-Oct-2026");
    expect(get("Client")).toBe("Bajaj Auto (new client)");
    expect(get("Location")).toBe("Waluj MIDC, Aurangabad");
    expect(get("Visit type")).toBe("Demo");
    expect(get("Saves to")).toBe("Aivy + DSR Google Sheet");
    expect((d.data as { lat: number }).lat).toBe(19.85);
  });

  it("dates a visit 'kal' to yesterday", async () => {
    await recordVisitTool(CTX, { client_name: "Exide", when_phrase: "kal", details_complete: true, at_client_location: false });
    expect((created[0].data as { dateLabel: string }).dateLabel).toBe("05-Oct-2026");
  });

  it("says the sheet will catch up when Google is not connected", async () => {
    await recordVisitTool({ ...CTX, googleToken: null }, { client_name: "Exide", details_complete: true, at_client_location: false });
    const lines = created[0].lines as Array<{ label: string; value: string }>;
    expect(lines.find((l) => l.label === "Saves to")?.value).toMatch(/catches up/);
  });
});

describe("set_visit_followup", () => {
  it("needs a saved visit to attach to", async () => {
    const r = await setVisitFollowupTool(CTX, { when_phrase: "10 din baad" });
    expect(r.ok).toBe(false);
  });

  it("puts the follow-up on the latest visit, in the future", async () => {
    latest.current = { id: "v1", clientName: "Bajaj Auto", dateLabel: "06-Oct-2026", nextStep: "Send quotation", products: "", discussion: "" };
    const r = await setVisitFollowupTool(CTX, { when_phrase: "16 October" });
    expect(r.ok).toBe(true);
    const data = created[0].data as { visitId: string; whenMs: number; note: string };
    expect(data.visitId).toBe("v1");
    expect(data.whenMs).toBeGreaterThan(Date.parse(CTX.nowIso));
    expect(data.note).toBe("Send quotation");
  });
});

describe("list_visits periods", () => {
  it("this_week starts on Monday, today is one day", () => {
    const today = periodRange("today", CTX.nowIso, CTX.timezone);
    expect(today.toMs - today.fromMs).toBe(24 * 3600 * 1000);
    const week = periodRange("this_week", CTX.nowIso, CTX.timezone);
    expect(new Date(week.fromMs).toISOString()).toBe("2026-10-04T18:30:00.000Z"); // Mon 5 Oct, IST midnight
  });
});
