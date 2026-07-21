import '../../reminders/models/reminder_item.dart';
import '../../tasks/models/task_item.dart';
import '../../tasks/utils/task_priority_calculator.dart';

/// Proactive, at-a-glance view of the user's day.
///
/// Produced by [AgentNudgeService] on app launch and re-derived by the
/// dashboard from live streams. The numbers drive the top banner / "Focus
/// Now" nudge so the user immediately knows what needs attention.
class AgentInsights {
  const AgentInsights({
    required this.pendingTaskCount,
    required this.overdueReminderCount,
    required this.overdueTaskCount,
    required this.dueTodayTaskCount,
    required this.focusTasks,
    required this.generatedAt,
  });

  final int pendingTaskCount;
  final int overdueReminderCount;
  final int overdueTaskCount;
  final int dueTodayTaskCount;

  /// Top priority tasks ("Do this now") sorted by [TaskPriorityCalculator].
  final List<TaskItem> focusTasks;
  final DateTime generatedAt;

  /// Total count of items that need user action right now. Used to craft
  /// the passive nudge notification body.
  int get pendingActionCount =>
      overdueTaskCount + overdueReminderCount + dueTodayTaskCount;

  /// Whether the user has anything that would make a nudge banner useful.
  bool get hasAnythingToNudgeAbout =>
      pendingTaskCount > 0 ||
      overdueReminderCount > 0 ||
      overdueTaskCount > 0 ||
      dueTodayTaskCount > 0;

  /// Short one-liner shown in the dashboard banner, e.g.
  /// "You have 5 pending tasks and 2 overdue reminders".
  String get bannerMessage {
    if (!hasAnythingToNudgeAbout) {
      return 'You\'re all caught up. Nice work.';
    }

    final parts = <String>[];
    parts.add(_pluralize(pendingTaskCount, 'pending task', 'pending tasks'));
    parts.add(
      _pluralize(overdueReminderCount, 'overdue reminder', 'overdue reminders'),
    );

    return 'You have ${parts[0]} and ${parts[1]}.';
  }

  /// Optional secondary line that highlights the most urgent focus area.
  String? get focusHint {
    if (overdueTaskCount > 0) {
      return '$overdueTaskCount ${overdueTaskCount == 1 ? 'task is' : 'tasks are'} overdue. Tap "Focus Now" to zero in on today.';
    }
    if (dueTodayTaskCount > 0) {
      return '$dueTodayTaskCount ${dueTodayTaskCount == 1 ? 'task is' : 'tasks are'} due today.';
    }
    return null;
  }

  /// Builds insights from the raw domain objects. Keeping this logic out of
  /// the widget layer makes it testable and lets both the launch-time
  /// one-shot fetch and the live stream reuse the same math.
  factory AgentInsights.fromData({
    required List<TaskItem> pendingTasks,
    required List<ReminderItem> overdueReminders,
    DateTime? reference,
  }) {
    final now = reference ?? DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    final startOfTomorrow = startOfToday.add(const Duration(days: 1));

    var overdueTaskCount = 0;
    var dueTodayTaskCount = 0;
    for (final task in pendingTasks) {
      final dueMs = task.dueDateMs;
      if (dueMs == null) {
        continue;
      }
      final due = DateTime.fromMillisecondsSinceEpoch(dueMs);
      if (due.isBefore(startOfToday)) {
        overdueTaskCount += 1;
      } else if (due.isBefore(startOfTomorrow)) {
        dueTodayTaskCount += 1;
      }
    }

    final focus = TaskPriorityCalculator.topFocusTasks(
      pendingTasks,
      count: 3,
      now: now,
    );

    return AgentInsights(
      pendingTaskCount: pendingTasks.length,
      overdueReminderCount: overdueReminders.length,
      overdueTaskCount: overdueTaskCount,
      dueTodayTaskCount: dueTodayTaskCount,
      focusTasks: focus,
      generatedAt: now,
    );
  }

  static String _pluralize(int count, String singular, String plural) {
    return '$count ${count == 1 ? singular : plural}';
  }
}
