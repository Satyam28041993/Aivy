import '../../reminders/utils/reminder_time_parser.dart';

/// Parsed single-line task reminder (all fields → jump to confirm).
class TaskReminderOneLineResult {
  const TaskReminderOneLineResult({
    required this.taskTitle,
    required this.dateMs,
    required this.timeMinutes,
    required this.priorityLabel,
    this.clientName,
  });

  final String taskTitle;
  final String? clientName;
  final int dateMs;
  final int timeMinutes;
  /// One of: High, Medium, Low
  final String priorityLabel;
}

/// Hinglish possessive: "Rakesh ka artwork approve …" → client + title.
({String title, String? client}) splitPossessiveTaskTitle(String raw) {
  final s = raw.trim();
  if (s.isEmpty) {
    return (title: '', client: null);
  }
  final m = RegExp(
    r'^([A-Za-z\u0900-\u097F][A-Za-z0-9\u0900-\u097F]*(?:\s+[A-Za-z\u0900-\u097F][A-Za-z0-9]*)?)\s+ka\s+(.+)$',
    caseSensitive: false,
  ).firstMatch(s);
  if (m != null) {
    final c = m.group(1)?.trim() ?? '';
    final tit = m.group(2)?.trim() ?? '';
    if (c.isNotEmpty && tit.length >= 2) {
      return (title: tit, client: c);
    }
  }
  return (title: s, client: null);
}

String? _labelFromPriorityTail(String matchedLower) {
  final m = matchedLower.trim();
  if (m.isEmpty) {
    return null;
  }
  if (RegExp(r'high|urgent|jaldi').hasMatch(m)) {
    return 'High';
  }
  if (RegExp(r'baad\s*me|baadme').hasMatch(m)) {
    return 'Low';
  }
  if (m.contains('low') && !m.contains('slow')) {
    return 'Low';
  }
  if (m.contains('medium') || m.contains('normal')) {
    return 'Medium';
  }
  return 'Medium';
}

/// Strips trailing priority phrase; returns remaining text and label (or null if none).
(String rest, String? priorityLabel) stripTrailingTaskPriority(String s) {
  final patterns = <RegExp>[
    RegExp(r'\s+high\s+priority\s*$', caseSensitive: false),
    RegExp(r'\s+low\s+priority\s*$', caseSensitive: false),
    RegExp(r'\s+medium\s+priority\s*$', caseSensitive: false),
    RegExp(r'\s+normal\s+priority\s*$', caseSensitive: false),
    RegExp(r'\s+high\s*$', caseSensitive: false),
    RegExp(r'\s+urgent\s*$', caseSensitive: false),
    RegExp(r'\s+jaldi\s*$', caseSensitive: false),
    RegExp(r'\s+medium\s*$', caseSensitive: false),
    RegExp(r'\s+normal\s*$', caseSensitive: false),
    RegExp(r'\s+low\s*$', caseSensitive: false),
    RegExp(r'\s+baad\s+me(in)?\s*$', caseSensitive: false),
  ];
  final lower = s.toLowerCase();
  for (final p in patterns) {
    final hit = p.firstMatch(lower);
    if (hit != null) {
      final matched = hit.group(0)!;
      final i = lower.lastIndexOf(matched);
      if (i > 0) {
        return (
          s.substring(0, i).trim(),
          _labelFromPriorityTail(matched),
        );
      }
    }
  }
  return (s, null);
}

/// Maps user text to `High` / `Medium` / `Low` (default Medium).
String parseTaskPriorityFromUserInput(String raw) {
  final s = raw.trim().toLowerCase();
  if (s.isEmpty) {
    return 'Medium';
  }
  if (RegExp(r'\b(high|urgent|jaldi)\b').hasMatch(s)) {
    return 'High';
  }
  if (RegExp(r'\b(baad\s*me|baadme|low)\b').hasMatch(s)) {
    return 'Low';
  }
  if (RegExp(r'\b(medium|normal)\b').hasMatch(s)) {
    return 'Medium';
  }
  return 'Medium';
}

/// If [input] contains a parseable deadline + task phrase (+ optional priority), returns
/// a full result so the flow can skip to confirm. Otherwise returns `null`.
TaskReminderOneLineResult? tryParseTaskReminderOneLine(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  final (afterPriority, pLabel) = stripTrailingTaskPriority(trimmed);
  var s = afterPriority.trim();
  if (s.isEmpty) {
    return null;
  }
  final words = s.split(RegExp(r'\s+'));
  if (words.length < 2) {
    return null;
  }

  ReminderDateStepParse? combo;
  var rest = '';
  var found = false;

  for (var i = words.length; i >= 1; i--) {
    final prefix = words.take(i).join(' ');
    final tryCombo = ReminderTimeParser.parseReminderDateStepAnswer(prefix);
    if (tryCombo != null) {
      combo = tryCombo;
      rest = words.sublist(i).join(' ').trim();
      found = true;
      break;
    }
  }

  if (!found) {
    for (var i = words.length; i >= 1; i--) {
      final suffix = words.sublist(words.length - i).join(' ');
      final tryCombo = ReminderTimeParser.parseReminderDateStepAnswer(suffix);
      if (tryCombo != null) {
        combo = tryCombo;
        rest = words.sublist(0, words.length - i).join(' ').trim();
        found = true;
        break;
      }
    }
  }

  if (combo == null || rest.length < 3) {
    return null;
  }

  final split = splitPossessiveTaskTitle(rest);
  if (split.title.length < 2) {
    return null;
  }

  return TaskReminderOneLineResult(
    taskTitle: split.title,
    clientName: split.client,
    dateMs: combo.dateMs,
    timeMinutes: combo.timeMinutes,
    priorityLabel: pLabel ?? 'Medium',
  );
}
