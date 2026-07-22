import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/intl.dart';

import '../../../features/payments/data/payment_repository.dart';
import '../../../features/payments/models/payment_record.dart';
import '../../../features/tasks/models/task_item.dart';

/// Time window helpers for voice business tools (mirrors `aivyVoiceAsk` snapshot).
class AivyBusinessTimeContext {
  AivyBusinessTimeContext({
    required this.timezone,
    required this.now,
  })  : nowMs = now.millisecondsSinceEpoch,
        startOfTodayMs = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch,
        endOfTodayMs = DateTime(now.year, now.month, now.day, 23, 59, 59, 999)
            .millisecondsSinceEpoch,
        startOfTomorrowMs = DateTime(now.year, now.month, now.day)
            .add(const Duration(days: 1))
            .millisecondsSinceEpoch,
        endOfTomorrowMs = DateTime(now.year, now.month, now.day)
            .add(const Duration(days: 1, hours: 23, minutes: 59, seconds: 59, milliseconds: 999))
            .millisecondsSinceEpoch,
        weekAheadMs = DateTime(now.year, now.month, now.day)
            .add(const Duration(days: 7, hours: 23, minutes: 59, seconds: 59, milliseconds: 999))
            .millisecondsSinceEpoch;

  final String timezone;
  final DateTime now;
  final int nowMs;
  final int startOfTodayMs;
  final int endOfTodayMs;
  final int startOfTomorrowMs;
  final int endOfTomorrowMs;
  final int weekAheadMs;

  String get localHuman => DateFormat('d MMM yyyy, h:mm a').format(now);

  static Future<AivyBusinessTimeContext> localNow() async {
    String timezone;
    try {
      timezone = await FlutterTimezone.getLocalTimezone();
    } catch (_) {
      timezone = 'Asia/Kolkata';
    }
    return AivyBusinessTimeContext(timezone: timezone, now: DateTime.now());
  }
}

/// One reminder row for Gemini tool responses.
class AivyReminderRow {
  const AivyReminderRow({
    required this.id,
    required this.kind,
    required this.title,
    this.client,
    required this.scheduledMs,
    required this.whenLabel,
  });

  final String id;
  final String kind;
  final String title;
  final String? client;
  final int scheduledMs;
  final String whenLabel;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'title': title,
        if (client != null) 'client': client,
        'scheduledMs': scheduledMs,
        'when': whenLabel,
      };
}

/// One task row for Gemini tool responses.
class AivyTaskRow {
  const AivyTaskRow({
    required this.id,
    required this.title,
    required this.category,
    this.dueMs,
    this.dueLabel,
  });

  final String id;
  final String title;
  final String category;
  final int? dueMs;
  final String? dueLabel;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'category': category,
        if (dueMs != null) 'dueMs': dueMs,
        if (dueLabel != null) 'dueLabel': dueLabel,
      };
}

int readReminderScheduledMs(Map<String, dynamic> d) {
  final ms = (d['scheduledTimeMs'] as num?)?.toInt() ??
      (d['remindAt'] as num?)?.toInt() ??
      0;
  return ms > 0 ? ms : 0;
}

String reminderKind(Map<String, dynamic> d) {
  final type = (d['type'] as String? ?? '').toLowerCase();
  final sub = (d['subType'] as String? ?? '').toLowerCase();
  final blob = [
    d['title'],
    d['message'],
    d['description'],
    type,
    sub,
  ].map((x) => (x ?? '').toString().toLowerCase()).join(' ');

  if (type == 'followup' || sub.contains('followup') || blob.contains('follow')) {
    return 'follow_up';
  }
  if (type == 'meeting' || blob.contains('meeting')) {
    return 'meeting';
  }
  if (type == 'call' || blob.contains('call')) {
    return 'call';
  }
  return 'reminder';
}

AivyReminderRow reminderRowFromDoc(
  QueryDocumentSnapshot<Map<String, dynamic>> doc,
  DateTime now,
) {
  final d = doc.data();
  final ms = readReminderScheduledMs(d);
  final kind = reminderKind(d);
  final client = (d['clientName'] as String? ?? d['client'] as String? ?? '')
      .trim();
  final title =
      (d['title'] as String? ?? d['message'] as String? ?? 'Reminder').trim();
  return AivyReminderRow(
    id: doc.id,
    kind: kind,
    title: title.isEmpty ? 'Reminder' : title,
    client: client.isEmpty ? null : client,
    scheduledMs: ms,
    whenLabel: DateFormat('d MMM, h:mm a').format(
      DateTime.fromMillisecondsSinceEpoch(ms),
    ),
  );
}

/// Loads structured business data from Firestore for Gemini Live function calling.
class AivyBusinessSnapshotService {
  AivyBusinessSnapshotService({
    required this.userId,
    FirebaseFirestore? firestore,
    PaymentRepository? payments,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _payments = payments ?? PaymentRepository();

  final String userId;
  final FirebaseFirestore _firestore;
  final PaymentRepository _payments;

  DocumentReference<Map<String, dynamic>> get _userDoc =>
      _firestore.collection('users').doc(userId);

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _pendingReminders() async {
    final snap = await _userDoc
        .collection('reminders')
        .where('status', isEqualTo: 'pending')
        .limit(200)
        .get();
    final docs = snap.docs.toList()
      ..sort((a, b) =>
          readReminderScheduledMs(a.data()) - readReminderScheduledMs(b.data()));
    return docs;
  }

  Future<List<TaskItem>> _pendingTasks() async {
    final snap = await _userDoc
        .collection('tasks')
        .where('status', isEqualTo: 'pending')
        .limit(120)
        .get();
    return snap.docs.map(TaskItem.fromDoc).toList();
  }

  List<AivyReminderRow> _remindersInRange({
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    required int startMs,
    required int endMs,
    String? kindFilter,
    required DateTime now,
  }) {
    final out = <AivyReminderRow>[];
    for (final doc in docs) {
      final ms = readReminderScheduledMs(doc.data());
      if (ms < startMs || ms > endMs) {
        continue;
      }
      final row = reminderRowFromDoc(doc, now);
      if (kindFilter != null && row.kind != kindFilter) {
        continue;
      }
      out.add(row);
    }
    return out;
  }

  Future<Map<String, dynamic>> getCallsToday([AivyBusinessTimeContext? tc]) async {
    final ctx = tc ?? await AivyBusinessTimeContext.localNow();
    final docs = await _pendingReminders();
    final calls = _remindersInRange(
      docs: docs,
      startMs: ctx.startOfTodayMs,
      endMs: ctx.endOfTodayMs,
      kindFilter: 'call',
      now: ctx.now,
    );
    return {
      'generatedAt': ctx.localHuman,
      'timezone': ctx.timezone,
      'callsToday': calls.map((e) => e.toJson()).toList(),
      'count': calls.length,
    };
  }

  Future<Map<String, dynamic>> getFollowUpsToday(
      [AivyBusinessTimeContext? tc]) async {
    final ctx = tc ?? await AivyBusinessTimeContext.localNow();
    final docs = await _pendingReminders();
    final rows = _remindersInRange(
      docs: docs,
      startMs: ctx.startOfTodayMs,
      endMs: ctx.endOfTodayMs,
      kindFilter: 'follow_up',
      now: ctx.now,
    );
    return {
      'generatedAt': ctx.localHuman,
      'timezone': ctx.timezone,
      'followUpsToday': rows.map((e) => e.toJson()).toList(),
      'count': rows.length,
    };
  }

  Future<Map<String, dynamic>> getFollowUpsTomorrow(
      [AivyBusinessTimeContext? tc]) async {
    final ctx = tc ?? await AivyBusinessTimeContext.localNow();
    final docs = await _pendingReminders();
    final rows = _remindersInRange(
      docs: docs,
      startMs: ctx.startOfTomorrowMs,
      endMs: ctx.endOfTomorrowMs,
      kindFilter: 'follow_up',
      now: ctx.now,
    );
    return {
      'generatedAt': ctx.localHuman,
      'timezone': ctx.timezone,
      'followUpsTomorrow': rows.map((e) => e.toJson()).toList(),
      'count': rows.length,
    };
  }

  Future<Map<String, dynamic>> getTodaysSummary(
      [AivyBusinessTimeContext? tc]) async {
    final ctx = tc ?? await AivyBusinessTimeContext.localNow();
    final docs = await _pendingReminders();
    final tasks = await _pendingTasks();

    final todayReminders = _remindersInRange(
      docs: docs,
      startMs: ctx.startOfTodayMs,
      endMs: ctx.endOfTodayMs,
      now: ctx.now,
    );
    final calls =
        todayReminders.where((r) => r.kind == 'call').map((e) => e.toJson());
    final meetings =
        todayReminders.where((r) => r.kind == 'meeting').map((e) => e.toJson());
    final followUps = todayReminders
        .where((r) => r.kind == 'follow_up')
        .map((e) => e.toJson());

    final tasksToday = <AivyTaskRow>[];
    for (final t in tasks) {
      final due = t.dueDateMs;
      if (due == null || due < ctx.startOfTodayMs || due > ctx.endOfTodayMs) {
        continue;
      }
      tasksToday.add(
        AivyTaskRow(
          id: t.id,
          title: t.title.trim().isEmpty ? 'Task' : t.title.trim(),
          category: t.category,
          dueMs: due,
          dueLabel: DateFormat('d MMM, h:mm a')
              .format(DateTime.fromMillisecondsSinceEpoch(due)),
        ),
      );
    }

    return {
      'generatedAt': ctx.localHuman,
      'timezone': ctx.timezone,
      'todaysFocus': {
        'callsToday': calls.toList(),
        'meetingsToday': meetings.toList(),
        'followUpsToday': followUps.toList(),
        'remindersToday': todayReminders.map((e) => e.toJson()).toList(),
        'tasksDueToday': tasksToday.map((e) => e.toJson()).toList(),
      },
      'counts': {
        'callsToday': todayReminders.where((r) => r.kind == 'call').length,
        'followUpsToday':
            todayReminders.where((r) => r.kind == 'follow_up').length,
        'tasksDueToday': tasksToday.length,
      },
    };
  }

  Future<Map<String, dynamic>> getOverdueItems(
      [AivyBusinessTimeContext? tc]) async {
    final ctx = tc ?? await AivyBusinessTimeContext.localNow();
    final docs = await _pendingReminders();
    final tasks = await _pendingTasks();

    final overdueReminders = <AivyReminderRow>[];
    for (final doc in docs) {
      final ms = readReminderScheduledMs(doc.data());
      if (ms <= 0 || ms >= ctx.startOfTodayMs) {
        continue;
      }
      overdueReminders.add(reminderRowFromDoc(doc, ctx.now));
    }

    final overdueTasks = <AivyTaskRow>[];
    for (final t in tasks) {
      final due = t.dueDateMs;
      if (due == null || due >= ctx.startOfTodayMs) {
        continue;
      }
      overdueTasks.add(
        AivyTaskRow(
          id: t.id,
          title: t.title.trim().isEmpty ? 'Task' : t.title.trim(),
          category: t.category,
          dueMs: due,
          dueLabel: DateFormat('d MMM, h:mm a')
              .format(DateTime.fromMillisecondsSinceEpoch(due)),
        ),
      );
    }

    return {
      'generatedAt': ctx.localHuman,
      'timezone': ctx.timezone,
      'overdue': {
        'reminders': overdueReminders.map((e) => e.toJson()).toList(),
        'tasks': overdueTasks.map((e) => e.toJson()).toList(),
      },
      'counts': {
        'overdueReminders': overdueReminders.length,
        'overdueTasks': overdueTasks.length,
      },
    };
  }

  Future<Map<String, dynamic>> getPaymentFollowUps(
      [AivyBusinessTimeContext? tc]) async {
    final ctx = tc ?? await AivyBusinessTimeContext.localNow();
    final dues = await _payments.getAllOpenDues(userId);
    final rows = <Map<String, dynamic>>[];

    for (final p in dues) {
      final due = p.dueDateMs;
      if (due == null) {
        continue;
      }
      final inWeek = due <= ctx.weekAheadMs;
      final overdue = due < ctx.startOfTodayMs;
      if (!inWeek && !overdue) {
        continue;
      }
      rows.add(_paymentRow(p, ctx.now, overdue: overdue));
      if (rows.length >= 25) {
        break;
      }
    }

    rows.sort((a, b) {
      final ad = (a['dueDateMs'] as int?) ?? 0;
      final bd = (b['dueDateMs'] as int?) ?? 0;
      return ad.compareTo(bd);
    });

    return {
      'generatedAt': ctx.localHuman,
      'timezone': ctx.timezone,
      'paymentFollowUpsThisWeek': rows,
      'count': rows.length,
    };
  }

  Map<String, dynamic> _paymentRow(
    PaymentRecord p,
    DateTime now, {
    required bool overdue,
  }) {
    final due = p.dueDateMs ?? 0;
    final daysLate = overdue && due > 0
        ? now.difference(DateTime.fromMillisecondsSinceEpoch(due)).inDays
        : 0;
    return {
      'client': p.clientName,
      'amountInr': p.effectiveRemaining,
      'dueDateMs': due > 0 ? due : null,
      'dueDateLabel': due > 0
          ? DateFormat('d MMM yyyy').format(
              DateTime.fromMillisecondsSinceEpoch(due),
            )
          : null,
      'daysLate': daysLate,
      'status': p.status,
    };
  }

  Future<Map<String, dynamic>> executeTool(
    String name, [
    Map<String, dynamic>? args,
  ]) async {
    switch (name) {
      case 'get_calls_today':
        return getCallsToday();
      case 'get_followups_today':
        return getFollowUpsToday();
      case 'get_followups_tomorrow':
        return getFollowUpsTomorrow();
      case 'get_todays_summary':
        return getTodaysSummary();
      case 'get_overdue_items':
        return getOverdueItems();
      case 'get_payment_followups':
        return getPaymentFollowUps();
      default:
        return {'error': 'Unknown tool: $name'};
    }
  }
}
