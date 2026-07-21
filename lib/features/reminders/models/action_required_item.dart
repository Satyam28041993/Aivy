import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint, immutable, kDebugMode;

import 'reminder_item.dart';

/// Grouping for the smart reminder popup: overdue, due today, or upcoming (≤24h).
enum ActionRequiredBucket {
  overdue,
  today,
  upcoming,
}

/// Row built from a `reminders` doc, a `payments` doc, or both (deduped by paymentId).
@immutable
class ActionRequiredItem {
  const ActionRequiredItem({
    required this.id,
    required this.source,
    required this.bucket,
    required this.titleLine,
    required this.subtitleLine,
    required this.reminderType,
    required this.dueOrScheduleMs,
    this.paymentId,
    this.reminderId,
    this.clientPhone,
    this.amount,
  });

  final String id;
  final ActionRequiredSource source;
  final ActionRequiredBucket bucket;
  final String titleLine;
  final String subtitleLine;
  final String reminderType;
  final int dueOrScheduleMs;
  final String? paymentId;
  final String? reminderId;
  final String? clientPhone;
  final double? amount;

  /// Firestore [scheduledTimeMs] and/or [remindAt] on reminders; uses `remindAt` if present in data.
  static int _reminderDueMs(Map<String, dynamic> data) {
    final a = (data['scheduledTimeMs'] as num?)?.toInt();
    if (a != null && a > 0) {
      return a;
    }
    final r = data['remindAt'];
    if (r is Timestamp) {
      return r.millisecondsSinceEpoch;
    }
    return 0;
  }

  static ActionRequiredBucket _bucketForMs(int dueMs) {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final due = DateTime.fromMillisecondsSinceEpoch(dueMs, isUtc: false);
    final dueDay = DateTime(due.year, due.month, due.day);
    if (dueDay.isBefore(todayStart)) {
      return ActionRequiredBucket.overdue;
    }
    if (dueDay == todayStart) {
      return ActionRequiredBucket.today;
    }
    return ActionRequiredBucket.upcoming;
  }

  static int wholeDaysOverdue(int dueMs) {
    final now = DateTime.now();
    final due = DateTime.fromMillisecondsSinceEpoch(dueMs);
    final todayStart = DateTime(now.year, now.month, now.day);
    final dueDay = DateTime(due.year, due.month, due.day);
    if (!dueDay.isBefore(todayStart)) {
      return 0;
    }
    return todayStart.difference(dueDay).inDays;
  }

  static String _formatSubtitle(ActionRequiredBucket bucket, int dueMs) {
    switch (bucket) {
      case ActionRequiredBucket.upcoming:
        return 'Upcoming';
      case ActionRequiredBucket.today:
        return 'Due Today';
      case ActionRequiredBucket.overdue:
        final d = wholeDaysOverdue(dueMs);
        if (d <= 0) {
          return 'Overdue';
        }
        return 'Overdue ($d day${d == 1 ? '' : 's'})';
    }
  }

  String get subtitle => _formatSubtitle(bucket, dueOrScheduleMs);

  String get iconEmoji {
    final t = reminderType.toLowerCase();
    switch (t) {
      case 'call':
        return '📞';
      case 'followup':
        return '🔁';
      case 'meeting':
        return '🗓️';
      case 'payment':
      case 'payment_followup':
      case 'manual_payment':
        return '💰';
      default:
        break;
    }
    final hinted = reminderIconEmojiHintFromTitles(title: titleLine);
    if (hinted != null) {
      return hinted;
    }
    return '📌';
  }

  /// e.g. `Ramesh ₹50,000 — Due Today` (pass formatted currency from UI).
  String toListLine(String formattedInr) {
    final amt = amount;
    if (amt != null && amt > 0 && formattedInr.isNotEmpty) {
      return '$titleLine $formattedInr — $subtitle';
    }
    return '$titleLine — $subtitle';
  }

  factory ActionRequiredItem.fromPaymentDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final name = (data['clientName'] as String? ?? data['client'] as String? ?? 'Client')
        .trim();
    final safeName = name.isNotEmpty ? name : 'Client';
    final rem = (data['remainingAmount'] as num?)?.toDouble();
    final amtRaw = (data['amount'] as num?)?.toDouble() ?? 0.0;
    final amount = (rem != null && rem >= 0) ? rem : amtRaw;
    final dueMs = (data['dueDateMs'] as num?)?.toInt() ?? 0;
    final phone = (data['clientPhone'] as String? ?? data['phone'] as String? ?? '')
        .trim();
    // Server marks overdue; treat as highest bucket.
    return ActionRequiredItem(
      id: doc.id,
      source: ActionRequiredSource.payment,
      bucket: ActionRequiredBucket.overdue,
      titleLine: safeName,
      subtitleLine: 'Payment follow-up',
      reminderType: 'payment',
      dueOrScheduleMs: dueMs > 0 ? dueMs : DateTime.now().millisecondsSinceEpoch,
      paymentId: doc.id,
      reminderId: null,
      clientPhone: phone.isNotEmpty ? phone : null,
      amount: amount > 0 ? amount : null,
    );
  }

  factory ActionRequiredItem.fromReminderDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final r = ReminderItem.fromDoc(doc);
    final dueMs = _reminderDueMs(data) != 0
        ? _reminderDueMs(data)
        : r.scheduledTimeMs;
    final bucket = _bucketForMs(dueMs);
    // Prefer structured [displayTitle] / [displaySubtitle] (re-parses [rawInput] when present).
    final displayTitle = r.displayTitle;
    var subtitle = r.displaySubtitle.trim();
    if (subtitle.isEmpty) {
      final name = (data['clientName'] as String? ?? '').trim();
      if (name.isNotEmpty && name.toLowerCase() != displayTitle.toLowerCase()) {
        subtitle = name;
      } else {
        final label = (data['clientLabel'] as String? ?? '').trim();
        if (label.isNotEmpty && label.toLowerCase() != displayTitle.toLowerCase()) {
          subtitle = label;
        }
      }
    }
    final amount = (data['amount'] as num?)?.toDouble();
    final phone = (data['clientPhone'] as String? ?? data['phone'] as String? ?? '')
        .trim();
    final type = r.effectiveDocType;
    final payRaw =
        (data['paymentId'] as String? ?? data['linkedId'] as String? ?? '')
            .trim();
    return ActionRequiredItem(
      id: doc.id,
      source: ActionRequiredSource.reminder,
      bucket: bucket,
      titleLine: displayTitle,
      subtitleLine: subtitle,
      reminderType: type,
      dueOrScheduleMs: dueMs,
      paymentId: payRaw.isNotEmpty ? payRaw : null,
      reminderId: doc.id,
      clientPhone: phone.isNotEmpty ? phone : null,
      amount: amount != null && amount > 0 ? amount : null,
    );
  }

  static int compareForPopup(ActionRequiredItem a, ActionRequiredItem b) {
    const order = {
      ActionRequiredBucket.overdue: 0,
      ActionRequiredBucket.today: 1,
      ActionRequiredBucket.upcoming: 2,
    };
    final c = (order[a.bucket] ?? 99).compareTo(order[b.bucket] ?? 99);
    if (c != 0) {
      return c;
    }
    return a.dueOrScheduleMs.compareTo(b.dueOrScheduleMs);
  }

  static List<ActionRequiredItem> mergeDedupe(
    List<ActionRequiredItem> payments,
    List<ActionRequiredItem> reminders,
  ) {
    final paymentIds = <String>{};
    for (final p in payments) {
      if (p.paymentId != null) {
        paymentIds.add(p.paymentId!);
      }
    }
    final out = <ActionRequiredItem>[...payments];
    for (final r in reminders) {
      final pid = r.paymentId;
      if (pid != null && paymentIds.contains(pid)) {
        if (kDebugMode) {
          debugPrint('ImportantReminders: skip duplicate reminder for payment $pid');
        }
        continue;
      }
      out.add(r);
    }
    out.sort(ActionRequiredItem.compareForPopup);
    return out;
  }
}

enum ActionRequiredSource { reminder, payment }
