import 'package:aivy/core/voice/gemini_live/aivy_business_snapshot_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('reminderKind', () {
    test('detects call reminders', () {
      expect(reminderKind({'type': 'call', 'title': 'Call Rahul'}), 'call');
      expect(reminderKind({'title': 'Rahul ko call karna hai'}), 'call');
    });

    test('detects follow-up reminders', () {
      expect(reminderKind({'type': 'followup'}), 'follow_up');
      expect(reminderKind({'title': 'Payment follow up'}), 'follow_up');
    });

    test('detects meeting reminders', () {
      expect(reminderKind({'type': 'meeting'}), 'meeting');
    });

    test('defaults to reminder', () {
      expect(reminderKind({'title': 'Send invoice'}), 'reminder');
    });
  });

  group('readReminderScheduledMs', () {
    test('prefers scheduledTimeMs', () {
      expect(
        readReminderScheduledMs({'scheduledTimeMs': 1000, 'remindAt': 2000}),
        1000,
      );
    });

    test('falls back to remindAt', () {
      expect(readReminderScheduledMs({'remindAt': 2000}), 2000);
    });

    test('returns 0 when missing', () {
      expect(readReminderScheduledMs({}), 0);
    });
  });

  group('AivyBusinessTimeContext', () {
    test('computes today boundaries', () {
      final now = DateTime(2026, 7, 22, 15, 30);
      final ctx = AivyBusinessTimeContext(timezone: 'Asia/Kolkata', now: now);
      expect(ctx.startOfTodayMs, DateTime(2026, 7, 22).millisecondsSinceEpoch);
      expect(ctx.endOfTodayMs, DateTime(2026, 7, 22, 23, 59, 59, 999).millisecondsSinceEpoch);
      expect(
        ctx.startOfTomorrowMs,
        DateTime(2026, 7, 23).millisecondsSinceEpoch,
      );
    });
  });
}
