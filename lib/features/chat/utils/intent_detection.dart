import 'package:flutter/foundation.dart';

/// Centralized chat intent. Priority: [reminder] > [payment] > [query] > [general].
enum AivyUserIntent { reminder, payment, query, general }

/// Single entry point for routing reminders, payments, and analytics.
///
/// - **Reminder**: time/date + action (call, follow up, etc.) or explicit
///   remind/yaad — **without** requiring the word "reminder".
/// - **Payment**: INR / amounts + lena|dena|payment|collect…
/// - **Query**: kitna, list, report, etc. (business questions)
AivyUserIntent detectIntent(String text) {
  final t = text.trim();
  if (t.isEmpty) {
    return AivyUserIntent.general;
  }
  final lower = t.toLowerCase();
  if (_isReminderIntent(lower, t)) {
    return AivyUserIntent.reminder;
  }
  if (_isPaymentIntent(lower, t)) {
    return AivyUserIntent.payment;
  }
  if (_isQueryIntent(lower)) {
    return AivyUserIntent.query;
  }
  return AivyUserIntent.general;
}

/// Mandatory debug: INPUT / INTENT / (optional) PARSED map.
void logAivyIntentDebug(
  String text,
  AivyUserIntent intent, {
  Map<String, Object?>? parsed,
}) {
  // ignore: avoid_print
  print('INPUT: $text');
  // ignore: avoid_print
  print('INTENT: ${intent.name}');
  if (parsed != null) {
    // ignore: avoid_print
    print('PARSED: $parsed');
  }
  if (kDebugMode) {
    debugPrint('AIVY_INTENT_DEBUG INPUT="$text" -> ${intent.name}');
  }
}

/// Strong business *stats / list* questions (not a personal schedule line).
bool _isBusinessStatsOrListQuestion(String lower) {
  final hasQuoteOrOrder = RegExp(
    r'\b(quotation|quote|qoutation|order|orders|dispatch|po|p\.o\.|purchase order|बुक|booking|कोटेशन)\b',
    caseSensitive: false,
  ).hasMatch(lower);
  if (!hasQuoteOrOrder) {
    return false;
  }
  return RegExp(
    r'\b(kitne|kitna|kitni|kisko|kisse|list|how\s+many|abhi\s*tak|total|'
    r'saare|count|batao|bata|report|naam|names|pichhle|pichle|mahine|month|aaj|kal|guzre|value)\b',
    caseSensitive: false,
  ).hasMatch(lower);
}

final RegExp _hReminder = RegExp(
  r'रिमाइंडर|रिमाइन्दर|रेमाइंडर|याद\s*दिल(?:ाओ|ाना|ा\s*दो|वाना)?',
  unicode: true,
);
final RegExp _hRelDay = RegExp(
  r'आज|कल(?!\u093e)|परसों|परसो|अगले\s*हफ्ते|अगले\s*सप्ताह',
  unicode: true,
);
final RegExp _hTime = RegExp(
  r'शाम|सुबह|दोपहर|बजे|[\u0966-\u096f]{1,2}\s*बजे',
  unicode: true,
);
final RegExp _hCall = RegExp(
  r'कॉल|फ़ोन|फोन|मिलना|मिलने|कॉल\s*कर|फोन\s*कर',
  unicode: true,
);

bool _hasTimeOrScheduleCue(String lower, String raw) {
  return RegExp(
    r'\b(baje|subah|shaam|sham|evening|morning|noon|am|pm|a\.m\.|p\.m\.|'
    r"o\'clock|oclock)\b",
    caseSensitive: false,
  ).hasMatch(lower) ||
      RegExp(r'\b(\d{1,2}:\d{2}|\d{1,2}\s*[:.]\s*\d{2})\b').hasMatch(lower) ||
      RegExp(r'\b\d{1,2}\s*(baje|bje|pm|am)\b', caseSensitive: false)
          .hasMatch(lower) ||
      _hTime.hasMatch(raw);
}

bool _hasDateOrRelativeDay(String lower, String raw) {
  return RegExp(
    r'\b(aaj|kal|parso|tomorrow|today|agla|next\s*week|is\s*hafte|is\s*week|'
    r'after\s+\d+\s*days?|'
    r'(\d+|ek|do|teen|char|chaar|paanch|one|two)\s*din(\s+ke\s+baad|\s*baad)?|'
    r'parson|day after tomorrow)\b',
    caseSensitive: false,
  ).hasMatch(lower) ||
      RegExp(r'\d{1,2}[/.-]\d{1,2}([/.-]\d{2,4})?').hasMatch(lower) ||
      _hRelDay.hasMatch(raw);
}

bool _hasScheduleAction(String lower, String raw) {
  return RegExp(
    r'\b(call|phone|milna|milne|mulakat|mulaqat|'
    r'follow\s*up|followup|bhejna|bhej|check|visit|dekhna|'
    r'meet|remind|reminder|yaad|dilao|dilana|dila|'
    r'call\s+karna|karna\s+hai.*\bcall|'
    r'lagao|laga|lagana|lagwa|lagwana|set\s+reminder|'
    r'need\s+to\s+call|have\s+to\s+call|got\s+to\s+call|must\s+call|want\s+to\s+call)\b',
    caseSensitive: false,
  ).hasMatch(lower) ||
      _hCall.hasMatch(raw);
}

bool _hasReminderKeyword(String lower, String raw) {
  if (RegExp(r'\b(remind|reminder)\b', caseSensitive: false).hasMatch(lower)) {
    return true;
  }
  if (RegExp(
    r'\b(remind\s+me(\s+to)?|please\s+remind|set\s+(up\s+)?a\s+reminder|'
    r'add\s+a\s+reminder|create\s+a\s+reminder)\b',
    caseSensitive: false,
  ).hasMatch(lower)) {
    return true;
  }
  if (_hReminder.hasMatch(raw)) {
    return true;
  }
  if (RegExp(
    r'\b(reminder\s+lag|lagao\s+reminder|lagwa\s+reminder|reminder\s+set|'
    r'set\s+reminder|reminder\s+dila|reminder\s+bana|mujhe\s+.+\s+reminder)\b',
    caseSensitive: false,
  ).hasMatch(lower)) {
    return true;
  }
  return false;
}

/// Questions like "aaj kise call karna hai" → server analytics (follow-up list),
/// not [reminder] (which skips analytics and forces reminder JSON / bad replies).
bool _isWhoToCallAnalyticsQuestion(String lower, String raw) {
  if (!_hasDateOrRelativeDay(lower, raw)) {
    return false;
  }
  final asksWhom = RegExp(
    r'\b(kise|kis\s*ko|kisko|kaun|kaun\s*sa|kaun\s*si|kya)\b',
    caseSensitive: false,
  ).hasMatch(lower);
  final hasCall = RegExp(
    r'\b(call|phone|milna|milne|follow\s*up|followup)\b',
    caseSensitive: false,
  ).hasMatch(lower);
  final asksGuidance = RegExp(
    r'\b(batao|bata|bataye|chahiye|hai\s*\?|hai\?|karna\s+hai|karu|karun|list|dikhao|dikha)\b',
    caseSensitive: false,
  ).hasMatch(lower);
  return asksWhom && hasCall && asksGuidance;
}

bool _isReminderIntent(String lower, String raw) {
  if (_isWhoToCallAnalyticsQuestion(lower, raw)) {
    return false;
  }
  if (_isBusinessStatsOrListQuestion(lower)) {
    return false;
  }
  if (_hasReminderKeyword(lower, raw)) {
    if (!RegExp(
      r'\b(kitne|kitna|kitni)\b.*(quotation|order|quote|dispatch)',
      caseSensitive: false,
    ).hasMatch(lower)) {
      return true;
    }
  }
  if (RegExp(
    r'yaad\s*(dilao|dilana|dila\s*do|dila\s*dena|dilwa|dilwana|karwa\s*do|karwa\s*dena|karwana)',
  ).hasMatch(lower)) {
    return true;
  }
  if (_hasTimeOrScheduleCue(lower, raw) && _hasScheduleAction(lower, raw)) {
    return true;
  }
  if (_hasDateOrRelativeDay(lower, raw) &&
      _hasTimeOrScheduleCue(lower, raw) &&
      _hasScheduleAction(lower, raw)) {
    return true;
  }
  if (RegExp(
    r'\b(baje|subah|shaam|sham|shaam\s*ko)\b',
  ).hasMatch(lower) && RegExp(
    r'\b(leni|lena|lana|lenaa|khareed|dawai|davai|facewash|face\s*wash|'
    r'medicine|tablet|syrup)\b',
  ).hasMatch(lower)) {
    return true;
  }
  if (_hasDateOrRelativeDay(lower, raw) &&
      _hasScheduleAction(lower, raw) &&
      !RegExp(
        r'\b(lena|lene|lenaa|dena|vasool|₹|rs\.?|rupees?)\b',
      ).hasMatch(lower)) {
    return true;
  }
  if (_hasDateOrRelativeDay(lower, raw) &&
      _hasTimeOrScheduleCue(lower, raw) &&
      RegExp(
        r'\b(ko|karna|karni|karne)\b',
      ).hasMatch(lower) &&
      RegExp(
        r'\b(call|phone|mil|bhej|check|follow)\b',
        caseSensitive: false,
      ).hasMatch(lower)) {
    return true;
  }
  if (RegExp(r'\b(mujhe|mere|meri|mera)\b', caseSensitive: false).hasMatch(lower) &&
      _hasDateOrRelativeDay(lower, raw) &&
      (_hasTimeOrScheduleCue(lower, raw) || RegExp(r'\d').hasMatch(lower)) &&
      (_hasScheduleAction(lower, raw) ||
          RegExp(r'\b(ko|karna|karni)\b').hasMatch(lower))) {
    return true;
  }
  if (RegExp(r'मुझे|मेरे|मेरी|मेरा', unicode: true).hasMatch(raw) &&
      _hRelDay.hasMatch(raw) &&
      (_hTime.hasMatch(raw) || RegExp(r'\d').hasMatch(raw))) {
    return true;
  }
  return false;
}

bool _isPaymentIntent(String lower, String raw) {
  if (_isBusinessStatsOrListQuestion(lower)) {
    return false;
  }
  final seHinglish = RegExp(
    r'\b([A-Za-z][A-Za-z0-9]*)\s+se\s+[\d,₹\sA-Za-z]*\d[\d,₹\s]*'
    r'(lena|lene|lenaa|leni|dena|deni)\b',
    caseSensitive: false,
  ).hasMatch(raw);
  if (seHinglish) {
    return true;
  }
  final hasMoney = RegExp(
    r'(₹|rs\.?|rupees?|inr|\b\d{3,7}\b)',
    caseSensitive: false,
  ).hasMatch(raw);
  final hasCollectVerb = RegExp(
    r'\b(lena|lene|lenaa|dena|deni|vasool|vasuli|chuk|payment|collect|'
    r'collection|receive|baki|jamaa?)\b',
    caseSensitive: false,
  ).hasMatch(lower);
  if (hasMoney && hasCollectVerb) {
    return true;
  }
  return false;
}

bool _isQueryIntent(String lower) {
  if (_isBusinessStatsOrListQuestion(lower)) {
    return true;
  }
  return RegExp(
    r'\b(kaun|kise|kisko|kisse|kya\s+bata|'
    r'kitne|kitna|kitni|list|saare|report|dashboard|batao|bata|count|'
    r'how\s+many|total|names|pichhle|guzre|dues|due|mahine|month)\b',
    caseSensitive: false,
  ).hasMatch(lower);
}
