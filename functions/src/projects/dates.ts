import { DateTime } from "luxon";

import type { ProjectClock } from "./types";

const WEEKDAYS: Record<string, number> = {
  sunday: 7,
  monday: 1,
  tuesday: 2,
  wednesday: 3,
  thursday: 4,
  friday: 5,
  saturday: 6,
  ravivar: 7,
  somvar: 1,
  mangalvar: 2,
  budhvar: 3,
  guruvar: 4,
  shukravar: 5,
  shanivar: 6,
  som: 1,
  mangal: 2,
  budh: 3,
  guru: 4,
  shukra: 5,
  shani: 6,
  ravi: 7,
};

export function clockToDateTime(clock: ProjectClock): DateTime {
  const zone = clock.timezone.trim() || "UTC";
  const zonedNow = DateTime.now().setZone(zone);
  const zoneName = zonedNow.isValid ? zone : "UTC";
  const iso = clock.nowIso.trim();
  if (iso) {
    const fromIso = DateTime.fromISO(iso, { setZone: true });
    if (fromIso.isValid) {
      const shifted = fromIso.setZone(zoneName);
      return shifted.isValid ? shifted : fromIso;
    }
  }
  const fallback = DateTime.now().setZone(zoneName);
  return fallback.isValid ? fallback : DateTime.utc();
}

function parseClockTime(raw: string): { hour: number; minute: number } | null {
  const t = raw.toLowerCase();
  const hm = t.match(/\b(\d{1,2})[:.](\d{2})\s*(am|pm|a\.m\.|p\.m\.)?\b/);
  if (hm) {
    let hour = Number(hm[1]);
    const minute = Number(hm[2]);
    const mer = (hm[3] ?? "").replace(/\./g, "");
    if (mer === "pm" && hour < 12) {
      hour += 12;
    }
    if (mer === "am" && hour === 12) {
      hour = 0;
    }
    if (hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59) {
      return { hour, minute };
    }
  }
  const ampm = t.match(/\b(\d{1,2})\s*(am|pm|a\.m\.|p\.m\.)\b/);
  if (ampm) {
    let hour = Number(ampm[1]);
    const mer = ampm[2].replace(/\./g, "");
    if (mer === "pm" && hour < 12) {
      hour += 12;
    }
    if (mer === "am" && hour === 12) {
      hour = 0;
    }
    return { hour, minute: 0 };
  }
  const baje = t.match(/\b(\d{1,2})\s*(baje|bje)\b/);
  if (baje) {
    let hour = Number(baje[1]);
    if (/\b(shaam|sham|evening|raat)\b/.test(t) && hour < 12) {
      hour += 12;
    }
    if (hour >= 0 && hour <= 23) {
      return { hour, minute: 0 };
    }
  }
  return null;
}

function nextWeekday(from: DateTime, weekday: number): DateTime {
  const current = from.weekday;
  let delta = weekday - current;
  if (delta <= 0) {
    delta += 7;
  }
  return from.plus({ days: delta }).startOf("day");
}

/**
 * Resolve a free-text due hint ("Monday tak", "5 tarikh", "kal 4pm") against [clock].
 * Default wall-clock is 11:00 when the user did not name a time (same as reminders).
 */
export function resolveDueHint(
  hint: string,
  clock: ProjectClock,
): { iso: string; ms: number; label: string } | null {
  const raw = hint.trim();
  if (!raw) {
    return null;
  }
  const now = clockToDateTime(clock);
  const lower = raw.toLowerCase();
  const time = parseClockTime(lower);
  const hour = time?.hour ?? 11;
  const minute = time?.minute ?? 0;

  let day: DateTime | null = null;

  if (/\b(aaj|today)\b/.test(lower)) {
    day = now.startOf("day");
  } else if (/\b(parso|parson|day after tomorrow)\b/.test(lower)) {
    day = now.plus({ days: 2 }).startOf("day");
  } else if (/\b(kal|tomorrow)\b/.test(lower)) {
    day = now.plus({ days: 1 }).startOf("day");
  }

  if (!day) {
    const wd = lower.match(
      /\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday|somvar|mangalvar|budhvar|guruvar|shukravar|shanivar|ravivar|som|mangal|budh|guru|shukra|shani|ravi)\b/,
    );
    if (wd) {
      const n = WEEKDAYS[wd[1]];
      if (n) {
        day = nextWeekday(now, n);
      }
    }
  }

  if (!day) {
    const tarikh = lower.match(/\b(\d{1,2})\s*(tarikh|tareekh|th|date)\b/);
    if (tarikh) {
      const d = Number(tarikh[1]);
      if (d >= 1 && d <= 31) {
        let candidate = now.set({ day: d }).startOf("day");
        if (!candidate.isValid || candidate < now.startOf("day")) {
          candidate = now.plus({ months: 1 }).set({ day: d }).startOf("day");
        }
        if (candidate.isValid) {
          day = candidate;
        }
      }
    }
  }

  if (!day) {
    const dmy = lower.match(/\b(\d{1,2})[\/.\-](\d{1,2})(?:[\/.\-](\d{2,4}))?\b/);
    if (dmy) {
      const dd = Number(dmy[1]);
      const mm = Number(dmy[2]);
      let yyyy = dmy[3] ? Number(dmy[3]) : now.year;
      if (yyyy < 100) {
        yyyy += 2000;
      }
      const candidate = DateTime.fromObject(
        { year: yyyy, month: mm, day: dd },
        { zone: now.zoneName ?? "UTC" },
      );
      if (candidate.isValid) {
        day = candidate.startOf("day");
      }
    }
  }

  if (!day) {
    const isoTry = DateTime.fromISO(raw, { setZone: true });
    if (isoTry.isValid) {
      const zoned = isoTry.setZone(now.zoneName ?? "UTC");
      return {
        iso: zoned.toISO() ?? isoTry.toISO() ?? raw,
        ms: zoned.toMillis(),
        label: zoned.toFormat("d MMM, h:mm a"),
      };
    }
    return null;
  }

  const when = day.set({ hour, minute, second: 0, millisecond: 0 });
  if (!when.isValid) {
    return null;
  }
  return {
    iso: when.toISO() ?? "",
    ms: when.toMillis(),
    label: when.toFormat("d MMM, h:mm a"),
  };
}

export function startOfLocalDayMs(clock: ProjectClock): number {
  return clockToDateTime(clock).startOf("day").toMillis();
}

export function startOfNextLocalDayMs(clock: ProjectClock): number {
  return clockToDateTime(clock).plus({ days: 1 }).startOf("day").toMillis();
}
