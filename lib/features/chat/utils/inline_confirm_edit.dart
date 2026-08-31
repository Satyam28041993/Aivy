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

  if ((draft['flowCategoryId'] as String? ?? '') == 'project_items') {
    final projectEdit = _tryProjectInlineEdit(t, next);
    if (projectEdit != null) {
      return projectEdit;
    }
  }

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

Map<String, dynamic>? _tryProjectInlineEdit(
  String t,
  Map<String, dynamic> draft,
) {
  final next = Map<String, dynamic>.from(draft);
  var changed = false;
  final nameM = RegExp(
    r'^(?:project\s+)?(?:naam|name)\s*[:\-]?\s+(.+)$',
    caseSensitive: false,
  ).firstMatch(t);
  if (nameM != null) {
    final n = nameM.group(1)!.trim();
    next['name'] = n;
    next['projectName'] = n;
    changed = true;
  }
  final clientM = RegExp(
    r'^client\s*[:\-]?\s+(.+)$',
    caseSensitive: false,
  ).firstMatch(t);
  if (clientM != null) {
    next['client'] = clientM.group(1)!.trim();
    changed = true;
  }
  final itemM = RegExp(
    r'^item\s+(\d+)\s+(.+)$',
    caseSensitive: false,
  ).firstMatch(t);
  if (itemM != null) {
    final idx = int.parse(itemM.group(1)!) - 1;
    final rest = itemM.group(2)!.trim().toLowerCase();
    final rawItems = next['items'];
    if (rawItems is List && idx >= 0 && idx < rawItems.length) {
      final items = [
        for (final e in rawItems)
          if (e is Map) Map<String, dynamic>.from(e) else e,
      ];
      if (items[idx] is Map<String, dynamic>) {
        final item = Map<String, dynamic>.from(items[idx] as Map);
        if (rest.contains('waiting')) {
          item['status'] = 'waiting_on_them';
        } else if (RegExp(r'\b(done|complete)\b').hasMatch(rest)) {
          item['status'] = 'done';
        } else if (RegExp(r'\b(pending|open)\b').hasMatch(rest)) {
          item['status'] = 'pending';
        } else if (RegExp(r'\b(cancel)\b').hasMatch(rest)) {
          item['status'] = 'cancelled';
        }
        final due = ReminderTimeParser.resolveScheduledTimeFromPlainText(
          itemM.group(2)!.trim(),
        );
        if (due != null) {
          item['dueAtMs'] = due.millisecondsSinceEpoch;
          item['dueAtIso'] = due.toIso8601String();
          item['dueLabel'] = ReminderTimeParser.formatReminderTime(due);
        }
        items[idx] = item;
        next['items'] = items;
        changed = true;
      }
    }
  }
  return changed ? next : null;
}
