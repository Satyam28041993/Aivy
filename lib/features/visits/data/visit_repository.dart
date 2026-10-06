import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/visit_record.dart';

/// Reads client visits — the DSR — from `users/{userId}/visits/*`, and the
/// DSR Google Sheet's address from `users/{userId}/meta/dsr`.
///
/// Read-only on purpose, like the other record screens: a visit is recorded by
/// telling Aivy, which is the path that also writes the sheet row and offers
/// the follow-up.
class VisitRepository {
  VisitRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> _col(String userId) {
    return _firestore.collection('users').doc(userId).collection('visits');
  }

  /// Newest first. 500 covers well over a year of visits for one person.
  Stream<List<VisitRecord>> watchVisits(String userId, {int limit = 500}) {
    return _col(userId)
        .orderBy('visitDateMs', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => VisitRecord.fromMap(d.id, d.data()))
              .where((v) => v.clientName.isNotEmpty)
              .toList(),
        );
  }

  /// The DSR sheet, once the first visit has been copied to it.
  Stream<DsrSheet?> watchSheet(String userId) {
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('meta')
        .doc('dsr')
        .snapshots()
        .map((snap) {
      final data = snap.data();
      final id = (data?['spreadsheetId'] ?? '').toString();
      if (id.isEmpty) {
        return null;
      }
      final url = (data?['url'] ?? '').toString();
      return DsrSheet(spreadsheetId: id, url: url);
    });
  }
}
