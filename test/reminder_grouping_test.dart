import 'package:aivy/features/reminders/models/reminder_item.dart';
import 'package:aivy/features/reminders/utils/reminder_grouping.dart';
import 'package:flutter_test/flutter_test.dart';

ReminderItem _r(String id, int ms, {String status = 'pending'}) {
  return ReminderItem(
    id: id,
    title: 't',
    description: '',
    client: '',
    type: 'task',
    message: '',
    scheduledTimeMs: ms,
    dueDateMs: ms,
    status: status,
    createdAtMs: 0,
  );
}

void main() {
  test('partition buckets overdue / today / tomorrow / upcoming', () {
    final now = DateTime(2026, 4, 28, 14, 0);
    final startToday = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final tomorrowMid = DateTime(now.year, now.month, now.day)
        .add(const Duration(days: 1))
        .millisecondsSinceEpoch +
        10 * Duration.millisecondsPerHour;
    final dayAfter = DateTime(now.year, now.month, now.day)
        .add(const Duration(days: 2))
        .millisecondsSinceEpoch +
        9 * Duration.millisecondsPerHour;

    final overdueMs = startToday + 2 * 3600000; // today morning — before now
    final lists = ReminderGrouping.partition(
      [
        _r('o', overdueMs),
        _r('t', startToday + 20 * 3600000), // later today
        _r('m', tomorrowMid),
        _r('u', dayAfter),
      ],
      now,
    );

    expect(lists.overdue.length, 1);
    expect(lists.today.length, 1);
    expect(lists.tomorrow.length, 1);
    expect(lists.upcoming.length, 1);
  });

  test('sorting preserves chronological order within buckets', () {
    final now = DateTime(2026, 4, 28, 12, 0);
    final t1 = DateTime(now.year, now.month, now.day, 18, 0).millisecondsSinceEpoch;
    final t2 = DateTime(now.year, now.month, now.day, 20, 0).millisecondsSinceEpoch;
    final lists = ReminderGrouping.partition(
      [_r('b', t2), _r('a', t1)],
      now,
    );
    expect(lists.today.map((e) => e.id).toList(), ['a', 'b']);
  });

  test(
    'buildReportSections splits upcoming into per-day bands and fold states',
    () {
      final now = DateTime(2026, 4, 28, 14, 0);
      final day0 = DateTime(2026, 4, 28);
      final day1 = day0.add(const Duration(days: 1));
      final day2 = day0.add(const Duration(days: 2));
      final day3 = day0.add(const Duration(days: 3));

      final overdueMs = day0.millisecondsSinceEpoch + 2 * 3600000;
      final todayMs =
          day0.millisecondsSinceEpoch + 20 * Duration.millisecondsPerHour;
      final tomorrowMs =
          day1.millisecondsSinceEpoch + 10 * Duration.millisecondsPerHour;
      final plus2Ms =
          day2.millisecondsSinceEpoch + 9 * Duration.millisecondsPerHour;
      final plus3aMs =
          day3.millisecondsSinceEpoch + 10 * Duration.millisecondsPerHour;
      final plus3bMs =
          day3.millisecondsSinceEpoch + 14 * Duration.millisecondsPerHour;

      final buckets = ReminderGrouping.partition(
        [
          _r('overdue_r', overdueMs),
          _r('today_r', todayMs),
          _r('tom_r', tomorrowMs),
          _r('d2_a', plus2Ms),
          _r('d3_a', plus3aMs),
          _r('d3_b', plus3bMs),
        ],
        now,
      );

      final sections = ReminderGrouping.buildReportSections(buckets, now);

      expect(sections.map((s) => s.sectionId).toList(), [
        'overdue',
        'today',
        'tomorrow',
        'day:2026-04-30',
        'day:2026-05-01',
      ]);
      ReminderReportSection sec(String id) =>
          sections.firstWhere((s) => s.sectionId == id);

      expect(sections.first.initiallyExpanded, true);
      expect(sec('today').initiallyExpanded, true);
      expect(sec('tomorrow').initiallyExpanded, true);
      expect(sec('day:2026-04-30').initiallyExpanded, true);
      expect(sec('day:2026-05-01').initiallyExpanded, false);

      expect(
        sec('day:2026-05-01').items.map((e) => e.id).toList(),
        ['d3_a', 'd3_b'],
      );
    },
  );
}
