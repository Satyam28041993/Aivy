import 'package:flutter/foundation.dart';

class NumbersContextParseResult {
  const NumbersContextParseResult({
    required this.text,
    required this.numbersFound,
    this.amount,
    this.durationDays,
    this.timeHour,
    this.timeMinute,
  });

  final String text;
  final List<int> numbersFound;
  final double? amount;
  final int? durationDays;
  final int? timeHour;
  final int? timeMinute;

  void debugLog() {
    if (!kDebugMode) {
      return;
    }
    final amt = amount;
    final days = durationDays;
    var timeStr = '—';
    if (timeHour != null) {
      final m = timeMinute;
      timeStr = m != null && m > 0
          ? '${timeHour}h${m}m'
          : '${timeHour}h';
    }
    debugPrint('TEXT: $text');
    debugPrint('NUMBERS FOUND: $numbersFound');
    debugPrint('AMOUNT: ${amt?.toString() ?? "—"}');
    debugPrint('DAYS: ${days?.toString() ?? "—"}');
    debugPrint('TIME: $timeStr');
  }
}

int? _parseNumberToken(String t) {
  final s = t.replaceAll(',', '');
  if (s.contains('.')) {
    return double.tryParse(s)?.round();
  }
  return int.tryParse(s);
}

/// Classifies numbers in [text] for INR amount vs "N din" / clock.
/// Priority: AMOUNT > TIME > DAYS. "N din" with N < 100 is duration, not rupees,
/// when another number encodes the actual amount.
NumbersContextParseResult parseNumbersWithContext(String text) {
  final raw = text.trim();
  if (raw.isEmpty) {
    return const NumbersContextParseResult(text: '', numbersFound: []);
  }

  final lower = raw.toLowerCase();
  final pattern = RegExp(
    r'(?:₹|rs\.?|inr)\s*(\d{1,12}(?:[.,]\d{1,2})?)|\b(\d{1,12}(?:[.,]\d{1,2})?)\b',
    caseSensitive: false,
  );

  final found = <int>[];
  void take(int? v) {
    if (v == null || v <= 0) {
      return;
    }
    if (!found.contains(v)) {
      found.add(v);
    }
  }

  for (final m in pattern.allMatches(raw)) {
    take(_parseNumberToken(m.group(1) ?? m.group(2) ?? ''));
  }
  final nums = List<int>.from(found)..sort();

  // --- DURATION: N din / N day(s) (never amount for the same token) ---
  final asDuration = <int>{};
  int? durationDays;

  var dinM = RegExp(
    r'(\d+)\s*din(?:\b|\s+(?:(?:ke\s+)?baad|me))',
    caseSensitive: false,
  ).firstMatch(lower);
  dinM ??= RegExp(
    r'(\d+)\s*din',
    caseSensitive: false,
  ).firstMatch(lower);
  if (dinM != null) {
    final d = int.tryParse(dinM.group(1) ?? '') ?? 0;
    if (d > 0) {
      asDuration.add(d);
      durationDays = d;
    }
  }
  if (durationDays == null) {
    final en = RegExp(
      r'after\s+(\d+)(?:\s*days?)?|(\d+)\s*(?:day|days)\b',
      caseSensitive: false,
    ).firstMatch(lower);
    if (en != null) {
      final d =
          int.tryParse(en.group(1) ?? en.group(2) ?? '') ?? 0;
      if (d > 0) {
        asDuration.add(d);
        durationDays = d;
      }
    }
  }
  if (durationDays == null) {
    final w = RegExp(
      r'\b(ek|do|teen|char|paanch|chhe|one|two|three|four|five|six)\s+din',
      caseSensitive: false,
    ).firstMatch(lower);
    if (w != null) {
      final t = (w.group(1) ?? '').toLowerCase();
      final d = const {
        'ek': 1,
        'do': 2,
        'teen': 3,
        'char': 4,
        'paanch': 5,
        'chhe': 6,
        'one': 1,
        'two': 2,
        'three': 3,
        'four': 4,
        'five': 5,
        'six': 6,
      }[t];
      if (d != null) {
        asDuration.add(d);
        durationDays = d;
      }
    }
  }

  // --- TIME: N baje, N am/pm (clock token excluded from default amount) ---
  final asTime = <int>{};
  int? timeHour;
  int? timeMinute;
  {
    final baje = RegExp(
      r'(\d{1,2})\s*baje',
      caseSensitive: false,
    ).firstMatch(lower);
    if (baje != null) {
      final h = int.tryParse(baje.group(1) ?? '') ?? 0;
      if (h >= 1 && h <= 12) {
        asTime.add(h);
        timeHour = h;
        timeMinute = 0;
      }
    }
  }
  if (timeHour == null) {
    final ap = RegExp(
      r'\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b',
      caseSensitive: false,
    ).firstMatch(lower);
    if (ap != null) {
      var h = int.tryParse(ap.group(1) ?? '') ?? 0;
      final mer = (ap.group(3) ?? '').toLowerCase();
      final min = int.tryParse(ap.group(2) ?? '') ?? 0;
      asTime.add(h);
      if (mer == 'pm' && h < 12) {
        h += 12;
      }
      if (mer == 'am' && h == 12) {
        h = 0;
      }
      timeHour = h;
      timeMinute = min;
    }
  }

  // --- AMOUNT hints: currency, "N" before lena/dena/payment, N > 999 ---
  final amountHints = <int>{};

  for (final m in RegExp(
    r'(?:₹|rs\.?|inr)\s*(\d{1,12}(?:[.,]\d{1,2})?)',
    caseSensitive: false,
  ).allMatches(raw)) {
    final n = _parseNumberToken(m.group(1) ?? '');
    if (n != null) {
      amountHints.add(n);
    }
  }

  for (final m in RegExp(
    r'(\d{1,12}(?:[.,]\d{1,2})?)\s+'
    r'(?:lena|lene|lenaa?|dena|dene|deni|payment|pay|milna|milega|collect)\b',
    caseSensitive: false,
  ).allMatches(lower)) {
    final n = _parseNumberToken(m.group(1) ?? '');
    if (n != null) {
      amountHints.add(n);
    }
  }

  for (final m in RegExp(
    r'\b(?:pay|collect)\s+(\d+)',
    caseSensitive: false,
  ).allMatches(lower)) {
    final n = _parseNumberToken(m.group(1) ?? '');
    if (n != null) {
      amountHints.add(n);
    }
  }

  for (final n in nums) {
    if (n > 999) {
      amountHints.add(n);
    }
  }

  bool eligibleAmount(int n) {
    if (asDuration.contains(n) && n < 100) {
      return false;
    }
    if (asTime.contains(n) && n < 100) {
      return false;
    }
    return true;
  }

  int? bestFrom(Iterable<int> c) {
    int? b;
    for (final n in c) {
      if (!eligibleAmount(n)) {
        continue;
      }
      if (b == null || n > b) {
        b = n;
      }
    }
    return b;
  }

  int? a = bestFrom(amountHints);
  a ??= bestFrom(nums);

  if (a != null) {
    var cur = a;
    final hasDin = RegExp(r'\bdin\b', caseSensitive: false).hasMatch(lower);
    if (cur < 100 && hasDin && asDuration.contains(cur)) {
      final alt = bestFrom(
        nums.where((n) => n > cur && (n > 999 || !asDuration.contains(n))),
      );
      if (alt != null) {
        cur = alt;
      }
    }
    if (cur < 100) {
      final top = bestFrom(
        nums.where((n) => n > cur),
      );
      if (top != null && (top > 999 || !asDuration.contains(top))) {
        if (amountHints.isNotEmpty) {
          if (amountHints.contains(cur) == false) {
            cur = top;
          }
        } else {
          cur = top;
        }
      }
    }
    if (cur < 100) {
      final top = nums.isEmpty
          ? null
          : nums.reduce((x, y) => x > y ? x : y);
      if (top != null && top > cur && !asDuration.contains(top)) {
        if (asDuration.isEmpty == false) {
          cur = top;
        } else if (top > 999) {
          cur = top;
        }
      }
    }
    a = cur;
  }

  double? finalAmount;
  if (a != null) {
    if (asDuration.contains(a) && a < 100) {
      final other = bestFrom(
        amountHints,
      ) ?? bestFrom(nums.where((n) => !asDuration.contains(n) || n > 999));
      finalAmount = (other ?? a).toDouble();
    } else {
      finalAmount = a.toDouble();
    }
  }

  if (finalAmount != null) {
    final v = finalAmount.round();
    if (v < 100) {
      final maxN = nums.isEmpty
          ? null
          : nums.reduce((x, y) => x > y ? x : y);
      if (maxN != null && maxN > v) {
        if (asDuration.contains(v) && !asDuration.contains(maxN)) {
          finalAmount = maxN.toDouble();
        } else if (maxN > 999) {
          finalAmount = maxN.toDouble();
        }
      }
    }
  }

  final out = NumbersContextParseResult(
    text: raw,
    numbersFound: nums,
    amount: finalAmount,
    durationDays: durationDays,
    timeHour: timeHour,
    timeMinute: timeMinute,
  );
  out.debugLog();
  return out;
}
