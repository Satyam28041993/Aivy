import 'package:flutter/foundation.dart';

/// A project or a task, as the app reads it.
///
/// The two are one shape in Firestore and one shape here. `isTask` decides how
/// it is drawn and nothing else — a task is a project with a deadline on the
/// whole thing and fewer parts inside it.
@immutable
class ProjectRecord {
  const ProjectRecord({
    required this.id,
    required this.name,
    required this.forWhom,
    required this.status,
    required this.isTask,
    required this.isPersonal,
    required this.note,
    required this.dueMs,
    required this.updatedAtMs,
  });

  final String id;
  final String name;

  /// The client on a project, whoever asked on a task. Empty when nobody did.
  final String forWhom;
  final String status;
  final bool isTask;
  final bool isPersonal;
  final String note;

  /// 0 when there is no deadline on the whole thing.
  final int dueMs;
  final int updatedAtMs;

  bool get isLive => status == 'active' || status == 'on_hold';

  static String _text(Object? v) => (v as String?)?.trim() ?? '';
  static int _ms(Object? v) {
    final n = (v as num?)?.toInt() ?? 0;
    return n > 0 ? n : 0;
  }

  static ProjectRecord fromMap(String id, Map<String, dynamic> m) {
    return ProjectRecord(
      id: id,
      name: _text(m['name']),
      forWhom: _text(m['clientName']),
      status: _text(m['status']).isEmpty ? 'active' : _text(m['status']),
      // Docs written before tasks existed carry no 'kind', and every one of
      // them is a project.
      isTask: _text(m['kind']) == 'task',
      isPersonal: _text(m['area']) == 'personal',
      note: _text(m['note']),
      dueMs: _ms(m['dueMs']),
      updatedAtMs: _ms(m['updatedAtMs']),
    );
  }
}

/// One piece of work inside a project or task.
@immutable
class ProjectItemRecord {
  const ProjectItemRecord({
    required this.id,
    required this.title,
    required this.kind,
    required this.status,
    required this.note,
    required this.dueMs,
    required this.createdAtMs,
  });

  final String id;
  final String title;
  final String kind;

  /// 'open' | 'waiting_on_them' | 'done' | 'dropped'
  final String status;
  final String note;
  final int dueMs;
  final int createdAtMs;

  bool get isLive => status == 'open' || status == 'waiting_on_them';

  /// The wording used on cards and in Aivy's answers, kept the same here so a
  /// screen and a reply never describe the same item differently.
  String get statusLabel {
    switch (status) {
      case 'waiting_on_them':
        return 'Waiting on them';
      case 'done':
        return 'Done';
      case 'dropped':
        return 'Dropped';
      default:
        return 'Open';
    }
  }

  static ProjectItemRecord fromMap(String id, Map<String, dynamic> m) {
    return ProjectItemRecord(
      id: id,
      title: ProjectRecord._text(m['title']),
      kind: ProjectRecord._text(m['kind']),
      status: ProjectRecord._text(m['status']).isEmpty
          ? 'open'
          : ProjectRecord._text(m['status']),
      note: ProjectRecord._text(m['note']),
      dueMs: ProjectRecord._ms(m['dueMs']),
      createdAtMs: ProjectRecord._ms(m['createdAtMs']),
    );
  }
}

/// One line of history — what was changed, and when.
@immutable
class ProjectEventRecord {
  const ProjectEventRecord({
    required this.id,
    required this.atMs,
    required this.kind,
    required this.text,
  });

  final String id;
  final int atMs;
  final String kind;
  final String text;

  static ProjectEventRecord? fromMap(String id, Map<String, dynamic> m) {
    final text = ProjectRecord._text(m['text']);
    final atMs = ProjectRecord._ms(m['atMs']);
    if (text.isEmpty || atMs == 0) {
      return null;
    }
    return ProjectEventRecord(
      id: id,
      atMs: atMs,
      kind: ProjectRecord._text(m['kind']),
      text: text,
    );
  }
}

/// Everything one detail view needs, fetched together.
@immutable
class ProjectDetail {
  const ProjectDetail({
    required this.project,
    required this.items,
    required this.events,
  });

  final ProjectRecord project;
  final List<ProjectItemRecord> items;
  final List<ProjectEventRecord> events;

  List<ProjectItemRecord> get open =>
      items.where((i) => i.status == 'open').toList();
  List<ProjectItemRecord> get waiting =>
      items.where((i) => i.status == 'waiting_on_them').toList();
  List<ProjectItemRecord> get done =>
      items.where((i) => i.status == 'done').toList();
}

/// One project or task as the browse list needs it: the record plus the counts
/// that decide what it says and where it sorts.
///
/// The counts come from its items, which means one read per project. That is
/// affordable for a list somebody opens on purpose, and the alternative —
/// keeping running totals on the project document — is a second copy of the
/// truth that goes wrong the first time a write half-fails.
@immutable
class ProjectSummary {
  const ProjectSummary({
    required this.project,
    required this.open,
    required this.waiting,
    required this.done,
    required this.overdue,
    required this.nextDueMs,
  });

  final ProjectRecord project;
  final int open;
  final int waiting;
  final int done;
  final int overdue;

  /// Soonest date still owed — the project's own deadline when it is a task,
  /// otherwise the earliest date on anything still live in it. 0 for neither.
  final int nextDueMs;

  int get total => open + waiting + done;
  int get live => open + waiting;

  static ProjectSummary from(
    ProjectRecord project,
    List<ProjectItemRecord> items, {
    DateTime? now,
  }) {
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final live = items.where((i) => i.isLive).toList();
    final dates = <int>[
      if (project.dueMs > 0) project.dueMs,
      ...live.where((i) => i.dueMs > 0).map((i) => i.dueMs),
    ]..sort();

    return ProjectSummary(
      project: project,
      open: items.where((i) => i.status == 'open').length,
      waiting: items.where((i) => i.status == 'waiting_on_them').length,
      done: items.where((i) => i.status == 'done').length,
      overdue: [
        if (project.dueMs > 0 && project.dueMs < nowMs) 1,
        ...live.where((i) => i.dueMs > 0 && i.dueMs < nowMs).map((_) => 1),
      ].length,
      nextDueMs: dates.isEmpty ? 0 : dates.first,
    );
  }

  /// The line under the name. Says the fewest true things that answer "where is
  /// this", and says "all clear" rather than nothing when there is no work left.
  String subtitle({DateTime? now}) {
    final parts = <String>[
      if (project.forWhom.isNotEmpty) project.forWhom,
      if (overdue > 0)
        overdue == 1 ? '1 late' : '$overdue late'
      else if (nextDueMs > 0)
        _dueWord(nextDueMs, now: now),
      if (open > 0) '$open pending',
      if (waiting > 0) '$waiting waiting on them',
    ];
    if (parts.isEmpty || (open == 0 && waiting == 0 && overdue == 0)) {
      parts.add(done > 0 ? 'all clear' : 'nothing in it yet');
    }
    return parts.join(' · ');
  }

  static String _dueWord(int dueMs, {DateTime? now}) {
    final today = now ?? DateTime.now();
    final start = DateTime(today.year, today.month, today.day);
    final due = DateTime.fromMillisecondsSinceEpoch(dueMs);
    final days = DateTime(due.year, due.month, due.day).difference(start).inDays;
    if (days <= 0) return 'due today';
    if (days == 1) return 'due tomorrow';
    return 'due ${due.day} ${_months[due.month - 1]}';
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
}
