import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/project_models.dart';

/// Reads projects and tasks: `users/{userId}/projects/*`.
///
/// Read-only on purpose. Creating and editing happen by talking to Aivy, and
/// giving the screen its own write path would mean the same data could be
/// half-written two different ways — one of them without the reminders, the
/// draft card, or the history line that every change through Aivy produces.
class ProjectRepository {
  ProjectRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> _col(String userId) {
    return _firestore.collection('users').doc(userId).collection('projects');
  }

  DocumentReference<Map<String, dynamic>> _doc(String userId, String projectId) {
    return _col(userId).doc(projectId);
  }

  /// Every project and task, with the counts the browse list shows.
  ///
  /// One read for the list and one per project for its items. That is the
  /// honest cost of counts that are always right; keeping running totals on the
  /// project document would be a second copy of the truth, and the first
  /// half-failed write would leave the two disagreeing with nothing to say so.
  Future<List<ProjectSummary>> summaries(String userId, {int limit = 60}) async {
    final snap = await _col(userId).limit(limit).get();
    final projects = snap.docs
        .map((d) => ProjectRecord.fromMap(d.id, d.data()))
        .where((p) => p.name.isNotEmpty)
        .toList();

    final built = await Future.wait(
      projects.map((p) async {
        List<ProjectItemRecord> items = const [];
        try {
          final itemSnap = await _doc(userId, p.id).collection('items').limit(200).get();
          items = itemSnap.docs
              .map((d) => ProjectItemRecord.fromMap(d.id, d.data()))
              .where((i) => i.title.isNotEmpty)
              .toList();
        } catch (_) {
          // One unreadable project should cost its counts, not the whole list.
        }
        return ProjectSummary.from(p, items);
      }),
    );

    // Late first, then soonest, then whatever was touched most recently — the
    // undated work has no other order worth having.
    built.sort((a, b) {
      if (a.overdue != b.overdue) return b.overdue.compareTo(a.overdue);
      if (a.nextDueMs > 0 && b.nextDueMs > 0) {
        return a.nextDueMs.compareTo(b.nextDueMs);
      }
      if (a.nextDueMs > 0) return -1;
      if (b.nextDueMs > 0) return 1;
      return b.project.updatedAtMs.compareTo(a.project.updatedAtMs);
    });
    return built;
  }

  /// One project or task with its items and its history.
  ///
  /// The three reads go together because the detail view is useless without
  /// all three, and running them in parallel keeps the sheet from opening in
  /// three visible stages.
  Future<ProjectDetail?> detail(String userId, String projectId) async {
    final ref = _doc(userId, projectId);
    final results = await Future.wait<Object?>([
      ref.get(),
      ref.collection('items').limit(200).get(),
      ref.collection('events').limit(200).get(),
    ]);

    final snap = results[0] as DocumentSnapshot<Map<String, dynamic>>;
    final data = snap.data();
    if (!snap.exists || data == null) {
      return null;
    }

    final itemDocs = (results[1] as QuerySnapshot<Map<String, dynamic>>).docs;
    final items = itemDocs
        .map((d) => ProjectItemRecord.fromMap(d.id, d.data()))
        .where((i) => i.title.isNotEmpty)
        .toList()
      // Dated work first and soonest first, then the undated in the order it
      // was added — the same order Aivy speaks them in.
      ..sort((a, b) {
        if (a.dueMs > 0 && b.dueMs > 0) return a.dueMs.compareTo(b.dueMs);
        if (a.dueMs > 0) return -1;
        if (b.dueMs > 0) return 1;
        return a.createdAtMs.compareTo(b.createdAtMs);
      });

    final eventDocs = (results[2] as QuerySnapshot<Map<String, dynamic>>).docs;
    final events = eventDocs
        .map((d) => ProjectEventRecord.fromMap(d.id, d.data()))
        .whereType<ProjectEventRecord>()
        .toList()
      // Newest first: you already know how it ends, you are looking for when
      // something changed.
      ..sort((a, b) => b.atMs.compareTo(a.atMs));

    return ProjectDetail(
      project: ProjectRecord.fromMap(snap.id, data),
      items: items,
      events: events,
    );
  }
}
