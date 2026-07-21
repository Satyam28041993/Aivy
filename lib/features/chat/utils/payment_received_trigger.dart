import '../../structured_actions/utils/name_normalize.dart';

/// Part 5 + Phase 6: payment received with a resolvable [name] (normalized) + raw token for aliases.
class PaymentReceivedNameResult {
  const PaymentReceivedNameResult({required this.normalized, this.rawName});

  final String normalized;
  /// Name substring as written (e.g. short "rav"); may be null if only normalized path used.
  final String? rawName;
}

String? detectPaymentReceivedWithName(String text) {
  return detectPaymentReceivedWithNameDetails(text)?.normalized;
}

/// Part 5: intent = payment received + a resolvable [name] (normalized).
PaymentReceivedNameResult? detectPaymentReceivedWithNameDetails(String text) {
  final t = text.trim();
  if (t.isEmpty) {
    return null;
  }
  final low = t.toLowerCase();
  if (!hasPaymentReceivedIntent(low)) {
    return null;
  }
  final name = _extractName(t);
  if (name == null || name.isEmpty) {
    return null;
  }
  final n = normalizeName(name);
  if (n.isEmpty) {
    return null;
  }
  return PaymentReceivedNameResult(normalized: n, rawName: name.trim());
}

/// Phase 6: "payment received" / mil gaya style — even if no [name] was parsed.
bool hasPaymentReceivedIntentText(String text) {
  return hasPaymentReceivedIntent(text.trim().toLowerCase());
}

/// Shared intent detector (lowercase input).
bool hasPaymentReceivedIntent(String low) {
  if (low.isEmpty) {
    return false;
  }
  if (RegExp(
    r'payment\s*received|receive\s*ho|receiv|vasool|collect',
    caseSensitive: false,
  ).hasMatch(low)) {
    return true;
  }
  const phrases = <String>[
    'aa gaya',
    'aa gayi',
    'aa gaye',
    'mil gaya',
    'mil gayi',
    'mil gaye',
    'receive hua',
    'receive hui',
    'recieve',
    'de diya',
    'de diye',
    'de dī',
    'paise aaye',
    'paisa aaya',
    'payment aa',
    'chala aaya',
    'ho gaya',
    'ho gayi',
  ];
  for (final p in phrases) {
    if (low.contains(p)) {
      return true;
    }
  }
  if (low.contains('receive') && low.contains('payment')) {
    return true;
  }
  return false;
}

String? _extractName(String t) {
  RegExpMatch? m = RegExp(
    r"([A-Za-z][A-Za-z.'-]{0,40})\s+ka(\s+payment|\s+paisa)?",
    caseSensitive: false,
  ).firstMatch(t);
  if (m != null) {
    return m.group(1);
  }
  m = RegExp(
    r"from\s+([A-Za-z][A-Za-z.'-]+)",
    caseSensitive: false,
  ).firstMatch(t);
  if (m != null) {
    return m.group(1);
  }
  m = RegExp(
    r"client\s+([A-Za-z][A-Za-z.'-]+)",
    caseSensitive: false,
  ).firstMatch(t);
  if (m != null) {
    return m.group(1);
  }
  m = RegExp(
    r"ne\s+([A-Za-z][A-Za-z.'-]+)\s+ko",
    caseSensitive: false,
  ).firstMatch(t);
  if (m != null) {
    return m.group(1);
  }
  if (t.split(RegExp(r'\s+')).length <= 8) {
    m = RegExp(
      r"\b([A-Za-z][a-zA-Z.'-]{2,20})\b",
    ).firstMatch(t);
    if (m != null) {
      return m.group(1);
    }
  }
  return null;
}
