import 'package:intl/intl.dart';

import '../../chat/models/aivy_ai_response.dart';

/// Calendar day + clock from the controlled reminder flow **date** step
/// (supports combined phrases like "kal 5pm", "10 din baad 4 baje").
class ReminderDateStepParse {
  const ReminderDateStepParse({
    required this.dateMs,
    required this.timeMinutes,
  });

  final int dateMs;
  final int timeMinutes;
}

class ReminderTimeParser {
  /// Local display for assistant copy, e.g. "21 Apr, 1:00 PM".
  static String formatReminderTime(DateTime time) {
    final loc = time.toLocal();
    return DateFormat('d MMM, h:mm a').format(loc);
  }

  static DateTime? resolveScheduledTime(
    ReminderSuggestion suggestion, {
    DateTime? reference,
  }) {
    final now = reference ?? DateTime.now();
    final fromIso = _parseIsoDate(suggestion.scheduledAtIso);
    if (fromIso != null) {
      return fromIso;
    }

    final fromHint = _parseFromHint(suggestion.timeHint, reference: now);
    if (fromHint != null) {
      return fromHint;
    }

    return null;
  }

  static DateTime? _parseIsoDate(String? value) {
    final iso = value?.trim() ?? '';
    if (iso.isEmpty) {
      return null;
    }

    final parsed = DateTime.tryParse(iso);
    return parsed?.toLocal();
  }

  static DateTime? _parseFromHint(
    String rawHint, {
    required DateTime reference,
  }) {
    final hint = rawHint.trim().toLowerCase();
    if (hint.isEmpty) {
      return null;
    }

    final relativeDuration = _parseRelativeDuration(hint);
    if (relativeDuration != null) {
      return reference.add(relativeDuration);
    }

    final date = _parseDate(hint, reference: reference, rawHint: rawHint.trim());
    final time = _parseTime(hint);
    if (date == null && time == null) {
      return null;
    }

    final anchor =
        date ?? DateTime(reference.year, reference.month, reference.day);
    final hour = time?.hour ?? 11;
    final minute = time?.minute ?? 0;
    var candidate = DateTime(
      anchor.year,
      anchor.month,
      anchor.day,
      hour,
      minute,
    );

    // Rule: if the target is today (either by "today" keyword or by the
    // absence of any date word) and the exact time has already passed in
    // the local clock, roll the reminder forward by exactly one day
    // instead of silently landing in the past. We do NOT shift to the
    // next morning or another arbitrary hour — the user's chosen time is
    // preserved, only the calendar day moves.
    final anchorIsToday =
        anchor.year == reference.year &&
        anchor.month == reference.month &&
        anchor.day == reference.day;
    final explicitlyOtherDay = date != null && !anchorIsToday;
    if (!explicitlyOtherDay &&
        candidate.isBefore(reference.add(const Duration(minutes: 1)))) {
      candidate = candidate.add(const Duration(days: 1));
    }

    return candidate;
  }

  static Duration? _parseRelativeDuration(String hint) {
    final relativePattern = RegExp(
      r'in\s+(\d+)\s*(minute|minutes|hour|hours|day|days)\b',
      caseSensitive: false,
    );
    final match = relativePattern.firstMatch(hint);
    if (match == null) {
      return null;
    }

    final value = int.tryParse(match.group(1) ?? '');
    final unit = match.group(2)?.toLowerCase() ?? '';
    if (value == null || value <= 0) {
      return null;
    }

    if (unit.startsWith('minute')) {
      return Duration(minutes: value);
    }
    if (unit.startsWith('hour')) {
      return Duration(hours: value);
    }
    return Duration(days: value);
  }

  /// Shared dd/mm(/yy) resolution for embedded dates in a longer hint.
  static DateTime? _dateFromSlashGroups(
    String? a,
    String? b,
    String? c, {
    required DateTime reference,
  }) {
    final aInt = int.tryParse(a ?? '');
    final bInt = int.tryParse(b ?? '');
    final cRaw = c ?? '';
    var cInt = int.tryParse(cRaw);
    if (aInt == null || bInt == null || cInt == null) {
      return null;
    }
    var year = cInt;
    if (cRaw.length <= 2) {
      year = 2000 + cInt;
    }
    int day;
    int month;
    if (aInt > 12) {
      day = aInt;
      month = bInt;
    } else if (bInt > 12) {
      month = aInt;
      day = bInt;
    } else {
      day = aInt;
      month = bInt;
    }
    if (month < 1 || month > 12 || day < 1 || day > 31) {
      return null;
    }
    try {
      return DateTime(year, month, day);
    } catch (_) {
      return null;
    }
  }

  static DateTime? _parseDate(
    String hint, {
    required DateTime reference,
    String? rawHint,
  }) {
    final raw = rawHint ?? hint;

    if (RegExp(r'आज', unicode: true).hasMatch(raw) ||
        RegExp(r'\b(aaj|today)\b', caseSensitive: false).hasMatch(hint)) {
      return DateTime(reference.year, reference.month, reference.day);
    }
    if (RegExp(r'कल(?!\u093e)', unicode: true).hasMatch(raw) ||
        RegExp(r'\b(kal|tomorrow)\b', caseSensitive: false).hasMatch(hint)) {
      final tomorrow = reference.add(const Duration(days: 1));
      return DateTime(tomorrow.year, tomorrow.month, tomorrow.day);
    }
    if (RegExp(r'परसों|परसो', unicode: true).hasMatch(raw) ||
        RegExp(r'\b(parso|day\s+after\s+tomorrow)\b', caseSensitive: false)
            .hasMatch(hint)) {
      final dayAfterTomorrow = reference.add(const Duration(days: 2));
      return DateTime(
        dayAfterTomorrow.year,
        dayAfterTomorrow.month,
        dayAfterTomorrow.day,
      );
    }

    final slashAny = RegExp(
      r'(?<![0-9])(\d{1,4})[/\-.](\d{1,2})[/\-.](\d{2,4})(?![0-9])',
    ).firstMatch(hint);
    if (slashAny != null) {
      final parsed = _dateFromSlashGroups(
        slashAny.group(1),
        slashAny.group(2),
        slashAny.group(3),
        reference: reference,
      );
      if (parsed != null) {
        return parsed;
      }
    }

    if (hint.contains('today')) {
      return DateTime(reference.year, reference.month, reference.day);
    }

    if (hint.contains('tomorrow')) {
      final tomorrow = reference.add(const Duration(days: 1));
      return DateTime(tomorrow.year, tomorrow.month, tomorrow.day);
    }

    final isoDatePattern = RegExp(r'\b(\d{4})-(\d{2})-(\d{2})\b');
    final isoDateMatch = isoDatePattern.firstMatch(hint);
    if (isoDateMatch != null) {
      final year = int.tryParse(isoDateMatch.group(1) ?? '');
      final month = int.tryParse(isoDateMatch.group(2) ?? '');
      final day = int.tryParse(isoDateMatch.group(3) ?? '');
      if (year != null && month != null && day != null) {
        return DateTime(year, month, day);
      }
    }

    final monthMap = <String, int>{
      'jan': 1,
      'january': 1,
      'feb': 2,
      'february': 2,
      'mar': 3,
      'march': 3,
      'apr': 4,
      'april': 4,
      'may': 5,
      'jun': 6,
      'june': 6,
      'jul': 7,
      'july': 7,
      'aug': 8,
      'august': 8,
      'sep': 9,
      'sept': 9,
      'september': 9,
      'oct': 10,
      'october': 10,
      'nov': 11,
      'november': 11,
      'dec': 12,
      'december': 12,
    };
    final monthDate = RegExp(
      r'\b(\d{1,2})(?:st|nd|rd|th)?\s+([a-zA-Z]{3,9})(?:\s+(\d{4}))?\b',
      caseSensitive: false,
    ).firstMatch(hint);
    if (monthDate != null) {
      final day = int.tryParse(monthDate.group(1) ?? '');
      final monthToken = (monthDate.group(2) ?? '').toLowerCase();
      final year = int.tryParse(monthDate.group(3) ?? '') ?? reference.year;
      final month = monthMap[monthToken];
      if (day != null && month != null) {
        return DateTime(year, month, day);
      }
    }

    final weekdays = <String, int>{
      'monday': DateTime.monday,
      'tuesday': DateTime.tuesday,
      'wednesday': DateTime.wednesday,
      'thursday': DateTime.thursday,
      'friday': DateTime.friday,
      'saturday': DateTime.saturday,
      'sunday': DateTime.sunday,
    };

    for (final entry in weekdays.entries) {
      if (hint.contains(entry.key)) {
        final delta = (entry.value - reference.weekday + 7) % 7;
        final dayDelta = delta == 0 ? 7 : delta;
        final target = reference.add(Duration(days: dayDelta));
        return DateTime(target.year, target.month, target.day);
      }
    }

    return null;
  }

  /// Calendar day only for the reminder **date** step (no clock required).
  /// Handles `aaj` / `kal` etc. Unlike [resolveScheduledTimeFromPlainText],
  /// never returns null for plain `aaj` — that method intentionally returns
  /// null when only "aaj" is given (same-day nudge).
  static DateTime? resolveDateDayForReminderFlow(
    String raw, {
    DateTime? reference,
  }) {
    final ref = reference ?? DateTime.now();
    final hint = raw.trim().toLowerCase();
    if (hint.isEmpty) {
      return null;
    }
    final d = _parseDateFromUserPlainText(hint, reference: ref);
    if (d != null) {
      return DateTime(d.year, d.month, d.day);
    }
    final rel = _parseHindiRelativeDays(hint, reference: ref);
    if (rel != null) {
      return DateTime(rel.year, rel.month, rel.day);
    }
    final eng = _parseEnglishAfterDaysHint(hint, reference: ref);
    if (eng != null) {
      return DateTime(eng.year, eng.month, eng.day);
    }
    final slashed = _tryParseSlashedDate(hint, reference: ref);
    if (slashed != null) {
      return DateTime(slashed.year, slashed.month, slashed.day);
    }
    return null;
  }

  static DateTime? _tryParseSlashedDate(
    String hint, {
    required DateTime reference,
  }) {
    final m = RegExp(r'^(\d{1,4})[/\-.](\d{1,2})[/\-.](\d{2,4})$')
        .firstMatch(hint.trim());
    if (m == null) {
      return null;
    }
    return _dateFromSlashGroups(
      m.group(1),
      m.group(2),
      m.group(3),
      reference: reference,
    );
  }

  /// Parses a local [DateTime] from free-form chat text for client-side
  /// reminder routing (e.g. "tomorrow 1pm", "aaj 3pm", "kal 10am").
  ///
  /// When no date phrase is found, the calendar day defaults to today; when
  /// no clock is found, time defaults to 11:00. Same "roll past times to
  /// tomorrow" rule as [_parseFromHint] when the anchor day is implicit.
  static DateTime? resolveScheduledTimeFromPlainText(
    String raw, {
    DateTime? reference,
  }) {
    final ref = reference ?? DateTime.now();
    final hint = raw.trim().toLowerCase();
    final fromEnglishAfterDays =
        _parseEnglishAfterDaysHint(hint, reference: ref);
    if (fromEnglishAfterDays != null) {
      return fromEnglishAfterDays;
    }
    final fromRelativeDays = _parseHindiRelativeDays(hint, reference: ref);
    if (fromRelativeDays != null) {
      return fromRelativeDays;
    }
    final date = _parseDateFromUserPlainText(hint, reference: ref);
    final anchor = date ?? DateTime(ref.year, ref.month, ref.day);
    final time = _parseTimeForPlainText(
      hint,
      reference: ref,
      anchor: anchor,
    );
    final ambiguousBajeHour = _parseAmbiguousHindiBajeHour(hint);
    final ambiguousDotTime = _parseAmbiguousDotTime(hint);

    // "Aaj" / "today" with no clock: nudge to ~1h from now on the same day so we
    // do not default to 09:00 (already passed → roll to tomorrow in old logic).
    final wantsSameDayNudge = time == null &&
        (RegExp(r'\baaj\b').hasMatch(hint) || RegExp(r'\btoday\b').hasMatch(hint));
    late int hour;
    late int minute;
    if (time != null) {
      hour = time.hour;
      minute = time.minute;
      if (ambiguousBajeHour != null) {
        final resolved = _resolveAmbiguous12HourTime(
          rawHour: ambiguousBajeHour,
          rawMinute: 0,
          reference: ref,
          anchor: anchor,
          preferPmForFutureDay: true,
        );
        hour = resolved.hour;
        minute = resolved.minute;
      } else if (ambiguousDotTime != null) {
        final resolved = _resolveAmbiguous12HourTime(
          rawHour: ambiguousDotTime.hour,
          rawMinute: ambiguousDotTime.minute,
          reference: ref,
          anchor: anchor,
          preferPmForFutureDay: true,
        );
        hour = resolved.hour;
        minute = resolved.minute;
      }
    } else if (wantsSameDayNudge) {
      return null;
    } else {
      hour = 11;
      minute = 0;
    }
    var candidate = DateTime(anchor.year, anchor.month, anchor.day, hour, minute);

    final anchorIsToday =
        anchor.year == ref.year &&
        anchor.month == ref.month &&
        anchor.day == ref.day;
    final explicitlyOtherDay = date != null && !anchorIsToday;
    if (!explicitlyOtherDay &&
        !wantsSameDayNudge &&
        candidate.isBefore(ref.add(const Duration(minutes: 1)))) {
      candidate = candidate.add(const Duration(days: 1));
    }
    if (wantsSameDayNudge && candidate.isBefore(ref)) {
      candidate = ref.add(const Duration(minutes: 2));
    }

    return candidate;
  }

  /// Combines [_parseTime] with Hindi day-word + bare hour ("kal 10") and
  /// keyword periods ("kal subah" handled elsewhere via default hour).
  static _TimeOfDayValue? _parseTimeForPlainText(
    String hint, {
    required DateTime reference,
    required DateTime anchor,
  }) {
    final t = _parseTime(hint);
    if (t != null) {
      return t;
    }
    final low = hint.trim().toLowerCase();

    final bareDayHour = RegExp(
      r'\b(?:kal|aaj|parso|tomorrow|today)\s+(\d{1,2})\b',
    ).firstMatch(low);
    if (bareDayHour != null &&
        !RegExp(r'\b\d{1,2}\s*baje\b').hasMatch(low) &&
        !RegExp(
          r'\b\d{1,2}(?::[0-5]\d)?\s*(am|pm)\b',
          caseSensitive: false,
        ).hasMatch(low)) {
      final h = int.tryParse(bareDayHour.group(1) ?? '');
      if (h != null && h >= 1 && h <= 23) {
        // Informal "kal 10" → 10:00 (morning-first), "kal 15" → 15:00.
        return _TimeOfDayValue(hour: h, minute: 0);
      }
    }

    final subahHour =
        RegExp(r'\b(?:subah|sabah|morning)\s+(\d{1,2})\b').firstMatch(low);
    if (subahHour != null) {
      final h = int.tryParse(subahHour.group(1) ?? '');
      if (h != null && h >= 1 && h <= 23) {
        return _TimeOfDayValue(hour: h.clamp(0, 23), minute: 0);
      }
    }

    if (RegExp(r'\b(subah|sabah|morning)\b').hasMatch(low)) {
      return const _TimeOfDayValue(hour: 9, minute: 0);
    }

    return null;
  }

  /// "after 2 days", "yes after 3 days" — date only at 11:00 (same as Hindi din).
  static DateTime? _parseEnglishAfterDaysHint(
    String hint, {
    required DateTime reference,
  }) {
    final m = RegExp(
      r'\bafter\s+(\d+)\s*days?\b',
      caseSensitive: false,
    ).firstMatch(hint);
    if (m == null) {
      return null;
    }
    final days = int.tryParse(m.group(1) ?? '');
    if (days == null || days <= 0) {
      return null;
    }
    final target = reference.add(Duration(days: days));
    return DateTime(target.year, target.month, target.day, 11, 0);
  }

  /// "2 din baad", "do din ke baad" — date only; time defaults below.
  static DateTime? _parseHindiRelativeDays(
    String hint, {
    required DateTime reference,
  }) {
    final wordNums = <String, int>{
      'ek': 1,
      'one': 1,
      'do': 2,
      'two': 2,
      'teen': 3,
      'char': 4,
      'chaar': 4,
      'paanch': 5,
    };
    final m = RegExp(
      r'\b(\d+|ek|do|teen|char|chaar|paanch|one|two)\s*din\s*(ke\s+baad|baad)?\b',
    ).firstMatch(hint);
    if (m == null) {
      return null;
    }
    final rawN = m.group(1) ?? '';
    var days = int.tryParse(rawN);
    days ??= wordNums[rawN.toLowerCase()];
    if (days == null || days <= 0) {
      return null;
    }
    final target = reference.add(Duration(days: days));
    return DateTime(target.year, target.month, target.day, 11, 0);
  }

  static DateTime? _parseDateFromUserPlainText(
    String hint, {
    required DateTime reference,
  }) {
    if (RegExp(r'\bnext\s+week\b').hasMatch(hint)) {
      final t = reference.add(const Duration(days: 7));
      return DateTime(t.year, t.month, t.day);
    }
    if (RegExp(r'\baaj\b').hasMatch(hint)) {
      return DateTime(reference.year, reference.month, reference.day);
    }
    if (RegExp(r'\btoday\b').hasMatch(hint)) {
      return DateTime(reference.year, reference.month, reference.day);
    }
    if (RegExp(r'\b(yesterday)\b').hasMatch(hint)) {
      final t = reference.subtract(const Duration(days: 1));
      return DateTime(t.year, t.month, t.day);
    }
    if (RegExp(r'\bkal\b').hasMatch(hint)) {
      final t = reference.add(const Duration(days: 1));
      return DateTime(t.year, t.month, t.day);
    }
    if (RegExp(r'\bparso\b').hasMatch(hint)) {
      final t = reference.add(const Duration(days: 2));
      return DateTime(t.year, t.month, t.day);
    }
    return _parseDate(hint, reference: reference);
  }

  static _TimeOfDayValue _resolveAmbiguous12HourTime({
    required int rawHour,
    required int rawMinute,
    required DateTime reference,
    required DateTime anchor,
    bool preferPmForFutureDay = false,
  }) {
    if (rawHour <= 0 || rawHour > 12) {
      return _TimeOfDayValue(hour: rawHour.clamp(0, 23), minute: rawMinute);
    }
    if (rawHour == 12) {
      return _TimeOfDayValue(hour: 12, minute: rawMinute);
    }
    final anchorIsToday =
        anchor.year == reference.year &&
        anchor.month == reference.month &&
        anchor.day == reference.day;
    if (!anchorIsToday) {
      if (preferPmForFutureDay) {
        return _TimeOfDayValue(hour: rawHour + 12, minute: rawMinute);
      }
      return _TimeOfDayValue(hour: rawHour, minute: rawMinute);
    }
    final amCandidate = DateTime(
      anchor.year,
      anchor.month,
      anchor.day,
      rawHour,
      rawMinute,
    );
    final pmCandidate = DateTime(
      anchor.year,
      anchor.month,
      anchor.day,
      rawHour + 12,
      rawMinute,
    );
    final nowFloor = reference.add(const Duration(minutes: 1));
    final candidates = <DateTime>[
      if (!amCandidate.isBefore(nowFloor)) amCandidate,
      if (!pmCandidate.isBefore(nowFloor)) pmCandidate,
    ]..sort((a, b) => a.compareTo(b));
    if (candidates.isNotEmpty) {
      final first = candidates.first;
      return _TimeOfDayValue(hour: first.hour, minute: first.minute);
    }
    return _TimeOfDayValue(hour: rawHour + 12, minute: rawMinute);
  }

  static int? _parseAmbiguousHindiBajeHour(String hint) {
    final hasAmPm = RegExp(
      r'\b\d{1,2}(?::[0-5]\d)?\s*(am|pm)\b',
      caseSensitive: false,
    ).hasMatch(hint);
    final has24 = RegExp(r'\b([01]?\d|2[0-3]):([0-5]\d)\b').hasMatch(hint);
    if (hasAmPm || has24) {
      return null;
    }
    final bajeMatch = RegExp(r'\b(\d{1,2})\s*baje\b').firstMatch(hint);
    if (bajeMatch == null) {
      return null;
    }
    final hasExplicitPeriod = RegExp(
      r'\b(subah|sabah|morning|shaam|sham|evening|sandhya|raat|night)\b',
    ).hasMatch(hint);
    if (hasExplicitPeriod) {
      return null;
    }
    return int.tryParse(bajeMatch.group(1) ?? '');
  }

  static _TimeOfDayValue? _parseAmbiguousDotTime(String hint) {
    final hasAmPm = RegExp(
      r'\b\d{1,2}[.]\d{2}\s*(am|pm)\b',
      caseSensitive: false,
    ).hasMatch(hint);
    if (hasAmPm) {
      return null;
    }
    final dot = RegExp(r'\b(\d{1,2})[.](\d{2})\b').firstMatch(hint);
    if (dot == null) {
      return null;
    }
    final hasExplicitPeriod = RegExp(
      r'\b(subah|sabah|morning|shaam|sham|evening|sandhya|raat|night)\b',
    ).hasMatch(hint);
    if (hasExplicitPeriod) {
      return null;
    }
    final hour = int.tryParse(dot.group(1) ?? '');
    final minute = int.tryParse(dot.group(2) ?? '');
    if (hour == null || minute == null || hour <= 0 || hour > 12) {
      return null;
    }
    if (minute < 0 || minute > 59) {
      return null;
    }
    return _TimeOfDayValue(hour: hour, minute: minute);
  }

  static _TimeOfDayValue? _parseTime(String hint) {
    final amPmPattern = RegExp(
      r'\b(\d{1,2})(?:(?::|\.)([0-5]\d))?\s*(am|pm)\b',
      caseSensitive: false,
    );
    final amPmMatch = amPmPattern.firstMatch(hint);
    if (amPmMatch != null) {
      var hour = int.tryParse(amPmMatch.group(1) ?? '');
      final minute = int.tryParse(amPmMatch.group(2) ?? '0');
      final period = (amPmMatch.group(3) ?? '').toLowerCase();
      if (hour != null && minute != null) {
        if (period == 'pm' && hour < 12) {
          hour += 12;
        }
        if (period == 'am' && hour == 12) {
          hour = 0;
        }
        return _TimeOfDayValue(hour: hour, minute: minute);
      }
    }

    final twentyFourPattern = RegExp(r'\b([01]?\d|2[0-3]):([0-5]\d)\b');
    final twentyFourMatch = twentyFourPattern.firstMatch(hint);
    if (twentyFourMatch != null) {
      final hour = int.tryParse(twentyFourMatch.group(1) ?? '');
      final minute = int.tryParse(twentyFourMatch.group(2) ?? '');
      if (hour != null && minute != null) {
        return _TimeOfDayValue(hour: hour, minute: minute);
      }
    }

    final dotTimePattern = RegExp(r'\b(\d{1,2})[.](\d{2})\b');
    final dotTimeMatch = dotTimePattern.firstMatch(hint);
    if (dotTimeMatch != null) {
      var hour = int.tryParse(dotTimeMatch.group(1) ?? '');
      final minute = int.tryParse(dotTimeMatch.group(2) ?? '');
      if (hour != null &&
          minute != null &&
          hour >= 0 &&
          hour <= 23 &&
          minute >= 0 &&
          minute <= 59) {
        hour = _applyDayPeriodHintToHour(hour, hint);
        return _TimeOfDayValue(hour: hour, minute: minute);
      }
    }

    final bajeMatch = RegExp(r'\b(\d{1,2})\s*baje\b').firstMatch(hint);
    if (bajeMatch != null) {
      var hour = int.tryParse(bajeMatch.group(1) ?? '');
      if (hour != null && hour >= 0 && hour <= 23) {
        final isSubah = RegExp(
          r'\b(subah|sabah|morning)\b',
        ).hasMatch(hint);
        final isShaam = RegExp(
          r'\b(shaam|sham|evening|sandhya|raat|night)\b',
        ).hasMatch(hint);
        if (hour >= 1 && hour <= 11) {
          if (isShaam && !isSubah) {
            hour += 12;
          } else if (RegExp(r'\braat\b').hasMatch(hint) && hour < 12) {
            hour += 12;
          }
        }
        if (hour == 12 && isSubah && !isShaam) {
          hour = 12;
        }
        return _TimeOfDayValue(hour: hour.clamp(0, 23), minute: 0);
      }
    }

    if (RegExp(r'\b(shaam|sham|evening)\b').hasMatch(hint) &&
        !RegExp(r'\b(\d{1,2})\s*baje\b').hasMatch(hint) &&
        !RegExp(r'\b\d{1,2}(?::[0-5]\d)?\s*(am|pm)\b', caseSensitive: false)
            .hasMatch(hint) &&
        !twentyFourPattern.hasMatch(hint)) {
      return const _TimeOfDayValue(hour: 18, minute: 0);
    }

    return null;
  }

  static DateTime? _hindiRelativeDaysDateOnly(
    String hint, {
    required DateTime reference,
  }) {
    final full = _parseHindiRelativeDays(hint, reference: reference);
    if (full == null) {
      return null;
    }
    return DateTime(full.year, full.month, full.day);
  }

  static DateTime? _englishAfterDaysDateOnly(
    String hint, {
    required DateTime reference,
  }) {
    final full = _parseEnglishAfterDaysHint(hint, reference: reference);
    if (full == null) {
      return null;
    }
    return DateTime(full.year, full.month, full.day);
  }

  /// True when the user clearly included a clock (baje, am/pm, HH:mm, etc.).
  static bool hasExplicitTimeInReminderPhrase(String low) {
    if (RegExp(r'\b\d{1,2}\s*baje\b').hasMatch(low)) {
      return true;
    }
    if (RegExp(
      r'\b\d{1,2}(?::[0-5]\d)?\s*(am|pm)\b',
      caseSensitive: false,
    ).hasMatch(low)) {
      return true;
    }
    if (RegExp(r'\b([01]?\d|2[0-3]):[0-5]\d\b').hasMatch(low)) {
      return true;
    }
    if (RegExp(r'\b\d{1,2}[.]([0-5]\d)\b').hasMatch(low)) {
      return true;
    }
    return false;
  }

  static int? tryParseExplicitTimeMinutesFromPhrase(String raw) {
    final low = raw.trim().toLowerCase();
    if (!hasExplicitTimeInReminderPhrase(low)) {
      return null;
    }
    final t = _parseTime(low);
    return t != null ? t.hour * 60 + t.minute : null;
  }

  /// Date step for controlled flow: reads calendar day + optional time;
  /// date-only phrases default to 11:00 AM.
  static ReminderDateStepParse? parseReminderDateStepAnswer(
    String raw, {
    DateTime? reference,
  }) {
    final ref = reference ?? DateTime.now();
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final low = trimmed.toLowerCase();

    var day = resolveDateDayForReminderFlow(trimmed, reference: ref);
    day ??= _hindiRelativeDaysDateOnly(low, reference: ref);
    day ??= _englishAfterDaysDateOnly(low, reference: ref);

    final wantsClock = hasExplicitTimeInReminderPhrase(low);
    final explicitMin = wantsClock
        ? tryParseExplicitTimeMinutesFromPhrase(trimmed)
        : null;

    if (day != null) {
      if (wantsClock && explicitMin == null) {
        return null;
      }
      return ReminderDateStepParse(
        dateMs: day.millisecondsSinceEpoch,
        timeMinutes: explicitMin ?? 11 * 60,
      );
    }

    final sched = resolveScheduledTimeFromPlainText(trimmed, reference: ref);
    if (sched != null) {
      final d = DateTime(sched.year, sched.month, sched.day);
      return ReminderDateStepParse(
        dateMs: d.millisecondsSinceEpoch,
        timeMinutes: sched.hour * 60 + sched.minute,
      );
    }
    return null;
  }

  /// Standalone "time" step (after date is chosen). Returns minutes 0..1439.
  /// "skip" / "default" → 11:00.
  static int? tryParseTimeMinutesForFlowStep(String raw) {
    final s = raw.trim();
    if (s.isEmpty) {
      return null;
    }
    final low = s.toLowerCase();
    if (RegExp(
      r'^(skip|default|ok|theek|bas|same)\b',
      caseSensitive: false,
    ).hasMatch(low)) {
      return 11 * 60;
    }
    if (RegExp(r'^(subah|sabah|morning)$', caseSensitive: false).hasMatch(low)) {
      return 9 * 60;
    }
    if (RegExp(r'^(shaam|sham|evening)$', caseSensitive: false).hasMatch(low)) {
      return 18 * 60;
    }
    final loneHour = RegExp(r'^(\d{1,2})$').firstMatch(low);
    if (loneHour != null) {
      final h = int.tryParse(loneHour.group(1) ?? '');
      if (h != null && h >= 1 && h <= 23) {
        return h * 60;
      }
    }
    final t = _parseTime(low);
    if (t != null) {
      return t.hour * 60 + t.minute;
    }
    return null;
  }

  static int _applyDayPeriodHintToHour(int hour, String hint) {
    if (hour < 0 || hour > 23) {
      return hour.clamp(0, 23);
    }
    final isSubah = RegExp(
      r'\b(subah|sabah|morning)\b',
    ).hasMatch(hint);
    final isShaam = RegExp(
      r'\b(shaam|sham|evening|sandhya|raat|night)\b',
    ).hasMatch(hint);
    if (hour >= 1 && hour <= 11) {
      if (isShaam && !isSubah) {
        return hour + 12;
      }
      if (RegExp(r'\braat\b').hasMatch(hint)) {
        return hour + 12;
      }
    }
    return hour;
  }
}

class _TimeOfDayValue {
  const _TimeOfDayValue({required this.hour, required this.minute});

  final int hour;
  final int minute;
}
