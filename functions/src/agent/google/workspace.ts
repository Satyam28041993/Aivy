/**
 * Google Workspace REST calls, done server-side with a token the client hands
 * over for the duration of one turn.
 *
 * Why server-side at all: the agent loop runs in the function, so if the token
 * stayed on the phone the model could only ever be *told* to write something —
 * it could never answer "calendar me kal kya hai" or "koi mail aaya kya",
 * because reading has to happen while the model is still thinking. Forwarding
 * the token keeps reads and writes on the same path.
 *
 * The token is never stored. It arrives in the callable payload, lives in
 * memory for that turn, and Google expires it in about an hour anyway.
 *
 * Every request shape here mirrors the app's own Dart clients exactly, so a
 * record written by the agent is indistinguishable from one written by the UI:
 *   - calendar → `lib/features/integrations/google/google_calendar_client.dart`
 *   - gmail    → `lib/features/integrations/google/google_gmail_client.dart`
 *   - sheets   → `lib/features/integrations/google/google_sheets_client.dart`
 *   - people   → `lib/features/contacts/data/google_people_contacts_client.dart`
 */

/** A Google API said no. `status` lets callers tell "not allowed" from "broken". */
export class GoogleApiError extends Error {
  constructor(
    readonly api: string,
    readonly status: number,
    readonly detail: string,
  ) {
    super(`${api} ${status}: ${detail}`);
    this.name = "GoogleApiError";
  }

  /** 401/403 means the token is stale or the scope was never granted. */
  get isAuth(): boolean {
    return this.status === 401 || this.status === 403;
  }

  /** Something to say to the user, in the app's voice. */
  get userMessage(): string {
    if (this.isAuth) {
      return "Google permission needed — allow it again from More → Allow Google extras.";
    }
    if (this.status === 404) {
      return "Google could not find that.";
    }
    return "Could not reach Google — try again shortly.";
  }
}

async function callGoogle<T>(
  api: string,
  token: string,
  url: string,
  init: { method?: string; body?: unknown } = {},
): Promise<T> {
  const res = await fetch(url, {
    method: init.method ?? "GET",
    headers: {
      Authorization: `Bearer ${token}`,
      ...(init.body === undefined ? {} : { "Content-Type": "application/json; charset=utf-8" }),
    },
    ...(init.body === undefined ? {} : { body: JSON.stringify(init.body) }),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new GoogleApiError(api, res.status, text.slice(0, 280));
  }
  const text = await res.text();
  return (text ? JSON.parse(text) : {}) as T;
}

// ---------------------------------------------------------------------------
// Calendar
// ---------------------------------------------------------------------------

export interface CalendarEventInput {
  summary: string;
  description?: string | null;
  /** Start instant, epoch millis. */
  startMs: number;
  durationMinutes: number;
  /** IANA zone, sent so Calendar shows the event where the user actually is. */
  timezone: string;
  attendeeEmails?: string[];
}

export interface CalendarEventRef {
  id: string;
  link: string;
}

export async function calendarInsertEvent(
  token: string,
  input: CalendarEventInput,
): Promise<CalendarEventRef> {
  const startIso = new Date(input.startMs).toISOString();
  const endIso = new Date(input.startMs + input.durationMinutes * 60_000).toISOString();
  const body: Record<string, unknown> = {
    summary: input.summary,
    start: { dateTime: startIso, timeZone: "UTC" },
    end: { dateTime: endIso, timeZone: "UTC" },
  };
  if (input.description && input.description.trim()) {
    body.description = input.description.trim();
  }
  const emails = (input.attendeeEmails ?? []).filter((e) => e.includes("@"));
  if (emails.length) {
    body.attendees = emails.map((email) => ({ email }));
  }
  const res = await callGoogle<{ id?: string; htmlLink?: string }>(
    "Calendar",
    token,
    "https://www.googleapis.com/calendar/v3/calendars/primary/events",
    { method: "POST", body },
  );
  return { id: `${res.id ?? ""}`, link: `${res.htmlLink ?? ""}` };
}

export interface CalendarEventRow {
  id: string;
  summary: string;
  startIso: string;
  endIso: string;
  allDay: boolean;
  location: string;
  link: string;
}

export async function calendarListEvents(
  token: string,
  opts: { timeMinIso: string; timeMaxIso: string; maxResults?: number },
): Promise<CalendarEventRow[]> {
  const q = new URLSearchParams({
    timeMin: opts.timeMinIso,
    timeMax: opts.timeMaxIso,
    singleEvents: "true",
    orderBy: "startTime",
    maxResults: String(Math.min(50, Math.max(1, opts.maxResults ?? 25))),
  });
  const res = await callGoogle<{
    items?: Array<Record<string, unknown>>;
  }>(
    "Calendar",
    token,
    `https://www.googleapis.com/calendar/v3/calendars/primary/events?${q.toString()}`,
  );
  return (res.items ?? []).map((item) => {
    const start = (item.start ?? {}) as Record<string, string>;
    const end = (item.end ?? {}) as Record<string, string>;
    return {
      id: `${item.id ?? ""}`,
      summary: `${item.summary ?? "(untitled event)"}`,
      startIso: start.dateTime ?? start.date ?? "",
      endIso: end.dateTime ?? end.date ?? "",
      allDay: !start.dateTime && Boolean(start.date),
      location: `${item.location ?? ""}`,
      link: `${item.htmlLink ?? ""}`,
    };
  });
}

// ---------------------------------------------------------------------------
// Gmail
// ---------------------------------------------------------------------------

function rfc822(to: string, subject: string, body: string): string {
  const subj = subject.replace(/[\r\n]+/g, " ").trim();
  const text = body.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
  return (
    `To: ${to}\r\n` +
    `Subject: ${subj}\r\n` +
    "Content-Type: text/plain; charset=UTF-8\r\n" +
    "\r\n" +
    text
  );
}

/** Gmail wants base64url with the padding stripped. */
function urlSafeBase64(raw: string): string {
  return Buffer.from(raw, "utf8")
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

export async function gmailSend(
  token: string,
  input: { to: string; subject: string; body: string },
): Promise<string> {
  const res = await callGoogle<{ id?: string }>(
    "Gmail",
    token,
    "https://gmail.googleapis.com/gmail/v1/users/me/messages/send",
    {
      method: "POST",
      body: { raw: urlSafeBase64(rfc822(input.to.trim(), input.subject, input.body)) },
    },
  );
  return `${res.id ?? ""}`;
}

export interface GmailSummaryRow {
  id: string;
  subject: string;
  from: string;
  snippet: string;
  receivedMs: number;
}

function headerValue(headers: unknown, name: string): string {
  if (!Array.isArray(headers)) {
    return "";
  }
  const want = name.toLowerCase();
  for (const h of headers) {
    if (h && typeof h === "object" && `${(h as Record<string, unknown>).name ?? ""}`.toLowerCase() === want) {
      return `${(h as Record<string, unknown>).value ?? ""}`.trim();
    }
  }
  return "";
}

/**
 * Recent inbox mail. Each message needs its own metadata fetch (the list call
 * returns ids only), so this is deliberately capped low — the model wants a
 * glance, not a mailbox.
 */
export async function gmailListRecent(
  token: string,
  opts: { maxResults?: number; query?: string } = {},
): Promise<GmailSummaryRow[]> {
  const max = Math.min(15, Math.max(1, opts.maxResults ?? 8));
  const q = new URLSearchParams({ maxResults: String(max), labelIds: "INBOX" });
  if (opts.query && opts.query.trim()) {
    q.set("q", opts.query.trim());
  }
  const list = await callGoogle<{ messages?: Array<{ id?: string }> }>(
    "Gmail",
    token,
    `https://gmail.googleapis.com/gmail/v1/users/me/messages?${q.toString()}`,
  );
  const ids = (list.messages ?? []).map((m) => `${m.id ?? ""}`).filter(Boolean);

  const rows = await Promise.all(
    ids.map(async (id) => {
      try {
        const msg = await callGoogle<Record<string, unknown>>(
          "Gmail",
          token,
          `https://gmail.googleapis.com/gmail/v1/users/me/messages/${id}` +
            "?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=Date",
        );
        const payload = (msg.payload ?? {}) as Record<string, unknown>;
        const subject = headerValue(payload.headers, "Subject");
        const from = headerValue(payload.headers, "From");
        const internal = Number(msg.internalDate ?? 0);
        return {
          id,
          subject: subject || "(no subject)",
          from: from || "—",
          snippet: `${msg.snippet ?? ""}`.trim(),
          receivedMs: Number.isFinite(internal) ? internal : 0,
        } satisfies GmailSummaryRow;
      } catch {
        // One unreadable message should not blank the whole list.
        return null;
      }
    }),
  );
  return rows.filter((r): r is GmailSummaryRow => r != null);
}

// ---------------------------------------------------------------------------
// Sheets
// ---------------------------------------------------------------------------

export async function sheetsAppendRow(
  token: string,
  input: { spreadsheetId: string; tab: string; cells: string[] },
): Promise<number> {
  const range = `${input.tab || "Sheet1"}!A1`;
  const url =
    `https://sheets.googleapis.com/v4/spreadsheets/${encodeURIComponent(input.spreadsheetId)}` +
    `/values/${encodeURIComponent(range)}:append` +
    "?valueInputOption=USER_ENTERED&insertDataOption=INSERT_ROWS";
  const res = await callGoogle<{ updates?: { updatedRows?: number } }>(
    "Sheets",
    token,
    url,
    { method: "POST", body: { values: [input.cells] } },
  );
  return Number(res.updates?.updatedRows ?? 0);
}

// ---------------------------------------------------------------------------
// People (contacts) — how "rohan ko mail bhej do" finds an address
// ---------------------------------------------------------------------------

export interface ContactRow {
  name: string;
  emails: string[];
  phones: string[];
}

function readPeople(items: unknown, key: string): ContactRow[] {
  const list = (items as Record<string, unknown>)?.[key];
  if (!Array.isArray(list)) {
    return [];
  }
  const out: ContactRow[] = [];
  for (const raw of list) {
    if (!raw || typeof raw !== "object") {
      continue;
    }
    const person = (raw as Record<string, unknown>).person ?? raw;
    const p = person as Record<string, unknown>;
    const names = Array.isArray(p.names) ? p.names : [];
    const emails = Array.isArray(p.emailAddresses) ? p.emailAddresses : [];
    const phones = Array.isArray(p.phoneNumbers) ? p.phoneNumbers : [];
    const name = `${(names[0] as Record<string, unknown>)?.displayName ?? ""}`.trim();
    const emailList = emails
      .map((e) => `${(e as Record<string, unknown>).value ?? ""}`.trim())
      .filter(Boolean);
    if (!name && emailList.length === 0) {
      continue;
    }
    out.push({
      name: name || emailList[0]!,
      emails: emailList,
      phones: phones
        .map((e) => `${(e as Record<string, unknown>).value ?? ""}`.trim())
        .filter(Boolean),
    });
  }
  return out;
}

/**
 * Searches saved contacts and the "other contacts" Google auto-collects.
 * Other-contacts is best-effort: that scope is often not granted, and a 403
 * there should not lose the saved-contact hits.
 */
export async function peopleSearch(token: string, query: string): Promise<ContactRow[]> {
  const q = query.trim();
  if (!q) {
    return [];
  }
  const readMask = "names,emailAddresses,phoneNumbers";
  const saved = await callGoogle<Record<string, unknown>>(
    "People",
    token,
    `https://people.googleapis.com/v1/people:searchContacts?query=${encodeURIComponent(q)}` +
      `&readMask=${encodeURIComponent(readMask)}&pageSize=10`,
  );
  const rows = readPeople(saved, "results");

  let others: ContactRow[] = [];
  try {
    const other = await callGoogle<Record<string, unknown>>(
      "People",
      token,
      `https://people.googleapis.com/v1/otherContacts:search?query=${encodeURIComponent(q)}` +
        `&readMask=${encodeURIComponent("names,emailAddresses")}&pageSize=10`,
    );
    others = readPeople(other, "results");
  } catch {
    others = [];
  }

  const seen = new Set<string>();
  const merged: ContactRow[] = [];
  for (const row of [...rows, ...others]) {
    const key = (row.emails[0] ?? row.name).toLowerCase();
    if (seen.has(key)) {
      continue;
    }
    seen.add(key);
    merged.push(row);
  }
  return merged;
}
