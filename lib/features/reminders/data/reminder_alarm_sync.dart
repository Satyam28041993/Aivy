import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../../../core/notifications/notification_service.dart';

/// What one reminder document says an alarm should look like.
///
/// Reminders have been written by three code paths over the app's life — the
/// old chat flow, the reminders screen, and now the agent on the server — and
/// they do not all carry the same fields. Reading that is separated out so it
/// can be tested without a Firestore.
@immutable
class ReminderAlarm {
  const ReminderAlarm({
    required this.id,
    required this.whenMs,
    required this.title,
    required this.body,
    this.subtitle,
  });

  final String id;
  final int whenMs;
  final String title;
  final String body;
  final String? subtitle;

  /// Null when the document names no usable time — an alarm cannot be set for
  /// a reminder that does not say when.
  static ReminderAlarm? fromDoc(String id, Map<String, dynamic> data) {
    final whenMs = _readScheduledMs(data);
    if (whenMs <= 0) {
      return null;
    }
    final title = _firstText(data, const ['title', 'message']);
    final note = _firstText(data, const ['note', 'description']);
    final client = _text(data['clientName']);

    // The task is the headline; the body carries what the headline cannot.
    // It used to read "Aivy reminder", which told the reader nothing they did
    // not already know from the app's own icon.
    final parts = <String>[
      if (note.isNotEmpty) note,
      if (client.isNotEmpty) client,
      _timeLabel(whenMs),
    ].where((p) => p.isNotEmpty).toList();

    return ReminderAlarm(
      id: id,
      whenMs: whenMs,
      title: title.isNotEmpty ? title : 'Reminder',
      body: parts.isEmpty ? 'Reminder' : parts.join(' · '),
      subtitle: client.isNotEmpty ? client : null,
    );
  }
}

int _readScheduledMs(Map<String, dynamic> data) {
  final ms = data['scheduledTimeMs'];
  if (ms is num && ms > 0) {
    return ms.toInt();
  }
  final at = data['scheduledAt'];
  if (at is Timestamp) {
    return at.millisecondsSinceEpoch;
  }
  if (at is DateTime) {
    return at.millisecondsSinceEpoch;
  }
  return 0;
}

String _text(Object? raw) => raw is String ? raw.trim() : '';

/// "3:45 PM" in the phone's own zone, which is the zone the user set it in.
String _timeLabel(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final minute = t.minute.toString().padLeft(2, '0');
  return '$hour:$minute ${t.hour < 12 ? 'AM' : 'PM'}';
}

String _firstText(Map<String, dynamic> data, List<String> keys) {
  for (final k in keys) {
    final v = _text(data[k]);
    if (v.isNotEmpty) {
      return v;
    }
  }
  return '';
}

/// Keeps the phone's alarms in step with the reminders in Firestore.
///
/// A reminder created inside the app scheduled its own local notification on
/// the way out. A reminder created by talking to Aivy never could: that write
/// happens on the server, so the phone was never told, and the reminder only
/// ever appeared as a line in the in-app list — silently, whenever the app
/// next happened to be open.
///
/// So the alarm is no longer tied to who created the reminder. This watches
/// every pending reminder and schedules one for each, which also repairs a
/// reminder made on another device, or before the app was reinstalled.
class ReminderAlarmSync {
  /// Reminders this has seen, and alarms it managed to queue.
  ///
  /// "Alarms queued: 0" means two very different things — that this never ran,
  /// or that it ran and every attempt was refused — and from a phone they look
  /// the same. These separate them.
  static int seen = 0;
  static int queued = 0;

  ReminderAlarmSync({
    FirebaseFirestore? firestore,
    NotificationService? notifications,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _notifications = notifications ?? NotificationService.instance;

  final FirebaseFirestore _firestore;
  final NotificationService _notifications;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;

  /// Reminder ids that already carry an alarm, so an unrelated change to the
  /// document — a note edited, a client attached — does not rebuild all of them.
  final Map<String, int> _scheduled = <String, int>{};

  /// Far enough ahead to cover anything a person would set by talking, and
  /// short enough that the OS is not holding hundreds of pending alarms.
  static const Duration _horizon = Duration(days: 60);

  void start(String userId) {
    if (userId.isEmpty || kIsWeb) {
      // Browsers have no alarm to set; the in-app list is the whole story there.
      return;
    }
    unawaited(_sub?.cancel());
    _scheduled.clear();
    _sub = _firestore
        .collection('users')
        .doc(userId)
        .collection('reminders')
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .listen(_apply, onError: (Object e) {
      debugPrint('ReminderAlarmSync: reminder stream failed: $e');
    });
  }

  Future<void> _apply(QuerySnapshot<Map<String, dynamic>> snap) async {
    final live = <String>{};
    final cutoffMs = DateTime.now().add(_horizon).millisecondsSinceEpoch;

    for (final doc in snap.docs) {
      final alarm = ReminderAlarm.fromDoc(doc.id, doc.data());
      if (alarm == null || alarm.whenMs > cutoffMs) {
        continue;
      }
      live.add(alarm.id);
      seen++;
      // Same reminder, same minute — the alarm standing on the OS is correct.
      if (_scheduled[alarm.id] == alarm.whenMs) {
        continue;
      }
      _scheduled[alarm.id] = alarm.whenMs;

      try {
        await _notifications.scheduleReminderNotification(
          title: alarm.title,
          body: alarm.body,
          subtitle: alarm.subtitle,
          scheduledTime: DateTime.fromMillisecondsSinceEpoch(alarm.whenMs),
          reminderId: alarm.id,
        );
        queued++;
      } catch (e) {
        debugPrint('ReminderAlarmSync: could not schedule ${alarm.id}: $e');
        _scheduled.remove(alarm.id);
      }
    }

    // Done, cancelled, or moved out of range — the alarm has to go with it,
    // or a reminder ticked off on the dashboard still rings at seven.
    for (final id in _scheduled.keys.toList()) {
      if (live.contains(id)) {
        continue;
      }
      _scheduled.remove(id);
      try {
        await _notifications.cancelReminderNotification(id);
      } catch (e) {
        debugPrint('ReminderAlarmSync: could not cancel $id: $e');
      }
    }
  }

  void dispose() {
    unawaited(_sub?.cancel());
    _sub = null;
    _scheduled.clear();
  }
}
