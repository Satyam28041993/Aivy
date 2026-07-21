import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import '../models/reminder_item.dart';

/// One collapsible band in Reports: overdue, today, tomorrow, or a future date.
///
/// [initiallyExpanded] is true for overdue and for today through the calendar
/// day that is **two days after** "today"; later dates start collapsed.
class ReminderReportSection {
  const ReminderReportSection({
    required this.sectionId,
    required this.title,
    required this.items,
    required this.initiallyExpanded,
  });

  /// Stable key for widget state (`overdue`, `today`, `tomorrow`, `day:yyyy-mm-dd`).
  final String sectionId;
  final String title;
  final List<ReminderItem> items;
  final bool initiallyExpanded;
}

/// Pending reminders partitioned for dashboard display (local calendar).
///
/// Query supplies sorted-by-[scheduledTimeMs] rows; grouping happens here only.
class ReminderGroupBuckets {
  const ReminderGroupBuckets({
    required this.overdue,
    required this.today,
    required this.tomorrow,
    required this.upcoming,
  });

  final List<ReminderItem> overdue;
  final List<ReminderItem> today;
  final List<ReminderItem> tomorrow;
  final List<ReminderItem> upcoming;

  bool get isEmpty =>
      overdue.isEmpty &&
      today.isEmpty &&
      tomorrow.isEmpty &&
      upcoming.isEmpty;
}

/// Groups **pending** reminders using [DateTime.now()]-relative boundaries.
///
/// - **Overdue**: `scheduledTime < now`
/// - **Today**: same calendar day as [now], and `scheduledTime >= now`
/// - **Tomorrow**: calendar day is tomorrow (any time that day)
/// - **Upcoming**: calendar day ≥ day after tomorrow
class ReminderGrouping {
  ReminderGrouping._();

  static DateTime _startOfDay(DateTime d) =>
      DateTime(d.year, d.month, d.day);

  static ReminderGroupBuckets partition(
    List<ReminderItem> reminders,
    DateTime now,
  ) {
    final nowMs = now.millisecondsSinceEpoch;
    final startToday = _startOfDay(now);
    final startTomorrow = startToday.add(const Duration(days: 1));
    final startDayAfter = startTomorrow.add(const Duration(days: 1));

    final overdue = <ReminderItem>[];
    final today = <ReminderItem>[];
    final tomorrow = <ReminderItem>[];
    final upcoming = <ReminderItem>[];

    final sorted = List<ReminderItem>.from(reminders)
      ..sort((a, b) => a.scheduledTimeMs.compareTo(b.scheduledTimeMs));

    for (final r in sorted) {
      if (r.status != 'pending') {
        continue;
      }
      final ms = r.scheduledTimeMs;
      final dt = DateTime.fromMillisecondsSinceEpoch(ms);
      final dayStart = _startOfDay(dt);

      if (ms < nowMs) {
        overdue.add(r);
      } else if (dayStart == startToday) {
        today.add(r);
      } else if (dayStart == startTomorrow) {
        tomorrow.add(r);
      } else if (!dayStart.isBefore(startDayAfter)) {
        upcoming.add(r);
      }
    }

    debugPrint(
      'AIVY_REMINDER_GROUPING: overdue=${overdue.length} today=${today.length} '
      'tomorrow=${tomorrow.length} upcoming=${upcoming.length}',
    );

    return ReminderGroupBuckets(
      overdue: overdue,
      today: today,
      tomorrow: tomorrow,
      upcoming: upcoming,
    );
  }

  /// Builds ordered sections for the Reports reminders accordion: every pending
  /// reminder appears once; **upcoming** is split by calendar day.
  static List<ReminderReportSection> buildReportSections(
    ReminderGroupBuckets buckets,
    DateTime now,
  ) {
    final startToday = _startOfDay(now);

    bool initiallyExpandedForDay(DateTime dayStart) {
      final offset = dayStart.difference(startToday).inDays;
      return offset >= 0 && offset <= 2;
    }

    String formatDayHeading(DateTime day) =>
        DateFormat('EEE, d MMM yyyy').format(day);

    void sortByTime(List<ReminderItem> list) {
      list.sort((a, b) => a.scheduledTimeMs.compareTo(b.scheduledTimeMs));
    }

    final out = <ReminderReportSection>[];

    if (buckets.overdue.isNotEmpty) {
      final items = List<ReminderItem>.from(buckets.overdue);
      sortByTime(items);
      out.add(
        ReminderReportSection(
          sectionId: 'overdue',
          title: 'Overdue',
          items: items,
          initiallyExpanded: true,
        ),
      );
    }

    if (buckets.today.isNotEmpty) {
      final items = List<ReminderItem>.from(buckets.today);
      sortByTime(items);
      out.add(
        ReminderReportSection(
          sectionId: 'today',
          title: 'Today · ${formatDayHeading(startToday)}',
          items: items,
          initiallyExpanded: initiallyExpandedForDay(startToday),
        ),
      );
    }

    final startTomorrow = startToday.add(const Duration(days: 1));
    if (buckets.tomorrow.isNotEmpty) {
      final items = List<ReminderItem>.from(buckets.tomorrow);
      sortByTime(items);
      out.add(
        ReminderReportSection(
          sectionId: 'tomorrow',
          title: 'Tomorrow · ${formatDayHeading(startTomorrow)}',
          items: items,
          initiallyExpanded: initiallyExpandedForDay(startTomorrow),
        ),
      );
    }

    final byDay = <DateTime, List<ReminderItem>>{};
    for (final r in buckets.upcoming) {
      final dt = DateTime.fromMillisecondsSinceEpoch(r.scheduledTimeMs);
      final day = _startOfDay(dt);
      byDay.putIfAbsent(day, () => <ReminderItem>[]).add(r);
    }
    final days = byDay.keys.toList()..sort();
    for (final day in days) {
      final items = byDay[day] ?? const [];
      if (items.isEmpty) {
        continue;
      }
      final list = List<ReminderItem>.from(items);
      sortByTime(list);
      final y = day.year.toString().padLeft(4, '0');
      final m = day.month.toString().padLeft(2, '0');
      final d = day.day.toString().padLeft(2, '0');
      out.add(
        ReminderReportSection(
          sectionId: 'day:$y-$m-$d',
          title: formatDayHeading(day),
          items: list,
          initiallyExpanded: initiallyExpandedForDay(day),
        ),
      );
    }

    debugPrint(
      'AIVY_REMINDER_SECTIONS: count=${out.length} '
      'totalItems=${out.fold<int>(0, (s, e) => s + e.items.length)}',
    );

    return out;
  }
}
