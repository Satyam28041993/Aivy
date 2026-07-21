import 'package:aivy/features/reminders/utils/reminder_time_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final ref = DateTime(2026, 4, 28, 12, 0);

  test('kal 10 → tomorrow at 10:00 local', () {
    final dt = ReminderTimeParser.resolveScheduledTimeFromPlainText(
      'kal 10',
      reference: ref,
    );
    expect(dt, isNotNull);
    expect(dt!.hour, 10);
    expect(dt.day, 29);
  });

  test('kal 6 baje → resolved clock (ambiguous evening preference)', () {
    final dt = ReminderTimeParser.resolveScheduledTimeFromPlainText(
      'kal 6 baje',
      reference: ref,
    );
    expect(dt, isNotNull);
    expect(dt!.hour, 18);
  });

  test('kal subah uses morning default hour', () {
    final dt = ReminderTimeParser.resolveScheduledTimeFromPlainText(
      'kal subah',
      reference: ref,
    );
    expect(dt, isNotNull);
    expect(dt!.hour, 9);
  });

  test('tryParse flow step subah / lone digit', () {
    expect(
      ReminderTimeParser.tryParseTimeMinutesForFlowStep('subah'),
      9 * 60,
    );
    expect(
      ReminderTimeParser.tryParseTimeMinutesForFlowStep('shaam'),
      18 * 60,
    );
    expect(
      ReminderTimeParser.tryParseTimeMinutesForFlowStep('10'),
      10 * 60,
    );
  });
}
