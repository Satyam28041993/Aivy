/**
 * The DSR: a visit lives in Firestore and is copied to the user's sheet. These
 * pin the parts that would silently go wrong — a visit saved without Google
 * catching up later, the follow-up landing in the right row, and a deleted
 * sheet not breaking every save after it.
 */

import { beforeEach, describe, expect, it, vi } from "vitest";

// --- a small in-memory Firestore -------------------------------------------
type Doc = Record<string, unknown>;
const store = new Map<string, Doc>(); // key: full path
let autoId = 0;

function docRef(path: string) {
  return {
    id: path.split("/").pop()!,
    get: async () => ({ exists: store.has(path), id: path.split("/").pop()!, data: () => store.get(path) }),
    set: async (d: Doc) => void store.set(path, { ...d }),
    update: async (d: Doc) => void store.set(path, { ...(store.get(path) ?? {}), ...d }),
    delete: async () => void store.delete(path),
    collection: (name: string) => collRef(`${path}/${name}`),
  };
}

function collRef(path: string) {
  const filters: Array<(d: Doc) => boolean> = [];
  let order: { field: string; dir: string } | null = null;
  let lim = Infinity;
  const q = {
    doc: (id?: string) => docRef(`${path}/${id ?? `auto${++autoId}`}`),
    where(field: string, op: string, value: unknown) {
      filters.push((d) => {
        const v = d[field] ?? null;
        if (op === "==") return v === value;
        if (op === ">=") return (v as number) >= (value as number);
        if (op === "<") return (v as number) < (value as number);
        return false;
      });
      return q;
    },
    orderBy(field: string, dir = "asc") {
      order = { field, dir };
      return q;
    },
    limit(n: number) {
      lim = n;
      return q;
    },
    async get() {
      let docs = [...store.entries()]
        .filter(([k]) => k.startsWith(`${path}/`) && !k.slice(path.length + 1).includes("/"))
        .map(([k, d]) => ({ id: k.split("/").pop()!, data: () => d, ref: docRef(k) }))
        .filter((x) => filters.every((f) => f(x.data())));
      if (order) {
        const { field, dir } = order;
        docs.sort((a, b) => ((a.data()[field] as number) - (b.data()[field] as number)) * (dir === "desc" ? -1 : 1));
      }
      docs = docs.slice(0, lim);
      return { docs, empty: docs.length === 0 };
    },
  };
  return q;
}

vi.mock("firebase-admin/firestore", () => ({
  getFirestore: () => ({
    collection: (name: string) => collRef(name),
    batch: () => {
      const ops: Array<() => Promise<void>> = [];
      return {
        update: (ref: { update: (d: Doc) => Promise<void> }, d: Doc) => ops.push(() => ref.update(d)),
        commit: async () => {
          for (const op of ops) await op();
        },
      };
    },
  }),
}));
vi.mock("firebase-functions", () => ({ logger: { warn: vi.fn() } }));

const createMock = vi.fn();
const appendMock = vi.fn();
const updateRowMock = vi.fn();
vi.mock("./google/workspace", async () => {
  const actual = await vi.importActual<typeof import("./google/workspace")>("./google/workspace");
  return {
    ...actual,
    sheetsCreate: (...a: unknown[]) => createMock(...a),
    sheetsAppendRowsRaw: (...a: unknown[]) => appendMock(...a),
    sheetsUpdateRow: (...a: unknown[]) => updateRowMock(...a),
  };
});

const { saveVisit, setVisitFollowUp, syncVisitsToSheet, visitToRow, DSR_HEADER, getVisit } = await import("./visitStore");
const { firstRowOf, GoogleApiError } = await import("./google/workspace");

const TZ = "Asia/Kolkata";
const base = {
  visitDateMs: Date.parse("2026-10-06T06:30:00Z"),
  dateLabel: "06-Oct-2026",
  clientId: "c1",
  clientName: "Bajaj Auto",
  contactPerson: "Mr. Sharma, Purchase",
  contactPhone: "09876543210",
  location: "Waluj, Aurangabad",
  visitType: "Demo",
  products: "BX410T",
  discussion: "Demo done, wants RFID option",
  status: "Interested",
  nextStep: "Send quotation",
  followUpMs: 0,
  followUpLabel: "",
  followUpReminderId: "",
};

beforeEach(() => {
  store.clear();
  createMock.mockReset().mockResolvedValue({ spreadsheetId: "S1", url: "https://sheet/S1" });
  appendMock.mockReset();
  updateRowMock.mockReset().mockResolvedValue(undefined);
});

describe("DSR row", () => {
  it("has one cell per heading, in order, and keeps the phone number as text", async () => {
    const v = await saveVisit("u", base);
    const row = visitToRow(v, TZ);
    expect(row).toHaveLength(DSR_HEADER.length);
    expect(row[0]).toBe("06-Oct-2026");
    expect(row[1]).toBe("Bajaj Auto");
    expect(row[3]).toBe("09876543210");
    expect(row[DSR_HEADER.indexOf("Follow-up Date")]).toBe("");
  });

  it("reads the first written row from Google's updatedRange", () => {
    expect(firstRowOf("DSR!A5:L7")).toBe(5);
    expect(firstRowOf("'DSR'!A12:L12")).toBe(12);
    expect(firstRowOf("")).toBeNull();
  });
});

describe("syncing visits to the sheet", () => {
  it("keeps a visit saved without Google, and copies it on the next save that has a token", async () => {
    const offline = await saveVisit("u", base);
    const r1 = await syncVisitsToSheet("u", null, TZ);
    expect(r1.problem).toMatch(/catch up/);
    expect(appendMock).not.toHaveBeenCalled();
    expect((await getVisit("u", offline.id))?.sheetRow).toBeNull();

    const second = await saveVisit("u", { ...base, clientName: "Exide", visitDateMs: base.visitDateMs + 1000 });
    appendMock.mockResolvedValue(2);
    const r2 = await syncVisitsToSheet("u", "tok", TZ);
    expect(createMock).toHaveBeenCalledTimes(1); // first visit ever → sheet made
    expect(r2.created).toBe(true);
    expect(r2.written).toBe(2);
    const rows = appendMock.mock.calls[0][1].rows as string[][];
    expect(rows.map((r) => r[1])).toEqual(["Bajaj Auto", "Exide"]); // oldest first
    expect((await getVisit("u", offline.id))?.sheetRow).toBe(2);
    expect((await getVisit("u", second.id))?.sheetRow).toBe(3);
  });

  it("does not create a second sheet once one exists", async () => {
    await saveVisit("u", base);
    appendMock.mockResolvedValue(2);
    await syncVisitsToSheet("u", "tok", TZ);
    await saveVisit("u", base);
    appendMock.mockResolvedValue(3);
    await syncVisitsToSheet("u", "tok", TZ);
    expect(createMock).toHaveBeenCalledTimes(1);
  });

  it("writes a follow-up added later into that visit's own row", async () => {
    const v = await saveVisit("u", base);
    appendMock.mockResolvedValue(7);
    await syncVisitsToSheet("u", "tok", TZ);
    await setVisitFollowUp("u", v.id, {
      followUpMs: Date.parse("2026-10-16T05:30:00Z"),
      followUpLabel: "Friday, 16 October, 11:00 AM",
      reminderId: "r1",
    });
    await syncVisitsToSheet("u", "tok", TZ);
    expect(updateRowMock).toHaveBeenCalledTimes(1);
    const call = updateRowMock.mock.calls[0][1];
    expect(call.row).toBe(7);
    expect(call.cells[DSR_HEADER.indexOf("Follow-up Date")]).toBe("16-Oct-2026");
    expect((await getVisit("u", v.id))?.sheetFollowUpPending).toBe(false);
  });

  it("starts a fresh sheet when the old one was deleted", async () => {
    await saveVisit("u", base);
    appendMock.mockResolvedValue(2);
    await syncVisitsToSheet("u", "tok", TZ);
    await saveVisit("u", base);
    createMock.mockResolvedValue({ spreadsheetId: "S2", url: "https://sheet/S2" });
    appendMock.mockRejectedValueOnce(new GoogleApiError("Sheets", 404, "gone")).mockResolvedValueOnce(2);
    const r = await syncVisitsToSheet("u", "tok", TZ);
    expect(r.problem).toBeNull();
    expect(r.url).toBe("https://sheet/S2");
  });

  it("reports a Google refusal instead of throwing — the visit is already safe", async () => {
    await saveVisit("u", base);
    appendMock.mockRejectedValue(new GoogleApiError("Sheets", 403, "no"));
    const r = await syncVisitsToSheet("u", "tok", TZ);
    expect(r.problem).toMatch(/permission/);
  });
});
