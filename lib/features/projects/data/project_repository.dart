import 'package:cloud_firestore/cloud_firestore.dart';

import '../../structured_actions/utils/name_normalize.dart';
import '../models/project_models.dart';

/// `users/{uid}/projects` + `users/{uid}/project_items`.
class ProjectRepository {
  ProjectRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> _projects(String uid) =>
      _firestore.collection('users').doc(uid).collection('projects');

  CollectionReference<Map<String, dynamic>> _items(String uid) =>
      _firestore.collection('users').doc(uid).collection('project_items');

  Stream<List<ProjectRecord>> watchProjects(String uid, {int limit = 80}) {
    return _projects(uid)
        .orderBy('updatedAtMs', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (s) => s.docs
              .map((d) => ProjectRecord.fromMap(d.id, d.data()))
              .toList(),
        );
  }

  Stream<List<ProjectItemRecord>> watchOpenItems(String uid) {
    return _items(uid).limit(400).snapshots().map((s) {
      return s.docs
          .map((d) => ProjectItemRecord.fromMap(d.id, d.data()))
          .where((i) => i.isOpen)
          .toList();
    });
  }

  Stream<List<ProjectItemRecord>> watchItemsForProject(
    String uid,
    String projectId,
  ) {
    return _items(uid)
        .where('projectId', isEqualTo: projectId)
        .snapshots()
        .map(
          (s) {
            final list = s.docs
                .map((d) => ProjectItemRecord.fromMap(d.id, d.data()))
                .toList();
            list.sort((a, b) => a.title.compareTo(b.title));
            return list;
          },
        );
  }

  Future<ProjectRecord?> getProject(String uid, String id) async {
    final doc = await _projects(uid).doc(id).get();
    final data = doc.data();
    if (!doc.exists || data == null) {
      return null;
    }
    return ProjectRecord.fromMap(doc.id, data);
  }

  Future<ProjectRecord?> findByNameOrClient(String uid, String hint) async {
    final key = normalizeName(hint);
    if (key.isEmpty) {
      return null;
    }
    final snap = await _projects(uid).limit(80).get();
    final all = snap.docs.map((d) => ProjectRecord.fromMap(d.id, d.data()));
    for (final p in all) {
      if (normalizeName(p.name) == key || normalizeName(p.client) == key) {
        return p;
      }
    }
    for (final p in all) {
      final nk = normalizeName(p.name);
      final ck = normalizeName(p.client);
      if (nk.contains(key) || key.contains(nk) || ck.contains(key)) {
        return p;
      }
    }
    return null;
  }

  Future<ProjectRecord> createProject({
    required String uid,
    required String name,
    String client = '',
    String notes = '',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final ref = _projects(uid).doc();
    final trimmedName = name.trim().isEmpty ? 'Untitled' : name.trim();
    final trimmedClient = client.trim();
    await ref.set({
      'name': trimmedName,
      'nameKey': normalizeName(trimmedName),
      'client': trimmedClient,
      'clientKey': normalizeName(
        trimmedClient.isEmpty ? trimmedName : trimmedClient,
      ),
      'status': 'active',
      'notes': notes.trim(),
      'createdAt': FieldValue.serverTimestamp(),
      'createdAtMs': now,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedAtMs': now,
    });
    return ProjectRecord(
      id: ref.id,
      name: trimmedName,
      client: trimmedClient,
      status: 'active',
      notes: notes.trim(),
      createdAtMs: now,
      updatedAtMs: now,
    );
  }

  Future<List<ProjectItemRecord>> addItems({
    required String uid,
    required ProjectRecord project,
    required List<Map<String, dynamic>> items,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = _firestore.batch();
    final out = <ProjectItemRecord>[];
    for (final raw in items) {
      final ref = _items(uid).doc();
      final title = (raw['title'] as String? ?? '').trim();
      if (title.isEmpty) {
        continue;
      }
      final data = <String, dynamic>{
        'projectId': project.id,
        'projectName': project.name,
        'title': title,
        'description': (raw['description'] as String? ?? '').trim(),
        'kind': (raw['kind'] as String? ?? 'general').trim(),
        'status': (raw['status'] as String? ?? 'pending').trim(),
        'dueAtIso': raw['dueAtIso'],
        'dueAtMs': raw['dueAtMs'],
        'waitingOn': (raw['waitingOn'] as String? ?? '').trim(),
        'notes': (raw['notes'] as String? ?? '').trim(),
        'reminderId': null,
        'createdAt': FieldValue.serverTimestamp(),
        'createdAtMs': now,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedAtMs': now,
      };
      batch.set(ref, data);
      out.add(ProjectItemRecord.fromMap(ref.id, data));
    }
    batch.update(_projects(uid).doc(project.id), {
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedAtMs': now,
    });
    await batch.commit();
    return out;
  }

  Future<void> setItemReminderId({
    required String uid,
    required String itemId,
    required String reminderId,
  }) async {
    await _items(uid).doc(itemId).update({
      'reminderId': reminderId,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> updateItemStatus({
    required String uid,
    required String itemId,
    required String status,
  }) async {
    await _items(uid).doc(itemId).update({
      'status': status,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
    });
  }
}
