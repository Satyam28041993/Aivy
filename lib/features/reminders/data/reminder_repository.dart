import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../../../core/notifications/notification_service.dart';
import '../../chat/models/aivy_ai_response.dart';
import '../utils/reminder_scheduling.dart';
import '../utils/reminder_time_parser.dart';

/// User-scoped reminders: `users/{userId}/reminders/*`.
class ReminderRepository {
  ReminderRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> _col(String userId) {
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('reminders');
  }

  /// Creates a scheduled reminder; returns the new document id.
  Future<String> createReminder({
    required String userId,
    required String title,
    required DateTime scheduledAt,
    required String type,
    required String subType,
    String? note,
    String? clientName,
    String? priority,
    Map<String, dynamic>? extraFields,
  }) async {
    final ref = _col(userId).doc();
    final local = scheduledAt.toLocal();
    final scheduledMs = ReminderScheduling.derivedScheduledTimeMs(local);
    final createdMs = DateTime.now().millisecondsSinceEpoch;
    final data = <String, dynamic>{
      'title': title.trim(),
      'scheduledAt': Timestamp.fromDate(local),
      'scheduledTimeMs': scheduledMs,
      'type': type.trim().toLowerCase(),
      'subType': subType.trim(),
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
      'createdAtMs': createdMs,
    };
    if (note != null && note.trim().isNotEmpty) {
      data['note'] = note.trim();
    }
    if (clientName != null && clientName.trim().isNotEmpty) {
      data['clientName'] = clientName.trim();
    }
    if (priority != null && priority.trim().isNotEmpty) {
      data['priority'] = priority.trim().toLowerCase();
    }
    if (extraFields != null && extraFields.isNotEmpty) {
      data.addAll(extraFields);
    }
    await ref.set(data);
    try {
      final subtitle = (clientName != null && clientName.trim().isNotEmpty)
          ? clientName.trim()
          : null;
      final body = (note != null && note.trim().isNotEmpty)
          ? note.trim()
          : 'Aivy reminder';
      await NotificationService.instance.scheduleReminderNotification(
        title: title.trim(),
        body: body,
        subtitle: subtitle,
        scheduledTime: local,
        reminderId: ref.id,
      );
    } catch (error, stackTrace) {
      debugPrint(
        'ReminderRepository: schedule reminder notification failed: '
        '$error\n$stackTrace',
      );
    }
    debugPrint(
      'AIVY_REMINDER_FINAL_SAVE: {title: ${data['title']}, type: ${data['type']}, subType: ${data['subType']}, '
      'scheduledAt: ${local.toIso8601String()}, '
      'scheduledTimeMs: $scheduledMs (derived), status: pending'
      '${note != null && note.trim().isNotEmpty ? ', note: ${note.trim()}' : ''}'
      '${clientName != null && clientName.trim().isNotEmpty ? ', clientName: ${clientName.trim()}' : ''}}',
    );
    return ref.id;
  }

  /// Persists each [ReminderSuggestion] from Aivy as a real `reminders` doc.
  /// Only suggestions with a non-empty title and a resolvable schedule are saved.
  Future<List<({String id, ReminderSuggestion suggestion, DateTime scheduledAt})>>
      persistAiReminderSuggestions({
    required String userId,
    required String entryId,
    required List<ReminderSuggestion> suggestions,
    String? sourceSnippet,
  }) async {
    final out = <({String id, ReminderSuggestion suggestion, DateTime scheduledAt})>[];
    for (final s in suggestions) {
      final title = s.title.trim();
      if (title.isEmpty) {
        continue;
      }
      final when = ReminderTimeParser.resolveScheduledTime(s);
      if (when == null) {
        if (kDebugMode) {
          debugPrint(
            'ReminderRepository: skip AI reminder "$title" — no schedule '
            '(hint="${s.timeHint}" iso=${s.scheduledAtIso})',
          );
        }
        continue;
      }
      final rt = (s.reminderType ?? '').trim().toLowerCase();
      final type =
          rt == 'payment_followup' || rt == 'manual_payment' ? 'followup' : 'task';
      final subType = rt.isNotEmpty ? rt : 'aivy_chat';
      final noteParts = <String>[];
      if (sourceSnippet != null && sourceSnippet.trim().isNotEmpty) {
        noteParts.add(sourceSnippet.trim());
      }
      if (s.note != null && s.note!.trim().isNotEmpty) {
        noteParts.add(s.note!.trim());
      }
      if (s.timeHint.trim().isNotEmpty) {
        noteParts.add('Time: ${s.timeHint.trim()}');
      }
      final note = noteParts.isEmpty ? null : noteParts.join(' · ');
      final id = await createReminder(
        userId: userId,
        title: title,
        scheduledAt: when,
        type: type,
        subType: subType,
        note: note,
        clientName: (s.displayClientName ?? '').trim().isNotEmpty
            ? s.displayClientName!.trim()
            : null,
        priority: s.priority,
        extraFields: {
          'entryId': entryId,
          'source': 'aivy_ai',
          if (s.orderId != null && s.orderId!.trim().isNotEmpty)
            'orderId': s.orderId!.trim(),
          if (s.paymentId != null && s.paymentId!.trim().isNotEmpty)
            'paymentId': s.paymentId!.trim(),
        },
      );
      out.add((id: id, suggestion: s, scheduledAt: when));
    }
    return out;
  }

  /// Re-syncs pending reminder notifications on app launch so reminders still
  /// fire if older rows were created before notification scheduling was added
  /// or if notifications were cleared by OS/update.
  Future<void> syncPendingReminderNotifications(
    String userId, {
    int lookAheadDays = 90,
    int limit = 300,
  }) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final maxMs = nowMs + Duration(days: lookAheadDays).inMilliseconds;
    final snap = await _col(userId)
        .where('status', isEqualTo: 'pending')
        .where('scheduledTimeMs', isGreaterThanOrEqualTo: nowMs)
        .where('scheduledTimeMs', isLessThanOrEqualTo: maxMs)
        .orderBy('scheduledTimeMs')
        .limit(limit)
        .get();
    for (final doc in snap.docs) {
      final data = doc.data();
      final title = (data['title'] as String? ?? '').trim();
      if (title.isEmpty) {
        continue;
      }
      final ms = ReminderScheduling.epochMsFromFirestoreMap(data);
      if (ms <= 0) {
        continue;
      }
      final scheduled = DateTime.fromMillisecondsSinceEpoch(ms);
      final note = (data['note'] as String? ?? '').trim();
      final clientName = (data['clientName'] as String? ?? '').trim();
      await NotificationService.instance.scheduleReminderNotification(
        title: title,
        body: note.isNotEmpty ? note : 'Aivy reminder',
        subtitle: clientName.isNotEmpty ? clientName : null,
        scheduledTime: scheduled,
        reminderId: doc.id,
      );
    }
  }

  Future<String> rescheduleQuotationFollowUpReminder({
    required String userId,
    required String quotationId,
    required DateTime scheduledAt,
    required String clientName,
    String? note,
  }) async {
    final existing = await _col(userId)
        .where('quotationId', isEqualTo: quotationId)
        .where('status', isEqualTo: 'pending')
        .get();
    for (final d in existing.docs) {
      await d.reference.update({
        'status': 'completed',
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    final title = 'Quotation follow-up: ${clientName.trim()}';
    return createReminder(
      userId: userId,
      title: title,
      scheduledAt: scheduledAt,
      type: 'followup',
      subType: 'quotation_followup',
      note: note,
      clientName: clientName,
      extraFields: {
        'quotationId': quotationId,
        'isFollowUp': true,
      },
    );
  }

  /// Used when undoing a just-created in-chat reminder.
  Future<void> deleteReminder(String userId, String docId) async {
    await _col(userId).doc(docId).delete();
  }
}
