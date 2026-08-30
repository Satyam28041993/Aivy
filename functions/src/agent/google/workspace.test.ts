import { afterEach, describe, expect, it, vi } from "vitest";

import {
  calendarInsertEvent,
  calendarListEvents,
  gmailListRecent,
  gmailSend,
  GoogleApiError,
  peopleSearch,
  sheetsAppendRow,
} from "./workspace";

/**
 * These assert the wire format, because that is the whole risk here: the app's
 * Dart clients already write to these APIs, and a row the agent writes must be
 * indistinguishable from one the UI wrote.
 */

interface Captured {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: unknown;
}

function stubFetch(responses: Array<{ status?: number; json?: unknown; text?: string }>) {
  const calls: Captured[] = [];
  let i = 0;
  vi.stubGlobal("fetch", (url: string, init: Record<string, unknown> = {}) => {
    calls.push({
      url,
      method: `${init.method ?? "GET"}`,
      headers: (init.headers ?? {}) as Record<string, string>,
      body: init.body ? JSON.parse(`${init.body}`) : undefined,
    });
    const r = responses[Math.min(i++, responses.length - 1)]!;
    const status = r.status ?? 200;
    return Promise.resolve({
      ok: status >= 200 && status < 300,
      status,
      text: () => Promise.resolve(r.text ?? JSON.stringify(r.json ?? {})),
    });
  });
  return calls;
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("calendar", () => {
  it("inserts a timed event on the primary calendar", async () => {
    const calls = stubFetch([{ json: { id: "ev1", htmlLink: "https://cal/ev1" } }]);
    const ref = await calendarInsertEvent("tok", {
      summary: "Meeting: new labels",
      description: null,
      startMs: Date.UTC(2025, 7, 30, 5, 30),
      durationMinutes: 30,
      timezone: "Asia/Kolkata",
    });

    expect(ref).toEqual({ id: "ev1", link: "https://cal/ev1" });
    const c = calls[0]!;
    expect(c.url).toBe("https://www.googleapis.com/calendar/v3/calendars/primary/events");
    expect(c.method).toBe("POST");
    expect(c.headers.Authorization).toBe("Bearer tok");
    expect(c.body).toEqual({
      summary: "Meeting: new labels",
      start: { dateTime: "2025-08-30T05:30:00.000Z", timeZone: "UTC" },
      end: { dateTime: "2025-08-30T06:00:00.000Z", timeZone: "UTC" },
    });
  });

  it("keeps only real addresses as attendees", async () => {
    const calls = stubFetch([{ json: { id: "ev2" } }]);
    await calendarInsertEvent("tok", {
      summary: "x",
      startMs: 0,
      durationMinutes: 60,
      timezone: "UTC",
      attendeeEmails: ["rohan@example.com", "not-an-address"],
    });
    expect((calls[0]!.body as Record<string, unknown>).attendees).toEqual([
      { email: "rohan@example.com" },
    ]);
  });

  it("reads a window back, flattening all-day events", async () => {
    stubFetch([
      {
        json: {
          items: [
            { id: "a", summary: "Timed", start: { dateTime: "2025-08-30T05:30:00Z" }, end: {} },
            { id: "b", summary: "Holiday", start: { date: "2025-08-31" }, end: {} },
          ],
        },
      },
    ]);
    const rows = await calendarListEvents("tok", {
      timeMinIso: "2025-08-30T00:00:00Z",
      timeMaxIso: "2025-08-31T00:00:00Z",
    });
    expect(rows.map((r) => [r.summary, r.allDay])).toEqual([
      ["Timed", false],
      ["Holiday", true],
    ]);
  });
});

describe("gmail", () => {
  it("sends base64url raw RFC822 with no padding", async () => {
    const calls = stubFetch([{ json: { id: "m1" } }]);
    await gmailSend("tok", {
      to: " rohan@example.com ",
      subject: "Quotation\nfollow-up",
      body: "Namaste,\r\nAttached hai.",
    });

    const raw = (calls[0]!.body as { raw: string }).raw;
    expect(raw).not.toContain("=");
    expect(raw).not.toContain("+");
    expect(raw).not.toContain("/");

    const decoded = Buffer.from(raw.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString("utf8");
    expect(decoded).toContain("To: rohan@example.com\r\n");
    // Newlines in a subject would break the header block.
    expect(decoded).toContain("Subject: Quotation follow-up\r\n");
    expect(decoded).toContain("Content-Type: text/plain; charset=UTF-8\r\n\r\n");
    expect(decoded.endsWith("Namaste,\nAttached hai.")).toBe(true);
  });

  it("lists recent inbox mail and survives one unreadable message", async () => {
    stubFetch([
      { json: { messages: [{ id: "1" }, { id: "2" }] } },
      {
        json: {
          snippet: "hi",
          internalDate: "1756000000000",
          payload: { headers: [{ name: "Subject", value: "Order" }, { name: "From", value: "R" }] },
        },
      },
      { status: 500, text: "boom" },
    ]);
    const rows = await gmailListRecent("tok", { maxResults: 2 });
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ subject: "Order", from: "R", snippet: "hi" });
  });
});

describe("sheets", () => {
  it("appends a row with USER_ENTERED and INSERT_ROWS", async () => {
    const calls = stubFetch([{ json: { updates: { updatedRows: 1 } } }]);
    const n = await sheetsAppendRow("tok", {
      spreadsheetId: "sheet 1/id",
      tab: "Log",
      cells: ["30 Aug", "Rohan", "50000"],
    });
    expect(n).toBe(1);
    expect(calls[0]!.url).toBe(
      "https://sheets.googleapis.com/v4/spreadsheets/sheet%201%2Fid/values/Log!A1:append" +
        "?valueInputOption=USER_ENTERED&insertDataOption=INSERT_ROWS",
    );
    expect(calls[0]!.body).toEqual({ values: [["30 Aug", "Rohan", "50000"]] });
  });
});

describe("people", () => {
  it("merges saved and other contacts, dropping duplicates", async () => {
    stubFetch([
      {
        json: {
          results: [
            {
              person: {
                names: [{ displayName: "Rohan Traders" }],
                emailAddresses: [{ value: "rohan@example.com" }],
              },
            },
          ],
        },
      },
      {
        json: {
          results: [
            {
              person: {
                names: [{ displayName: "Rohan T" }],
                emailAddresses: [{ value: "rohan@example.com" }],
              },
            },
            {
              person: {
                names: [{ displayName: "Rohit" }],
                emailAddresses: [{ value: "rohit@example.com" }],
              },
            },
          ],
        },
      },
    ]);
    const rows = await peopleSearch("tok", "roh");
    expect(rows.map((r) => r.name)).toEqual(["Rohan Traders", "Rohit"]);
  });

  it("still returns saved contacts when otherContacts is forbidden", async () => {
    stubFetch([
      {
        json: {
          results: [
            { person: { names: [{ displayName: "Rohan" }], emailAddresses: [{ value: "r@e.com" }] } },
          ],
        },
      },
      { status: 403, text: "insufficient scope" },
    ]);
    const rows = await peopleSearch("tok", "rohan");
    expect(rows.map((r) => r.name)).toEqual(["Rohan"]);
  });
});

describe("errors", () => {
  it("tells a permission problem apart from a broken one", async () => {
    stubFetch([{ status: 403, text: "insufficient scope" }]);
    const err = await gmailSend("tok", { to: "a@b.com", subject: "x", body: "y" }).catch((e) => e);
    expect(err).toBeInstanceOf(GoogleApiError);
    expect((err as GoogleApiError).isAuth).toBe(true);
    expect((err as GoogleApiError).userMessage).toContain("Allow Google extras");

    stubFetch([{ status: 500, text: "server" }]);
    const err2 = await gmailSend("tok", { to: "a@b.com", subject: "x", body: "y" }).catch((e) => e);
    expect((err2 as GoogleApiError).isAuth).toBe(false);
  });
});
