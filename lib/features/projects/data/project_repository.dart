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

  DocumentReference<Map<String, dynamic>> _doc(String userId, String projectId) {
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('projects')
        .doc(projectId);
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
