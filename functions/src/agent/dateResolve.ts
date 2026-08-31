/**
 * Hybrid date resolution for the agent.
 *
 * The model never does calendar arithmetic. It hands over three things:
 *   - `phrase`  — what the user actually said ("kal 11 baje")
 *   - `tense`   — future / past, read from the sentence's grammar
 *   - `period`  — morning / afternoon / evening / night, when implied
 *
 * This module does the arithmetic. It deliberately fixes three bugs that the
 * app's own `reminder_time_parser.dart` still has (see
 * `AIVY_INTENT_AND_DATE_ANALYSIS.md` §D3–D5):
 *
 *  1. "kal 11 baje" resolved to 23:00 because any future day got a blanket +12.
 *     Here 9/10/11 read as morning and 1–7 as evening, matching how business
 *     hours are actually spoken.
 *  2. "kal 10" (10:00) and "kal 10 baje" (22:00) disagreed. One code path now.
 *  3. "kal"/"parso" were always future, so "kal payment aaya tha" landed on
 *     tomorrow. Tense decides the direction.
 *
 * It also covers what the old parser never did: Hindi weekdays, "is/agle hafte",
 * "is/agle mahine", and "15 tarikh".
 */

import { DateTime } from "luxon";

export type WhenTense = "future" | "past";
export type DayPeriod = "morning" | "afternoon" | "evening" | "night";

export interface ResolveWhenInput {
  /** Raw phrase as spoken, e.g. "kal 11 baje", "agle somvar", "15 tarikh". */
  phrase: string;
  /** IANA zone, e.g. "Asia/Kolkata". */
  timezone: string;
  /** ISO instant treated as "now". Defaults to the real clock. */
  nowIso?: string;
  /** Grammatical direction. Defaults to future. */
  tense?: WhenTense;
  /** Day period when the sentence implies one but gives no am/pm. */
  period?: DayPeriod | null;
  /** Hour used when the phrase carries a day but no clock at all. */
  defaultHour?: number;
}

export interface ResolveWhenResult {
  /** Resolved instant, ISO with offset. Null when nothing could be read. */
  iso: string | null;
  /** Epoch millis for the resolved instant. */
  epochMs: number | null;
  /** Human line for the confirm card, e.g. "Monday, 24 August, 11:00 AM". */
  label: string | null;
  /** True when the phrase carried an explicit clock. */
  hasExplicitTime: boolean;
  /** What the resolver actually understood — useful for debugging. */
  matched: string | null;
}

const HINDI_WEEKDAYS: Record<string, number> = {
  somvar: 1,
  somwar: 1,
  mangalvar: 2,
  mangalwar: 2,
  budhvar: 3,
  budhwar: 3,
  guruvar: 4,
  guruwar: 4,
  brihaspativar: 4,
  shukravar: 5,
  shukrawar: 5,
  shanivar: 6,
  shaniwar: 6,
  ravivar: 7,
  raviwar: 7,
  itwar: 7,
  itvar: 7,
};

const ENGLISH_WEEKDAYS: Record<string, number> = {
  monday: 1,
  tuesday: 2,
  wednesday: 3,
  thursday: 4,
  friday: 5,
  saturday: 6,
  sunday: 7,
};

/**
 * Cards are read, not spoken, and the app reads in English — "Sunday, 30
 * August" rather than "Ravivar". Hindi weekday *input* is still understood;
 * this is only how a resolved date is written back.
 */
const WEEKDAY_LABELS = [
  "",
  "Monday",
  "Tuesday",
  "Wednesday",
  "Thursday",
  "Friday",
  "Saturday",
  "Sunday",
];

const MONTHS: Record<string, number> = {
  jan: 1, january: 1, janvari: 1,
  feb: 2, february: 2, farvari: 2,
  mar: 3, march: 3,
  apr: 4, april: 4,
  may: 5, mai: 5,
  jun: 6, june: 6,
  jul: 7, july: 7, julai: 7,
  aug: 8, august: 8, agast: 8,
  sep: 9, sept: 9, september: 9, sitambar: 9,
  oct: 10, october: 10, aktubar: 10,
  nov: 11, november: 11, navambar: 11,
  dec: 12, december: 12, disambar: 12,
};

/** Word-form small numbers used in "do din baad" style phrases. */
const WORD_NUMBERS: Record<string, number> = {
  ek: 1, one: 1,
  do: 2, two: 2,
  teen: 3, tin: 3, three: 3,
  char: 4, chaar: 4, four: 4,
  paanch: 5, panch: 5, five: 5,
  chah: 6, chhah: 6, chhe: 6, six: 6,
  saat: 7, seven: 7,
  aath: 8, eight: 8,
  nau: 9, nine: 9,
  das: 10, dus: 10, ten: 10,
};

const DEFAULT_HOUR = 11;

/** Period → the hour used when the phrase names a period but no clock. */
const PERIOD_DEFAULT_HOUR: Record<DayPeriod, number> = {
  morning: 9,
  afternoon: 14,
  evening: 18,
  night: 20,
};

/**
 * Turns a bare 1–12 hour into a 24-hour value.
 *
 * This is bug #1's fix. The old parser added 12 to every ambiguous hour on a
 * future day, which is right for "4 baje" and wrong for "11 baje". Indian
 * business hours make 8–11 morning and 1–7 evening, so we split there instead.
 */
export function disambiguateHour(
  rawHour: number,
  period: DayPeriod | null | undefined,
): number {
  if (rawHour < 0 || rawHour > 23) {
    return Math.min(Math.max(rawHour, 0), 23);
  }
  // Already unambiguous.
  if (rawHour === 0 || rawHour > 12) {
    return rawHour;
  }
  if (period === "morning") {
    return rawHour === 12 ? 0 : rawHour;
  }
  if (period === "afternoon") {
    if (rawHour === 12) return 12;
    return rawHour < 12 ? rawHour + 12 : rawHour;
  }
  if (period === "evening" || period === "night") {
    return rawHour === 12 ? 12 : rawHour + 12;
  }
  if (rawHour === 12) {
    return 12;
  }
  // No period given: 8–11 are morning hours, 1–7 are evening hours.
  return rawHour >= 8 ? rawHour : rawHour + 12;
}

interface TimeRead {
  hour: number;
  minute: number;
  explicit: boolean;
}

/** Reads a clock out of the phrase. One path for "10" and "10 baje" alike. */
function readTime(hint: string, period: DayPeriod | null | undefined): TimeRead | null {
  // 3:30pm / 3.30 pm / 7pm
  const ampm = hint.match(/\b(\d{1,2})(?:[:.]([0-5]\d))?\s*(am|pm)\b/i);
  if (ampm) {
    let hour = parseInt(ampm[1]!, 10);
    const minute = ampm[2] ? parseInt(ampm[2], 10) : 0;
    const isPm = ampm[3]!.toLowerCase() === "pm";
    if (hour === 12) {
      hour = isPm ? 12 : 0;
    } else if (isPm) {
      hour += 12;
    }
    if (hour >= 0 && hour <= 23) {
      return { hour, minute, explicit: true };
    }
  }

  // 24-hour or explicit HH:MM
  const colon = hint.match(/\b([01]?\d|2[0-3]):([0-5]\d)\b/);
  if (colon) {
    return {
      hour: parseInt(colon[1]!, 10),
      minute: parseInt(colon[2]!, 10),
      explicit: true,
    };
  }

  // "11 baje", "11:30 baje", "sade 4 baje"
  const baje = hint.match(/\b(\d{1,2})(?:[:.]([0-5]\d))?\s*baje\b/);
  if (baje) {
    const raw = parseInt(baje[1]!, 10);
    const minute = baje[2] ? parseInt(baje[2], 10) : 0;
    return { hour: disambiguateHour(raw, period), minute, explicit: true };
  }

  // Bare hour right after a day word: "kal 10", "aaj 4". Same treatment as
  // "kal 10 baje" — this is bug #2's fix.
  const bareAfterDay = hint.match(
    /\b(?:aaj|kal|parso|narso|today|tomorrow|yesterday|subah|shaam|sham|raat|dopahar)\s+(\d{1,2})\b(?!\s*(?:din|tarikh|baje|:))/,
  );
  if (bareAfterDay) {
    const raw = parseInt(bareAfterDay[1]!, 10);
    if (raw >= 0 && raw <= 23) {
      return { hour: disambiguateHour(raw, period), minute: 0, explicit: true };
    }
  }

  // Only a period word, no number.
  if (period) {
    return { hour: PERIOD_DEFAULT_HOUR[period], minute: 0, explicit: false };
  }
  const spoken = hint.match(/\b(subah|savere|morning|dopahar|afternoon|shaam|sham|evening|raat|night)\b/);
  if (spoken) {
    const w = spoken[1]!;
    const p: DayPeriod =
      w === "subah" || w === "savere" || w === "morning"
        ? "morning"
        : w === "dopahar" || w === "afternoon"
          ? "afternoon"
          : w === "raat" || w === "night"
            ? "night"
            : "evening";
    return { hour: PERIOD_DEFAULT_HOUR[p], minute: 0, explicit: false };
  }

  return null;
}

/** Reads a period word out of the phrase so `readTime` can use it. */
function readPeriod(hint: string): DayPeriod | null {
  if (/\b(subah|savere|morning)\b/.test(hint)) return "morning";
  if (/\b(dopahar|afternoon)\b/.test(hint)) return "afternoon";
  if (/\b(shaam|sham|evening)\b/.test(hint)) return "evening";
  if (/\b(raat|night)\b/.test(hint)) return "night";
  return null;
}

function wordOrDigitCount(token: string): number | null {
  const n = parseInt(token, 10);
  if (!Number.isNaN(n)) {
    return n;
  }
  const w = WORD_NUMBERS[token];
  return w ?? null;
}

interface DayRead {
  date: DateTime;
  matched: string;
}

/**
 * Reads the calendar day. `tense` decides which way ambiguous Hindi words point
 * — this is bug #3's fix, since "kal" and "parso" mean both directions.
 */
function readDay(
  hint: string,
  now: DateTime,
  tense: WhenTense,
): DayRead | null {
  const back = tense === "past";

  // dd/mm/yyyy, dd-mm-yy, dd.mm
  const numeric = hint.match(/\b(\d{1,2})[/\-.](\d{1,2})(?:[/\-.](\d{2,4}))?\b/);
  if (numeric) {
    const day = parseInt(numeric[1]!, 10);
    const month = parseInt(numeric[2]!, 10);
    let year = numeric[3] ? parseInt(numeric[3], 10) : now.year;
    if (year < 100) {
      year += 2000;
    }
    if (day >= 1 && day <= 31 && month >= 1 && month <= 12) {
      const dt = DateTime.fromObject(
        { year, month, day },
        { zone: now.zone },
      );
      if (dt.isValid) {
        return { date: dt, matched: "numeric_date" };
      }
    }
  }

  // "5 May" / "May 5" / "20 agast"
  const monthNames = Object.keys(MONTHS).join("|");
  const dayThenMonth = hint.match(
    new RegExp(`\\b(\\d{1,2})\\s*(?:st|nd|rd|th)?\\s+(${monthNames})\\b`),
  );
  const monthThenDay = hint.match(
    new RegExp(`\\b(${monthNames})\\s+(\\d{1,2})\\b`),
  );
  const namedMonth = dayThenMonth
    ? { day: parseInt(dayThenMonth[1]!, 10), month: MONTHS[dayThenMonth[2]!]! }
    : monthThenDay
      ? { day: parseInt(monthThenDay[2]!, 10), month: MONTHS[monthThenDay[1]!]! }
      : null;
  if (namedMonth && namedMonth.day >= 1 && namedMonth.day <= 31) {
    let dt = DateTime.fromObject(
      { year: now.year, month: namedMonth.month, day: namedMonth.day },
      { zone: now.zone },
    );
    if (dt.isValid) {
      // Roll the year so the date sits on the side the tense implies.
      if (!back && dt < now.startOf("day")) {
        dt = dt.plus({ years: 1 });
      } else if (back && dt > now.endOf("day")) {
        dt = dt.minus({ years: 1 });
      }
      return { date: dt, matched: "named_month" };
    }
  }

  // "15 tarikh" / "mahine ki 5 tarikh" — never supported before.
  const tarikh = hint.match(/\b(\d{1,2})\s*(?:tarikh|tareekh|tarik)\b/);
  if (tarikh) {
    const day = parseInt(tarikh[1]!, 10);
    if (day >= 1 && day <= 31) {
      const nextMonth = /\b(agle|agla|next)\s*(mahine|mahina|month)\b/.test(hint);
      let dt = DateTime.fromObject(
        { year: now.year, month: now.month, day },
        { zone: now.zone },
      );
      if (dt.isValid) {
        if (nextMonth) {
          dt = dt.plus({ months: 1 });
        } else if (!back && dt < now.startOf("day")) {
          dt = dt.plus({ months: 1 });
        } else if (back && dt > now.endOf("day")) {
          dt = dt.minus({ months: 1 });
        }
        return { date: dt, matched: "tarikh" };
      }
    }
  }

  // "2 din baad" / "do din ke baad" / "2 din me" / "3 din pehle"
  //
  // "me" and "tak" belong here as much as "baad" does. A deadline is nearly
  // always said as "2 din me" or "2 din tak", not "2 din baad", and leaving
  // them out meant the commonest way of giving a deadline resolved to no date
  // at all.
  const relDays = hint.match(
    /\b([a-z]+|\d{1,3})\s*dino?n?\s*(?:ke\s*)?(baad|bad|me|mein|mai|main|andar|tak|pehle|pahle)\b/,
  );
  if (relDays) {
    const n = wordOrDigitCount(relDays[1]!);
    if (n != null && n > 0) {
      const backwards = /pehle|pahle/.test(relDays[2]!);
      const dt = backwards ? now.minus({ days: n }) : now.plus({ days: n });
      return { date: dt.startOf("day"), matched: "relative_days" };
    }
  }
  const afterDays = hint.match(/\b(?:in|within|after)\s+(\d{1,3})\s*days?\b/);
  if (afterDays) {
    const n = parseInt(afterDays[1]!, 10);
    if (n > 0) {
      return { date: now.plus({ days: n }).startOf("day"), matched: "relative_days" };
    }
  }
  const agoDays = hint.match(/\b(\d{1,3})\s*days?\s+ago\b/);
  if (agoDays) {
    const n = parseInt(agoDays[1]!, 10);
    if (n > 0) {
      return { date: now.minus({ days: n }).startOf("day"), matched: "relative_days" };
    }
  }

  // "agle hafte" / "is hafte" / "pichhle hafte" — never supported before.
  if (/\b(agle|agla|next)\s*(hafte|hafta|week)\b/.test(hint)) {
    return { date: now.plus({ weeks: 1 }).startOf("day"), matched: "next_week" };
  }
  if (/\b(pichhle|pichle|last)\s*(hafte|hafta|week)\b/.test(hint)) {
    return { date: now.minus({ weeks: 1 }).startOf("day"), matched: "last_week" };
  }
  if (/\b(is|isi|this)\s*(hafte|hafta|week)\b/.test(hint)) {
    return { date: now.startOf("day"), matched: "this_week" };
  }

  // "2 hafte me" / "do hafte baad" / "in 3 weeks" — the same shape as days.
  // Checked after "agle hafte" so that phrase keeps its own reading.
  const relWeeks = hint.match(
    /\b([a-z]+|\d{1,3})\s*(?:hafte|hafta|hafton|weeks?)\s*(?:ke\s*)?(baad|bad|me|mein|mai|main|andar|tak|pehle|pahle)\b/,
  );
  if (relWeeks) {
    const n = wordOrDigitCount(relWeeks[1]!);
    if (n != null && n > 0) {
      const backwards = /pehle|pahle/.test(relWeeks[2]!);
      const dt = backwards ? now.minus({ weeks: n }) : now.plus({ weeks: n });
      return { date: dt.startOf("day"), matched: "relative_weeks" };
    }
  }
  const afterWeeks = hint.match(/\b(?:in|within|after)\s+(\d{1,3})\s*weeks?\b/);
  if (afterWeeks) {
    const n = parseInt(afterWeeks[1]!, 10);
    if (n > 0) {
      return { date: now.plus({ weeks: n }).startOf("day"), matched: "relative_weeks" };
    }
  }

  // "agle mahine" / "pichhle mahine"
  if (/\b(agle|agla|next)\s*(mahine|mahina|month)\b/.test(hint)) {
    return { date: now.plus({ months: 1 }).startOf("day"), matched: "next_month" };
  }
  if (/\b(pichhle|pichle|last)\s*(mahine|mahina|month)\b/.test(hint)) {
    return { date: now.minus({ months: 1 }).startOf("day"), matched: "last_month" };
  }

  // Weekday names — Hindi ones are new.
  const allWeekdays = { ...ENGLISH_WEEKDAYS, ...HINDI_WEEKDAYS };
  for (const [word, weekday] of Object.entries(allWeekdays)) {
    if (!new RegExp(`\\b${word}\\b`).test(hint)) {
      continue;
    }
    const wantsLast = back || /\b(pichhle|pichle|last|gaye|gaya)\b/.test(hint);
    if (wantsLast) {
      let delta = (now.weekday - weekday + 7) % 7;
      if (delta === 0) delta = 7;
      return { date: now.minus({ days: delta }).startOf("day"), matched: "weekday" };
    }
    let delta = (weekday - now.weekday + 7) % 7;
    if (delta === 0) delta = 7;
    return { date: now.plus({ days: delta }).startOf("day"), matched: "weekday" };
  }

  // Explicit English directions first — these are never ambiguous.
  if (/\bday\s+before\s+yesterday\b/.test(hint)) {
    return { date: now.minus({ days: 2 }).startOf("day"), matched: "relative_word" };
  }
  if (/\bday\s+after\s+tomorrow\b/.test(hint)) {
    return { date: now.plus({ days: 2 }).startOf("day"), matched: "relative_word" };
  }
  if (/\byesterday\b/.test(hint)) {
    return { date: now.minus({ days: 1 }).startOf("day"), matched: "relative_word" };
  }
  if (/\btomorrow\b/.test(hint)) {
    return { date: now.plus({ days: 1 }).startOf("day"), matched: "relative_word" };
  }
  if (/\btoday\b/.test(hint)) {
    return { date: now.startOf("day"), matched: "relative_word" };
  }

  // Hindi relatives: direction comes from the tense.
  if (/\bnarso\b/.test(hint)) {
    const dt = back ? now.minus({ days: 3 }) : now.plus({ days: 3 });
    return { date: dt.startOf("day"), matched: "relative_word" };
  }
  if (/\bparso(?:n)?\b/.test(hint)) {
    const dt = back ? now.minus({ days: 2 }) : now.plus({ days: 2 });
    return { date: dt.startOf("day"), matched: "relative_word" };
  }
  if (/\bkal\b/.test(hint)) {
    const dt = back ? now.minus({ days: 1 }) : now.plus({ days: 1 });
    return { date: dt.startOf("day"), matched: "relative_word" };
  }
  if (/\b(aaj|abhi)\b/.test(hint)) {
    return { date: now.startOf("day"), matched: "relative_word" };
  }

  return null;
}

/** "Monday, 24 August, 11:00 AM" — spelled out so mistakes are obvious. */
export function formatWhenLabel(dt: DateTime, withTime: boolean): string {
  const weekday = WEEKDAY_LABELS[dt.weekday] ?? dt.weekdayLong ?? "";
  const datePart = dt.toFormat("d MMMM");
  if (!withTime) {
    return `${weekday}, ${datePart}`;
  }
  return `${weekday}, ${datePart}, ${dt.toFormat("h:mm a")}`;
}

/**
 * Resolves a spoken phrase into an instant. Returns nulls when the phrase
 * carries no date or time at all, so callers can ask instead of guessing.
 */
export function resolveWhen(input: ResolveWhenInput): ResolveWhenResult {
  const zone = input.timezone?.trim() || "Asia/Kolkata";
  const now = input.nowIso
    ? DateTime.fromISO(input.nowIso, { zone })
    : DateTime.now().setZone(zone);
  const base = now.isValid ? now : DateTime.now().setZone(zone);

  const hint = (input.phrase ?? "")
    .toLowerCase()
    .replace(/\s+/g, " ")
    .trim();

  const empty: ResolveWhenResult = {
    iso: null,
    epochMs: null,
    label: null,
    hasExplicitTime: false,
    matched: null,
  };
  if (!hint) {
    return empty;
  }

  const tense: WhenTense = input.tense === "past" ? "past" : "future";
  const period = input.period ?? readPeriod(hint);

  const day = readDay(hint, base, tense);
  const time = readTime(hint, period);

  if (!day && !time) {
    return empty;
  }

  const anchor = day ? day.date : base.startOf("day");
  const hour = time ? time.hour : (input.defaultHour ?? DEFAULT_HOUR);
  const minute = time ? time.minute : 0;

  let resolved = anchor.set({ hour, minute, second: 0, millisecond: 0 });

  // A time with no day means "the next time it is that o'clock" going forward,
  // or the most recent one when the sentence is in the past tense.
  if (!day) {
    if (tense === "future" && resolved <= base) {
      resolved = resolved.plus({ days: 1 });
    } else if (tense === "past" && resolved > base) {
      resolved = resolved.minus({ days: 1 });
    }
  }

  return {
    iso: resolved.toISO(),
    epochMs: resolved.toMillis(),
    label: formatWhenLabel(resolved, time != null),
    hasExplicitTime: time?.explicit ?? false,
    matched: day?.matched ?? "time_only",
  };
}
