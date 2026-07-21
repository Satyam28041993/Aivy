import '../../reminders/utils/reminder_time_parser.dart';
import '../../structured_actions/utils/name_normalize.dart';
import '../utils/extract_inr_amount.dart';

/// Part 5: apply natural edits to a confirm [draft] map.
Map<String, dynamic>? tryParseInlineEdit(String text, Map<String, dynamic> draft) {
  final t = text.trim();
  if (t.isEmpty) {
    return null;
  }
  final low = t.toLowerCase();
  var next = Map<String, dynamic>.from(draft);
  var changed = false;

  final ns = _tryNameSwap(t);
  if (ns != null) {
    next['name'] = ns;
    next['nameLower'] = normalizeName(ns);
    changed = true;
  }

  if (_wantsAmount(low, t)) {
    final a = _parseAmount(t);
    if (a != null && a > 0) {
      next['amount'] = a;
      changed = true;
    }
  }

  if (_wantsDate(low)) {
    var slice = t;
    slice = slice.replaceFirst(
      RegExp(
        r'^(date|tareekh|tariikh|kal|parso|aaj|tomorrow|today)\b\s*[:\-]?\s*',
        caseSensitive: false,
      ),
      '',
    ).trim();
    if (slice.isEmpty) {
      slice = t;
    }
    final d = ReminderTimeParser.resolveScheduledTimeFromPlainText(slice) ??
        ReminderTimeParser.resolveScheduledTimeFromPlainText(t);
    if (d != null) {
      next['date'] = d.millisecondsSinceEpoch;
      changed = true;
    }
  }

  if (!changed && RegExp(r'^(name|client|naam)\s*[:,]?\s*', caseSensitive: false)
      .hasMatch(t)) {
    final rest = t
        .replaceFirst(
          RegExp(r'^(name|client|naam)\s*[:,]?\s*', caseSensitive: false),
          '',
        )
        .trim();
    if (rest.length > 1) {
      next['name'] = rest;
      next['nameLower'] = normalizeName(rest);
      changed = true;
    }
  }

  if (!changed) {
    return null;
  }
  return next;
}

String? _tryNameSwap(String t) {
  final m = RegExp(
    r"([A-Za-z\u00C0-\u024F][A-Za-z\u00C0-\u024F.'-]+)\s+ki\s+jagah\s+([A-Za-z\u00C0-\u024F][A-Za-z\u00C0-\u024F.'-]+)",
    caseSensitive: false,
  ).firstMatch(t);
  if (m != null) {
    return m.group(2)!.trim();
  }
  return null;
}

bool _wantsAmount(String low, String t) {
  if (RegExp(
    r'amount|₹|rupee|rs\.?|rupa|rupay|paisa|kar do|bana do|set karo',
    caseSensitive: false,
  ).hasMatch(low)) {
    return true;
  }
  return RegExp(r'[\d₹]').hasMatch(t) &&
      !RegExp(r'^\d{1,2}[/-]\d{1,2}', caseSensitive: false).hasMatch(t);
}

bool _wantsDate(String low) {
  return RegExp(
    r'\b(aaj|kal|parso|date|kalf|tareekh|tariikh|tomorrow|today|is\s*week|agla|next)\b',
    caseSensitive: false,
  ).hasMatch(low);
}

double? _parseAmount(String t) {
  final e = extractInrAmountFromText(t);
  if (e != null) {
    return e;
  }
  final m = RegExp(r'(\d[\d,]*\.?\d*)').firstMatch(t);
  if (m == null) {
    return null;
  }
  return double.tryParse(m.group(1)!.replaceAll(',', ''));
}
