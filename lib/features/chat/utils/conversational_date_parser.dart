// Centralized calendar-day parsing for chat-first UX (payment receive, etc.).
// Does not set clock time — date only, local calendar day.

import '../../reminders/utils/reminder_time_parser.dart';

const _kExamplesHint =
    'Date samajh nahi aayi. Example:\naaj / kal / parso / 5 May / 02/05/2026';

String get conversationalDateParseExamplesMessage => _kExamplesHint;

/// Maps fullwidth Latin letters/digits (e.g. ＡＡＪ) to ASCII so word-boundary
/// regexes in the Hindi/English date stack match chat / IME input.
String normalizeLatinHomoglyphsForDateInput(String raw) {
  const fwA = 0xFF21; // Ａ
  const fwZ = 0xFF3A;
  const fwa = 0xFF41; // ａ
  const fwz = 0xFF5A;
  const fw0 = 0xFF10;
  const fw9 = 0xFF19;
  final sb = StringBuffer();
  for (final r in raw.runes) {
    if (r >= fwA && r <= fwZ) {
      sb.writeCharCode(r - 0xFEE0);
    } else if (r >= fwa && r <= fwz) {
      sb.writeCharCode(r - 0xFEE0);
    } else if (r >= fw0 && r <= fw9) {
      sb.writeCharCode(r - 0xFEE0);
    } else {
      sb.writeCharCode(r);
    }
  }
  return sb.toString();
}

/// Parse a single conversational date from user chat input.
///
/// Supports Hindi + English relatives, named months, common numeric formats,
/// and strips trailing particles like "ka" ("kal ka").
DateTime? parseConversationalDate(
  String raw, {
  DateTime? reference,
}) {
  final ref = reference ?? DateTime.now();
  final trimmed = normalizeLatinHomoglyphsForDateInput(raw).trim();
  if (trimmed.isEmpty) {
    return DateTime(ref.year, ref.month, ref.day);
  }

  var hint = trimmed.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  hint = hint.replaceAll(RegExp(r'\s+ka$'), '');
  hint = hint.replaceAll(RegExp(r'\s+ki$'), '');
  hint = hint.trim();
  if (hint.isEmpty) {
    return DateTime(ref.year, ref.month, ref.day);
  }

  if (RegExp(r'\b(yesterday)\b').hasMatch(hint)) {
    final t = ref.subtract(const Duration(days: 1));
    return DateTime(t.year, t.month, t.day);
  }

  final n = _tryParseNumericSlashedOrDashedDate(hint, reference: ref);
  if (n != null) {
    return n;
  }

  final mf = _tryParseMonthNameFirst(hint, reference: ref);
  if (mf != null) {
    return mf;
  }

  final dm = _tryParseDayThenMonthName(hint, reference: ref);
  if (dm != null) {
    return dm;
  }

  return ReminderTimeParser.resolveDateDayForReminderFlow(hint, reference: ref);
}

DateTime? _tryParseDayThenMonthName(
  String hint, {
  required DateTime reference,
}) {
  final m = RegExp(
    r'^(\d{1,2})(?:st|nd|rd|th)?\s+([a-z]{3,9})(?:\s+(\d{4}))?$',
    caseSensitive: false,
  ).firstMatch(hint);
  if (m == null) {
    return null;
  }
  final day = int.tryParse(m.group(1) ?? '');
  final monthTok = (m.group(2) ?? '').toLowerCase();
  final month = _monthNumber(monthTok);
  final yStr = m.group(3);
  final year = int.tryParse(yStr ?? '') ?? reference.year;
  if (day == null || month == null) {
    return null;
  }
  if (day < 1 || day > 31) {
    return null;
  }
  try {
    return DateTime(year, month, day);
  } catch (_) {
    return null;
  }
}

DateTime? _tryParseNumericSlashedOrDashedDate(
  String hint, {
  required DateTime reference,
}) {
  final m = RegExp(r'^(\d{1,4})[/\-.](\d{1,2})[/\-.](\d{2,4})$').firstMatch(hint);
  if (m == null) {
    return null;
  }
  final a = int.tryParse(m.group(1) ?? '');
  final b = int.tryParse(m.group(2) ?? '');
  final cRaw = m.group(3) ?? '';
  var c = int.tryParse(cRaw);
  if (a == null || b == null || c == null) {
    return null;
  }

  var year = c;
  if (cRaw.length <= 2) {
    year = 2000 + c;
    if (year > reference.year + 80) {
      year -= 100;
    }
  }

  int day;
  int month;
  if (a > 12) {
    day = a;
    month = b;
  } else if (b > 12) {
    month = a;
    day = b;
  } else {
    // DD/MM/YYYY (India-first when ambiguous)
    day = a;
    month = b;
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

int? _monthNumber(String token) {
  final t = token.toLowerCase();
  const map = <String, int>{
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
  return map[t];
}

DateTime? _tryParseMonthNameFirst(
  String hint, {
  required DateTime reference,
}) {
  final m = RegExp(
    r'^([a-z]{3,9})\s+(\d{1,2})(?:st|nd|rd|th)?(?:\s+(\d{4}))?$',
    caseSensitive: false,
  ).firstMatch(hint);
  if (m == null) {
    return null;
  }
  final monthTok = (m.group(1) ?? '').toLowerCase();
  final day = int.tryParse(m.group(2) ?? '');
  final month = _monthNumber(monthTok);
  final yStr = m.group(3);
  final year = int.tryParse(yStr ?? '') ?? reference.year;
  if (day == null || month == null) {
    return null;
  }
  if (day < 1 || day > 31) {
    return null;
  }
  try {
    return DateTime(year, month, day);
  } catch (_) {
    return null;
  }
}
