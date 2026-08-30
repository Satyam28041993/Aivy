import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aivy/features/reminders/data/reminder_alarm_sync.dart';

void main() {
  group('ReminderAlarm.fromDoc', () {
    test('reads a reminder the agent wrote on the server', () {
      final alarm = ReminderAlarm.fromDoc('r1', {
        'title': 'Mummy ki dawa',
        'scheduledTimeMs': 1757000000000,
        'status': 'pending',
        'type': 'reminder',
        'subType': 'personal',
      });

      expect(alarm, isNotNull);
      expect(alarm!.whenMs, 1757000000000);
      expect(alarm.title, 'Mummy ki dawa');
      // Nothing to add, so the body carries the time rather than a filler
      // line repeating what the app icon already says.
      expect(alarm.body, matches(r'^\d{1,2}:\d{2} (AM|PM)$'));
      expect(alarm.subtitle, isNull);
    });

    test('falls back to scheduledAt when the ms field is missing', () {
      final at = DateTime(2026, 9, 10, 8);
      final alarm = ReminderAlarm.fromDoc('r2', {
        'title': 'Parents meeting',
        'scheduledAt': Timestamp.fromDate(at),
      });
      expect(alarm!.whenMs, at.millisecondsSinceEpoch);
    });

    test('puts the note in the body and the client in the subtitle', () {
      final alarm = ReminderAlarm.fromDoc('r3', {
        'title': 'Follow up',
        'note': 'Quotation 50000',
        'clientName': 'Rohan Traders',
        'scheduledTimeMs': 1757000000000,
      });
      // Note, then who it is about, then when — the headline is the task, so
      // the body must not repeat it.
      expect(alarm!.body, startsWith('Quotation 50000 · Rohan Traders · '));
      expect(alarm.subtitle, 'Rohan Traders');
    });

    test('uses the older message and description fields when that is all there is', () {
      final alarm = ReminderAlarm.fromDoc('r4', {
        'message': 'Call Rohan',
        'description': 'about the pending order',
        'scheduledTimeMs': 1757000000000,
      });
      expect(alarm!.title, 'Call Rohan');
      expect(alarm.body, startsWith('about the pending order · '));
    });

    test('refuses a reminder with no usable time', () {
      expect(
        ReminderAlarm.fromDoc('r5', {'title': 'Someday'}),
        isNull,
      );
      expect(
        ReminderAlarm.fromDoc('r6', {'title': 'x', 'scheduledTimeMs': 0}),
        isNull,
      );
    });

    test('still yields an alarm when the reminder has no title at all', () {
      final alarm = ReminderAlarm.fromDoc('r7', {
        'scheduledTimeMs': 1757000000000,
      });
      expect(alarm!.title, 'Reminder');
    });
  });
}
