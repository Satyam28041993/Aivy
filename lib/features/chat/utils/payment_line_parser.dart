import 'number_context_parser.dart';

/// "Rakesh ne 10,000 diya" style — payment received (direct).
class PaymentReceivedDirectParse {
  const PaymentReceivedDirectParse({
    required this.clientName,
    required this.amountInr,
    this.rawClientToken,
  });

  final String clientName;
  final double amountInr;
  final String? rawClientToken;
}

/// "Rakesh ko 50000 dena hai" / "Rakesh ko ₹50,000 dena hai" — payment due.
class PaymentDueKoParse {
  const PaymentDueKoParse({
    required this.clientName,
    required this.amountInr,
    this.rawClientToken,
  });

  final String clientName;
  final double amountInr;
  final String? rawClientToken;
}

PaymentReceivedDirectParse? tryParsePaymentReceivedDirect(String text) {
  final t = text.trim();
  if (t.isEmpty) {
    return null;
  }
  final low = t.toLowerCase();
  if (!RegExp(
    r'\b(ne|ney)\b',
    caseSensitive: false,
  ).hasMatch(low)) {
    return null;
  }
  if (!RegExp(
    r'\b(diya|diye|de\s+diya|de\s+diye|mil\s+gaya|mil\s+gayi|pay\s+kar\s+diya|bhej\s+diya)\b',
    caseSensitive: false,
  ).hasMatch(low)) {
    return null;
  }
  final ctx = parseNumbersWithContext(t);
  final amount = ctx.amount;
  if (amount == null || amount <= 0) {
    return null;
  }
  final nameMatch = RegExp(
    r"^([A-Za-z][A-Za-z\s.'-]{0,80}?)\s+(?:ne|ney)\b",
    caseSensitive: false,
  ).firstMatch(t);
  if (nameMatch == null) {
    return null;
  }
  var raw = (nameMatch.group(1) ?? '').trim();
  if (raw.isEmpty) {
    return null;
  }
  var cap = raw;
  if (cap.isNotEmpty) {
    cap = cap[0].toUpperCase() + cap.substring(1).toLowerCase();
  }
  return PaymentReceivedDirectParse(
    clientName: cap,
    amountInr: amount,
    rawClientToken: raw,
  );
}

PaymentDueKoParse? tryParsePaymentDueKo(String text) {
  final t = text.trim();
  if (t.isEmpty) {
    return null;
  }
  final low = t.toLowerCase();
  if (!RegExp(r'\bko\b', caseSensitive: false).hasMatch(low)) {
    return null;
  }
  if (!RegExp(
    r'\b(dena|deni|denaa|denge|de\s*na|pay\s*karna|pay\s*kar)\b',
    caseSensitive: false,
  ).hasMatch(low)) {
    return null;
  }
  final ctx = parseNumbersWithContext(t);
  final amount = ctx.amount;
  if (amount == null || amount <= 0) {
    return null;
  }
  final nameMatch = RegExp(
    r"^([A-Za-z][A-Za-z\s.'-]{0,80}?)\s+ko\b",
    caseSensitive: false,
  ).firstMatch(t);
  if (nameMatch == null) {
    return null;
  }
  var raw = (nameMatch.group(1) ?? '').trim();
  if (raw.isEmpty) {
    return null;
  }
  var cap = raw;
  if (cap.isNotEmpty) {
    cap = cap[0].toUpperCase() + cap.substring(1).toLowerCase();
  }
  return PaymentDueKoParse(
    clientName: cap,
    amountInr: amount,
    rawClientToken: raw,
  );
}

/// Optional parse of Hinglish manual collection: "karan se 50000 lena hai 5 din baad"
class ManualPaymentParse {
  const ManualPaymentParse({
    required this.clientName,
    required this.amountInr,
    required this.dueDaysFromToday,
  });

  final String clientName;
  final double amountInr;
  /// 0 = today EOD-style (use scheduled time from [ReminderTimeParser]).
  final int dueDaysFromToday;
}

/// Returns structured payment info when the line is clearly a collection request.
ManualPaymentParse? tryParseManualPaymentLine(String text) {
  final t = text.trim();
  if (t.isEmpty) {
    return null;
  }
  if (tryParsePaymentReceivedDirect(t) != null) {
    return null;
  }
  if (tryParsePaymentDueKo(t) != null) {
    return null;
  }
  final lower = t.toLowerCase();

  final se = RegExp(
    r'\b([A-Za-z][A-Za-z0-9]*)\s+se\s+',
    caseSensitive: false,
  ).firstMatch(t);
  if (se == null) {
    return null;
  }
  final name = (se.group(1) ?? '').trim();
  if (name.isEmpty) {
    return null;
  }
  if (!RegExp(
    r'\b(lena|lene|lenaa|leni|lenaa|vasool|vasuli|chuk|payment|collect|receive|dena|deni|milna|milega|hai)\b',
    caseSensitive: false,
  ).hasMatch(lower)) {
    return null;
  }
  final ctx = parseNumbersWithContext(t);
  final amount = ctx.amount;
  if (amount == null || amount <= 0) {
    return null;
  }

  var days = ctx.durationDays ?? 0;
  if (days == 0) {
    final din = RegExp(
      r'(\d+|ek|do|teen|char|paanch|one|two|three|four|five)\s*din'
      r'(\s+ke\s+baad|\s*baad)?',
      caseSensitive: false,
    ).firstMatch(lower);
    if (din != null) {
      final w = (din.group(1) ?? '').toLowerCase();
      final n = int.tryParse(w) ??
          const {
            'ek': 1,
            'do': 2,
            'teen': 3,
            'char': 4,
            'paanch': 5,
            'one': 1,
            'two': 2,
            'three': 3,
            'four': 4,
            'five': 5,
          }[w];
      if (n != null && n > 0) {
        days = n;
      }
    } else if (RegExp(
      r'\b(aaj|kal|tomorrow|today|parso|parson)\b',
    ).hasMatch(lower)) {
      if (RegExp(r'\bkal|tomorrow\b').hasMatch(lower)) {
        days = 1;
      }
    } else if (RegExp(
      r'\b(after|baad|later)\b',
    ).hasMatch(lower)) {
      final m = RegExp(
        r'after\s+(\d+)|(\d+)\s*days',
        caseSensitive: false,
      ).firstMatch(lower);
      if (m != null) {
        final v = int.tryParse(m.group(1) ?? m.group(2) ?? '') ?? 0;
        if (v > 0) {
          days = v;
        }
      }
    }
  }

  return ManualPaymentParse(
    clientName: name[0].toUpperCase() + name.substring(1).toLowerCase(),
    amountInr: amount,
    dueDaysFromToday: days,
  );
}
