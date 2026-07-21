import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/task_priority_calculator.dart';

class TaskItem {
  const TaskItem({
    required this.id,
    required this.title,
    required this.sourceEntryId,
    required this.createdAtMs,
    required this.status,
    required this.priority,
    required this.category,
    this.dueDateMs,
  });

  final String id;
  final String title;
  final String sourceEntryId;
  final int createdAtMs;
  final int? dueDateMs;
  final String status;
  final String priority;

  /// Tag inherited from the source entry so the dashboard can filter
  /// ("client only", etc.). One of `client`, `work`, `personal`, `general`.
  final String category;

  /// Computed, never persisted. Ranks this task against its peers for the
  /// dashboard "Focus Now" list. Callers pass [now] to keep the score
  /// consistent across a batch when sorting many tasks together.
  double priorityScore({DateTime? now}) =>
      TaskPriorityCalculator.scoreOf(this, now: now);

  /// Convenience flag used by UI code to pick an accent color.
  bool isOverdue({DateTime? now}) {
    final due = dueDateMs;
    if (due == null) {
      return false;
    }
    final reference = now ?? DateTime.now();
    final startOfToday =
        DateTime(reference.year, reference.month, reference.day);
    return DateTime.fromMillisecondsSinceEpoch(due).isBefore(startOfToday);
  }

  bool isDueToday({DateTime? now}) {
    final due = dueDateMs;
    if (due == null) {
      return false;
    }
    final reference = now ?? DateTime.now();
    final startOfToday =
        DateTime(reference.year, reference.month, reference.day);
    final startOfTomorrow = startOfToday.add(const Duration(days: 1));
    final dueDate = DateTime.fromMillisecondsSinceEpoch(due);
    return !dueDate.isBefore(startOfToday) && dueDate.isBefore(startOfTomorrow);
  }

  factory TaskItem.fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    return TaskItem(
      id: doc.id,
      title: data['title'] as String? ?? '',
      sourceEntryId: data['sourceEntryId'] as String? ?? '',
      createdAtMs: (data['createdAtMs'] as num?)?.toInt() ?? 0,
      dueDateMs: (data['dueDateMs'] as num?)?.toInt(),
      status: data['status'] as String? ?? 'pending',
      priority: data['priority'] as String? ?? 'medium',
      category: _normalizeCategory(data['category'] as String?),
    );
  }

  static String _normalizeCategory(String? raw) {
    final lowered = (raw ?? '').trim().toLowerCase();
    const valid = {'client', 'work', 'personal', 'general'};
    if (valid.contains(lowered)) {
      return lowered;
    }
    return 'general';
  }
}
