import '../../reminders/utils/reminder_time_parser.dart';
import '../utils/extract_inr_amount.dart';
import '../utils/task_reminder_parser.dart';
import 'flow_catalog.dart';

/// Result of [FlowStepEngine.applyAnswer].
sealed class FlowApplyResult {
  const FlowApplyResult();
}

class FlowApplyOk extends FlowApplyResult {
  const FlowApplyOk({
    required this.updatedData,
    required this.nextStepIndex,
    this.done = false,
  });

  final Map<String, dynamic> updatedData;
  final int nextStepIndex;
  final bool done;
}

class FlowApplyInvalid extends FlowApplyResult {
  const FlowApplyInvalid(this.message);
  final String message;
}

/// Conversational step engine (Phase 4): questions, answers, [pendingData] keys
/// [name], [amount], [date] (int ms), [note], [query], plus legacy [clientName] bridge.
class FlowStepEngine {
  const FlowStepEngine._();

  static const String kName = 'name';
  static const String kAmount = 'amount';
  static const String kDate = 'date';
  static const String kTime = 'time';
  static const String kNote = 'note';
  static const String kQuery = 'query';
  static const String kCategory = 'category';
  static const String kTaskTitle = 'taskTitle';
  static const String kBirthDate = 'birthDate';

  /// Map flow field key -> canonical [pendingData] key.
  static String canonicalKey(String fieldKey) {
    return switch (fieldKey) {
      'clientName' => kName,
      'time' => kTime,
      _ => fieldKey,
    };
  }

  static List<String> stepKeysFor(String category, String sub) =>
      fieldKeysFor(category, sub);

  static String? categoryIconFor(String? category) {
    return switch (category) {
      'reminder' => '📞',
      'payment' => '💰',
      'order' => '📦',
      'quotation' => '📄',
      'followup' => '🔁',
      'personal' => '📌',
      'reports' => '📈',
      _ => '✨',
    };
  }

  static String getNextQuestion(
    int stepIndex,
    String category,
    String sub,
  ) {
    final icon = category == 'reminder' && sub == 'task'
        ? '✅'
        : (categoryIconFor(category) ?? '✨');
    final keys = stepKeysFor(category, sub);
    if (stepIndex < 0 || stepIndex >= keys.length) {
      return '$icon Done — confirm karein.';
    }
    final k = keys[stepIndex];
    if (category == 'reminder' && sub != 'task' && k == 'time') {
      return '$icon Kitne baje yaad dilau?';
    }
    return '$icon ${fieldPrompt(k, category: category, sub: sub)}';
  }

  /// [pendingData] is required for reminder flows to validate required fields
  /// (name, date, time) before confirm/save.
  static bool isFlowComplete(
    int stepIndex,
    String category,
    String sub, {
    Map<String, dynamic>? pendingData,
  }) {
    final keys = stepKeysFor(category, sub);
    if (stepIndex < keys.length) {
      return false;
    }
    if (category == 'reminder' && pendingData != null) {
      final d = normalizeData(pendingData);
      final fcid = (d['flowCategoryId'] as String? ?? '').trim();
      if (fcid == 'reminder_task') {
        final tt = (d[kTaskTitle] ?? '').toString().trim();
        if (tt.isEmpty) {
          return false;
        }
        if (d[kDate] == null && d['date'] == null) {
          return false;
        }
        if (d[kTime] == null && d['time'] == null) {
          return false;
        }
        final pr = (d['priority'] ?? '').toString().trim();
        if (pr.isEmpty) {
          return false;
        }
        return true;
      }
      final name = (d[kName] ?? d['clientName'] ?? '').toString().trim();
      if (name.isEmpty) {
        return false;
      }
      final dateVal = d[kDate] ?? d['date'];
      if (dateVal == null) {
        return false;
      }
      final timeVal = d[kTime] ?? d['time'];
      if (timeVal == null) {
        return false;
      }
    }
    return true;
  }

  /// Step index for [field] in `reminder:*` flows (`name`, `date`, `time`, `note`).
  /// Returns -1 if the field is not in this flow.
  static int reminderStepIndexForEditField(String sub, String field) {
    final keys = stepKeysFor('reminder', sub);
    if (sub == 'task') {
      switch (field) {
        case 'taskTitle':
        case 'name':
          return keys.indexWhere((k) => k == 'taskTitle');
        case 'date':
        case 'time':
          return keys.indexWhere((k) => canonicalKey(k) == kDate);
        case 'priority':
          return keys.indexWhere((k) => k == 'priority');
        case 'note':
          return keys.indexWhere((k) => canonicalKey(k) == kNote);
        case 'clientName':
        case 'client':
          return -1;
        default:
          return -1;
      }
    }
    switch (field) {
      case 'name':
        return keys.indexWhere(
          (k) => canonicalKey(k) == kName || k == 'clientName',
        );
      case 'date':
        return keys.indexWhere((k) => canonicalKey(k) == kDate);
      case 'time':
        return keys.indexWhere((k) => k == 'time');
      case 'note':
        return keys.indexWhere((k) => canonicalKey(k) == kNote);
      default:
        return -1;
    }
  }

  /// Defaults merged when starting a flow (e.g. date = today, payment follow-up = +5d).
  static Map<String, dynamic> initialPendingData(
    String category,
    String sub,
  ) {
    final now = DateTime.now();
    final start = <String, dynamic>{
      'flowCategoryId': flowCategoryIdFor(category, sub),
    };

    if (category == 'payment' && sub == 'followup') {
      start[kDate] = now
          .add(const Duration(days: 5))
          .millisecondsSinceEpoch;
    }
    if (category == 'payment' && sub == 'received') {
      final today = DateTime(now.year, now.month, now.day);
      start[kDate] = today.millisecondsSinceEpoch;
    }
    return start;
  }

  /// Merges [raw] (may contain clientName) into name/amount/date/time/note, plus
  /// [kCategory] from [flowCategoryId] when present.
  static Map<String, dynamic> normalizeData(Map<String, dynamic> raw) {
    final o = Map<String, dynamic>.from(raw);
    final fcidEarly = (o['flowCategoryId'] as String? ?? '').trim();
    final isTaskReminder = fcidEarly == 'reminder_task';
    if (!isTaskReminder) {
      if (o.containsKey('clientName') && !o.containsKey(kName)) {
        o[kName] = o['clientName'];
      }
      if (o.containsKey(kName) && !o.containsKey('clientName')) {
        o['clientName'] = o[kName];
      }
    }
    final fcid = o['flowCategoryId'] as String?;
    if (fcid != null && fcid.isNotEmpty) {
      o[kCategory] = fcid;
    }
    return o;
  }

  /// Try to parse [userInput] for [fieldKey] and store under canonical key.
  static FlowApplyResult applyAnswer({
    required int stepIndex,
    required String category,
    required String sub,
    required Map<String, dynamic> pendingData,
    required String userInput,
  }) {
    final keys = stepKeysFor(category, sub);
    if (stepIndex < 0 || stepIndex >= keys.length) {
      return const FlowApplyInvalid('Flow already complete.');
    }
    final fieldKey = keys[stepIndex];
    final cKey = canonicalKey(fieldKey);
    var t = userInput.trim();
    if (t.isEmpty) {
      if (cKey == kTime) {
        t = 'skip';
      } else if (category == 'reminder' &&
          sub == 'task' &&
          fieldKey == 'note') {
        final next = Map<String, dynamic>.from(normalizeData(pendingData))
          ..remove(kNote)
          ..remove('note');
        final nextIndex = stepIndex + 1;
        final done = nextIndex >= keys.length;
        return FlowApplyOk(
          updatedData: next,
          nextStepIndex: nextIndex,
          done: done,
        );
      } else if (category == 'reminder' &&
          sub == 'task' &&
          fieldKey == 'priority') {
        t = 'medium';
      } else {
        return const FlowApplyInvalid('Kuch type karein.');
      }
    }

    if (category == 'reminder' && sub == 'task' && fieldKey == 'taskTitle') {
      final one = tryParseTaskReminderOneLine(t);
      if (one != null) {
        final next = Map<String, dynamic>.from(normalizeData(pendingData))
          ..[kTaskTitle] = one.taskTitle
          ..[kDate] = one.dateMs
          ..[kTime] = one.timeMinutes
          ..['priority'] = one.priorityLabel;
        next.remove('timeSkipped');
        if (one.clientName != null && one.clientName!.trim().isNotEmpty) {
          next['clientName'] = one.clientName!.trim();
        } else {
          next.remove('clientName');
        }
        return FlowApplyOk(
          updatedData: next,
          nextStepIndex: keys.length,
          done: true,
        );
      }
      final split = splitPossessiveTaskTitle(t);
      if (split.title.length < 2) {
        return const FlowApplyInvalid(
          'Task thoda clear likhiye — khaali nahi.',
        );
      }
      final next = Map<String, dynamic>.from(normalizeData(pendingData))
        ..[kTaskTitle] = split.title;
      if (split.client != null && split.client!.trim().isNotEmpty) {
        next['clientName'] = split.client!.trim();
      }
      final nextIndex = stepIndex + 1;
      final done = nextIndex >= keys.length;
      return FlowApplyOk(
        updatedData: next,
        nextStepIndex: nextIndex,
        done: done,
      );
    }

    if (category == 'reminder' && cKey == kDate) {
      final combo = ReminderTimeParser.parseReminderDateStepAnswer(t);
      if (combo == null) {
        return const FlowApplyInvalid(
          'Date clear nahi — aaj, kal, 10 din baad, ya 5 May bataiye (saath mein time bhi chalega).',
        );
      }
      final next = Map<String, dynamic>.from(normalizeData(pendingData))
        ..[kDate] = combo.dateMs
        ..[kTime] = combo.timeMinutes;
      next.remove('timeSkipped');
      var nextIndex = stepIndex + 1;
      if (stepIndex + 1 < keys.length &&
          keys[stepIndex + 1] == 'time' &&
          sub != 'task') {
        nextIndex = stepIndex + 2;
      }
      final done = nextIndex >= keys.length;
      return FlowApplyOk(
        updatedData: next,
        nextStepIndex: nextIndex,
        done: done,
      );
    }

    if (category == 'quotation' && cKey == kDate) {
      final combo = ReminderTimeParser.parseReminderDateStepAnswer(t);
      if (combo == null) {
        return const FlowApplyInvalid(
          'Follow-up date/time clear nahi — jaise kal 5pm, aaj 4 baje, ya 20 May 11am.',
        );
      }
      final day = DateTime.fromMillisecondsSinceEpoch(combo.dateMs);
      final h = combo.timeMinutes ~/ 60;
      final m = combo.timeMinutes % 60;
      final scheduled = DateTime(day.year, day.month, day.day, h, m);
      final next = Map<String, dynamic>.from(normalizeData(pendingData))
        ..[kDate] = scheduled.millisecondsSinceEpoch;
      final nextIndex = stepIndex + 1;
      final done = nextIndex >= keys.length;
      return FlowApplyOk(
        updatedData: next,
        nextStepIndex: nextIndex,
        done: done,
      );
    }

    if (category == 'followup' && cKey == kDate) {
      final combo = ReminderTimeParser.parseReminderDateStepAnswer(t);
      if (combo == null) {
        return const FlowApplyInvalid(
          'Follow-up date/time clear nahi — jaise kal 5pm, aaj 4 baje, ya 20 May 11am.',
        );
      }
      final day = DateTime.fromMillisecondsSinceEpoch(combo.dateMs);
      final h = combo.timeMinutes ~/ 60;
      final m = combo.timeMinutes % 60;
      final scheduled = DateTime(day.year, day.month, day.day, h, m);
      final next = Map<String, dynamic>.from(normalizeData(pendingData))
        ..[kDate] = scheduled.millisecondsSinceEpoch;
      final nextIndex = stepIndex + 1;
      final done = nextIndex >= keys.length;
      return FlowApplyOk(
        updatedData: next,
        nextStepIndex: nextIndex,
        done: done,
      );
    }
    if (category == 'personal' && sub == 'task' && cKey == kDate) {
      final combo = ReminderTimeParser.parseReminderDateStepAnswer(t);
      if (combo == null) {
        return const FlowApplyInvalid(
          'Date/time clear nahi — jaise kal 7pm, 20 May 10:30am.',
        );
      }
      final day = DateTime.fromMillisecondsSinceEpoch(combo.dateMs);
      final h = combo.timeMinutes ~/ 60;
      final m = combo.timeMinutes % 60;
      final scheduled = DateTime(day.year, day.month, day.day, h, m);
      final next = Map<String, dynamic>.from(normalizeData(pendingData))
        ..[kDate] = scheduled.millisecondsSinceEpoch;
      final nextIndex = stepIndex + 1;
      final done = nextIndex >= keys.length;
      return FlowApplyOk(
        updatedData: next,
        nextStepIndex: nextIndex,
        done: done,
      );
    }
    if (category == 'personal' && sub == 'birthday' && fieldKey == kBirthDate) {
      final parsed = _parseBirthdayDateToken(t);
      if (parsed == null) {
        return const FlowApplyInvalid(
          'Birthday date clear nahi — 20-05, 20/05, ya 20 May likhiye.',
        );
      }
      final next = Map<String, dynamic>.from(normalizeData(pendingData))
        ..[kBirthDate] = parsed;
      final nextIndex = stepIndex + 1;
      final done = nextIndex >= keys.length;
      return FlowApplyOk(
        updatedData: next,
        nextStepIndex: nextIndex,
        done: done,
      );
    }

    var parsed = _parseFieldValue(fieldKey, t);
    if (fieldKey == 'time' && parsed == null && t == 'skip') {
      parsed = 11 * 60;
    }
    if (parsed == null) {
      if (fieldKey == 'taskTitle' || cKey == kTaskTitle) {
        return const FlowApplyInvalid(
          'Task thoda clear likhiye — khaali nahi.',
        );
      }
      if (fieldKey == 'priority') {
        return const FlowApplyInvalid(
          'Priority bataiye — High, Medium, ya Low.',
        );
      }
      if (cKey == kName) {
        return const FlowApplyInvalid('Naam thoda saaf likhiye — khaali nahi.');
      }
      if (cKey == kAmount) {
        return const FlowApplyInvalid('Amount number mein — jaise 50000 ya ₹1,20,000.');
      }
      if (cKey == kDate) {
        return const FlowApplyInvalid('Date clear nahi — aaj, kal, ya 5 May bataiye.');
      }
      if (cKey == kTime) {
        return const FlowApplyInvalid(
          'Time clear nahi — jaise 10 baje, 3:30pm, ya "skip" (11 baje).',
        );
      }
      return const FlowApplyInvalid('Samjhe nahi — phir se try karein.');
    }
    final next = Map<String, dynamic>.from(normalizeData(pendingData))..[cKey] = parsed;
    if (fieldKey == 'time') {
      if (t == 'skip') {
        next['timeSkipped'] = true;
      } else {
        next.remove('timeSkipped');
      }
    }
    final nextIndex = stepIndex + 1;
    final done = nextIndex >= keys.length;
    return FlowApplyOk(
      updatedData: next,
      nextStepIndex: nextIndex,
      done: done,
    );
  }

  static Object? _parseFieldValue(String key, String text) {
    final s = text.trim();
    if (s.isEmpty) {
      return null;
    }
    final c = canonicalKey(key);
    if (c == kAmount) {
      if (const {'haan', 'yes', 'ok', 'theek'}.contains(s.toLowerCase())) {
        return null;
      }
      final a = extractInrAmountFromText(s) ??
          double.tryParse(s.replaceAll(RegExp(r'[₹,\s]'), ''));
      if (a == null || a <= 0) {
        return null;
      }
      return a;
    }
    if (c == kDate) {
      if (const {'haan', 'yes', 'ok'}.contains(s.toLowerCase())) {
        return null;
      }
      final day = ReminderTimeParser.resolveDateDayForReminderFlow(s);
      if (day == null) {
        return null;
      }
      return day.millisecondsSinceEpoch;
    }
    if (c == kName || c == 'clientName' || key == 'clientName') {
      if (s.length < 2) {
        return null;
      }
      return s;
    }
    if (c == kQuery) {
      return s;
    }
    if (c == kNote) {
      return s;
    }
    if (key == kBirthDate || c == kBirthDate) {
      return _parseBirthdayDateToken(s);
    }
    if (key == 'taskTitle' || c == kTaskTitle) {
      if (s.length < 2) {
        return null;
      }
      return s;
    }
    if (key == 'priority' || c == 'priority') {
      return parseTaskPriorityFromUserInput(s);
    }
    if (key == 'time' || c == kTime) {
      return ReminderTimeParser.tryParseTimeMinutesForFlowStep(s);
    }
    return s;
  }

  static String? _parseBirthdayDateToken(String raw) {
    final s = raw.trim().toLowerCase();
    if (s.isEmpty) {
      return null;
    }
    final m1 = RegExp(
      r'^(\d{1,2})[/-](\d{1,2})(?:[/-](\d{2,4}))?$',
    ).firstMatch(s);
    if (m1 != null) {
      final d = int.tryParse(m1.group(1) ?? '');
      final mo = int.tryParse(m1.group(2) ?? '');
      final yRaw = m1.group(3);
      final y = yRaw == null ? null : int.tryParse(yRaw);
      if (d != null && mo != null && d >= 1 && d <= 31 && mo >= 1 && mo <= 12) {
        if (y != null && y > 0) {
          final yy = y < 100 ? 2000 + y : y;
          return '${d.toString().padLeft(2, '0')}-${mo.toString().padLeft(2, '0')}-$yy';
        }
        return '${d.toString().padLeft(2, '0')}-${mo.toString().padLeft(2, '0')}';
      }
      return null;
    }
    final m2 = RegExp(
      r'^(\d{1,2})\s+([a-z]{3,9})(?:\s+(\d{4}))?$',
      caseSensitive: false,
    ).firstMatch(s);
    if (m2 == null) {
      return null;
    }
    final d = int.tryParse(m2.group(1) ?? '');
    final monTok = (m2.group(2) ?? '').toLowerCase();
    final y = int.tryParse(m2.group(3) ?? '');
    const month = <String, int>{
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
    final mo = month[monTok];
    if (d == null || mo == null || d < 1 || d > 31) {
      return null;
    }
    if (y != null && y > 0) {
      return '${d.toString().padLeft(2, '0')}-${mo.toString().padLeft(2, '0')}-$y';
    }
    return '${d.toString().padLeft(2, '0')}-${mo.toString().padLeft(2, '0')}';
  }
}
