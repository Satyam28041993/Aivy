import '../models/task_item.dart';

/// Pure function calculator that turns a [TaskItem] into a dynamic
/// `priorityScore` used to rank the dashboard's "Focus Now" list.
///
/// The score is recomputed on demand (never persisted) so it always reflects
/// the current wall-clock time: a task that was merely "due today" at 9am
/// becomes "overdue" by midnight without any Firestore writes.
///
/// The weighting, from most to least impactful:
///   * Overdue tasks dominate (lateness keeps growing).
///   * Due-today gets a strong boost.
///   * Category weight nudges client > work > personal > general.
///   * Stored priority (high/medium/low) adds a smaller lift.
///   * Age-since-created adds a small urgency tick so stale tasks float up.
class TaskPriorityCalculator {
  const TaskPriorityCalculator._();

  static const double _overdueBase = 1000;
  static const double _overduePerDay = 120;
  static const double _dueTodayBase = 500;
  static const double _dueSoonBase = 200;
  static const double _ageCapDays = 14;
  static const double _agePerDay = 8;

  static const Map<String, double> _categoryWeight = {
    'client': 180,
    'work': 120,
    'personal': 70,
    'general': 30,
  };

  static const Map<String, double> _priorityWeight = {
    'high': 150,
    'medium': 60,
    'low': 15,
  };

  /// Computes a score for [task] given the current time [now]. Higher means
  /// more urgent. Callers should sort descending.
  static double scoreOf(TaskItem task, {DateTime? now}) {
    final reference = now ?? DateTime.now();
    final startOfToday =
        DateTime(reference.year, reference.month, reference.day);
    final startOfTomorrow = startOfToday.add(const Duration(days: 1));

    var score = 0.0;

    final categoryWeight =
        _categoryWeight[task.category.toLowerCase()] ?? _categoryWeight['general']!;
    score += categoryWeight;

    final priorityWeight =
        _priorityWeight[task.priority.toLowerCase()] ?? _priorityWeight['medium']!;
    score += priorityWeight;

    final ageDays = ((reference.millisecondsSinceEpoch - task.createdAtMs) /
            Duration.millisecondsPerDay)
        .clamp(0, _ageCapDays)
        .toDouble();
    score += ageDays * _agePerDay;

    final dueMs = task.dueDateMs;
    if (dueMs != null) {
      final due = DateTime.fromMillisecondsSinceEpoch(dueMs);
      if (due.isBefore(startOfToday)) {
        final overdueDays = startOfToday.difference(due).inDays + 1;
        score += _overdueBase + overdueDays * _overduePerDay;
      } else if (due.isBefore(startOfTomorrow)) {
        score += _dueTodayBase;
      } else {
        final hoursAway = due.difference(reference).inHours;
        if (hoursAway <= 48) {
          score += _dueSoonBase - hoursAway;
        }
      }
    }

    return score;
  }

  /// Returns a copy of [tasks] ordered by descending priority score.
  static List<TaskItem> sortedByPriority(
    List<TaskItem> tasks, {
    DateTime? now,
  }) {
    final reference = now ?? DateTime.now();
    final scored = tasks
        .map((task) => _ScoredTask(task, scoreOf(task, now: reference)))
        .toList(growable: false)
      ..sort((a, b) => b.score.compareTo(a.score));
    return scored.map((entry) => entry.task).toList(growable: false);
  }

  /// Picks the [count] highest-priority tasks for the "Focus Now" panel.
  static List<TaskItem> topFocusTasks(
    List<TaskItem> tasks, {
    int count = 3,
    DateTime? now,
  }) {
    if (tasks.isEmpty || count <= 0) {
      return const [];
    }
    final sorted = sortedByPriority(tasks, now: now);
    return sorted.take(count).toList(growable: false);
  }
}

class _ScoredTask {
  const _ScoredTask(this.task, this.score);
  final TaskItem task;
  final double score;
}
